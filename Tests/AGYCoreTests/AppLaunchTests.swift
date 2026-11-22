import CoreServices
import Foundation
import Testing
@testable import AGYCore

struct AppLaunchTests {
    @Test func distinguishesLoginLaunchFromOpeningOrReopeningTheApp() {
        let launch = makeEvent(id: kAEOpenApplication)
        #expect(!AppLaunch.isLoginItem(nil))
        #expect(!AppLaunch.isLoginItem(launch))

        let login = NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem)
        launch.setParam(login, forKeyword: keyAEPropData)
        #expect(AppLaunch.isLoginItem(launch))

        let reopen = makeEvent(id: kAEReopenApplication)
        reopen.setParam(login, forKeyword: keyAEPropData)
        #expect(!AppLaunch.isLoginItem(reopen))
    }

    private func makeEvent(id: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: kCoreEventClass,
            eventID: id,
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }
}
