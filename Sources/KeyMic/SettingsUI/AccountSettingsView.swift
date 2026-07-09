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
