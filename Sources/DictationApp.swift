import SwiftUI

@main
struct DictationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Window managed manually by AppDelegate for menu bar app compatibility
        Settings { EmptyView() }
    }
}
