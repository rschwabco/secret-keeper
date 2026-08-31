import SwiftUI
import SecretKeeperCore
import AppKit

struct ContentView: View {
    @ObservedObject var controller: VaultController
    @State private var selectedAppID: UUID?
    @State private var showingNewApp = false
    @State private var showingExport = false
    @State private var showingImport = false
    @State private var copyPromptFeedback = false
    @State private var unlocking = false

    var body: some View {
        ZStack {
            AtmosphereBackground()

            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
            .navigationSplitViewStyle(.balanced)
        }
        .alert(alertTitle, isPresented: Binding(
            get: { controller.lastError != nil },
            set: { if !$0 { controller.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { controller.lastError = nil }
        } message: {
            Text(controller.lastError ?? "")
        }
        .sheet(isPresented: $showingNewApp) {
            NewAppSheet(controller: controller) { app in
                selectedAppID = app.id
            }
        }
        .sheet(isPresented: $showingExport) {
            ExportVaultSheet(controller: controller)
        }
        .sheet(isPresented: $showingImport) {
            ImportVaultSheet(controller: controller)
        }
    }

    private var sidebar: some View {
        List(selection: $selectedAppID) {
            Section {
                if controller.state != .unlocked {
                    Text("Unlock to manage apps")
                        .foregroundStyle(.secondary)
                        .font(.system(.subheadline, design: .rounded))
                } else if controller.apps.isEmpty {
                    Text("No apps yet")
                        .foregroundStyle(.secondary)
                        .font(.system(.subheadline, design: .rounded))
                } else {
                    ForEach(controller.apps) { app in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name)
                                .font(.system(.body, design: .rounded).weight(.medium))
                            Text(app.rootFolder)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 2)
                        .tag(app.id)
                        .listRowBackground(
                            SidebarRowBackground(selected: selectedAppID == app.id)
                        )
                    }
                }
            } header: {
                Text("Apps")
                    .font(SKTheme.sectionFont)
                    .textCase(nil)
            }

            Section {
                if controller.grants.isEmpty {
                    Text(controller.state == .unlocked ? "No active grants" : "—")
                        .foregroundStyle(.secondary)
                        .font(.system(.subheadline, design: .rounded))
                } else {
                    ForEach(controller.grants, id: \.id) { grant in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(grant.appName)
                                .font(.system(.body, design: .rounded).weight(.medium))
                            Text(grant.worktreePath)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button("Revoke", role: .destructive) {
                                Task { await controller.revokeGrant(worktreePath: grant.worktreePath) }
                            }
                        }
                    }
                }
            } header: {
                Text("Grants")
                    .font(SKTheme.sectionFont)
                    .textCase(nil)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        .navigationTitle("Secret Keeper")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewApp = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(controller.state != .unlocked)
                .help("Add app")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Export Vault\u{2026}") { showingExport = true }
                        .disabled(controller.apps.isEmpty)
                    Button("Import Vault\u{2026}") { showingImport = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(controller.state != .unlocked)
                .help("Export or import an encrypted vault archive")
            }
        }
        .safeAreaInset(edge: .bottom) {
            lockBar
        }
    }

    private var lockBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: controller.state == .unlocked ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(controller.state == .unlocked ? SKTheme.success : SKTheme.brandAccent)
                    .symbolEffect(.bounce, value: controller.state == .unlocked)
                Text(controller.state == .unlocked ? "Unlocked" : "Locked")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                Spacer()
                if controller.state == .unlocked {
                    Button("Lock") {
                        Task { await controller.lock() }
                    }
                    .controlSize(.small)
                } else {
                    Button("Unlock") {
                        Task { await performUnlock() }
                    }
                    .controlSize(.small)
                    .disabled(unlocking)
                }
            }

            Button {
                AgentPrompt.copyToPasteboard()
                copyPromptFeedback = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copyPromptFeedback = false
                }
            } label: {
                Label(
                    copyPromptFeedback ? "Copied!" : "Copy agent prompt",
                    systemImage: copyPromptFeedback ? "checkmark.circle.fill" : "doc.on.clipboard"
                )
                .font(.system(.caption, design: .rounded).weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .contentTransition(.symbolEffect(.replace))
            }
            .controlSize(.small)
            .help("Copy a ready-to-paste prompt that teaches an agent how to install and use the Secret Keeper MCP")
        }
        .padding(12)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Divider().opacity(0.5)
                }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if controller.state != .unlocked {
            LockedVaultView(unlocking: unlocking) {
                Task { await performUnlock() }
            }
        } else if let app = controller.apps.first(where: { $0.id == selectedAppID }) {
            AppDetailView(controller: controller, app: app)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            EmptySelectionView()
        }
    }

    @MainActor
    private func performUnlock() async {
        guard !unlocking else { return }
        unlocking = true
        defer { unlocking = false }
        await AppRuntime.unlockVault(controller)
    }

    private var alertTitle: String {
        let message = controller.lastError ?? ""
        if message == "Unlock canceled."
            || message.hasPrefix("Unlock was interrupted")
        {
            return "Unlock"
        }
        return "Error"
    }
}

// MARK: - Locked / empty states

struct LockedVaultView: View {
    let unlocking: Bool
    var onUnlock: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 24)

            LockGlyph(unlocked: false)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)

            VStack(spacing: 8) {
                Text("Secret Keeper")
                    .font(SKTheme.brandTitleFont)
                    .foregroundStyle(SKTheme.brandPrimary)
                    .shadow(color: SKTheme.brandPrimary.opacity(0.12), radius: 8, y: 2)

                Text("Unlock with Touch ID or Apple Watch to manage secrets.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)

            Button {
                onUnlock()
            } label: {
                HStack(spacing: 8) {
                    if unlocking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "lock.open")
                    }
                    Text(unlocking ? "Waiting…" : "Unlock")
                }
            }
            .buttonStyle(UnlockButtonStyle())
            .disabled(unlocking)
            .keyboardShortcut("u", modifiers: [.command])
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.94)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }
}

struct EmptySelectionView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 40, weight: .medium, design: .rounded))
                .foregroundStyle(SKTheme.brandPrimary.opacity(0.85))
            Text("Select an App")
                .font(.system(.title2, design: .rounded).weight(.semibold))
            Text("Each app maps to a project folder. Agents request `.env.local` for worktrees of that folder.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - App detail

struct AppDetailView: View {
    @ObservedObject var controller: VaultController
    let app: VaultApp

    @State private var draftName: String = ""
    @State private var draftFolder: String = ""
    @State private var draftSecrets: [SecretItem] = []
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var showingPasteEnv = false
    @State private var importSummary: String?
    @State private var revealSecrets = false

    var body: some View {
        Form {
            Section("App") {
                TextField("Name", text: $draftName)
                HStack {
                    TextField("Root folder", text: $draftFolder)
                    Button("Choose…") { pickFolder() }
                }
            }

            Section {
                secretsToolbar

                ForEach(Array(draftSecrets.enumerated()), id: \.element.id) { index, _ in
                    secretRow(at: index)
                }

                newSecretRow

                if let importSummary {
                    Text(importSummary)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Secrets")
            }

            Section {
                HStack {
                    Button("Save") {
                        Task {
                            var updated = app
                            updated.name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                            updated.rootFolder = draftFolder
                            updated.secrets = draftSecrets
                            await controller.upsertApp(updated)
                        }
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .tint(SKTheme.brandPrimary)

                    Spacer()

                    Button("Delete App", role: .destructive) {
                        Task { await controller.deleteApp(id: app.id) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(app.name)
        .onAppear { load(from: app) }
        .onChange(of: app.id) { _, _ in
            revealSecrets = false
            load(from: app)
        }
        .onChange(of: app) { _, newValue in load(from: newValue) }
        .sheet(isPresented: $showingPasteEnv) {
            PasteEnvSheet { content, replaceAll in
                applyEnvPaste(content, replaceAll: replaceAll)
            }
        }
    }

    private var secretsToolbar: some View {
        HStack(spacing: 14) {
            if !draftSecrets.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        revealSecrets.toggle()
                    }
                } label: {
                    Label(
                        revealSecrets ? "Hide values" : "Reveal values",
                        systemImage: revealSecrets ? "eye.slash" : "eye"
                    )
                }
                .buttonStyle(.borderless)
                .help(revealSecrets ? "Hide secret values" : "Reveal secret values")
            }

            Button {
                showingPasteEnv = true
            } label: {
                Label("Paste .env", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .help("Import keys from a pasted .env file")

            Spacer()

            Text("\(draftSecrets.count) key\(draftSecrets.count == 1 ? "" : "s")")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .font(.system(.caption, design: .rounded).weight(.semibold))
    }

    @ViewBuilder
    private func secretRow(at index: Int) -> some View {
        HStack(spacing: 8) {
            TextField("KEY", text: bindingKey(at: index))
                .font(SKTheme.mono)
            Group {
                if revealSecrets {
                    TextField("Value", text: bindingValue(at: index))
                } else {
                    SecureField("Value", text: bindingValue(at: index))
                }
            }
            .font(SKTheme.mono)
            Button(role: .destructive) {
                withAnimation(.easeOut(duration: 0.18)) {
                    _ = draftSecrets.remove(at: index)
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove secret")
        }
    }

    private var newSecretRow: some View {
        HStack(spacing: 8) {
            TextField("NEW_KEY", text: $newKey)
                .font(SKTheme.mono)
            Group {
                if revealSecrets {
                    TextField("value", text: $newValue)
                } else {
                    SecureField("value", text: $newValue)
                }
            }
            .font(SKTheme.mono)
            Button("Add") {
                let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    draftSecrets.append(SecretItem(key: key, value: newValue))
                }
                newKey = ""
                newValue = ""
            }
            .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func applyEnvPaste(_ content: String, replaceAll: Bool) {
        let parsed = EnvParser.parse(content)
        guard !parsed.isEmpty else {
            importSummary = "No keys found in pasted content."
            return
        }
        if replaceAll {
            draftSecrets = parsed
            importSummary = "Replaced secrets with \(parsed.count) key\(parsed.count == 1 ? "" : "s") from .env."
        } else {
            let before = Set(draftSecrets.map(\.key))
            draftSecrets = EnvParser.merge(existing: draftSecrets, parsed: parsed)
            let updated = parsed.filter { before.contains($0.key) }.count
            let added = parsed.count - updated
            importSummary = "Imported \(parsed.count) key\(parsed.count == 1 ? "" : "s") (\(added) new, \(updated) updated)."
        }
    }

    private func load(from app: VaultApp) {
        draftName = app.name
        draftFolder = app.rootFolder
        draftSecrets = app.secrets
    }

    private func bindingKey(at index: Int) -> Binding<String> {
        Binding(
            get: { draftSecrets[index].key },
            set: { draftSecrets[index].key = $0 }
        )
    }

    private func bindingValue(at index: Int) -> Binding<String> {
        Binding(
            get: { draftSecrets[index].value },
            set: { draftSecrets[index].value = $0 }
        )
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: draftFolder.isEmpty ? NSHomeDirectory() : draftFolder)
        if panel.runModal() == .OK, let url = panel.url {
            draftFolder = url.path
            if draftName.isEmpty {
                draftName = url.lastPathComponent
            }
        }
    }
}

struct PasteEnvSheet: View {
    var onImport: (_ content: String, _ replaceAll: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var replaceAll = false

    private var previewCount: Int {
        EnvParser.parse(content).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Paste .env")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text("Paste the contents of a `.env` / `.env.local` file. Keys and values are parsed automatically.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $content)
                .font(SKTheme.mono)
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(SKTheme.brandPrimary.opacity(0.25))
                )

            Toggle("Replace existing secrets", isOn: $replaceAll)
            Text(previewCount == 0
                 ? "No keys detected yet."
                 : "\(previewCount) key\(previewCount == 1 ? "" : "s") detected.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") {
                    onImport(content, replaceAll)
                    dismiss()
                }
                .disabled(previewCount == 0)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(SKTheme.brandPrimary)
            }
        }
        .padding(24)
        .frame(width: 560, height: 420)
        .onAppear {
            if content.isEmpty, let clip = NSPasteboard.general.string(forType: .string), clip.contains("=") {
                content = clip
            }
        }
    }
}

struct NewAppSheet: View {
    @ObservedObject var controller: VaultController
    var onCreated: (VaultApp) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder = ""
    @State private var envPaste = ""
    @State private var showingPasteEnv = false

    private var parsedSecrets: [SecretItem] {
        EnvParser.parse(envPaste)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add App")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text("Secrets are grouped by app, and each app maps to a project folder on this Mac.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)

            TextField("Name", text: $name)
            HStack {
                TextField("Root folder", text: $folder)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        folder = url.path
                        if name.isEmpty { name = url.lastPathComponent }
                    }
                }
            }

            HStack {
                Button("Paste .env…") { showingPasteEnv = true }
                if !parsedSecrets.isEmpty {
                    Text("\(parsedSecrets.count) key\(parsedSecrets.count == 1 ? "" : "s") ready to import")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let app = VaultApp(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        rootFolder: folder,
                        secrets: parsedSecrets
                    )
                    Task {
                        await controller.upsertApp(app)
                        onCreated(app)
                        dismiss()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folder.isEmpty)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(SKTheme.brandPrimary)
            }
        }
        .padding(24)
        .frame(width: 480)
        .sheet(isPresented: $showingPasteEnv) {
            PasteEnvSheet { content, _ in
                envPaste = content
            }
        }
    }
}
