import AppKit
import Observation
import SwiftUI

// MARK: - State

@Observable
final class OverlayState {
    var text: String = "Listening..."
    var audioLevel: CGFloat = 0   // 0…1, already smoothed by the panel
    var isAnimating: Bool = false
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

    func show(text: String = "Listening...") {
        state.text = text
        state.isAnimating = true

        let w = idealWidth(for: text)
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

        let w = idealWidth(for: text)
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

    func showRefining() {
        state.isAnimating = false
        smoothedLevel = 0
        state.audioLevel = 0
        updateText("Refining...")
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
        let label = "🔒 \(ruleName) detected — saved to Vault"
        state.isAnimating = false
        smoothedLevel = 0
        state.audioLevel = 0
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
        smoothedLevel = 0
        state.audioLevel = 0
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

    private func idealWidth(for text: String) -> CGFloat {
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

            Text(state.text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: true, vertical: false)
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

    private static let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private static let minFraction: CGFloat = 0.15
    private static let barWidth: CGFloat = 4.5
    private static let barSpacing: CGFloat = 3.5

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: Self.barSpacing) {
                ForEach(Self.weights.indices, id: \.self) { i in
                    let fraction = animating
                        ? Self.minFraction + (1 - Self.minFraction) * max(0, min(level, 1)) * Self.weights[i]
                        : Self.minFraction
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: Self.barWidth, height: geo.size.height * fraction)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .animation(.easeInOut(duration: 0.18), value: animating)
        .accessibilityHidden(true)
    }
}
