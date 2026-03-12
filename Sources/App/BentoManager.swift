import AppKit
import ApplicationServices

// MARK: - Divider Content View

private final class DividerContentView: NSView {
    let axis: BentoDividerWindow.Axis

    init(axis: BentoDividerWindow.Axis) {
        self.axis = axis
        super.init(frame: .zero)
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1.0, alpha: 0.08).setFill()
        switch axis {
        case .vertical:
            NSRect(x: bounds.midX - 0.5, y: 8, width: 1, height: bounds.height - 16).fill()
        case .horizontal:
            NSRect(x: 8, y: bounds.midY - 0.5, width: bounds.width - 16, height: 1).fill()
        }
        // Affordance dots
        NSColor(white: 1.0, alpha: 0.15).setFill()
        let cx = bounds.midX, cy = bounds.midY
        let r: CGFloat = 1.5, sp: CGFloat = 5
        for i in -2...2 {
            let rect: NSRect
            switch axis {
            case .vertical:  rect = NSRect(x: cx - r, y: cy + CGFloat(i) * sp - r, width: r * 2, height: r * 2)
            case .horizontal: rect = NSRect(x: cx + CGFloat(i) * sp - r, y: cy - r, width: r * 2, height: r * 2)
            }
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
    }
    override func mouseExited(with event: NSEvent) { NSCursor.pop() }
}

// MARK: - Bento Divider Window

final class BentoDividerWindow: NSWindow {
    enum Axis { case vertical, horizontal }

    let axis: Axis
    let index: Int
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    private var lastMouseLocation: NSPoint?
    private var isCurrentlyVisible = false
    private var isOrderedIn = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(axis: Axis, index: Int) {
        self.axis = axis
        self.index = index
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        contentView = DividerContentView(axis: axis)
    }

    func show() {
        guard !isCurrentlyVisible else { return }
        isCurrentlyVisible = true
        if !isOrderedIn { isOrderedIn = true; orderFront(nil) }
        alphaValue = 1
    }

    func hide() {
        guard isCurrentlyVisible else { return }
        isCurrentlyVisible = false
        alphaValue = 0
    }

    func remove() {
        isCurrentlyVisible = false
        isOrderedIn = false
        alphaValue = 0
        orderOut(nil)
    }

    override func mouseDown(with event: NSEvent) {
        lastMouseLocation = NSEvent.mouseLocation
        (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastMouseLocation else { return }
        let cur = NSEvent.mouseLocation
        let delta: CGFloat = axis == .vertical ? cur.x - last.x : -(cur.y - last.y)
        lastMouseLocation = cur
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        lastMouseLocation = nil
        NSCursor.pop()
        onDragEnd?()
    }
}

// MARK: - Bento Manager

/// Manages Bento Mode: a dynamic grid layout for terminal windows.
/// - Launchpad-style drag-to-rearrange with animated window shuffling
/// - Draggable dividers between cells for resizing
/// - 60fps animation timer for smooth position interpolation
final class BentoManager {

    // MARK: - Public State

    private(set) var isActive = false
    private(set) var isDragging = false

    // MARK: - Grid State

    private var cols = 1
    private var rows = 1
    private var colProportions: [CGFloat] = [1.0]
    private var rowProportions: [CGFloat] = [1.0]

    /// Canonical cell assignments (source of truth)
    private(set) var cellAssignments: [CGWindowID?] = []
    /// Visual assignments during drag (shifted to show drop preview)
    private var displayAssignments: [CGWindowID?] = []

    private var windowLabels: [CGWindowID: String] = [:]

    // MARK: - Screen / Grid Geometry (AX coordinates)

    /// Full available screen area
    private var screenOriginAX: CGPoint = .zero
    private var screenSize: CGSize = .zero
    /// Actual grid area (may be smaller than screen if cells hit max size — centered)
    private var gridOriginAX: CGPoint = .zero
    private var gridSize: CGSize = .zero

    // MARK: - Animation

    private var animationTimer: Timer?
    /// Current interpolated position per window (AX coords)
    private var currentPos: [CGWindowID: CGPoint] = [:]
    /// Target position per window
    private var targetPos: [CGWindowID: CGPoint] = [:]
    /// Target size per window
    private var targetSize: [CGWindowID: CGSize] = [:]
    /// Whether size has been applied (we only set size once, not every frame)
    private var sizeApplied: Set<CGWindowID> = []

    private let lerpSpeed: CGFloat = 0.2   // higher = snappier (0..1)
    private let snapThreshold: CGFloat = 2 // snap to target when within this

    // MARK: - Drag State

    private var draggedWindowId: CGWindowID?
    private var dragSourceIndex: Int = -1
    private var currentHoverIndex: Int = -1

    // MARK: - Dividers

    private var vDividers: [BentoDividerWindow] = []
    private var hDividers: [BentoDividerWindow] = []

    /// Timestamp of last programmatic reposition — ignore AX resize events shortly after
    private var lastRepositionTime: Date = .distantPast
    private let repositionCooldown: TimeInterval = 0.3

    // MARK: - Constants

    private let gap: CGFloat = 8
    private let labelReserve: CGFloat = 64
    private let dividerHitWidth: CGFloat = 14
    private let minProportion: CGFloat = 0.12

    // MARK: - Callbacks

    var axWindowProvider: ((CGWindowID) -> AXUIElement?)?
    var onRepositioned: (() -> Void)?
    var activateTargetApp: (() -> Void)?

    // MARK: - Activate

    func activate(windows: [(windowId: CGWindowID, label: String)]) {
        guard !windows.isEmpty else { return }
        if isActive { destroyDividers(); stopAnimationTimer() }
        isActive = true

        windowLabels.removeAll()
        for w in windows { windowLabels[w.windowId] = w.label }

        let sorted = windows.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }

        // Responsive grid: compute cols/rows + centered grid area from screen + constraints
        (cols, rows) = computeResponsiveGrid(windowCount: sorted.count)
        colProportions = Array(repeating: 1.0 / CGFloat(cols), count: cols)
        rowProportions = Array(repeating: 1.0 / CGFloat(rows), count: rows)

        cellAssignments = Array(repeating: nil, count: cols * rows)
        for (i, w) in sorted.enumerated() where i < cellAssignments.count {
            cellAssignments[i] = w.windowId
        }
        displayAssignments = cellAssignments
        snapAllToGrid()
        createDividers()
        startAnimationTimer()
        activateTargetApp?()
    }

    // MARK: - Deactivate

    func deactivate() {
        isActive = false
        isDragging = false
        draggedWindowId = nil
        stopAnimationTimer()
        destroyDividers()
        cellAssignments.removeAll()
        displayAssignments.removeAll()
        windowLabels.removeAll()
        currentPos.removeAll()
        targetPos.removeAll()
        targetSize.removeAll()
        sizeApplied.removeAll()
    }

    // MARK: - Drag Lifecycle

    /// Start a Launchpad-style drag rearrangement.
    func beginDrag(windowId: CGWindowID) {
        guard isActive else { return }
        guard let idx = cellAssignments.firstIndex(of: windowId) else { return }

        isDragging = true
        draggedWindowId = windowId
        dragSourceIndex = idx
        currentHoverIndex = idx
        displayAssignments = cellAssignments
    }

    /// Update during drag — pass the dragged window's center in AX coords.
    /// Shifts other windows in real-time (Launchpad-style).
    func updateDrag(windowCenter: CGPoint) {
        guard isDragging, let dragWid = draggedWindowId else { return }

        let newHover = cellIndexForAXPoint(windowCenter)
        guard newHover >= 0, newHover < cellAssignments.count else { return }
        guard newHover != currentHoverIndex else { return }

        currentHoverIndex = newHover

        // Build shifted arrangement: remove dragged, insert gap at hover position
        var compacted: [CGWindowID] = []
        for wid in cellAssignments {
            if let wid, wid != dragWid { compacted.append(wid) }
        }

        var result: [CGWindowID?] = Array(repeating: nil, count: cols * rows)
        var ci = 0
        for i in 0..<result.count {
            if i == newHover {
                result[i] = dragWid  // Reserve for dragged
            } else if ci < compacted.count {
                result[i] = compacted[ci]
                ci += 1
            }
        }
        displayAssignments = result

        // Update animation targets for all non-dragged windows
        updateTargets(excludeDragged: true)
    }

    /// Finalize the drag — commit the shuffled arrangement.
    /// `dropPosition` is the dragged window's current position in AX coords (where the user released it).
    func endDrag(dropPosition: CGPoint? = nil) {
        guard isDragging, let dragWid = draggedWindowId else { return }

        cellAssignments = displayAssignments

        // Set currentPos to where the user actually dropped the window,
        // so the animation goes drop → target (not old cell → target).
        if let drop = dropPosition {
            currentPos[dragWid] = CGPoint(x: round(drop.x), y: round(drop.y))
        }

        isDragging = false
        draggedWindowId = nil
        dragSourceIndex = -1
        currentHoverIndex = -1

        // Animate the dropped window to its final cell
        updateTargets(excludeDragged: false)
    }

    // MARK: - Magnetic Borders (window resize → flex neighbors)

    /// Called when a bento window is resized by the user (via window edge drag).
    /// Adjusts grid proportions so adjacent windows flex to fill the space.
    func handleWindowResize(windowId: CGWindowID, newFrame: CGRect) {
        guard isActive, !isDragging else { return }

        // Cooldown: ignore AX events shortly after we repositioned (avoids feedback loop)
        if Date().timeIntervalSince(lastRepositionTime) < repositionCooldown { return }

        guard let idx = cellAssignments.firstIndex(of: windowId) else { return }

        // Ignore if the frame matches our target — this is our own AX positioning, not user resize
        if let tPos = targetPos[windowId], let tSize = targetSize[windowId] {
            if abs(newFrame.width - tSize.width) < 4 && abs(newFrame.height - tSize.height) < 4
                && abs(newFrame.origin.x - tPos.x) < 4 && abs(newFrame.origin.y - tPos.y) < 4 {
                return
            }
        }

        let row = idx / cols
        let col = idx % cols
        let oldFrame = cellFrame(row: row, col: col)

        let usableW = gridSize.width - gap * CGFloat(cols + 1)
        let usableH = gridSize.height - gap * CGFloat(rows + 1) - labelReserve * CGFloat(rows)

        var changed = false
        let s = Settings.shared

        // Width change → adjust column proportions
        let dw = newFrame.width - oldFrame.width
        if abs(dw) > 3 && cols > 1 && usableW > 0 {
            let dp = dw / usableW
            let minP = s.bentoMinCellWidth / usableW
            let maxP = s.bentoMaxCellWidth / usableW

            colProportions[col] = max(minP, min(maxP, colProportions[col] + dp))
            // Distribute negative delta to neighbors proportionally
            let remainder = 1.0 - colProportions[col]
            let othersSum = (0..<cols).filter { $0 != col }.reduce(CGFloat(0)) { $0 + colProportions[$1] }
            if othersSum > 0 {
                for c in 0..<cols where c != col {
                    colProportions[c] = max(minP, min(maxP, colProportions[c] * remainder / othersSum))
                }
            }
            // Normalize
            let total = colProportions.reduce(0, +)
            if total > 0 { colProportions = colProportions.map { $0 / total } }
            changed = true
        }

        // Height change → adjust row proportions
        let dh = newFrame.height - oldFrame.height
        if abs(dh) > 3 && rows > 1 && usableH > 0 {
            let dp = dh / usableH
            let minP = s.bentoMinCellHeight / usableH
            let maxP = s.bentoMaxCellHeight / usableH

            rowProportions[row] = max(minP, min(maxP, rowProportions[row] + dp))
            let remainder = 1.0 - rowProportions[row]
            let othersSum = (0..<rows).filter { $0 != row }.reduce(CGFloat(0)) { $0 + rowProportions[$1] }
            if othersSum > 0 {
                for r in 0..<rows where r != row {
                    rowProportions[r] = max(minP, min(maxP, rowProportions[r] * remainder / othersSum))
                }
            }
            let total = rowProportions.reduce(0, +)
            if total > 0 { rowProportions = rowProportions.map { $0 / total } }
            changed = true
        }

        if changed {
            repositionAllWindows()
        }
    }

    // MARK: - Update from scan

    func updateWindows(_ windows: [(windowId: CGWindowID, label: String)]) {
        guard isActive, !isDragging else { return }

        let newIds = Set(windows.map { $0.windowId })
        for w in windows { windowLabels[w.windowId] = w.label }

        // Remove closed
        for (i, wid) in cellAssignments.enumerated() {
            if let wid, !newIds.contains(wid) {
                cellAssignments[i] = nil
                windowLabels.removeValue(forKey: wid)
                currentPos.removeValue(forKey: wid)
                targetPos.removeValue(forKey: wid)
                targetSize.removeValue(forKey: wid)
                sizeApplied.remove(wid)
            }
        }

        let existingIds = Set(cellAssignments.compactMap { $0 })
        let unassigned = windows.filter { !existingIds.contains($0.windowId) }

        // Nothing new — don't reposition (avoids jitter from periodic scans)
        guard !unassigned.isEmpty else { return }

        let totalNeeded = existingIds.count + unassigned.count
        if totalNeeded > cols * rows {
            let all = cellAssignments.compactMap { $0 }.map {
                (windowId: $0, label: windowLabels[$0] ?? "")
            } + unassigned
            activate(windows: all)
            return
        }
        var ui = 0
        for (i, wid) in cellAssignments.enumerated() where wid == nil && ui < unassigned.count {
            cellAssignments[i] = unassigned[ui].windowId
            windowLabels[unassigned[ui].windowId] = unassigned[ui].label
            ui += 1
        }

        displayAssignments = cellAssignments
        updateTargets(excludeDragged: false)
    }

    // MARK: - Responsive Grid Layout

    /// Calculate optimal grid dimensions from screen size, window count, and cell constraints.
    /// Returns (cols, rows) and also sets gridOriginAX/gridSize (centered if cells hit max).
    private func computeResponsiveGrid(windowCount: Int) -> (cols: Int, rows: Int) {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let vf = screen.visibleFrame
        let sh = screen.frame.height

        screenOriginAX = CGPoint(x: vf.origin.x, y: sh - vf.origin.y - vf.height)
        screenSize = CGSize(width: vf.width, height: vf.height)

        let s = Settings.shared
        let minW = s.bentoMinCellWidth
        let maxW = s.bentoMaxCellWidth
        let minH = s.bentoMinCellHeight
        let maxH = s.bentoMaxCellHeight
        let idealW = (minW + maxW) / 2

        guard windowCount > 0 else {
            gridOriginAX = screenOriginAX
            gridSize = screenSize
            return (1, 1)
        }

        // Available space for cells (subtract gaps and label reserves later per candidate)
        let availW = screenSize.width
        let availH = screenSize.height

        // Try candidate column counts and pick the best fit
        let maxPossibleCols = max(1, Int(floor(availW / minW)))
        var bestCols = 1
        var bestRows = windowCount
        var bestScore: CGFloat = -.greatestFiniteMagnitude

        for c in 1...min(maxPossibleCols, windowCount) {
            let r = max(1, Int(ceil(Double(windowCount) / Double(c))))

            let totalGapH = gap * CGFloat(c + 1)
            let totalGapV = gap * CGFloat(r + 1) + labelReserve * CGFloat(r)
            let cellW = (availW - totalGapH) / CGFloat(c)
            let cellH = (availH - totalGapV) / CGFloat(r)

            // Skip if cells would be too small
            if cellW < minW || cellH < minH { continue }

            // Score: prefer cells close to ideal size, penalize excess empty cells
            let clampedW = min(cellW, maxW)
            _ = min(cellH, maxH)
            let aspectScore = min(clampedW / idealW, idealW / clampedW)  // closer to 1 is better
            let emptyPenalty = CGFloat(c * r - windowCount) * 0.1
            let score = aspectScore - emptyPenalty

            if score > bestScore {
                bestScore = score
                bestCols = c
                bestRows = r
            }
        }

        // Compute actual cell sizes (clamped to max)
        let totalGapH = gap * CGFloat(bestCols + 1)
        let totalGapV = gap * CGFloat(bestRows + 1) + labelReserve * CGFloat(bestRows)
        let rawCellW = (availW - totalGapH) / CGFloat(bestCols)
        let rawCellH = (availH - totalGapV) / CGFloat(bestRows)
        let finalCellW = min(rawCellW, maxW)
        let finalCellH = min(rawCellH, maxH)

        // Grid dimensions (may be smaller than screen)
        let gridW = finalCellW * CGFloat(bestCols) + totalGapH
        let gridH = finalCellH * CGFloat(bestRows) + totalGapV

        // Center the grid in available space
        let offsetX = (availW - gridW) / 2
        let offsetY = (availH - gridH) / 2

        gridOriginAX = CGPoint(
            x: screenOriginAX.x + offsetX,
            y: screenOriginAX.y + offsetY
        )
        gridSize = CGSize(width: gridW, height: gridH)

        return (bestCols, bestRows)
    }

    /// Convenience for one-shot Arrange Bento (used by AppDelegate).
    static func responsiveGridDimensions(
        for count: Int, screenWidth: CGFloat, screenHeight: CGFloat
    ) -> (cols: Int, rows: Int) {
        let s = Settings.shared
        let minW = s.bentoMinCellWidth
        let maxW = s.bentoMaxCellWidth
        let minH = s.bentoMinCellHeight
        let idealW = (minW + maxW) / 2
        let gap: CGFloat = 8
        let labelReserve: CGFloat = 64

        let maxCols = max(1, Int(floor(screenWidth / minW)))
        var bestCols = 1, bestRows = count
        var bestScore: CGFloat = -.greatestFiniteMagnitude

        for c in 1...min(maxCols, count) {
            let r = max(1, Int(ceil(Double(count) / Double(c))))
            let totalGapH = gap * CGFloat(c + 1)
            let totalGapV = gap * CGFloat(r + 1) + labelReserve * CGFloat(r)
            let cellW = (screenWidth - totalGapH) / CGFloat(c)
            let cellH = (screenHeight - totalGapV) / CGFloat(r)
            if cellW < minW || cellH < minH { continue }
            let clampedW = min(cellW, maxW)
            let aspectScore = min(clampedW / idealW, idealW / clampedW)
            let emptyPenalty = CGFloat(c * r - count) * 0.1
            let score = aspectScore - emptyPenalty
            if score > bestScore { bestScore = score; bestCols = c; bestRows = r }
        }
        return (bestCols, bestRows)
    }

    // MARK: - Cell Frame

    func cellFrame(row: Int, col: Int) -> CGRect {
        let usableW = gridSize.width - gap * CGFloat(cols + 1)
        let usableH = gridSize.height - gap * CGFloat(rows + 1) - labelReserve * CGFloat(rows)

        var x = gridOriginAX.x + gap
        for c in 0..<col { x += colProportions[c] * usableW + gap }
        let w = colProportions[col] * usableW

        var y = gridOriginAX.y + gap + labelReserve
        for r in 0..<row { y += rowProportions[r] * usableH + gap + labelReserve }
        let h = rowProportions[row] * usableH

        // Round to whole pixels — AX positions are integer-aligned
        return CGRect(x: round(x), y: round(y), width: round(w), height: round(h))
    }

    // MARK: - Cell Lookup

    private func cellIndexForAXPoint(_ point: CGPoint) -> Int {
        var bestIdx = -1
        var bestDist = CGFloat.greatestFiniteMagnitude
        for r in 0..<rows {
            for c in 0..<cols {
                let frame = cellFrame(row: r, col: c)
                let dist = hypot(point.x - frame.midX, point.y - frame.midY)
                if dist < bestDist { bestDist = dist; bestIdx = r * cols + c }
            }
        }
        return bestIdx
    }

    // MARK: - Position Management

    /// Snap all windows to grid immediately (no animation). Used on first activate.
    private func snapAllToGrid() {
        lastRepositionTime = Date()
        currentPos.removeAll()
        targetPos.removeAll()
        targetSize.removeAll()
        sizeApplied.removeAll()

        for r in 0..<rows {
            for c in 0..<cols {
                let idx = r * cols + c
                guard idx < cellAssignments.count,
                      let wid = cellAssignments[idx],
                      let axWin = axWindowProvider?(wid) else { continue }

                let frame = cellFrame(row: r, col: c)

                var size = CGSize(width: frame.width, height: frame.height)
                if let sv = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sv)
                }
                var point = frame.origin
                if let pv = AXValueCreate(.cgPoint, &point) {
                    AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, pv)
                }
                AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)

                currentPos[wid] = frame.origin
                targetPos[wid] = frame.origin
                targetSize[wid] = size
                sizeApplied.insert(wid)
            }
        }
        repositionDividers()
        onRepositioned?()
    }

    /// Update animation targets from displayAssignments.
    private func updateTargets(excludeDragged: Bool) {
        for r in 0..<rows {
            for c in 0..<cols {
                let idx = r * cols + c
                guard idx < displayAssignments.count,
                      let wid = displayAssignments[idx] else { continue }
                if excludeDragged && wid == draggedWindowId { continue }

                let frame = cellFrame(row: r, col: c)
                targetPos[wid] = frame.origin
                let newSize = CGSize(width: frame.width, height: frame.height)
                targetSize[wid] = newSize

                // Initialize current position if new window
                if currentPos[wid] == nil {
                    currentPos[wid] = frame.origin
                }

                // Apply size if changed
                if !sizeApplied.contains(wid) {
                    sizeApplied.insert(wid)
                    if let axWin = axWindowProvider?(wid) {
                        var s = newSize
                        if let sv = AXValueCreate(.cgSize, &s) {
                            AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sv)
                        }
                    }
                }
            }
        }
    }

    /// Called by divider resize — immediately reposition + resize all windows.
    func repositionAllWindows() {
        lastRepositionTime = Date()
        displayAssignments = cellAssignments
        sizeApplied.removeAll()  // Force size re-apply

        for r in 0..<rows {
            for c in 0..<cols {
                let idx = r * cols + c
                guard idx < cellAssignments.count,
                      let wid = cellAssignments[idx],
                      let axWin = axWindowProvider?(wid) else { continue }

                let frame = cellFrame(row: r, col: c)
                targetPos[wid] = frame.origin
                currentPos[wid] = frame.origin  // Snap (no animation for resize)
                targetSize[wid] = CGSize(width: frame.width, height: frame.height)
                sizeApplied.insert(wid)

                var size = CGSize(width: frame.width, height: frame.height)
                if let sv = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sv)
                }
                var point = frame.origin
                if let pv = AXValueCreate(.cgPoint, &point) {
                    AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, pv)
                }
            }
        }
        repositionDividers()
        onRepositioned?()
    }

    // MARK: - Animation

    private func startAnimationTimer() {
        stopAnimationTimer()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.animationTick()
        }
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func animationTick() {
        var anyMoved = false

        for (wid, target) in targetPos {
            if isDragging && wid == draggedWindowId { continue }

            guard var cur = currentPos[wid] else { continue }

            let dx = target.x - cur.x
            let dy = target.y - cur.y

            // Round to whole pixels — AX snaps to integers anyway.
            // Without this, sub-pixel lerp causes infinite oscillation.
            let rx = round(cur.x + dx * lerpSpeed)
            let ry = round(cur.y + dy * lerpSpeed)

            // Already at target (pixel-exact)?
            if rx == round(target.x) && ry == round(target.y) {
                if rx != round(cur.x) || ry != round(cur.y) {
                    cur = CGPoint(x: round(target.x), y: round(target.y))
                    currentPos[wid] = cur
                    applyPosition(wid, cur)
                    anyMoved = true
                }
                // Settled — nothing to do
                continue
            }

            cur = CGPoint(x: rx, y: ry)
            currentPos[wid] = cur
            applyPosition(wid, cur)
            anyMoved = true
        }

        if anyMoved {
            onRepositioned?()
        }
    }

    private func applyPosition(_ wid: CGWindowID, _ pos: CGPoint) {
        lastRepositionTime = Date()
        guard let axWin = axWindowProvider?(wid) else { return }
        var point = pos
        if let pv = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, pv)
        }
    }

    // MARK: - Dividers

    private func createDividers() {
        destroyDividers()

        for i in 0..<(cols - 1) {
            let div = BentoDividerWindow(axis: .vertical, index: i)
            div.onDrag = { [weak self] delta in self?.handleVDividerDrag(i, delta) }
            vDividers.append(div)
        }
        for i in 0..<(rows - 1) {
            let div = BentoDividerWindow(axis: .horizontal, index: i)
            div.onDrag = { [weak self] delta in self?.handleHDividerDrag(i, delta) }
            hDividers.append(div)
        }

        repositionDividers()
        for d in vDividers { d.show() }
        for d in hDividers { d.show() }
    }

    private func repositionDividers() {
        let sh = NSScreen.screens.first?.frame.height ?? 900

        for (i, div) in vDividers.enumerated() {
            let left = cellFrame(row: 0, col: i)
            let bottom = cellFrame(row: rows - 1, col: i)
            let axCX = left.maxX + gap / 2
            let axTop = left.minY - labelReserve
            let axBot = bottom.maxY
            div.setFrame(
                NSRect(x: axCX - dividerHitWidth / 2, y: sh - axBot,
                       width: dividerHitWidth, height: axBot - axTop),
                display: false
            )
        }

        for (i, div) in hDividers.enumerated() {
            let topCell = cellFrame(row: i, col: 0)
            let botCell = cellFrame(row: i + 1, col: 0)
            let rightCell = cellFrame(row: i, col: cols - 1)
            // Center between bottom of top cell and top of bottom cell
            let axCY = (topCell.maxY + botCell.minY) / 2
            let axL = topCell.minX - gap / 2
            let axR = rightCell.maxX + gap / 2
            div.setFrame(
                NSRect(x: axL, y: sh - axCY - dividerHitWidth / 2,
                       width: axR - axL, height: dividerHitWidth),
                display: false
            )
        }
    }

    private func destroyDividers() {
        for d in vDividers { d.remove(); d.close() }
        for d in hDividers { d.remove(); d.close() }
        vDividers.removeAll()
        hDividers.removeAll()
    }

    // MARK: - Divider Drag

    private func handleVDividerDrag(_ i: Int, _ delta: CGFloat) {
        let usableW = gridSize.width - gap * CGFloat(cols + 1)
        guard usableW > 0 else { return }

        let s = Settings.shared
        let minP = s.bentoMinCellWidth / usableW
        let maxP = s.bentoMaxCellWidth / usableW

        let dp = delta / usableW
        var l = colProportions[i] + dp
        var r = colProportions[i + 1] - dp
        // Clamp to min/max cell widths
        l = max(minP, min(maxP, l))
        r = max(minP, min(maxP, r))
        // Normalize pair
        let sum = colProportions[i] + colProportions[i + 1]
        if l + r != sum { r = sum - l }
        if r < minP { r = minP; l = sum - r }
        colProportions[i] = l
        colProportions[i + 1] = r
        repositionAllWindows()
    }

    private func handleHDividerDrag(_ i: Int, _ delta: CGFloat) {
        let usableH = gridSize.height - gap * CGFloat(rows + 1) - labelReserve * CGFloat(rows)
        guard usableH > 0 else { return }

        let s = Settings.shared
        let minP = s.bentoMinCellHeight / usableH
        let maxP = s.bentoMaxCellHeight / usableH

        let dp = delta / usableH
        var t = rowProportions[i] + dp
        var b = rowProportions[i + 1] - dp
        t = max(minP, min(maxP, t))
        b = max(minP, min(maxP, b))
        let sum = rowProportions[i] + rowProportions[i + 1]
        if t + b != sum { b = sum - t }
        if b < minP { b = minP; t = sum - b }
        rowProportions[i] = t
        rowProportions[i + 1] = b
        repositionAllWindows()
    }
}
