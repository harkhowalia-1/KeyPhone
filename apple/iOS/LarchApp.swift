import SwiftUI

@main
struct LarchApp: App {
    var body: some Scene {
        WindowGroup {
            PhoneView()
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .background(Color.black)
        }
    }
}
