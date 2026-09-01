import AppKit
import Foundation
import SecretKeeperCore

/// Manual "Check for Updates…" path.
///
/// The background launchd agent does the routine work; this just runs the same
/// script on demand so the menu has an answer when someone asks. The script is
/// the installed copy under Application Support when present, otherwise the one
/// shipped inside this bundle.
enum UpdateChecker {
    static var scriptURL: URL? {
        let fileManager = FileManager.default
        let installed = SecretKeeperPaths.applicationSupportDirectory
            .appendingPathComponent("updater/secret-keeper-update")
        if fileManager.isReadableFile(atPath: installed.path) {
            return installed
        }
        if let bundled = Bundle.main.url(forResource: "secret-keeper-update", withExtension: nil),
           fileManager.isReadableFile(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    static var isInstalled: Bool { scriptURL != nil }

    /// Runs the updater and returns whatever it printed.
    static func check() async -> String {
        guard let scriptURL else {
            return """
                Automatic updates are not set up for this copy.

                Re-run the installer to enable them:
                curl -fsSL https://raw.githubusercontent.com/rschwabco/secret-keeper/main/Scripts/install.sh | bash
                """
        }

        let path = scriptURL.path
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [path, "--user-initiated"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(
                        returning: "Could not start the updater.\n\n\(error.localizedDescription)"
                    )
                    return
                }

                // Drain before waiting so a chatty run cannot fill the pipe and deadlock.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if output.isEmpty {
                    continuation.resume(
                        returning: process.terminationStatus == 0
                            ? "Secret Keeper is up to date."
                            : "The update check failed (exit \(process.terminationStatus)). "
                                + "See ~/Library/Logs/SecretKeeper/updater.log."
                    )
                    return
                }
                continuation.resume(returning: output)
            }
        }
    }

    @MainActor
    static func presentResult(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Software Update"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
