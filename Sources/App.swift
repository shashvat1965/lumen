import SwiftUI

struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            RootView().environmentObject(DisplayManager.shared)
        } label: {
            Image(systemName: "sun.max.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        MainActor.assumeIsolated {
            Settings.register()
            VirtualScreens.shared.start()
            DisplayManager.shared.start()
            if CommandLine.arguments.contains("--diagnose") { Diagnostics.run(); return }
            if Settings.mediaKeys { MediaKeys.shared.start() }
            CLI.startServer()
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        MainActor.assumeIsolated { DisplayManager.shared.restoreOnQuit() }
    }
}
