import AppKit
import Observation
import SwiftUI

@main
enum AGYSwitcherEntry {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == UpdateInstaller.installArgument {
            UpdateInstaller.finish(arguments: Array(CommandLine.arguments.dropFirst(2)))
            return
        }
        AGYSwitcherApp.main()
    }
}

struct AGYSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        accountsWindow
    }

    private var accountsWindow: some Scene {
        let open = openWindow
        let delegate = appDelegate
        // Bind the SwiftUI action even when the accounts window has never appeared.
        DispatchQueue.main.async {
            delegate.bindAccountsWindow { open(id: "accounts") }
        }

        return Window("AGY Switcher", id: "accounts") {
            MainWindow(
                model: appDelegate.model,
                updater: appDelegate.updater,
                page: Binding(get: { appDelegate.page }, set: { appDelegate.page = $0 })
            )
            .environment(\.appLanguage, appDelegate.model.preferences.language)
            .environment(\.locale, appDelegate.model.preferences.language.locale)
            .onChange(of: appDelegate.model.preferences.appearance, initial: true) { _, appearance in
                appDelegate.applyAppearance(appearance)
            }
            .onAppear { appDelegate.setAccountsWindowVisible(true) }
            .onDisappear { appDelegate.setAccountsWindowVisible(false) }
        }
        .defaultSize(width: AppLaunch.isDemoUsage ? 860 : 720, height: AppLaunch.isDemoUsage ? 730 : 520)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

private struct MenuBarPopoverContent: View {
    let appDelegate: AppDelegate

    var body: some View {
        AccountsMenu(
            model: appDelegate.model,
            runsWithoutDock: appDelegate.isDockIconHidden,
            updateTag: appDelegate.updater.update?.tag
        ) { selectedPage in
            appDelegate.showAccountsWindow(page: selectedPage)
        }
        .environment(\.appLanguage, appDelegate.model.preferences.language)
        .environment(\.locale, appDelegate.model.preferences.language.locale)
    }
}

@MainActor
@Observable
private final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AccountsModel()
    let updater = AppUpdater()
    var page: WindowPage = AppLaunch.isDemoUsage ? .usage : .accounts
    private(set) var isDockIconHidden = true
    @ObservationIgnored private var demoBackdrop: NSWindow?
    @ObservationIgnored private var accountsWindowVisible = false
    @ObservationIgnored private var openAccountsWindow: (() -> Void)?
    @ObservationIgnored private var accountsWindowRequested = false
    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance(model.preferences.appearance)
        setupStatusItem()
        updater.start()
        let isLoginItem = AppLaunch.isLoginItem(NSAppleEventManager.shared().currentAppleEvent)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
        if isLoginItem {
            setDockIconHidden(true)
        } else {
            requestAccountsWindow()
        }
        if AppLaunch.isDemoAccounts {
            // 截图用：主窗口稳定后自动弹出菜单栏弹窗，供 scripts/demo-screenshot.sh 捕获。
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in showDemoPopover() }
        }
    }

    /// 演示模式专用：主动展示一次菜单栏弹窗。
    private func showDemoPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        let popover = ensurePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // 截图用：在弹窗正下方铺一块白色底板，让玻璃材质与圆角空隙都落在干净背景上。
        if let popoverWindow = popover.contentViewController?.view.window {
            let backdrop = NSWindow(
                contentRect: popoverWindow.frame.insetBy(dx: -24, dy: -24),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            backdrop.backgroundColor = .white
            backdrop.level = popoverWindow.level - 1
            backdrop.isOpaque = true
            backdrop.orderFrontRegardless()
            demoBackdrop = backdrop
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag { return true }
        requestAccountsWindow()
        return false
    }

    func bindAccountsWindow(_ action: @escaping () -> Void) {
        openAccountsWindow = action
        presentAccountsWindowIfRequested()
    }

    func showAccountsWindow(page: WindowPage? = nil) {
        popover?.performClose(nil)
        if let page { self.page = page }
        requestAccountsWindow()
    }

    func applyAppearance(_ appearance: AppPreferences.Appearance) {
        let nsAppearance = appearance.nsAppearance
        NSApplication.shared.appearance = nsAppearance
        popover?.appearance = nsAppearance
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let image = NSImage(named: "MenuBarIcon") {
                image.isTemplate = false
                button.image = image
            }
            button.setAccessibilityLabel("AGY Switcher")
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover(relativeTo: sender)
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            popover?.performClose(nil)
            showStatusMenu(for: sender)
        } else {
            togglePopover(relativeTo: sender)
        }
    }

    private func showStatusMenu(for button: NSStatusBarButton) {
        let language = model.preferences.language
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: language.text("打开窗口"),
            action: #selector(openWindowFromMenu),
            keyEquivalent: ""
        )
        openItem.target = self
        openItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: language.text("退出应用"),
            action: #selector(quitAppFromMenu),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openWindowFromMenu() {
        showAccountsWindow(page: .accounts)
    }

    @objc private func quitAppFromMenu() {
        NSApplication.shared.terminate(nil)
    }

    private func ensurePopover() -> NSPopover {
        if let popover { return popover }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let controller = NSHostingController(rootView: MenuBarPopoverContent(appDelegate: self))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.appearance = model.preferences.appearance.nsAppearance
        self.popover = popover
        return popover
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let popover = ensurePopover()
        popover.appearance = model.preferences.appearance.nsAppearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { await model.surfaceOpened() }
    }

    private func requestAccountsWindow() {
        accountsWindowRequested = true
        presentAccountsWindowIfRequested()
    }

    func prepareToShowAccountsWindow() {
        setDockIconHidden(false)
    }

    func setAccountsWindowVisible(_ visible: Bool) {
        accountsWindowVisible = visible
        if visible {
            setDockIconHidden(false)
        } else {
            DispatchQueue.main.async { [self] in
                guard !accountsWindowVisible, AppPreferences.storedWindowCloseBehavior() != .quit else { return }
                setDockIconHidden(true)
            }
        }
    }

    private func presentAccountsWindowIfRequested() {
        guard accountsWindowRequested, let openAccountsWindow else { return }
        accountsWindowRequested = false
        DispatchQueue.main.async { [self] in
            prepareToShowAccountsWindow()
            openAccountsWindow()
            NSApplication.shared.activate()
        }
    }

    func setDockIconHidden(_ hidden: Bool) {
        isDockIconHidden = hidden
        let application = NSApplication.shared
        let policy: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
        guard application.activationPolicy() != policy else { return }

        let wasActive = application.isActive
        if application.setActivationPolicy(policy), wasActive {
            application.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppPreferences.storedWindowCloseBehavior() == .quit
    }
}

private extension AppPreferences.Appearance {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
