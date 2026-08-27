import SwiftUI

@main
struct PhoneMirrorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 920, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 PhoneMirror") { NSApp.orderFrontStandardAboutPanel(nil) }
            }
        }
    }
}
