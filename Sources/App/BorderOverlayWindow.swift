import AppKit

// MARK: - Border View

/// Custom view that draws a colored border around the window perimeter
/// with a small project name badge at the top-left.
private final class BorderView: NSView {
    var borderColor: NSColor = NSColor(hex: 0xC8A064) {
        didSet { needsDisplay = true }
    }
    var projectName: String = "" {
        didSet { needsDisplay = true }
    }
    var colorName: String = "" {
        didSet { needsDisplay = true }
    }

    private let borderWidth: CGFloat = 2
    private let cornerRadius: CGFloat = 10  // macOS window corner radius
    private let badgePadding: CGFloat = 6
    private let badgeHeight: CGFloat = 20
    private let badgeCornerRadius: CGFloat = 4
    private let badgeFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let R = cornerRadius

        // Draw border around the full perimeter
        let borderRect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: R, yRadius: R)
        borderColor.withAlphaComponent(0.7).setStroke()
        borderPath.lineWidth = borderWidth
        borderPath.stroke()

        // Draw subtle glow behind border
        let glowRect = bounds.insetBy(dx: -1, dy: -1)
        let glowPath = NSBezierPath(roundedRect: glowRect, xRadius: R + 1, yRadius: R + 1)
        borderColor.withAlphaComponent(0.15).setStroke()
        glowPath.lineWidth = 4
        glowPath.stroke()

        // Draw project badge at top-left, inset from the border
        guard !projectName.isEmpty else { return }

        let badgeText = projectName

        let attrs: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: NSColor(hex: 0xE8E2DA),
        ]
        let textSize = (badgeText as NSString).size(withAttributes: attrs)
        let badgeWidth = textSize.width + badgePadding * 2

        let badgeX: CGFloat = borderWidth + 8
        let badgeY: CGFloat = bounds.height - borderWidth - 8 - badgeHeight  // top-left (flipped: near maxY)

        let badgeRect = NSRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeHeight)
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: badgeCornerRadius, yRadius: badgeCornerRadius)

        // Badge background
        NSColor(hex: 0x1A1816, alpha: 0.88).setFill()
        badgePath.fill()

        // Badge border
        borderColor.withAlphaComponent(0.5).setStroke()
        badgePath.lineWidth = 1
        badgePath.stroke()

        // Badge text
        let textRect = NSRect(
            x: badgeX + badgePadding,
            y: badgeY + (badgeHeight - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        (badgeText as NSString).draw(in: textRect, withAttributes: attrs)
    }
}

// MARK: - Border Overlay Window

/// Transparent floating window that draws a colored border around a target window.
/// Used for browser and desktop app windows in multi-app clustering mode.
final class BorderOverlayWindow: NSWindow {
    private let borderView = BorderView()

    /// Callback on click (bring cluster to front).
    var onClicked: (() -> Void)?

    /// The CGWindowID of the target window this border tracks.
    var trackedWindowId: CGWindowID = 0

    /// The bundle ID of the app that owns the tracked window.
    var trackedBundleId: String = ""

    /// Whether the border is logically visible (alpha = 1).
    /// Visibility is toggled via alphaValue, NOT orderFront/orderOut,
    /// to avoid z-index thrashing that causes flicker.
    private var isCurrentlyVisible = false

    /// Whether we've called orderFront at least once (window is in the window list).
    private var isOrderedIn = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // Above normal windows but below floating panels/overlays.
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        // Window starts off-screen (not ordered in) — no need to pre-hide.

        contentView = borderView
    }

    // MARK: - Public API

    func update(projectName: String, colorName: String) {
        borderView.projectName = projectName
        borderView.colorName = colorName
    }

    func setBorderColor(_ color: NSColor) {
        borderView.borderColor = color
    }

    /// Position to exactly cover the target window.
    /// `targetFrame` is in AX/CG coordinates (origin = top-left of primary screen).
    func positionOverTarget(frame targetFrame: CGRect) {
        let screenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 900

        // Expand slightly to draw border outside the window
        let inset: CGFloat = -3
        let x = targetFrame.origin.x + inset
        let axY = targetFrame.origin.y + inset
        let w = targetFrame.width - inset * 2
        let h = targetFrame.height - inset * 2

        // Convert from AX (top-left origin) to NS (bottom-left origin)
        let nsY = screenHeight - axY - h

        let newFrame = NSRect(x: x, y: nsY, width: w, height: h)

        // Skip setFrame if position hasn't meaningfully changed (avoids window manager churn)
        let current = self.frame
        let threshold: CGFloat = 0.5
        if abs(current.origin.x - newFrame.origin.x) < threshold
            && abs(current.origin.y - newFrame.origin.y) < threshold
            && abs(current.width - newFrame.width) < threshold
            && abs(current.height - newFrame.height) < threshold {
            return
        }

        borderView.frame = NSRect(x: 0, y: 0, width: w, height: h)
        setFrame(newFrame, display: false)
    }

    func showBorder() {
        guard !isCurrentlyVisible else { return }
        isCurrentlyVisible = true
        if !isOrderedIn {
            isOrderedIn = true
            orderFront(nil)
        }
        alphaValue = 1
    }

    func hideBorder() {
        guard isCurrentlyVisible else { return }
        isCurrentlyVisible = false
        alphaValue = 0
    }

    /// Remove from screen entirely (for cleanup before close).
    func removeBorder() {
        isCurrentlyVisible = false
        isOrderedIn = false
        alphaValue = 0
        orderOut(nil)
    }
}
