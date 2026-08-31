import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SecretKeeperCore

// MARK: - Export

struct ExportVaultSheet: View {
    @ObservedObject var controller: VaultController

    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var revealPassphrase = false
    @State private var generatedHint = false
    @State private var working = false
    @State private var localError: String?

    private var appCount: Int { controller.apps.count }
    private var keyCount: Int { controller.apps.reduce(0) { $0 + $1.secrets.count } }

    private var validationMessage: String? {
        if passphrase.isEmpty { return nil }
        if passphrase.count < VaultArchive.minimumPassphraseLength {
            return "At least \(VaultArchive.minimumPassphraseLength) characters."
        }
        if !confirmation.isEmpty && passphrase != confirmation {
            return "The two passphrases do not match."
        }
        return nil
    }

    private var canExport: Bool {
        !working
            && passphrase.count >= VaultArchive.minimumPassphraseLength
            && passphrase == confirmation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Vault")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text("Writes every app and key to one encrypted `.\(VaultArchive.fileExtension)` file that another Secret Keeper can import. Grants stay on this Mac.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                "\(appCount) app\(appCount == 1 ? "" : "s") · \(keyCount) key\(keyCount == 1 ? "" : "s")",
                systemImage: "shippingbox"
            )
            .font(.system(.callout, design: .rounded).weight(.medium))
            .foregroundStyle(SKTheme.brandPrimary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Passphrase")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    Spacer()
                    Toggle("Show", isOn: $revealPassphrase)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    Button("Generate") {
                        let generated = VaultArchive.suggestPassphrase()
                        passphrase = generated
                        confirmation = generated
                        revealPassphrase = true
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(generated, forType: .string)
                        generatedHint = true
                    }
                    .controlSize(.small)
                    .help("Generate a strong passphrase and copy it to the clipboard")
                }

                if revealPassphrase {
                    TextField("Passphrase", text: $passphrase)
                        .font(SKTheme.mono)
                    TextField("Confirm passphrase", text: $confirmation)
                        .font(SKTheme.mono)
                } else {
                    SecureField("Passphrase", text: $passphrase)
                    SecureField("Confirm passphrase", text: $confirmation)
                }

                if generatedHint {
                    Text("Generated and copied to the clipboard. Store it somewhere safe now.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(SKTheme.success)
                }
                if let validationMessage {
                    Text(validationMessage)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(SKTheme.danger)
                }
            }

            Label(
                "The archive is only as strong as this passphrase, and it cannot be recovered. Send the file and the passphrase over different channels.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(.caption, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let localError {
                Text(localError)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(SKTheme.danger)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(working ? "Exporting…" : "Export…") {
                    // Run the panel synchronously off the button action; NSSavePanel
                    // blocks the main thread, so it must not sit inside the async path.
                    guard let url = presentSavePanel() else { return }
                    Task { await runExport(to: url) }
                }
                .disabled(!canExport)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(SKTheme.brandPrimary)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @MainActor
    private func runExport(to url: URL) async {
        working = true
        defer { working = false }

        localError = nil
        let ok = await controller.exportArchive(to: url, passphrase: passphrase)
        if ok {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            dismiss()
        } else {
            localError = controller.lastError
            controller.lastError = nil
        }
    }

    private func presentSavePanel() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Secret Keeper Vault"
        panel.nameFieldStringValue = defaultFileName()
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: VaultArchive.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "secret-keeper-\(formatter.string(from: Date())).\(VaultArchive.fileExtension)"
    }
}

// MARK: - Import

struct ImportVaultSheet: View {
    @ObservedObject var controller: VaultController

    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?
    @State private var header: VaultArchive.Header?
    @State private var passphrase = ""
    @State private var mode: ImportMode = .merge
    @State private var working = false
    @State private var localError: String?
    @State private var summary: ImportSummary?

    private var canImport: Bool {
        !working && fileURL != nil && header != nil && !passphrase.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Vault")
                .font(.system(.title2, design: .rounded).weight(.bold))

            if let summary {
                resultView(summary)
            } else {
                formView
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder
    private var formView: some View {
        Text("Open an encrypted `.\(VaultArchive.fileExtension)` archive exported from another Secret Keeper.")
            .font(.system(.body, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack {
            Button("Choose Archive…") { chooseFile() }
            if let fileURL {
                Text(fileURL.lastPathComponent)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }

        if let header {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "\(header.appCount) app\(header.appCount == 1 ? "" : "s") · format v\(header.version)",
                    systemImage: "shippingbox"
                )
                Text("Created \(header.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            .font(.system(.caption, design: .rounded))
            .foregroundStyle(SKTheme.brandPrimary)
        }

        SecureField("Passphrase", text: $passphrase)
            .disabled(header == nil)

        Picker("On import", selection: $mode) {
            ForEach(ImportMode.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .disabled(header == nil)

        Text(mode.detail)
            .font(.system(.caption, design: .rounded))
            .foregroundStyle(mode == .replace ? SKTheme.danger : .secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let localError {
            Text(localError)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(SKTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button(working ? "Importing…" : "Import") {
                Task { await runImport() }
            }
            .disabled(!canImport)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(mode == .replace ? SKTheme.danger : SKTheme.brandPrimary)
        }
    }

    @ViewBuilder
    private func resultView(_ summary: ImportSummary) -> some View {
        Label(summary.headline, systemImage: "checkmark.seal.fill")
            .font(.system(.body, design: .rounded))
            .foregroundStyle(SKTheme.success)
            .fixedSize(horizontal: false, vertical: true)

        if !summary.appsWithMissingFolders.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Root folders not found on this Mac", systemImage: "folder.badge.questionmark")
                    .font(.system(.callout, design: .rounded).weight(.medium))
                Text(summary.appsWithMissingFolders.joined(separator: ", "))
                    .font(.system(.caption, design: .rounded))
                Text("Point each app at its folder on this Mac before requesting a grant.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(SKTheme.brandAccent)
            .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(SKTheme.brandPrimary)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Secret Keeper Archive"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: VaultArchive.fileExtension) {
            panel.allowedContentTypes = [type, .json, .data]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        fileURL = url
        localError = nil
        header = controller.inspectArchive(at: url)
        if header == nil {
            localError = "That file is not a Secret Keeper archive."
        }
    }

    @MainActor
    private func runImport() async {
        guard let fileURL else { return }
        working = true
        defer { working = false }

        localError = nil
        if let result = await controller.importArchive(from: fileURL, passphrase: passphrase, mode: mode) {
            summary = result
        } else {
            localError = controller.lastError
            controller.lastError = nil
        }
    }
}
