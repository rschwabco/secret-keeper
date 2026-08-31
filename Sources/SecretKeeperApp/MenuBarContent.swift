import SwiftUI
import AppKit
import SecretKeeperCore

struct MenuBarContent: View {
    @ObservedObject var controller: VaultController
    @State private var copiedPrompt = false
    @State private var checkingForUpdates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Secret Keeper")
                .font(.system(.headline, design: .rounded))
            Text(statusLabel)
                .foregroundStyle(.secondary)
                .font(.system(.caption, design: .rounded))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        Divider()

        if controller.state == .unlocked {
            Button("Lock") {
                Task { await controller.lock() }
            }
        } else {
            Button("Unlock…") {
                // Defer past MenuBarExtra menu teardown; starting LA while the menu
                // dismisses yields LAError.systemCancel (-4).
                Task { @MainActor in
                    await AppRuntime.unlockVault(controller)
                }
            }
        }

        Button("Show Window") {
            AppRuntime.showMainWindow()
        }

        Button(copiedPrompt ? "Copied Agent Prompt" : "Copy Agent Prompt") {
            AgentPrompt.copyToPasteboard()
            copiedPrompt = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                copiedPrompt = false
            }
        }

        Divider()

        Button(checkingForUpdates ? "Checking for Updates…" : "Check for Updates…") {
            Task { @MainActor in
                checkingForUpdates = true
                let result = await UpdateChecker.check()
                checkingForUpdates = false
                UpdateChecker.presentResult(result)
            }
        }
        .disabled(checkingForUpdates)

        Divider()

        Button("Quit") {
            Task {
                await controller.lock()
                NSApp.terminate(nil)
            }
        }
    }

    private var statusLabel: String {
        switch controller.state {
        case .unlocked: return "Unlocked"
        case .locked: return "Locked"
        case .unavailable: return controller.needsSetup ? "Needs setup" : "Unavailable"
        }
    }
}
