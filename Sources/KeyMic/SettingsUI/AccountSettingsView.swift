import SwiftUI
import AppKit
import os

private let viewLog = Logger(subsystem: "io.keymic.app", category: "AccountSettingsView")

struct AccountSettingsView: View {
    private var store: AccountStore { AccountStore.shared }

    var body: some View {
        let _ = viewLog.info("body — signedIn=\(store.signedIn) email=\(store.user?.email ?? "nil", privacy: .public)")
        return VStack(alignment: .leading, spacing: 16) {
            Text("Account").font(.headline)
            if store.signedIn, let user = store.user {
                signedInView(user: user)
                Divider()
                ConfigSyncSectionView()
            } else {
                signedOutView
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 240)
        .task { await store.refresh() }
    }

    private var signedOutView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.lastRevokedAt != nil {
                Text("Your session was revoked. Please sign in again.")
                    .foregroundStyle(.orange)
                    .font(.caption)
            } else {
                Text("Not signed in").foregroundStyle(.secondary)
            }
            Button("Sign in with browser") { AuthClient.beginLogin() }
                .controlSize(.large)
        }
    }

    private func signedInView(user: MeResponse.User) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(user.email).bold()
                Spacer()
            }
            if let name = user.name, !name.isEmpty {
                Text(name).foregroundStyle(.secondary)
            }
            Button("Sign out", role: .destructive) { store.signOut() }
        }
    }
}

// MARK: - Config Sync

private extension SyncSection {
    var displayName: String {
        switch self {
        case .general: return "General"
        case .voice: return "Voice"
        case .llm: return "LLM"
        case .personas: return "Personas"
        case .hotkeys: return "Hotkeys"
        case .keyMapping: return "Key Mapping"
        case .clipboard: return "Clipboard"
        case .screenshot: return "Screenshot"
        }
    }
}

struct ConfigSyncSectionView: View {
    @State private var controller = ConfigSyncController.shared

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Config Sync").font(.subheadline).bold()
                Spacer()
                Toggle("", isOn: Binding(
                    get: { controller.enabled },
                    set: { on in
                        controller.enabled = on
                        if on { Task { await controller.handleEnable() } }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            if controller.enabled {
                Text("What syncs:").font(.caption).foregroundStyle(.secondary)
                ForEach(SyncSection.allCases, id: \.self) { section in
                    sectionRow(section)
                }

                if let err = controller.lastError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
                if controller.restartHint {
                    Text("Some changes take effect after restart.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Upload all") { Task { await controller.uploadAll() } }
                    Button("Download all") { Task { await controller.downloadAll() } }
                    if controller.busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .disabled(controller.busy)

                // Auto-sync (Pro) is hidden until the subscription plumbing lands.
                // autoSyncRow

                Text("API keys or clipboard content are never synced.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("Sync your settings across all Macs signed in to this account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await controller.refreshStatus() }
        .confirmationDialog(
            "This Mac and the cloud have different settings.",
            isPresented: Binding(get: { controller.showBootstrapSheet }, set: { if !$0 { controller.resolveBootstrapCancel() } }),
            titleVisibility: .visible
        ) {
            Button("Use cloud settings") { Task { await controller.resolveBootstrapUseCloud() } }
            Button("Keep this Mac's settings") { Task { await controller.resolveBootstrapKeepLocal() } }
            Button("Cancel", role: .cancel) { controller.resolveBootstrapCancel() }
        } message: {
            Text("Choose which settings to keep. The other side will be overwritten.")
        }
    }

    private func sectionRow(_ section: SyncSection) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { controller.isSectionEnabled(section) },
                set: { controller.toggleSection(section, on: $0) }
            ))
            .labelsHidden()
            Text(section.displayName).frame(width: 110, alignment: .leading)
            statusLabel(for: section)
            Spacer()
        }
        .font(.callout)
    }

    @ViewBuilder
    private func statusLabel(for section: SyncSection) -> some View {
        switch controller.statuses[section] ?? .notSynced {
        case .excluded:
            Text(section == .llm ? "excluded · API key never syncs" : "excluded")
                .font(.caption).foregroundStyle(.tertiary)
        case .notSynced:
            Text("not synced yet").font(.caption).foregroundStyle(.secondary)
        case .inSync:
            Label("in sync", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
        case .localNewer:
            Text("local newer ↑").font(.caption).foregroundStyle(.blue)
        case .cloudNewer(let date):
            Text("cloud · \(Self.dateFormatter.string(from: date))")
                .font(.caption).foregroundStyle(.blue)
        }
    }

    private var autoSyncRow: some View {
        HStack {
            Image(systemName: "bolt.fill").foregroundStyle(.secondary)
            Text("Auto sync across devices")
            if !controller.isPro {
                Text("PRO")
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
            }
            Spacer()
            Toggle("", isOn: .constant(false))
                .labelsHidden()
                .disabled(!controller.isPro)
                .help(controller.isPro ? "" : "Upgrade to Pro at keymic.io to enable automatic sync.")
        }
        .font(.callout)
    }
}
