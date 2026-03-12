import AppKit

// MARK: - Zenith Design Tokens

private enum Zenith {
    // Colors
    static let bg        = NSColor(hex: 0x1A1816, alpha: 0.92)
    static let border    = NSColor(hex: 0x3D3630)
    static let accent    = NSColor(hex: 0xC8A064)
    static let text      = NSColor(hex: 0xE8E2DA)
    static let secondary = NSColor(hex: 0xB8AD9E)
    static let notifyGold = NSColor(hex: 0xC8A064) // badge color
    static let notifyGlow = NSColor(hex: 0xC8A064, alpha: 0.3) // glow behind badge

    // Layout
    static let labelWidth: CGFloat  = 360
    static let labelHeight: CGFloat = 56
    static let margin: CGFloat      = 8   // inset from window edge
    static let cornerRadius: CGFloat = 8
    static let borderWidth: CGFloat = 1
    static let accentWidth: CGFloat = 3
    static let accentInset: CGFloat = 6   // inset from top/bottom
    static let textPadding: CGFloat = 14  // text left padding

    // Badge
    static let badgeSize: CGFloat = 10
    static let badgeGlowSize: CGFloat = 18
    static let badgeMarginRight: CGFloat = 12
    static let badgeMarginTop: CGFloat = 10

    // Typography
    static let projectFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        .withDesign(.rounded) ?? NSFont.systemFont(ofSize: 13, weight: .medium)
    static let statusFont  = NSFont.systemFont(ofSize: 11, weight: .regular)
}

// MARK: - Label View

/// Custom view that draws the Zenith-styled session label.
private final class LabelView: NSView, NSTextFieldDelegate {
    var projectName: String = ""
    var statusText: String = ""
    var animationStyle: AnimationStyle = .accentBar
    /// Optional cluster accent color. When nil, uses default Zenith.accent (gold).
    var clusterColor: NSColor?
    private var effectiveAccent: NSColor { clusterColor ?? Zenith.accent }
    var hasNotification: Bool = false {
        didSet {
            if hasNotification != oldValue {
                if hasNotification { startGlowAnimation() } else { stopGlowAnimation() }
            }
        }
    }
    var isWorking: Bool = false {
        didSet {
            if isWorking != oldValue {
                if isWorking { startWorkingAnimation() } else { stopWorkingAnimation() }
            }
        }
    }

    /// Callback when the user commits a custom name via inline editing.
    var onCustomName: ((String) -> Void)?

    // Animation state
    private var animationTimer: Timer?
    private var animationPhase: CGFloat = 0  // 0..1 oscillating

    private var isEditing = false
    private lazy var editField: NSTextField = {
        let tf = NSTextField()
        tf.isBordered = false
        tf.drawsBackground = true
        tf.backgroundColor = NSColor(hex: 0x2A2520)
        tf.textColor = Zenith.accent
        tf.font = Zenith.projectFont
        tf.focusRingType = .none
        tf.isHidden = true
        tf.delegate = self
        tf.cell?.isScrollable = true
        tf.cell?.wraps = false
        tf.cell?.lineBreakMode = .byTruncatingTail
        tf.target = self
        tf.action = #selector(editFieldAction(_:))
        return tf
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(editField)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: - Edit Mode

    func enterEditMode() {
        guard !isEditing else { return }
        isEditing = true

        editField.stringValue = projectName
        editField.frame = NSRect(
            x: Zenith.textPadding,
            y: 6,
            width: bounds.width - Zenith.textPadding - 12,
            height: 22
        )
        editField.isHidden = false
        editField.isEditable = true
        editField.selectText(nil)

        window?.makeFirstResponder(editField)
    }

    func exitEditMode(save: Bool) {
        guard isEditing else { return }
        isEditing = false

        if save {
            let newName = editField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty {
                onCustomName?(newName)
            }
        }

        editField.isHidden = true
        editField.isEditable = false
        needsDisplay = true
    }

    @objc private func editFieldAction(_ sender: NSTextField) {
        exitEditMode(save: true)
        (window as? OverlayWindow)?.finishEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(cancelOperation(_:)) {
            exitEditMode(save: false)
            (window as? OverlayWindow)?.finishEditing()
            return true
        }
        return false
    }

    // MARK: - Animations

    private func startWorkingAnimation() {
        stopAllAnimations()
        animationPhase = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.animationPhase += 0.025
            if self.animationPhase > 1 { self.animationPhase -= 1 }
            self.needsDisplay = true
        }
    }

    private func stopWorkingAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationPhase = 0
        needsDisplay = true
    }

    private func startGlowAnimation() {
        stopAllAnimations()
        animationPhase = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.animationPhase += 0.015
            if self.animationPhase > 1 { self.animationPhase -= 1 }
            self.needsDisplay = true
        }
    }

    private func stopGlowAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationPhase = 0
        needsDisplay = true
    }

    private func stopAllAnimations() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationPhase = 0
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let R = Zenith.cornerRadius
        let path = NSBezierPath(roundedRect: bounds, xRadius: R, yRadius: R)

        switch animationStyle {
        case .accentBar:
            drawAccentBarStyle(bounds: bounds, path: path)
        case .borderLoop:
            drawBorderLoopStyle(bounds: bounds, path: path, R: R)
        }

        let projectColor = hasNotification ? NSColor(hex: 0x2A1E10) : effectiveAccent
        let statusColor = hasNotification ? NSColor(hex: 0x4A3820) : Zenith.secondary

        let textLeft: CGFloat = animationStyle == .accentBar ? Zenith.textPadding : 12
        let projectAttrs: [NSAttributedString.Key: Any] = [
            .font: Zenith.projectFont,
            .foregroundColor: projectColor,
        ]
        let showBadge = hasNotification && animationStyle == .accentBar
        let projectStr = truncate(projectName, maxChars: 44) as NSString
        let projectRect = NSRect(
            x: textLeft,
            y: 8,
            width: bounds.width - textLeft - (showBadge ? 30 : 8),
            height: 20
        )
        projectStr.draw(in: projectRect, withAttributes: projectAttrs)

        let statusAttrs: [NSAttributedString.Key: Any] = [
            .font: Zenith.statusFont,
            .foregroundColor: statusColor,
        ]
        let statusStr = truncate(statusText, maxChars: 52) as NSString
        let statusRect = NSRect(
            x: textLeft,
            y: 30,
            width: bounds.width - textLeft - 8,
            height: 18
        )
        statusStr.draw(in: statusRect, withAttributes: statusAttrs)
    }

    // MARK: - Style A: Accent Bar

    private func drawAccentBarStyle(bounds: NSRect, path: NSBezierPath) {
        let accent = effectiveAccent
        if hasNotification {
            accent.withAlphaComponent(0.92).setFill()
            path.fill()

            accent.withAlphaComponent(0.6).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            Zenith.bg.setFill()
            path.fill()
            Zenith.border.setStroke()
            path.lineWidth = Zenith.borderWidth
            path.stroke()
        }

        let accentRect = NSRect(
            x: Zenith.accentWidth,
            y: Zenith.accentInset,
            width: Zenith.accentWidth,
            height: bounds.height - Zenith.accentInset * 2
        )
        let accentPath = NSBezierPath(roundedRect: accentRect, xRadius: 1.5, yRadius: 1.5)

        if isWorking {
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.saveGState()

            accent.withAlphaComponent(0.35).setFill()
            accentPath.fill()

            let barH = bounds.height - Zenith.accentInset * 2
            let shimmerY = Zenith.accentInset + animationPhase * barH
            let shimmerH: CGFloat = 16
            let shimmerRect = NSRect(
                x: Zenith.accentWidth - 1,
                y: shimmerY - shimmerH / 2,
                width: Zenith.accentWidth + 2,
                height: shimmerH
            )
            accentPath.addClip()
            let shimmerGradient = NSGradient(colors: [
                accent.withAlphaComponent(0),
                accent.withAlphaComponent(1),
                accent.withAlphaComponent(0),
            ])
            shimmerGradient?.draw(in: shimmerRect, angle: 90)
            ctx.restoreGState()
        } else {
            accent.setFill()
            accentPath.fill()
        }

        if hasNotification {
            let badgeX = bounds.width - Zenith.badgeMarginRight - Zenith.badgeSize / 2
            let badgeY = Zenith.badgeMarginTop

            let glowRect = NSRect(
                x: badgeX - Zenith.badgeGlowSize / 2,
                y: badgeY - Zenith.badgeGlowSize / 2 + Zenith.badgeSize / 2,
                width: Zenith.badgeGlowSize,
                height: Zenith.badgeGlowSize
            )
            let glowPath = NSBezierPath(ovalIn: glowRect)
            accent.withAlphaComponent(0.3).setFill()
            glowPath.fill()

            let dotRect = NSRect(
                x: badgeX - Zenith.badgeSize / 2,
                y: badgeY,
                width: Zenith.badgeSize,
                height: Zenith.badgeSize
            )
            let dotPath = NSBezierPath(ovalIn: dotRect)
            accent.setFill()
            dotPath.fill()
        }
    }

    // MARK: - Style B: Border Loop

    private func drawBorderLoopStyle(bounds: NSRect, path: NSBezierPath, R: CGFloat) {
        let ctx = NSGraphicsContext.current!.cgContext
        let P = computePerimeter(bounds, R: R)
        let accent = effectiveAccent

        Zenith.bg.setFill()
        path.fill()

        if isWorking {
            accent.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 2
            path.stroke()

            ctx.saveGState()
            let shimmerLen: CGFloat = 16
            let phase = -animationPhase * P

            let glowPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: R - 0.5, yRadius: R - 0.5)
            glowPath.setLineDash([shimmerLen * 3, P - shimmerLen * 3], count: 2, phase: phase)
            accent.withAlphaComponent(0.4).setStroke()
            glowPath.lineWidth = 4
            glowPath.stroke()

            let corePath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: R - 1, yRadius: R - 1)
            corePath.setLineDash([shimmerLen, P - shimmerLen], count: 2, phase: phase)
            accent.setStroke()
            corePath.lineWidth = 2
            corePath.stroke()

            ctx.restoreGState()
        } else if hasNotification {
            accent.withAlphaComponent(0.92).setFill()
            path.fill()

            accent.withAlphaComponent(0.6).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            accent.withAlphaComponent(0.3).setStroke()
            path.lineWidth = Zenith.borderWidth
            path.stroke()
        }
    }

    private func computePerimeter(_ bounds: NSRect, R: CGFloat) -> CGFloat {
        let W = bounds.width
        let H = bounds.height
        return 2 * (W - 2 * R) + 2 * (H - 2 * R) + 2 * .pi * R
    }

    private func truncate(_ text: String, maxChars: Int) -> String {
        if text.count <= maxChars { return text }
        return String(text.prefix(maxChars - 1)) + "\u{2026}"
    }
}

// MARK: - Overlay Window

/// Borderless, transparent, non-activating floating window for a session label.
/// Temporarily becomes key-accepting during inline edit mode (double-click to rename).
final class OverlayWindow: NSWindow {
    private let labelView = LabelView()
    private var isEditMode = false

    /// Callback when the user commits a custom name.
    var onCustomName: ((String) -> Void)? {
        get { labelView.onCustomName }
        set { labelView.onCustomName = newValue }
    }

    /// Callback on single-click (bring cluster to front).
    var onSingleClick: (() -> Void)?

    /// Whether the label is logically visible (alpha = 1).
    /// Visibility is toggled via alphaValue, NOT orderFront/orderOut,
    /// to avoid z-index thrashing that causes flicker.
    private var isCurrentlyVisible = false
    private var isOrderedIn = false

    override var canBecomeKey: Bool { isEditMode }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Zenith.labelWidth, height: Zenith.labelHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true   // Pass clicks through to windows below
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        // Window starts off-screen (not ordered in) — no need to pre-hide.

        labelView.frame = NSRect(x: 0, y: 0, width: Zenith.labelWidth, height: Zenith.labelHeight)
        contentView = labelView
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            enterEditMode()
        } else if event.clickCount == 1 {
            // Delay to distinguish from double-click
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, !self.isEditMode else { return }
                self.onSingleClick?()
            }
        }
    }

    // MARK: - Edit Mode

    func enterEditMode() {
        isEditMode = true
        ignoresMouseEvents = false  // Enable interaction for editing
        isCurrentlyVisible = true
        isOrderedIn = true
        alphaValue = 1
        makeKeyAndOrderFront(nil)
        labelView.enterEditMode()
    }

    func finishEditing() {
        isEditMode = false
        ignoresMouseEvents = true   // Resume click pass-through
        resignKey()
        // Re-activate the target app after editing
        let targetBundleId = Settings.shared.targetBundleId
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == targetBundleId }?
            .activate()
    }

    // MARK: - Public API

    func update(project: String, status: String?) {
        labelView.projectName = project
        labelView.statusText = status ?? "Active session"
        labelView.needsDisplay = true
    }

    func setNotification(_ on: Bool) {
        guard labelView.hasNotification != on else { return }
        labelView.hasNotification = on
        if on { labelView.isWorking = false }
        labelView.needsDisplay = true
    }

    var hasNotification: Bool {
        labelView.hasNotification
    }

    func setWorking(_ on: Bool) {
        guard labelView.isWorking != on else { return }
        labelView.isWorking = on
        labelView.needsDisplay = true
    }

    func setAnimationStyle(_ style: AnimationStyle) {
        labelView.animationStyle = style
        labelView.needsDisplay = true
    }

    func setClusterColor(_ color: NSColor?) {
        guard labelView.clusterColor != color else { return }
        labelView.clusterColor = color
        labelView.needsDisplay = true
    }

    /// Position just above the top-right corner of a target window.
    /// `termFrame` is in AX coordinates (origin = top-left of primary screen).
    func positionRelativeTo(termFrame: CGRect) {
        let screenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 900

        let gap: CGFloat = 4
        let x = termFrame.origin.x + termFrame.width - Zenith.labelWidth
        let axY = termFrame.origin.y - Zenith.labelHeight - gap
        let nsY = screenHeight - axY - Zenith.labelHeight

        let newFrame = NSRect(x: x, y: nsY, width: Zenith.labelWidth, height: Zenith.labelHeight)

        // Skip if position hasn't meaningfully changed
        let current = self.frame
        if abs(current.origin.x - newFrame.origin.x) < 0.5
            && abs(current.origin.y - newFrame.origin.y) < 0.5 {
            return
        }

        setFrame(newFrame, display: false)
    }

    func showLabel() {
        guard !isCurrentlyVisible else { return }
        isCurrentlyVisible = true
        if !isOrderedIn {
            isOrderedIn = true
            orderFront(nil)
        }
        alphaValue = 1
    }

    func hideLabel() {
        guard isCurrentlyVisible else { return }
        isCurrentlyVisible = false
        alphaValue = 0
    }

    /// Remove from screen entirely (for cleanup before close).
    func removeLabel() {
        isCurrentlyVisible = false
        isOrderedIn = false
        alphaValue = 0
        orderOut(nil)
    }
}

// MARK: - NSColor Hex Initializer

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1.0) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

private extension NSFont {
    func withDesign(_ design: NSFontDescriptor.SystemDesign) -> NSFont? {
        guard let descriptor = fontDescriptor.withDesign(design) else { return nil }
        return NSFont(descriptor: descriptor, size: pointSize)
    }
}
