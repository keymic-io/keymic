import AppKit
import Observation
import SwiftUI

// MARK: - State

@Observable
final class OverlayState {
    var text: String = String(localized: "Listening...")
    var audioLevel: CGFloat = 0   // 0…1, already smoothed by the panel
    var isAnimating: Bool = false
    var showsText: Bool = true
}

// MARK: - Panel host

final class OverlayPanel: NSPanel {
    private let state = OverlayState()
    private var smoothedLevel: CGFloat = 0
    private var pendingToast: String?
    private var toastDismissWorkItem: DispatchWorkItem?

    private let capsuleHeight: CGFloat = 56
    private let hPad: CGFloat = 24
    private let waveSize: CGFloat = 44
    private let gap: CGFloat = 14
    private let minWidth: CGFloat = 160
    private let maxWidth: CGFloat = 560
    private let labelFont = NSFont.systemFont(ofSize: 15, weight: .medium)

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        let host = NSHostingController(rootView: OverlayContent(state: state))
        host.view.translatesAutoresizingMaskIntoConstraints = false

        let cv = contentView!
        cv.wantsLayer = true
        cv.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: cv.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])
    }

    // MARK: - Public API (unchanged)

    func show(text: String = String(localized: "Listening...")) {
        state.text = text
        state.showsText = true
        state.isAnimating = true

        let w = idealWidth(for: text, showsText: true)
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let x = area.midX - w / 2
        let y = area.minY + 56

        setFrame(NSRect(x: x, y: y - 14, width: w, height: capsuleHeight), display: true)
        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.175, 0.885, 0.32, 1.1)
            animator().alphaValue = 1
            animator().setFrame(
                NSRect(x: x, y: y, width: w, height: capsuleHeight),
                display: true
            )
        }
    }

    func updateText(_ text: String) {
        state.text = text
        state.showsText = true

        let w = idealWidth(for: text, showsText: true)
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let x = area.midX - w / 2
        let newFrame = NSRect(x: x, y: frame.origin.y, width: w, height: capsuleHeight)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
            ctx.allowsImplicitAnimation = true
            animator().setFrame(newFrame, display: true)
        }
    }

    func updateAudioLevel(_ level: Float) {
        let target = CGFloat(level)
        let attack: CGFloat = 0.4
        let release: CGFloat = 0.15
        let factor = target > smoothedLevel ? attack : release
        smoothedLevel += (target - smoothedLevel) * factor
        state.audioLevel = smoothedLevel
    }

    private func resetAudioLevel() {
        smoothedLevel = 0
        state.audioLevel = 0
    }

    func showRefining() {
        state.text = ""
        state.showsText = false
        state.isAnimating = true
        resetAudioLevel()

        let w = idealWidth(for: nil, showsText: false)
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let x = area.midX - w / 2
        let newFrame = NSRect(x: x, y: frame.origin.y, width: w, height: capsuleHeight)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
            ctx.allowsImplicitAnimation = true
            animator().setFrame(newFrame, display: true)
        }
    }

    func showMessage(_ text: String) {
        state.isAnimating = false
        resetAudioLevel()
        if isVisible {
            updateText(text)
        } else {
            show(text: text)
            state.isAnimating = false  // override show()'s animating=true since this is a static toast
        }
    }

    /// Surfaces an OutputRouter result. Silent on success; transient toast on fallback / error.
    func showRouteResult(_ result: RouteResult) {
        switch result {
        case .injected, .userCancelled:
            return
        case .fellBackToClipboard(let reason):
            let label: String
            switch reason {
            case .selectionNotEditable:
                label = String(localized: "Copied — couldn't edit in place")
            case .noFocusedElement:
                label = String(localized: "Copied — no focused field")
            case .axPermissionMissing:
                label = String(localized: "Copied — Accessibility permission needed")
            case .strategyNotImplemented:
                label = String(localized: "Copied — strategy coming soon")
            }
            showTransientToast(label, durationSeconds: 2.5)
        case .failed(let message):
            showTransientToast(String(localized: "Error: \(message)"), durationSeconds: 3.0)
        }
    }

    /// Reuses showSecretToast's dismiss-after-N pattern but with arbitrary text and duration.
    func showTransientToast(_ label: String, durationSeconds: Double) {
        if isShowingTranscript { return }
        state.isAnimating = false
        resetAudioLevel()
        if isVisible {
            updateText(label)
        } else {
            show(text: label)
            state.isAnimating = false
        }
        toastDismissWorkItem?.cancel()
        let wi = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.isShowingTranscript { self.dismiss() }
        }
        toastDismissWorkItem = wi
        DispatchQueue.main.asyncAfter(deadline: .now() + durationSeconds, execute: wi)
    }

    private var isShowingTranscript: Bool {
        // Voice flow drives `state.isAnimating == true` while listening, and uses `show()` and `updateText()` calls.
        // We treat the panel as busy with transcription whenever it's visible AND animating.
        return self.isVisible && state.isAnimating
    }

    func showSecretToast(ruleName: String) {
        if isShowingTranscript {
            pendingToast = ruleName
            return
        }
        let label = String(localized: "🔒 \(ruleName) detected — saved to Vault")
        state.isAnimating = false
        resetAudioLevel()
        if isVisible {
            updateText(label)
        } else {
            show(text: label)
            state.isAnimating = false
        }
        toastDismissWorkItem?.cancel()
        let wi = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.isShowingTranscript {
                self.dismiss()
            }
        }
        toastDismissWorkItem = wi
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: wi)
    }

    /// Called by voice flow on dismiss — flushes a pending toast if one was queued.
    func flushPendingToast() {
        guard let pending = pendingToast else { return }
        pendingToast = nil
        showSecretToast(ruleName: pending)
    }

    func dismiss() {
        state.isAnimating = false
        resetAudioLevel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
            animator().setFrame(
                NSRect(
                    x: frame.origin.x + frame.width * 0.02,
                    y: frame.origin.y - 8,
                    width: frame.width * 0.96,
                    height: capsuleHeight
                ),
                display: true
            )
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.flushPendingToast()
        })
    }

    private func idealWidth(for text: String?, showsText: Bool) -> CGFloat {
        guard showsText, let text else { return minWidth }
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont]
        let textW = ceil((text as NSString).size(withAttributes: attrs).width)
        let total = hPad + waveSize + gap + textW + hPad
        return min(max(total, minWidth), maxWidth)
    }
}

// MARK: - SwiftUI content

private struct OverlayContent: View {
    @Bindable var state: OverlayState

    var body: some View {
        HStack(spacing: 14) {
            WaveformView(level: state.audioLevel, animating: state.isAnimating)
                .frame(width: 44, height: 32)

            if state.showsText {
                Text(state.text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    // Keep the newest text: the capsule width is capped at `maxWidth`, so a
                    // long live transcript truncates at the HEAD (leading "…") instead of the
                    // tail — the user sees the words just spoken, not the start of the utterance.
                    // No `fixedSize(horizontal:)`: that would force the full intrinsic width and
                    // defeat truncation (the text would overflow and get clipped by the capsule).
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Capsule()
                    .fill(Color.black.opacity(0.72))
                Capsule()
                    .fill(.ultraThinMaterial)
                    .opacity(0.75)
                Capsule()
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            }
        )
        .clipShape(Capsule())
        .preferredColorScheme(.dark)
    }
}

private struct WaveformView: View {
    let level: CGFloat
    let animating: Bool

    @State private var phase: CGFloat = 0

    private static let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private static let minFraction: CGFloat = 0.15
    private static let loadingAmplitude: CGFloat = 0.35
    private static let barWidth: CGFloat = 4.5
    private static let barSpacing: CGFloat = 3.5

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: Self.barSpacing) {
                ForEach(Self.weights.indices, id: \.self) { i in
                    let clampedLevel = max(0, min(level, 1))
                    let loadingOffset = (sin(phase + CGFloat(i) * 0.9) + 1) / 2
                    let animatedLevel = clampedLevel > 0
                        ? clampedLevel
                        : Self.loadingAmplitude * loadingOffset
                    let fraction = animating
                        ? Self.minFraction + (1 - Self.minFraction) * animatedLevel * Self.weights[i]
                        : Self.minFraction
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: Self.barWidth, height: geo.size.height * fraction)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .onAppear {
            updatePhaseAnimation()
        }
        .onChange(of: animating) { _, _ in
            updatePhaseAnimation()
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .animation(.easeInOut(duration: 0.18), value: animating)
        .accessibilityHidden(true)
    }

    private func updatePhaseAnimation() {
        if animating {
            phase = 0
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        } else {
            phase = 0
        }
    }
}
