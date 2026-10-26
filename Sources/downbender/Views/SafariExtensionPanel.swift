import AppKit
import DownbenderCore
import SwiftUI

/// Settings → Browser extension when Safari is selected. Permanent mode signs the extension with
/// the user's own free Apple certificate; Quick mode signs it ad hoc.
struct SafariExtensionPanel: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case permanent = "Permanent"
        case quick = "Quick"

        var id: String { rawValue }
    }

    @State private var state: SafariIntegrationState?
    @State private var mode: Mode = .permanent
    @State private var selectedIdentity: String?
    @State private var working = false

    private static let renewalSteps =
        "Create a new one in Xcode (Settings → Accounts → Manage Certificates… → + → Apple Development); " +
        "Downbender re-signs the extension with it the next time it opens."

    private static let certificateSteps = """
    1. Install Xcode from the App Store (about 10 GB, needed once; you can delete it afterwards).
    2. In Xcode → Settings → Accounts, click + → Apple Account and sign in.
    3. Select your Personal Team → Manage Certificates… → + → Apple Development.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let state {
                content(state)
            } else {
                LabeledContent("Checking Safari") {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.accent)
                }
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    @ViewBuilder
    private func content(_ state: SafariIntegrationState) -> some View {
        if !state.canInstall {
            caption("Move Downbender to Applications to install the Safari extension.")
        } else {
            if let message = state.errorMessage {
                Label("Safari extension not installed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                caption(message)
            }
            if let attention = state.attention {
                Label(attentionText(attention), systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
            if let installed = state.installedMode {
                installedStatus(installed, expiry: state.certificateExpiry)
            }

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(working)

            if let installed = state.installedMode, Self.mode(of: installed) != mode {
                caption("Safari will treat this as a new extension: enable it again in Safari's settings after switching.")
            }

            switch mode {
            case .permanent: permanentSetup(state)
            case .quick: quickSetup(state)
            }

            if working {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.accent)
                    caption("Working… this can take up to a minute.")
                }
            }
        }
    }

    private func installedStatus(_ installed: SafariExtensionMode, expiry: Date?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(statusText(installed, expiry: expiry), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
            caption(
                "In Safari → Settings → Extensions, enable Downbender and allow it on your video sites " +
                    "(Always Allow on Every Website works too)."
            )
            HStack {
                Button("Open Safari") { SafariIntegration.openSafariExtensionSettings() }
                    .buttonStyle(CommandButtonStyle(.secondary))
                Button("Remove") { run { await SafariIntegration.remove() } }
                    .buttonStyle(CommandButtonStyle(.danger))
            }
            .disabled(working)
        }
    }

    @ViewBuilder
    private func permanentSetup(_ state: SafariIntegrationState) -> some View {
        caption("Uses your free Apple certificate, so Safari keeps it enabled like any other extension.")
        switch state.certificate {
        case .missing:
            caption("You need a free Apple Development certificate first:\n" + Self.certificateSteps)
            checkAgainButton
        case .unusable:
            caption("Your Apple Development certificate is not valid. Create a new one:\n" + Self.certificateSteps)
            checkAgainButton
        case .needsAppleIntermediate:
            caption("macOS is missing a public Apple certificate it needs to recognize yours.")
            Button("Install Apple certificate") { run { await SafariIntegration.installAppleIntermediate() } }
                .buttonStyle(CommandButtonStyle(.primary))
                .disabled(working)
        case .ready(let identities):
            if identities.count > 1 {
                Picker("Certificate", selection: identityBinding(identities)) {
                    ForEach(identities, id: \.sha1) {
                        Text(identityLabel($0, expiries: state.identityExpiries)).tag($0.sha1)
                    }
                }
                .pickerStyle(.menu)
            }
            if state.installedMode != .permanent(identitySHA1: resolvedIdentity(identities)) {
                caption("macOS will ask to use your signing key: enter your Mac password and choose Always Allow.")
            }
            installButton(state, mode: .permanent(identitySHA1: resolvedIdentity(identities)))
        }
    }

    @ViewBuilder
    private func quickSetup(_ state: SafariIntegrationState) -> some View {
        caption(
            "No certificate needed. In Safari → Settings → Advanced, turn on Show features for web developers, " +
                "then Developer → Allow unsigned extensions. Safari turns it off every time it quits, " +
                "so you'll re-enable it after each restart."
        )
        installButton(state, mode: .quick)
    }

    private func installButton(_ state: SafariIntegrationState, mode: SafariExtensionMode) -> some View {
        Button(state.installedMode == nil ? "Install for Safari" : "Reinstall") {
            run { await SafariIntegration.install(mode: mode) }
        }
        .buttonStyle(CommandButtonStyle(.primary))
        .disabled(working)
    }

    private var checkAgainButton: some View {
        Button("Check again") { Task { await refresh() } }
            .buttonStyle(CommandButtonStyle(.secondary))
            .disabled(working)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func refresh() async {
        // A keychain prompt reactivates the app mid-install; refreshing then would race the install
        // and could erase its error message.
        guard !working else { return }
        let refreshed = await SafariIntegration.status()
        guard !working else { return }
        if state == nil, let installed = refreshed.installedMode { mode = Self.mode(of: installed) }
        state = refreshed
    }

    private func run(_ action: @escaping @MainActor () async -> SafariIntegrationState) {
        working = true
        Task {
            state = await action()
            working = false
        }
    }

    private func resolvedIdentity(_ identities: [SafariSigningIdentity]) -> String {
        if let selectedIdentity, identities.contains(where: { $0.sha1 == selectedIdentity }) { return selectedIdentity }
        // Keep the installed certificate while it is healthy; otherwise offer the one that lasts longest.
        if case .permanent(let installed) = state?.installedMode, state?.attention == nil,
           identities.contains(where: { $0.sha1 == installed }) { return installed }
        let expiries = state?.identityExpiries ?? [:]
        let longest = identities.max { (expiries[$0.sha1] ?? .distantPast) < (expiries[$1.sha1] ?? .distantPast) }
        return (longest ?? identities[0]).sha1
    }

    private func identityLabel(_ identity: SafariSigningIdentity, expiries: [String: Date]) -> String {
        guard let expiry = expiries[identity.sha1] else { return identity.name }
        return "\(identity.name) · expires \(expiry.formatted(date: .abbreviated, time: .omitted))"
    }

    private func identityBinding(_ identities: [SafariSigningIdentity]) -> Binding<String> {
        Binding(get: { resolvedIdentity(identities) }, set: { selectedIdentity = $0 })
    }

    private func statusText(_ installed: SafariExtensionMode, expiry: Date?) -> String {
        switch installed {
        case .quick:
            return "Installed · Quick"
        case .permanent:
            guard let expiry else { return "Installed · Permanent" }
            return "Installed · Permanent (certificate expires \(expiry.formatted(date: .abbreviated, time: .omitted)))"
        }
    }

    private func attentionText(_ attention: SafariAttention) -> String {
        switch attention {
        case .updateFailed:
            return "Downbender couldn't update the Safari extension after the last app update. Click Reinstall."
        case .certificateMissing:
            return "Your Apple Development certificate is missing. " + Self.renewalSteps
        case .certificateExpiringSoon(let date):
            return "Your Apple Development certificate expires on \(date.formatted(date: .abbreviated, time: .omitted)). " +
                "Before then: " + Self.renewalSteps
        case .certificateExpired(let date):
            return "Your Apple Development certificate expired on \(date.formatted(date: .abbreviated, time: .omitted)). " +
                Self.renewalSteps
        }
    }

    private static func mode(of installed: SafariExtensionMode) -> Mode {
        if case .permanent = installed { return .permanent }
        return .quick
    }
}
