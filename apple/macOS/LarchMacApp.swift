import SwiftUI
import AppKit

/// Closing the phone's window quits the app, like closing a phone off.
final class LarchAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct LarchMacApp: App {
    @NSApplicationDelegateAdaptor(LarchAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Larch K7") {
            MacPhoneView()
                .frame(minWidth: 260, idealWidth: 380, minHeight: 600, idealHeight: 860)
                .background(Color(red: 0.12, green: 0.14, blue: 0.17))
        }
        .defaultSize(width: 380, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
