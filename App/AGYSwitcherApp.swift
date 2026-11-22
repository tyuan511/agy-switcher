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
        if CommandLine.arguments.dropFirst().first == AGYUsageTracking.recordArgument {
            guard CommandLine.arguments.count == 3, let token = UUID(uuidString: CommandLine.arguments[2]) else { return }
            try? AGYUsageTracking().record(FileHandle.standardInput.readDataToEndOfFile(), token: token)
            return
        }
        AGYSwitcherApp.main()
    }
}

struct AGYSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var model = AccountsModel()
    @State private var page: WindowPage = .accounts

    var body: some Scene {
        accountsWindow

        MenuBarExtra {
            AccountsMenu(
                model: model,
                runsWithoutDock: model.preferences.hideDockIcon || appDelegate.isLoginMenuOnly,
                updateTag: appDelegate.updater.update?.tag
            ) { selectedPage in
                page = selectedPage
                appDelegate.prepareToShowAccountsWindow()
            }
            .environment(\.appLanguage, model.preferences.language)
            .environment(\.locale, model.preferences.language.locale)
            .preferredColorScheme(model.preferences.appearance.colorScheme)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.original)
                .accessibilityLabel("AGY Switcher")
        }
        .menuBarExtraStyle(.window)
    }

    private var accountsWindow: some Scene {
        let open = openWindow
        let delegate = appDelegate
        // Bind the SwiftUI action even when the accounts window has never appeared.
        DispatchQueue.main.async {
            delegate.bindAccountsWindow { open(id: "accounts") }
        }

        return Window("AGY Switcher", id: "accounts") {
            MainWindow(model: model, updater: appDelegate.updater, page: $page)
                .environment(\.appLanguage, model.preferences.language)
                .environment(\.locale, model.preferences.language.locale)
                .preferredColorScheme(model.preferences.appearance.colorScheme)
        }
        .defaultSize(width: 720, height: 520)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .onChange(of: model.preferences.hideDockIcon) { _, hidden in
            appDelegate.setDockIconHidden(hidden)
        }
    }
}

@MainActor
@Observable
private final class AppDelegate: NSObject, NSApplicationDelegate {
    let updater = AppUpdater()
    private(set) var isLoginMenuOnly = false
    @ObservationIgnored private var openAccountsWindow: (() -> Void)?
    @ObservationIgnored private var accountsWindowRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        updater.start()
        isLoginMenuOnly = AppLaunch.isLoginItem(NSAppleEventManager.shared().currentAppleEvent)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
        if isLoginMenuOnly {
            setDockIconHidden(true)
        } else {
            requestAccountsWindow()
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

    private func requestAccountsWindow() {
        accountsWindowRequested = true
        presentAccountsWindowIfRequested()
    }

    func prepareToShowAccountsWindow() {
        isLoginMenuOnly = false
        setDockIconHidden(AppPreferences.storedHideDockIcon())
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
