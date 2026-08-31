import SwiftUI
import SecretKeeperCore
import AppKit

@MainActor
enum AppRuntime {
    static var controller: VaultController?
    static weak var mainWindow: NSWindow?

    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        if let existing = NSApp.windows.first(where: {
            $0.title == "Secret Keeper"
                && !$0.className.contains("StatusBar")
                && !$0.className.contains("MenuBar")
        }) {
            mainWindow = existing
            existing.makeKeyAndOrderFront(nil)
            return
        }

        guard let controller else { return }

        let root = ContentView(controller: controller)
            .frame(minWidth: 780, minHeight: 480)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Secret Keeper"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 880, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
    }

    /// Activate the app and wait for menu dismissal / focus to settle before LA.
    /// Starting evaluatePolicy while a MenuBarExtra menu is tearing down causes
    /// LAError.systemCancel (-4).
    static func prepareForAuthentication() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showMainWindow()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    static func unlockVault(_ controller: VaultController) async {
        prepareForAuthentication()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 200_000_000)
        prepareForAuthentication()
        await controller.unlock()
    }
}

@main
struct SecretKeeperAppMain: App {
    @StateObject private var controller: VaultController
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let controller = VaultController()
        _controller = StateObject(wrappedValue: controller)
        AppRuntime.controller = controller
        Task { @MainActor in
            await controller.bootstrap()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(controller: controller)
        } label: {
            Image(systemName: controller.state == .unlocked ? "lock.open.fill" : "lock.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            await AppRuntime.controller?.bootstrap()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                AppRuntime.showMainWindow()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppRuntime.showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppRuntime.controller?.lock()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
