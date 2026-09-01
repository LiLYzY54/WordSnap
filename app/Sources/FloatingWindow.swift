import AppKit
import SwiftUI

final class FloatingWindow: NSPanel {

    /// 系统原生玻璃窗口边缘自带的光学描边：内侧一圈镜面高光（上亮下淡，
    /// 中段最暗），最外圈一道极淡的深色发丝线。手动合成 NSGlassEffectView
    /// 时系统不送这层，得自己补——否则面板在浅色壁纸上边缘发虚、没有
    /// 「金属收口」的质感。
    private final class EdgeStrokeView: NSView {

        var cornerRadius: CGFloat = 30 { didSet { needsLayout = true } }

        private let gradient = CAGradientLayer()
        private let ringMask = CAShapeLayer()
        private let outerLine = CAShapeLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true

            gradient.colors = [
                NSColor(white: 1, alpha: 0.65).cgColor,
                NSColor(white: 1, alpha: 0.10).cgColor,
                NSColor(white: 1, alpha: 0.32).cgColor,
            ]
            gradient.locations = [0, 0.45, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            gradient.mask = ringMask
            layer?.addSublayer(gradient)

            outerLine.strokeColor = NSColor(white: 0, alpha: 0.10).cgColor
            outerLine.fillColor = nil
            outerLine.lineWidth = 1
            layer?.addSublayer(outerLine)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            super.layout()
            // 窗口高度动画期间 AppKit 会持续回调 layout，环随帧更新
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.frame = bounds
            outerLine.frame = bounds

            let outer = ringPath(inset: 0.5)
            let path = CGMutablePath()
            path.addPath(outer)
            path.addPath(ringPath(inset: 1.5))
            ringMask.path = path
            ringMask.fillRule = .evenOdd
            outerLine.path = outer
            CATransaction.commit()
        }

        private func ringPath(inset: CGFloat) -> CGPath {
            let r = max(0, cornerRadius - inset)
            return NSBezierPath(
                roundedRect: bounds.insetBy(dx: inset, dy: inset),
                xRadius: r, yRadius: r
            ).cgPath
        }

        /// 纯装饰层：绝不拦截玻璃内容层的鼠标事件
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Top edge inset from the visible screen, Spotlight-style.
    private static let topInsetFraction: CGFloat = 0.18
    private static let barOnlyHeight: CGFloat = 68
    /// Spotlight-like corner radius (≈0.45 × bar height) for both states.
    private static let panelCornerRadius: CGFloat = 30

    private let glass = NSGlassEffectView()
    private let edgeStrokes = EdgeStrokeView(frame: .zero)
    /// Clips every layer (including the glass) to the panel's rounded shape,
    /// so nothing can paint into the square window corners.
    private let clipContainer = NSView()
    private var appliedCornerRadius: CGFloat = -1
    private var pendingHeight: CGFloat?
    private var flushScheduled = false
    private var hideObserver: NSObjectProtocol?
    /// kVK_Escape
    private static let escapeKeyCode: UInt16 = 53

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
        clipContainer.addSubview(edgeStrokes)
        edgeStrokes.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            edgeStrokes.leadingAnchor.constraint(equalTo: clipContainer.leadingAnchor),
            edgeStrokes.trailingAnchor.constraint(equalTo: clipContainer.trailingAnchor),
            edgeStrokes.topAnchor.constraint(equalTo: clipContainer.topAnchor),
            edgeStrokes.bottomAnchor.constraint(equalTo: clipContainer.bottomAnchor),
        ])
        contentView = clipContainer

        applyShape(radius: Self.panelCornerRadius)
        positionLikeSpotlight()

        // Esc（onExitCommand）和保存成功后的自动消失都走这条通知，在此统一收起面板。
        hideObserver = NotificationCenter.default.addObserver(
            forName: .wordSnapHidePanel, object: nil, queue: .main
        ) { [weak self] _ in
            self?.orderOut(nil)
        }

        // SwiftUI 的 onExitCommand 在 TextField 聚焦时被输入法机制吞掉
        // （实测按 Esc 只会清选区/候选，回调根本不触发），Esc 收起必须
        // 在窗口层直接拦截键码，不能依赖 SwiftUI 回调链。
        // 仅本应用的本地事件，不影响其他应用。
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self, event.keyCode == Self.escapeKeyCode else {
                return event
            }
            NSLog("WordSnap [esc] intercepted, hiding panel")
            self.orderOut(nil)
            return nil // 已消费，不再下发
        }
    }

    private var escMonitor: Any?

    deinit {
        if let hideObserver {
            NotificationCenter.default.removeObserver(hideObserver)
        }
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
        }
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
            edgeStrokes.cornerRadius = r
            CATransaction.commit()
        }
    }

    override var canBecomeKey: Bool { true }

    func toggle() {
        NSLog("WordSnap [toggle] visible=%d", isVisible ? 1 : 0)
        if isVisible {
            orderOut(nil)
        } else {
            showPanel()
        }
    }

    /// 呼出面板并直接查某个词（今日一词入口）。
    func summonAndLookup(_ word: String) {
        showPanel()
        model.searchText = word
        Task { await model.lookup() }
    }

    private func showPanel() {
        // 预热直连，让首查就命中活连接
        Task { WordService.YoudaoDirectClient.shared.warmUp() }
        // Every summon starts from a fresh capsule — no leftover results.
        model.reset()
        model.prefillFromClipboard()
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
