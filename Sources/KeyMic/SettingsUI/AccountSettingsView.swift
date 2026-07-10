import SwiftUI
import AppKit
import os

private let viewLog = Logger(subsystem: "io.keymic.app", category: "AccountSettingsView")

struct AccountSettingsView: View {
    private var store: AccountStore { AccountStore.shared }

    var body: some View {
        let _ = viewLog.info("body — signedIn=\(store.signedIn) email=\(store.user?.email ?? "nil", privacy: .public)")
        return Form {
            if store.signedIn, let user = store.user {
                SignedInAccountSection(user: user)
                ConfigSyncSection()
            } else {
                SignedOutAccountSection(revoked: store.lastRevokedAt != nil)
                SignedOutSyncInfoSection()
            }
        }
        .formStyle(.grouped)
        .task { await store.refresh() }
    }
}

// MARK: - Sync status row

/// The single sync-status line, promoted from plain text into an icon + label
/// component. Colors follow state but never carry meaning alone — every state
/// has a distinct symbol and label.
private struct SyncStatusRow: View {
    let status: OverallSyncStatus
    let lastSyncedAt: Date?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(label)
            if status == .inSync, let date = lastSyncedAt {
                Text("· last synced \(Self.dateFormatter.string(from: date))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch status {
        case .notSynced: "circle.dashed"
        case .inSync: "checkmark.circle.fill"
        case .localNewer: "arrow.up.circle.fill"
        case .cloudNewer: "arrow.down.circle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .notSynced: .secondary
        case .inSync: .green
        case .localNewer, .cloudNewer: .blue
        }
    }

    private var label: LocalizedStringKey {
        switch status {
        case .notSynced: "Not synced yet"
        case .inSync: "In sync"
        case .localNewer: "Local changes not uploaded"
        case .cloudNewer: "Cloud has newer settings"
        }
    }
}

// MARK: - Account sections

private struct SignedInAccountSection: View {
    let user: MeResponse.User

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(user.email).font(.headline)
                if let name = user.name, !name.isEmpty {
                    Text(name).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            Button("Sign out", role: .destructive) { AccountStore.shared.signOut() }
                .controlSize(.small)
        } header: {
            Text("Account")
        }
    }
}

private struct SignedOutAccountSection: View {
    let revoked: Bool

    var body: some View {
        Section {
            if revoked {
                Text("Your session was revoked. Please sign in again.")
                    .foregroundStyle(.orange)
            } else {
                Text("Sign in to sync your KeyMic settings across your Macs.")
                    .foregroundStyle(.secondary)
            }
            Button("Sign in with browser") { AuthClient.beginLogin() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        } header: {
            Text("Account")
        }
    }
}

// MARK: - Config Sync section (signed in)

private struct ConfigSyncSection: View {
    @State private var controller = ConfigSyncController.shared

    var body: some View {
        Section {
            Toggle("Enable Config Sync", isOn: Binding(
                get: { controller.enabled },
                set: { on in
                    controller.enabled = on
                    if on { Task { await controller.handleEnable() } }
                }
            ))
            .toggleStyle(.switch)

            if controller.enabled {
                SyncStatusRow(status: controller.overall, lastSyncedAt: controller.lastSyncedAt)

                if let err = controller.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if controller.restartHint {
                    Text("Some changes take effect after restart.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button { Task { await controller.uploadAll() } } label: {
                        Label("Upload", systemImage: "arrow.up")
                    }
                    Button { Task { await controller.downloadAll() } } label: {
                        Label("Download", systemImage: "arrow.down")
                    }
                    if controller.busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .disabled(controller.busy)

                Text("API keys and clipboard content are never synced.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Sync your settings across all Macs signed in to this account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Config Sync")
        }
        .task { await controller.refreshStatus() }
        .confirmationDialog(
            "This Mac and the cloud have different settings.",
            isPresented: Binding(
                get: { controller.showBootstrapSheet },
                set: { if !$0 { controller.resolveBootstrapCancel() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Use cloud settings") { Task { await controller.resolveBootstrapUseCloud() } }
            Button("Keep this Mac's settings") { Task { await controller.resolveBootstrapKeepLocal() } }
            Button("Cancel", role: .cancel) { controller.resolveBootstrapCancel() }
        } message: {
            Text("Choose which settings to keep. The other side will be overwritten.")
        }
    }
}

// MARK: - Config Sync info section (signed out)

private struct SignedOutSyncInfoSection: View {
    var body: some View {
        Section {
            Text("Once you sign in, KeyMic can sync your settings — voice, hotkeys, key mapping, personas, and more — across every Mac on your account.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("API keys and clipboard content are never synced.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } header: {
            Text("Config Sync")
        }
    }
}
