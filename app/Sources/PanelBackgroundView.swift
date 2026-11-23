import AppKit

/// Keeps references to macOS 26 types inside availability checks so the same
/// binary can load on macOS 13. The opt-out lets tests exercise the older path.
final class PanelBackgroundView: NSView {
    private let effectView: NSView

    var cornerRadius: CGFloat = 0 {
        didSet {
            if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
                glass.cornerRadius = cornerRadius
            }
            layer?.cornerRadius = cornerRadius
        }
    }

    init(preferLiquidGlass: Bool = true) {
        if #available(macOS 26.0, *), preferLiquidGlass {
            let glass = NSGlassEffectView()
            glass.style = .regular
            effectView = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            effectView = material
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        pinToEdges(effectView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setContentView(_ content: NSView) {
        if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
            glass.contentView = content
        } else {
            // Keep SwiftUI above the material, without inheriting text vibrancy.
            pinToEdges(content)
        }
    }

    private func pinToEdges(_ view: NSView) {
        addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
