import CoreServices
import Foundation

enum AppLaunch {
    static func isLoginItem(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventClass == kCoreEventClass
            && event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
