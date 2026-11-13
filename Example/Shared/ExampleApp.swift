import SwiftUI

@main
struct ExampleApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            CallView(engine: appDelegate.engine, placeCall: appDelegate.placeCall)
        }
    }
}
