import AppKit
import SwiftUI

final class FloatingWindow: NSPanel {

    /// Top edge inset from the visible screen, Spotlight-style.
    private static let topInsetFraction: CGFloat = 0.18
    private static let barOnlyHeight: CGFloat = 68
    /// Spotlight-like corner radius (≈0.45 × bar height) for both states.
    private static let panelCornerRadius: CGFloat = 30

    private let glass = NSGlassEffectView()
    /// Clips every layer (including the glass) to the panel's rounded shape,
    /// so nothing can paint into the square window corners.
    private let clipContainer = NSView()
    private var appliedCornerRadius: CGFloat = -1
    private var pendingHeight: CGFloat?
    private var flushScheduled = false

    let model = SearchModel()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: Self.barOnlyHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        // System shadow traces the rectangular window bounds and leaves a
        // fuzzy outline around our rounded shapes — draw none.
        hasShadow = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        clipContainer.wantsLayer = true

        // Single native Liquid Glass piece: the capsule morphs into the
        // result panel with a liquid spring animation.
        glass.style = .regular // 标准玻璃：白背景下也能看清面板
        glass.contentView = NSHostingView(
            rootView: RootSearchView(
                model: model,
                onHeightChange: { [weak self] height in self?.applyContentHeight(height) }
            )
        )
        clipContainer.addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: clipContainer.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: clipContainer.trailingAnchor),
            glass.topAnchor.constraint(equalTo: clipContainer.topAnchor),
            glass.bottomAnchor.constraint(equalTo: clipContainer.bottomAnchor),
        ])
        contentView = clipContainer

        applyShape(radius: Self.panelCornerRadius)
        positionLikeSpotlight()
    }

    /// Debug helper for automated visual tests.
    func debugLookup(_ word: String) {
        model.searchText = word
        Task { await model.lookup() }
    }

    /// Horizontally centered near the top of the screen, like Spotlight.
    private func positionLikeSpotlight() {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - frame.width / 2
        let y = visibleFrame.maxY - frame.height - visibleFrame.height * Self.topInsetFraction
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Resize while keeping the top edge anchored. Capsule-shaped while
    /// compact, soft rounded rect once expanded.
    private func applyContentHeight(_ height: CGFloat) {
        // SwiftUI fires this repeatedly during layout; coalesce to one flush
        // per runloop tick so the spring is never restarted mid-flight
        // (that read as stutter).
        pendingHeight = height
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushScheduled = false
            self?.flushPendingHeight()
        }
    }

    private func flushPendingHeight() {
        guard let height = pendingHeight else { return }
        pendingHeight = nil

        let clamped = max(height, Self.barOnlyHeight)
        guard abs(frame.height - clamped) > 0.5 else { return }

        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        var newFrame = frame
        newFrame.size.height = clamped
        newFrame.origin.x = visibleFrame.midX - newFrame.width / 2
        newFrame.origin.y = visibleFrame.maxY - clamped - visibleFrame.height * Self.topInsetFraction

        // One shared spring drives frame AND corner morph together.
        let spring = CAMediaTimingFunction(controlPoints: 0.32, 1.22, 0.55, 1)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.42
            context.timingFunction = spring
            context.allowsImplicitAnimation = true
            animator().setFrame(newFrame, display: true)
        }, completionHandler: nil)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.42)
        CATransaction.setAnimationTimingFunction(spring)
        applyShape(radius: Self.panelCornerRadius)
        CATransaction.commit()
    }

    private func applyShape(height: CGFloat? = nil, radius: CGFloat? = nil) {
        if let r = radius ?? height.map({ $0 / 2 }), abs(appliedCornerRadius - r) > 0.5 {
            appliedCornerRadius = r
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clipContainer.layer?.cornerRadius = r
            clipContainer.layer?.cornerCurve = .continuous
            clipContainer.layer?.masksToBounds = true
            glass.cornerRadius = r
            CATransaction.commit()
        }
    }

    override var canBecomeKey: Bool { true }

    func toggle() {
        if isVisible {
            orderOut(nil)
        } else {
            // 预热直连，让首查就命中活连接
            WordService.YoudaoDirectClient.shared.warmUp()
            // Every summon starts from a fresh capsule — no leftover results.
            model.reset()
            let barHeight = Self.barOnlyHeight
            if let screen = NSScreen.main {
                let visibleFrame = screen.visibleFrame
                let barFrame = NSRect(
                    x: visibleFrame.midX - frame.width / 2,
                    y: visibleFrame.maxY - barHeight - visibleFrame.height * Self.topInsetFraction,
                    width: frame.width,
                    height: barHeight
                )
                setFrame(barFrame, display: false)
            }
            applyShape(radius: Self.panelCornerRadius)
            // Activate the app so keystrokes reach the search field.
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
        }
    }
}
