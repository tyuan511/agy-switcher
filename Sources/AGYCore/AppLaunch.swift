import CoreServices
import Foundation

enum AppLaunch {
    /// 演示模式：用虚构数据渲染「用量」页，供 README 截图使用。
    static let isDemoUsage = ProcessInfo.processInfo.arguments.contains("-AGYDemoUsage")

    /// 演示模式：用虚构账号渲染「账号管理」页与菜单栏弹窗，供 README 截图使用。
    static let isDemoAccounts = ProcessInfo.processInfo.arguments.contains("-AGYDemoAccounts")

    static func isLoginItem(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventClass == kCoreEventClass
            && event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
