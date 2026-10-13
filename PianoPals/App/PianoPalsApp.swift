import SwiftUI

@main
struct PianoPalsApp: App {
    var body: some Scene {
        WindowGroup {
            // An iPhone becomes the iPad's second camera; an iPad runs the lessons.
            if CompanionRole.isPhone {
                CompanionRootView()
            } else {
                RootView()
            }
        }
    }
}
