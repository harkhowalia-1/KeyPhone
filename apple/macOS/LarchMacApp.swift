import SwiftUI

@main
struct LarchMacApp: App {
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
