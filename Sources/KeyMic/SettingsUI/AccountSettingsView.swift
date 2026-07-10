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

// MARK: - Card container

/// Shared card chrome so every Account module has the same visual rhythm:
/// left-aligned content, consistent padding, subtle border on a control-tinted
/// background. Presentation only — no state.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
    }
}

// MARK: - Config Sync

struct ConfigSyncSectionView: View {
    @State private var controller = ConfigSyncController.shared

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
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
                statusLine

                if let err = controller.lastError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
                if controller.restartHint {
                    Text("Some changes take effect after restart.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
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

    @ViewBuilder
    private var statusLine: some View {
        switch controller.overall {
        case .notSynced:
            Text("Not synced yet").font(.caption).foregroundStyle(.secondary)
        case .inSync:
            HStack(spacing: 4) {
                Label("In sync", systemImage: "checkmark").foregroundStyle(.green)
                if let date = controller.lastSyncedAt {
                    Text("· last synced \(Self.dateFormatter.string(from: date))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        case .localNewer:
            Label("Local changes not uploaded", systemImage: "arrow.up.circle")
                .font(.caption).foregroundStyle(.blue)
        case .cloudNewer:
            Label("Cloud has newer settings", systemImage: "arrow.down.circle")
                .font(.caption).foregroundStyle(.blue)
        }
    }
}
