import SwiftUI
import UIKit

enum RemoteVideoGeometry {
    private static func pixelAligned(_ rect: CGRect) -> CGRect {
        let scale = max(UIScreen.main.scale, 1)
        let minX = (rect.minX * scale).rounded() / scale
        let minY = (rect.minY * scale).rounded() / scale
        let maxX = (rect.maxX * scale).rounded() / scale
        let maxY = (rect.maxY * scale).rounded() / scale
        return CGRect(x: minX, y: minY,
                      width: max(0, maxX - minX),
                      height: max(0, maxY - minY))
    }

    static func aspectFitRect(containerSize: CGSize,
                              videoSize: CGSize) -> CGRect? {
        guard containerSize.width > 0, containerSize.height > 0,
              videoSize.width > 0, videoSize.height > 0 else { return nil }
        let videoAspect = videoSize.width / videoSize.height
        let containerAspect = containerSize.width / containerSize.height
        if videoAspect > containerAspect {
            let height = containerSize.width / videoAspect
            return pixelAligned(
                CGRect(x: 0, y: (containerSize.height - height) / 2,
                       width: containerSize.width, height: height)
            )
        }
        let width = containerSize.height * videoAspect
        return pixelAligned(
            CGRect(x: (containerSize.width - width) / 2, y: 0,
                   width: width, height: containerSize.height)
        )
    }

    static func transformedRect(containerSize: CGSize,
                                videoSize: CGSize,
                                scale: CGFloat,
                                offset: CGSize) -> CGRect? {
        guard let baseRect = aspectFitRect(containerSize: containerSize,
                                           videoSize: videoSize) else {
            return nil
        }
        // SwiftUI scales the video around the center of its own pixel-aligned
        // frame. That center can differ fractionally from the container center
        // after edge alignment, and the difference is amplified at 10x.
        let center = CGPoint(x: baseRect.midX, y: baseRect.midY)
        return CGRect(
            x: center.x + (baseRect.minX - center.x) * scale + offset.width,
            y: center.y + (baseRect.minY - center.y) * scale + offset.height,
            width: baseRect.width * scale,
            height: baseRect.height * scale
        )
    }

    static func verticalPointerOverflow(y: CGFloat, dy: CGFloat, visibleRect: CGRect) -> CGFloat {
        guard !visibleRect.isNull, !visibleRect.isEmpty else { return 0 }
        if dy > 0 { return min(dy, max(0, y + dy - visibleRect.maxY)) }
        if dy < 0 { return max(dy, min(0, y + dy - visibleRect.minY)) }
        return 0
    }

    // Leave enough room for the cursor glyph around its hotspot.
    static let pointerInset: CGFloat = 18

    static func pointerPan(position: CGFloat, length: CGFloat) -> CGFloat {
        let margin = min(pointerInset, length / 2)
        return min(max(position, margin), length - margin) - position
    }
}

struct RemoteTouchInputView: UIViewRepresentable {
    let mouseInput: RemoteMouseInput
    let keyboardGeometry: RemoteKeyboardGeometry?
    let videoSize: CGSize
    let controlMode: MouseControlMode
    let remoteCursorPosition: CGPoint?
    let remoteCursorPositionRevision: UInt64
    let viewportScale: CGFloat
    let viewportOffset: CGSize
    let viewportChanged: (CGFloat, CGSize) -> Void
    let move: (Float, Float) -> Void
    let leftDown: (Float, Float) -> Void
    let leftUp: (Float, Float) -> Void
    let rightClick: (Float, Float) -> Void
    let scroll: (Float, Float, Int, Int) -> Void
    /// Shows the mouse-shaped control attached to the remote cursor.
    var followMouseVisible = false
    var followMouseScale: CGFloat = 1
    var followMouseOpacity: CGFloat = 0.82
    var toggleKeyboard: () -> Void = {}
    var switchDisplay: (Int) -> Void = { _ in }
    /// Non-empty while a keyboard is shown; changes when its kind changes.
    var keyboardRevision = ""

    func makeUIView(context: Context) -> RemoteTouchSurface {
        RemoteTouchSurface()
    }

    func updateUIView(_ view: RemoteTouchSurface, context: Context) {
        view.mouseInput = mouseInput
        view.keyboardGeometry = keyboardGeometry
        view.videoSize = videoSize
        view.controlMode = controlMode
        view.setViewport(scale: viewportScale, offset: viewportOffset)
        view.onViewportChanged = viewportChanged
        view.onMove = move
        view.onLeftDown = leftDown
        view.onLeftUp = leftUp
        view.onRightClick = rightClick
        view.onScroll = scroll
        view.onToggleKeyboard = toggleKeyboard
        view.onSwitchDisplay = switchDisplay
        view.synchronizeRemoteCursor(remoteCursorPosition,
                                     revision: remoteCursorPositionRevision)
        view.updateFollowMouse(visible: followMouseVisible,
                               scale: followMouseScale,
                               opacity: followMouseOpacity)
        // After keyboardGeometry, so hiding restores against the full height.
        view.keyboardRevision = keyboardRevision
    }

    static func dismantleUIView(_ view: RemoteTouchSurface, coordinator: ()) {
        view.stopMomentum()
        view.updateFollowMouse(visible: false, scale: 1, opacity: 1)
    }
}

/// Keep the initial finger spacing until a pinch is recognized, including short pinches.
private final class FingerPinchGestureRecognizer: UIGestureRecognizer {
    private let spanTolerance: CGFloat = 4
    /// Span change required before two fingers count as a zoom rather than a scroll.
    private let beginThreshold: CGFloat = 10
    private var fingers: [UITouch] = []
    private var referenceSpan: CGFloat = 0
    private var initialSpan: CGFloat = 0

    private var span: CGFloat {
        let first = fingers[0].location(in: view)
        let second = fingers[1].location(in: view)
        return max(spanTolerance, hypot(second.x - first.x, second.y - first.y))
    }

    /// Total spacing change since both fingers landed.
    var spanChange: CGFloat {
        fingers.count == 2 ? abs(span - initialSpan) : 0
    }

    func takeScaleFactor() -> CGFloat {
        let current = span
        let factor = current / referenceSpan
        referenceSpan = current
        return factor
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            if fingers.count < 2 {
                fingers.append(touch)
                if fingers.count == 2 {
                    referenceSpan = span
                    initialSpan = referenceSpan
                }
            } else if state == .possible {
                // A third finger belongs to a three-finger gesture.
                state = .failed
                return
            } else {
                ignore(touch, for: event)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard fingers.count == 2 else { return }
        if state == .possible {
            if abs(span - referenceSpan) >= beginThreshold { state = .began }
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        fingers.removeAll(keepingCapacity: true)
        referenceSpan = 0
        initialSpan = 0
    }
}

/// Gestures (both modes unless noted):
/// - tap: left click; double tap: double click
/// - long press: right click (haptic); two-finger tap: right click
/// - tap, then press and drag: left-button drag
/// - one finger: touch mode moves the pointer at 1x and pans when zoomed;
///   trackpad mode moves the cursor with acceleration
/// - two-finger slide: wheel with momentum; pinch: zoom; two-finger double tap: smart zoom
/// - three-finger tap: keyboard; three-finger swipe: switch display
final class RemoteTouchSurface: UIView, UIGestureRecognizerDelegate {
    private enum TwoFingerIntent { case undecided, scroll, zoom }

    weak var keyboardGeometry: RemoteKeyboardGeometry?
    var mouseInput: RemoteMouseInput? {
        didSet {
            guard oldValue !== mouseInput else { return }
            oldValue?.relativeMotion = nil
            mouseInput?.relativeMotion = { [weak self] dx, dy, exact in
                _ = self?.updateRelativeCursor(by: CGPoint(x: CGFloat(dx), y: CGFloat(dy)),
                                               gain: exact ? 1 : nil)
                self?.layoutFollowMouse()
            }
            if followMouse != nil {
                followMouse?.removeFromSuperview()
                followMouse = nil
            }
        }
    }
    private var gestureRevisions: [ObjectIdentifier: UInt64] = [:]
    var videoSize = CGSize.zero {
        didSet { setNeedsLayout() }
    }
    var controlMode: MouseControlMode = .absolute {
        didSet {
            guard oldValue != controlMode else { return }
            relativeCursorPoint = lastRemoteCursorPoint ?? (0.5, 0.5)
            relativePanActive = false
            heldDragPoint = nil
            heldDragLastLocation = nil
            hoverLastLocation = nil
            singleFingerViewportPan = false
            stopMomentum()
        }
    }
    var onMove: ((Float, Float) -> Void)?
    var onLeftDown: ((Float, Float) -> Void)?
    var onLeftUp: ((Float, Float) -> Void)?
    var onRightClick: ((Float, Float) -> Void)?
    var onScroll: ((Float, Float, Int, Int) -> Void)?
    var onViewportChanged: ((CGFloat, CGSize) -> Void)?
    var onToggleKeyboard: (() -> Void)?
    var onSwitchDisplay: ((Int) -> Void)?

    private let preferences = InputPreferences.shared
    private var fallbackCursorPoint: (Float, Float) = (0.5, 0.5)
    private var relativeCursorPoint: (Float, Float) {
        get { mouseInput.map { ($0.x, $0.y) } ?? fallbackCursorPoint }
        set {
            fallbackCursorPoint = newValue
            mouseInput?.position(x: newValue.0, y: newValue.1)
        }
    }
    private var lastRemoteCursorPoint: (Float, Float)?
    private var lastRemoteCursorRevision: UInt64?
    private var relativePanActive = false
    private var heldDragPoint: (Float, Float)?
    private var heldDragLastLocation: CGPoint?
    private var hoverLastLocation: CGPoint?
    private var viewportScale: CGFloat = 1
    private var viewportOffset = CGSize.zero
    private var edgePanned = false
    private var followMousePanned = false
    private var needsViewportRestore = true
    private var pinchActive = false
    private let basePointerSpeed: CGFloat = 1.35
    private let maximumViewportScale: CGFloat = 10
    private let smartZoomScale: CGFloat = 2.5
    private let minimumVisibleHeightFraction: CGFloat = 0.2

    private var tapRecognizer: UITapGestureRecognizer?
    private var tapDragRecognizer: UILongPressGestureRecognizer?
    private var fingerPinch: FingerPinchGestureRecognizer?
    /// Set while a tap-and-drag owns the touch so the trailing tap is not clicked again.
    private var tapDragEngaged = false
    private var singleFingerViewportPan = false
    private var twoFingerIntent = TwoFingerIntent.undecided
    private var wheelActive = false
    private var pendingWheelTranslation = CGPoint.zero
    private var scrollRemainder = CGPoint.zero
    private var scrollAnchor: (Float, Float)?
    private var momentumVelocity = CGPoint.zero
    private var momentumLink: CADisplayLink?
    private var momentumTimestamp: CFTimeInterval = 0

    private var followMouse: FollowMouseView?
    private var followMouseScale: CGFloat = 1

    /// While a keyboard is shown the view is lifted so the text caret (the
    /// last click point) stays visible above it, then restored on hide.
    var keyboardRevision = "" {
        didSet {
            guard keyboardRevision != oldValue else { return }
            if keyboardRevision.isEmpty {
                restoreAfterKeyboard()
            } else {
                scheduleKeyboardReveal()
            }
        }
    }
    private var keyboardRevealWork: [DispatchWorkItem] = []
    private var viewportBeforeKeyboard: (scale: CGFloat, offset: CGSize, edgePanned: Bool)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        keyboardLayoutGuide.followsUndockedKeyboard = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        tap.numberOfTouchesRequired = 1
        addGestureRecognizer(tap)
        tapRecognizer = tap

        let smartZoom = UITapGestureRecognizer(target: self, action: #selector(handleSmartZoom(_:)))
        smartZoom.delegate = self
        smartZoom.numberOfTouchesRequired = 2
        smartZoom.numberOfTapsRequired = 2
        addGestureRecognizer(smartZoom)

        let rightTap = UITapGestureRecognizer(target: self, action: #selector(handleRightTap(_:)))
        rightTap.delegate = self
        rightTap.numberOfTouchesRequired = 2
        rightTap.require(toFail: smartZoom)
        tap.require(toFail: rightTap)
        addGestureRecognizer(rightTap)

        let threeFingerTap = UITapGestureRecognizer(target: self,
                                                    action: #selector(handleThreeFingerTap(_:)))
        threeFingerTap.delegate = self
        threeFingerTap.numberOfTouchesRequired = 3
        addGestureRecognizer(threeFingerTap)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self,
                                                 action: #selector(handleThreeFingerSwipe(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 3
            swipe.delegate = self
            addGestureRecognizer(swipe)
            threeFingerTap.require(toFail: swipe)
        }

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        drag.delegate = self
        addGestureRecognizer(drag)

        // Tap once, then press and drag: the trackpad convention for a held
        // left button. The press must start within the system double-tap interval.
        let tapDrag = UILongPressGestureRecognizer(target: self,
                                                   action: #selector(handleTapDrag(_:)))
        tapDrag.numberOfTapsRequired = 1
        tapDrag.numberOfTouchesRequired = 1
        tapDrag.minimumPressDuration = 0.1
        tapDrag.allowableMovement = 24
        tapDrag.delegate = self
        addGestureRecognizer(tapDrag)
        tapDragRecognizer = tapDrag

        let longPress = UILongPressGestureRecognizer(target: self,
                                                     action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.allowableMovement = 10
        longPress.numberOfTouchesRequired = 1
        longPress.delegate = self
        addGestureRecognizer(longPress)

        let pinch = FingerPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pinch.delegate = self
        addGestureRecognizer(pinch)
        rightTap.require(toFail: pinch)
        fingerPinch = pinch

        // Trackpads deliver their pinch through UIKit's indirect gesture path.
        let trackpadPinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        trackpadPinch.allowedTouchTypes = [UITouch.TouchType.indirect, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        trackpadPinch.delegate = self
        addGestureRecognizer(trackpadPinch)

        let wheel = UIPanGestureRecognizer(target: self, action: #selector(handleWheel(_:)))
        wheel.minimumNumberOfTouches = 2
        wheel.maximumNumberOfTouches = 2
        wheel.delegate = self
        addGestureRecognizer(wheel)

        let hover = UIHoverGestureRecognizer(target: self,
                                             action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

        // The system keyboard can change height after it appears (emoji,
        // candidates, dictation); re-check that the caret is still visible.
        NotificationCenter.default.addObserver(self, selector: #selector(systemKeyboardDidShow),
                                               name: UIResponder.keyboardDidShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemKeyboardDidShow),
                                               name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
    }

    // MARK: - Keyboard avoidance

    @objc private func systemKeyboardDidShow() {
        guard !keyboardRevision.isEmpty else { return }
        revealCursorAboveKeyboard()
    }

    private func scheduleKeyboardReveal() {
        keyboardRevealWork.forEach { $0.cancel() }
        // Keyboards animate in and are measured after layout; try a few times.
        keyboardRevealWork = [0.05, 0.3, 0.6].map { delay in
            let work = DispatchWorkItem { [weak self] in self?.revealCursorAboveKeyboard() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func revealCursorAboveKeyboard() {
        guard !keyboardRevision.isEmpty, let geometry = keyboardGeometry,
              let rect = renderRect(), rect.height > 0 else { return }
        let visibleHeight = geometry.visibleHeight(in: self)
        guard visibleHeight > 80, visibleHeight < bounds.height - 1 else { return }
        let cursorY = rect.minY + CGFloat(relativeCursorPoint.1) * rect.height
        // Keep the caret line plus a little context above the keyboard.
        let target = visibleHeight - min(64, visibleHeight * 0.25)
        guard cursorY > target else { return }
        if viewportBeforeKeyboard == nil {
            viewportBeforeKeyboard = (viewportScale, viewportOffset, edgePanned)
        }
        panForPointer(dx: 0, dy: target - cursorY)
    }

    private func restoreAfterKeyboard() {
        keyboardRevealWork.forEach { $0.cancel() }
        keyboardRevealWork.removeAll()
        guard let saved = viewportBeforeKeyboard else { return }
        viewportBeforeKeyboard = nil
        // Keep the user's own zoom if they changed it while typing.
        guard abs(saved.scale - viewportScale) < 0.001 else { return }
        // keyboardRevision changes during SwiftUI's updateUIView pass; publish
        // on the next run-loop turn so SwiftUI does not warn about state mutation.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.keyboardRevision.isEmpty else { return }
            guard abs(saved.scale - self.viewportScale) < 0.001 else { return }
            self.edgePanned = saved.edgePanned
            self.viewportOffset = self.constrainedViewportOffset(saved.offset,
                                                                 scale: self.viewportScale)
            self.publishViewport()
            if self.followMouse != nil {
                self.adjustViewportForFollowMouse(allowRelax: true)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // The display link retains its target; never leave it running offscreen.
        if newWindow == nil { stopMomentum() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if needsViewportRestore { restoreEdgePanAllowance() }
        mouseInput?.viewportSize = renderRect()?.size ?? .zero
        let constrained = constrainedViewportOffset(viewportOffset,
                                                     scale: viewportScale)
        if constrained != viewportOffset {
            viewportOffset = constrained
            publishViewport()
        }
        layoutFollowMouse()
    }

    func setViewport(scale: CGFloat, offset: CGSize) {
        let nextScale = min(max(scale, 1), maximumViewportScale)
        viewportScale = nextScale
        if nextScale == 1 && offset == .zero {
            edgePanned = false
            followMousePanned = false
        }
        viewportOffset = offset
        if needsViewportRestore { restoreEdgePanAllowance() }
        setNeedsLayout()
        mouseInput?.viewportSize = renderRect()?.size ?? .zero
    }

    private func restoreEdgePanAllowance() {
        // SwiftUI can restore state before assigning the new surface's bounds.
        guard let baseRect = baseRenderRect() else { return }
        needsViewportRestore = false
        if abs(viewportOffset.height) > baseRect.height * (viewportScale - 1) / 2 ||
            abs(viewportOffset.width) > baseRect.width * (viewportScale - 1) / 2 {
            edgePanned = true
        }
    }

    func synchronizeRemoteCursor(_ position: CGPoint?, revision: UInt64) {
        // SwiftUI refreshes this view for video frames and shape-only feedback
        // too. Consume each position update once, even when it arrives during
        // local movement, so a later refresh cannot restore an old coordinate.
        guard revision != lastRemoteCursorRevision else { return }
        lastRemoteCursorRevision = revision
        guard let position else {
            lastRemoteCursorPoint = nil
            return
        }
        let point = (
            Float(min(max(position.x, 0), 1)),
            Float(min(max(position.y, 0), 1))
        )
        lastRemoteCursorPoint = point
        guard controlMode == .relative,
              mouseInput?.hasVirtualButton != true,
              mouseInput?.isNudging != true,
              !relativePanActive,
              heldDragPoint == nil,
              hoverLastLocation == nil,
              momentumLink == nil else { return }
        relativeCursorPoint = point
    }

    // MARK: - Cursor-following virtual mouse

    private var followMouseSize: CGSize {
        CGSize(width: FollowMouseView.baseSize.width * followMouseScale,
               height: FollowMouseView.baseSize.height * followMouseScale)
    }

    /// Space below and right of the cursor tip needed to keep the full fused
    /// mouse (left/right buttons, wheel, and drag body) inside the screen.
    private var followMousePadding: CGSize {
        guard followMouse != nil else { return .zero }
        let offset = FollowMouseView.tipOffset * followMouseScale
        let margin: CGFloat = 8
        let size = followMouseSize
        return CGSize(width: offset + size.width + margin,
                      height: offset + size.height + margin)
    }

    func updateFollowMouse(visible: Bool, scale: CGFloat, opacity: CGFloat) {
        guard visible, let mouseInput else {
            if let mouse = followMouse {
                mouse.removeFromSuperview()
                followMouse = nil
                mouse.input.releaseAll()
                if followMousePanned && keyboardRevision.isEmpty {
                    followMousePanned = false
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.followMouse == nil,
                              self.keyboardRevision.isEmpty else { return }
                        if self.viewportScale <= 1.001 {
                            self.edgePanned = false
                            self.viewportOffset = .zero
                        } else {
                            self.viewportOffset = self.constrainedViewportOffset(
                                self.viewportOffset, scale: self.viewportScale)
                        }
                        self.publishViewport()
                    }
                }
            }
            return
        }
        let justCreated = followMouse == nil
        if followMouse == nil {
            let mouse = FollowMouseView(input: mouseInput)
            addSubview(mouse)
            followMouse = mouse
        }
        followMouse?.alpha = min(max(opacity, 0.2), 1)
        let clampedScale = min(max(scale, 0.6), 1.5)
        let scaleChanged = abs(clampedScale - followMouseScale) > 0.001
        followMouseScale = clampedScale
        if justCreated || scaleChanged {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.adjustViewportForFollowMouse(allowRelax: false)
                self.layoutFollowMouse()
            }
        }
        layoutFollowMouse()
    }

    /// Keeps the fused mouse completely onscreen when the cursor approaches the
    /// bottom (e.g. taskbar) or right edge. At 1x zoom, smoothly relaxes back
    /// to center as the cursor moves away from those edges.
    private func adjustViewportForFollowMouse(allowRelax: Bool) {
        guard followMouse != nil, keyboardRevision.isEmpty,
              let baseRect = baseRenderRect(),
              let rect = renderRect(),
              rect.width > 0, rect.height > 0 else { return }
        let leftMargin = max(RemoteVideoGeometry.pointerInset, safeAreaInsets.left + 8)
        let topMargin = max(RemoteVideoGeometry.pointerInset, safeAreaInsets.top + 8)
        let rightLimit = bounds.width - safeAreaInsets.right
        let bottomLimit = bounds.height - safeAreaInsets.bottom
        let pad = followMousePadding
        let maxCursorX = max(leftMargin, rightLimit - pad.width)
        let maxCursorY = max(topMargin, bottomLimit - pad.height)
        let (nx, ny) = relativeCursorPoint

        if viewportScale <= 1.001 {
            let restX = baseRect.minX + CGFloat(nx) * baseRect.width
            let restY = baseRect.minY + CGFloat(ny) * baseRect.height
            let neededX = min(0, maxCursorX - restX)
            let neededY = min(0, maxCursorY - restY)
            let targetX = allowRelax ? neededX : min(viewportOffset.width, neededX)
            let targetY = allowRelax ? neededY : min(viewportOffset.height, neededY)
            if targetX == 0 && targetY == 0 {
                guard followMousePanned || viewportOffset != .zero else { return }
                edgePanned = false
                followMousePanned = false
                viewportOffset = .zero
                publishViewport()
            } else {
                edgePanned = true
                followMousePanned = true
                let next = constrainedViewportOffset(CGSize(width: targetX, height: targetY),
                                                     scale: viewportScale)
                if next != viewportOffset {
                    viewportOffset = next
                    publishViewport()
                }
            }
            return
        }

        let cursorX = rect.minX + CGFloat(nx) * rect.width
        let cursorY = rect.minY + CGFloat(ny) * rect.height
        var panX: CGFloat = 0
        if cursorX < leftMargin {
            panX = leftMargin - cursorX
        } else if cursorX > maxCursorX {
            panX = maxCursorX - cursorX
        }
        var panY: CGFloat = 0
        if cursorY < topMargin {
            panY = topMargin - cursorY
        } else if cursorY > maxCursorY {
            panY = maxCursorY - cursorY
        }
        if panX != 0 || panY != 0 {
            followMousePanned = true
            panForPointer(dx: panX, dy: panY)
        }
    }

    private func layoutFollowMouse() {
        guard let mouse = followMouse else { return }
        guard let rect = renderRect(), rect.width > 0, rect.height > 0 else {
            mouse.isHidden = true
            return
        }
        mouse.isHidden = false
        let size = followMouseSize
        let (nx, ny) = relativeCursorPoint
        let cursor = CGPoint(x: rect.minX + CGFloat(nx) * rect.width,
                             y: rect.minY + CGFloat(ny) * rect.height)
        // The mouse and pointer are one shape: its tail tip is the hotspot and
        // the body hangs down-right of it, like a real mouse. It never flips.
        let offset = FollowMouseView.tipOffset * followMouseScale
        let margin: CGFloat = 4
        // Fallback clamp if the viewport cannot pan further (e.g. while a
        // keyboard is open); the tail slants smoothly to keep pointing at the tip.
        let maxX = max(margin, bounds.width - safeAreaInsets.right - size.width * 0.5)
        let x = min(cursor.x + offset, maxX)
        let y = cursor.y + offset
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        if mouse.frame != frame { mouse.frame = frame }
        mouse.tip = CGPoint(x: cursor.x - x, y: cursor.y - y)
    }

    // MARK: - Gesture arbitration

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        if let mouse = followMouse, let view = touch.view, view.isDescendant(of: mouse) {
            return false
        }
        stopMomentum()
        if gestureRecognizer is UITapGestureRecognizer || gestureRecognizer is UILongPressGestureRecognizer {
            guard mouseInput?.hasVirtualButton != true else { return false }
            gestureRevisions[ObjectIdentifier(gestureRecognizer)] = mouseInput?.revision ?? 0
        }
        return true
    }

    private func allowsPointerGesture(_ recognizer: UIGestureRecognizer) -> Bool {
        mouseInput?.hasVirtualButton != true &&
            gestureRevisions[ObjectIdentifier(recognizer)] == (mouseInput?.revision ?? 0)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer || gestureRecognizer is UILongPressGestureRecognizer {
            // Decline recognition before a stale long press can cancel the pan
            // used by the other finger to move a held virtual mouse button.
            return allowsPointerGesture(gestureRecognizer)
        }
        if gestureRecognizer is FingerPinchGestureRecognizer || gestureRecognizer is UIPinchGestureRecognizer {
            return mouseInput?.hasVirtualButton != true
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let recognizers = [gestureRecognizer, otherGestureRecognizer]
        // The first tap of a tap-and-drag clicks immediately; the press that
        // follows must stay eligible instead of being failed by that click.
        if recognizers.contains(where: { $0 === tapRecognizer }) &&
            recognizers.contains(where: { $0 === tapDragRecognizer }) {
            return true
        }
        let hasPinch = recognizers.contains { $0 is FingerPinchGestureRecognizer || $0 is UIPinchGestureRecognizer }
        let hasTwoFingerPan = recognizers.contains { recognizer in
            guard let pan = recognizer as? UIPanGestureRecognizer else {
                return false
            }
            return pan.minimumNumberOfTouches == 2
        }
        return hasPinch && hasTwoFingerPan
    }

    // MARK: - Clicks

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard allowsPointerGesture(recognizer), !tapDragEngaged else { return }
        let location = recognizer.location(in: self)
        guard recognizer.state == .ended,
              let point = pointerPoint(for: location) else { return }
#if DEBUG
        NSLog("CrossDesk tap location=%@ normalized=(%.5f, %.5f) " +
              "render=%@ scale=%.4f offset=%@ mode=%@",
              String(describing: location), point.0, point.1,
              renderRect().map { String(describing: $0) } ?? "nil",
              viewportScale, String(describing: viewportOffset),
              controlMode == .relative ? "relative" : "absolute")
#endif
        onMove?(point.0, point.1)
        onLeftDown?(point.0, point.1)
        onLeftUp?(point.0, point.1)
    }

    @objc private func handleRightTap(_ recognizer: UITapGestureRecognizer) {
        guard allowsPointerGesture(recognizer) else { return }
        guard recognizer.state == .ended,
              let point = pointerPoint(for: recognizer.location(in: self)) else { return }
        onMove?(point.0, point.1)
        onRightClick?(point.0, point.1)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard allowsPointerGesture(recognizer), recognizer.state == .began,
              let point = pointerPoint(for: recognizer.location(in: self)) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onMove?(point.0, point.1)
        onRightClick?(point.0, point.1)
    }

    @objc private func handleSmartZoom(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, mouseInput?.hasVirtualButton != true else { return }
        if viewportScale > 1.01 {
            viewportScale = 1
            viewportOffset = .zero
            edgePanned = false
            followMousePanned = false
            publishViewport()
            return
        }
        let focus = recognizer.location(in: self)
        guard renderRect()?.contains(focus) == true else { return }
        zoom(to: smartZoomScale, focus: focus)
    }

    @objc private func handleThreeFingerTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onToggleKeyboard?()
    }

    @objc private func handleThreeFingerSwipe(_ recognizer: UISwipeGestureRecognizer) {
        guard recognizer.state == .ended, mouseInput?.hasVirtualButton != true else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        // Swiping left reveals the next display, like paging.
        onSwitchDisplay?(recognizer.direction == .left ? 1 : -1)
    }

    // MARK: - One finger

    @objc private func handleDrag(_ recognizer: UIPanGestureRecognizer) {
        if controlMode == .relative {
            handleRelativeDrag(recognizer)
            return
        }

        switch recognizer.state {
        case .began:
            // At 1x a sliding finger hovers the pointer; zoomed in it pans the view.
            singleFingerViewportPan = viewportScale > 1.001
            recognizer.setTranslation(.zero, in: self)
            guard !singleFingerViewportPan,
                  let point = normalized(recognizer.location(in: self)) else { return }
            onMove?(point.0, point.1)
        case .changed:
            if singleFingerViewportPan {
                let translation = recognizer.translation(in: self)
                recognizer.setTranslation(.zero, in: self)
                panViewport(by: translation)
                return
            }
            let location = recognizer.location(in: self)
            panForAbsolutePointer(at: location)
            guard let point = normalized(location) else { return }
            onMove?(point.0, point.1)
        default:
            let wasViewportPan = singleFingerViewportPan
            singleFingerViewportPan = false
            if !wasViewportPan && recognizer.state == .ended {
                adjustViewportForFollowMouse(allowRelax: true)
            }
        }
    }

    @objc private func handleTapDrag(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            tapDragEngaged = true
        case .ended, .cancelled, .failed:
            // The trailing tap recognizer may report in the same run-loop turn.
            DispatchQueue.main.async { [weak self] in self?.tapDragEngaged = false }
        default:
            break
        }
        guard allowsPointerGesture(recognizer) else {
            // A virtual button took ownership while the surface gesture was in flight.
            heldDragPoint = nil
            heldDragLastLocation = nil
            return
        }
        if controlMode == .relative {
            handleRelativeHeldDrag(recognizer)
            return
        }

        let location = recognizer.location(in: self)
        if recognizer.state == .changed { panForAbsolutePointer(at: location) }
        let point = normalized(location) ?? heldDragPoint
        switch recognizer.state {
        case .began:
            guard let point else { return }
            heldDragPoint = point
            onMove?(point.0, point.1)
            onLeftDown?(point.0, point.1)
        case .changed:
            guard let point else { return }
            heldDragPoint = point
            onMove?(point.0, point.1)
        case .ended, .cancelled, .failed:
            if let point {
                onLeftUp?(point.0, point.1)
            }
            heldDragPoint = nil
            if recognizer.state == .ended {
                adjustViewportForFollowMouse(allowRelax: true)
            }
        default:
            break
        }
    }

    private func handleRelativeDrag(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            let location = recognizer.location(in: self)
            relativePanActive = canStartRelativePointerGesture(at: location)
            recognizer.setTranslation(.zero, in: self)
            if relativePanActive {
                onMove?(relativeCursorPoint.0, relativeCursorPoint.1)
            }
        case .changed:
            guard relativePanActive else { return }
            let translation = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            let gain = pointerGain(velocity: recognizer.velocity(in: self))
            if let point = updateRelativeCursor(by: translation, gain: gain) {
                onMove?(point.0, point.1)
            }
        default:
            relativePanActive = false
        }
    }

    private func handleRelativeHeldDrag(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            guard canStartRelativePointerGesture(at: location) else { return }
            heldDragLastLocation = location
            heldDragPoint = relativeCursorPoint
            onMove?(relativeCursorPoint.0, relativeCursorPoint.1)
            onLeftDown?(relativeCursorPoint.0, relativeCursorPoint.1)
        case .changed:
            guard let previous = heldDragLastLocation else { return }
            heldDragLastLocation = location
            if let point = updateRelativeCursor(
                by: CGPoint(x: location.x - previous.x,
                            y: location.y - previous.y)
            ) {
                heldDragPoint = point
                onMove?(point.0, point.1)
            }
        case .ended, .cancelled, .failed:
            if let point = heldDragPoint {
                onLeftUp?(point.0, point.1)
            }
            heldDragPoint = nil
            heldDragLastLocation = nil
        default:
            break
        }
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        let location = recognizer.location(in: self)
        if controlMode == .relative {
            switch recognizer.state {
            case .began:
                guard canStartRelativePointerGesture(at: location) else { return }
                hoverLastLocation = location
                onMove?(relativeCursorPoint.0, relativeCursorPoint.1)
            case .changed:
                guard let previous = hoverLastLocation else { return }
                hoverLastLocation = location
                if let point = updateRelativeCursor(
                    by: CGPoint(x: location.x - previous.x,
                                y: location.y - previous.y)
                ) {
                    onMove?(point.0, point.1)
                }
            default:
                hoverLastLocation = nil
            }
            return
        }

        if recognizer.state == .changed { panForAbsolutePointer(at: location) }
        guard recognizer.state == .began || recognizer.state == .changed,
              let point = normalized(location) else { return }
        onMove?(point.0, point.1)
    }

    // MARK: - Two fingers

    @objc private func handlePinch(_ recognizer: UIGestureRecognizer) {
        guard mouseInput?.hasVirtualButton != true else { pinchActive = false; return }
        let focus = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            if recognizer === fingerPinch {
                // A two-finger slide already chose to scroll; keep it a scroll.
                guard twoFingerIntent != .scroll else { pinchActive = false; return }
                twoFingerIntent = .zoom
            }
            // The full touch surface accepts pinches, including letterboxing.
            pinchActive = bounds.contains(focus) && renderRect() != nil
            fallthrough
        case .changed:
            guard pinchActive else { return }
            let factor: CGFloat
            if let pinch = recognizer as? FingerPinchGestureRecognizer {
                factor = pinch.takeScaleFactor()
            } else if let pinch = recognizer as? UIPinchGestureRecognizer {
                factor = pinch.scale
                pinch.scale = 1
            } else { return }
            let oldScale = viewportScale
            let newScale = min(max(oldScale * factor, 1),
                               maximumViewportScale)
            if newScale == 1 {
                // Pinching back to fit also ends any cursor-edge pan, even
                // when the gesture starts at 1x with an off-center image.
                viewportScale = 1
                viewportOffset = .zero
                edgePanned = false
                followMousePanned = false
                publishViewport()
                return
            }
            guard abs(newScale - oldScale) > 0.0001 else { return }
            zoom(to: newScale, focus: focus)
        case .ended, .cancelled, .failed:
            pinchActive = false
            if !wheelActive { twoFingerIntent = .undecided }
            if viewportScale <= 1.001 {
                viewportScale = 1
                viewportOffset = .zero
                edgePanned = false
                followMousePanned = false
                publishViewport()
            }
        default:
            break
        }
    }

    @objc private func handleWheel(_ recognizer: UIPanGestureRecognizer) {
        guard mouseInput?.hasVirtualButton != true else { wheelActive = false; return }
        switch recognizer.state {
        case .began:
            stopMomentum()
            wheelActive = true
            pendingWheelTranslation = .zero
            scrollRemainder = .zero
            scrollAnchor = pointerPoint(for: recognizer.location(in: self))
            if pinchActive { twoFingerIntent = .zoom }
            let translation = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            consumeWheelTranslation(translation)
        case .changed:
            let translation = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            consumeWheelTranslation(translation)
        default:
            if recognizer.state == .ended, twoFingerIntent == .scroll {
                startMomentum(velocity: recognizer.velocity(in: self))
            }
            wheelActive = false
            pendingWheelTranslation = .zero
            if !pinchActive { twoFingerIntent = .undecided }
        }
    }

    private func consumeWheelTranslation(_ translation: CGPoint) {
        switch twoFingerIntent {
        case .undecided:
            pendingWheelTranslation.x += translation.x
            pendingWheelTranslation.y += translation.y
            let distance = hypot(pendingWheelTranslation.x, pendingWheelTranslation.y)
            let spread = fingerPinch?.spanChange ?? 0
            // Fingers moving together scroll; fingers spreading apart zoom.
            guard distance >= 12, spread < distance * 0.6 else { return }
            twoFingerIntent = .scroll
            let pending = pendingWheelTranslation
            pendingWheelTranslation = .zero
            performScroll(pending)
        case .scroll:
            performScroll(translation)
        case .zoom:
            guard viewportScale > 1.001 || pinchActive else { return }
            panViewport(by: translation)
        }
    }

    // MARK: - Scrolling and momentum

    private var scrollStep: CGFloat {
        16 / CGFloat(max(0.25, preferences.scrollSpeed))
    }

    private func performScroll(_ translation: CGPoint) {
        // Natural scrolling moves the content with the fingers: fingers up
        // scrolls down, which the desktop receives as negative wheel units.
        let direction: CGFloat = preferences.naturalScrolling ? 1 : -1
        scrollRemainder.x += translation.x * direction
        scrollRemainder.y += translation.y * direction
        emitScrollTicks()
    }

    private func emitScrollTicks() {
        guard let point = scrollAnchor else {
            scrollRemainder = .zero
            return
        }
        let step = scrollStep
        // The wire format carries one axis and one notch per message.
        if abs(scrollRemainder.y) >= abs(scrollRemainder.x) {
            scrollRemainder.x = 0
            let ticks = Int(scrollRemainder.y / step)
            guard ticks != 0 else { return }
            scrollRemainder.y -= CGFloat(ticks) * step
            for _ in 0..<min(abs(ticks), 12) {
                onScroll?(point.0, point.1, 0, ticks > 0 ? 1 : -1)
            }
        } else {
            scrollRemainder.y = 0
            let ticks = Int(scrollRemainder.x / step)
            guard ticks != 0 else { return }
            scrollRemainder.x -= CGFloat(ticks) * step
            for _ in 0..<min(abs(ticks), 12) {
                onScroll?(point.0, point.1, ticks > 0 ? 1 : -1, 0)
            }
        }
    }

    private func startMomentum(velocity: CGPoint) {
        guard preferences.scrollMomentum, scrollAnchor != nil else { return }
        let direction: CGFloat = preferences.naturalScrolling ? 1 : -1
        var next = CGPoint(x: velocity.x * direction, y: velocity.y * direction)
        if abs(next.y) >= abs(next.x) { next.x = 0 } else { next.y = 0 }
        let speed = hypot(next.x, next.y)
        guard speed.isFinite, speed > 300 else { return }
        let limit: CGFloat = 4500
        if speed > limit {
            next.x *= limit / speed
            next.y *= limit / speed
        }
        stopMomentum()
        momentumVelocity = next
        momentumTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        guard momentumTimestamp != 0 else {
            momentumTimestamp = link.timestamp
            return
        }
        let dt = min(max(link.timestamp - momentumTimestamp, 0), 1.0 / 20)
        momentumTimestamp = link.timestamp
        scrollRemainder.x += momentumVelocity.x * CGFloat(dt)
        scrollRemainder.y += momentumVelocity.y * CGFloat(dt)
        emitScrollTicks()
        // About 0.94 per 60 Hz frame, independent of the display refresh rate.
        let decay = CGFloat(pow(0.94, dt * 60))
        momentumVelocity.x *= decay
        momentumVelocity.y *= decay
        if hypot(momentumVelocity.x, momentumVelocity.y) < 60 { stopMomentum() }
    }

    func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
        momentumVelocity = .zero
        momentumTimestamp = 0
    }

    // MARK: - Pointer mapping

    private var basePointerGain: CGFloat {
        basePointerSpeed * CGFloat(preferences.pointerSpeed)
    }

    /// Slow movement is precise and fast flicks travel further, like a system trackpad.
    private func pointerGain(velocity: CGPoint) -> CGFloat {
        let base = basePointerGain
        guard preferences.pointerAcceleration else { return base }
        let speed = hypot(velocity.x, velocity.y)
        guard speed.isFinite else { return base }
        let t = min(speed / 1400, 1)
        return base * (0.55 + 1.45 * t)
    }

    private func pointerPoint(for location: CGPoint) -> (Float, Float)? {
        if controlMode == .relative {
            guard canStartRelativePointerGesture(at: location) else { return nil }
            return relativeCursorPoint
        }
        return normalized(location)
    }

    private func canStartRelativePointerGesture(at location: CGPoint) -> Bool {
        // The entire touch surface acts as a trackpad, including letterboxing.
        // A valid video rect is still required to scale pointer movement.
        bounds.contains(location) && renderRect() != nil
    }

    private func updateRelativeCursor(by translation: CGPoint,
                                      gain: CGFloat? = nil) -> (Float, Float)? {
        guard let renderRect = renderRect(),
              renderRect.width > 0, renderRect.height > 0 else { return nil }
        let factor = gain ?? basePointerGain
        let delta = CGPoint(x: translation.x * factor,
                            y: translation.y * factor)
        guard delta.x.isFinite, delta.y.isFinite else { return nil }
        guard delta != .zero else { return relativeCursorPoint }
        let (x, y) = relativeCursorPoint
        let nextX = Float(min(max(CGFloat(x) + delta.x / renderRect.width, 0), 1))
        let nextY = Float(min(max(CGFloat(y) + delta.y / renderRect.height, 0), 1))
        if followMouse != nil && keyboardRevision.isEmpty {
            relativeCursorPoint = (nextX, nextY)
            adjustViewportForFollowMouse(allowRelax: true)
            layoutFollowMouse()
            return relativeCursorPoint
        }
        let cursorY = renderRect.minY + CGFloat(y) * renderRect.height
        var panY = -RemoteVideoGeometry.verticalPointerOverflow(
            y: cursorY, dy: delta.y, visibleRect: renderRect.intersection(bounds))
        let cursorX = renderRect.minX + CGFloat(nextX) * renderRect.width
        let nextCursorY = renderRect.minY + CGFloat(nextY) * renderRect.height
        var panX: CGFloat = 0
        if viewportScale > 1.001 {
            panX = RemoteVideoGeometry.pointerPan(position: cursorX, length: bounds.width)
        }
        let upperPoint = CGPoint(x: cursorX + panX, y: min(cursorY, nextCursorY))
        let visibleHeight = keyboardGeometry?.visibleHeight(in: self, at: upperPoint) ?? bounds.height
        if visibleHeight > 0 && (viewportScale > 1.001 || visibleHeight < bounds.height) {
            panY += RemoteVideoGeometry.pointerPan(position: nextCursorY + panY, length: visibleHeight)
        }
        panForPointer(dx: panX, dy: panY)
        relativeCursorPoint = (nextX, nextY)
        layoutFollowMouse()
        return relativeCursorPoint
    }

    private func panForAbsolutePointer(at point: CGPoint) {
        guard let height = keyboardGeometry?.visibleHeight(in: self, at: point),
              height < bounds.height, point.y >= 0, point.y < height,
              let rect = renderRect(), rect.contains(point) else { return }
        let dy = RemoteVideoGeometry.pointerPan(position: point.y, length: height)
        // Keep the remote point under the finger or mouse as the image moves.
        panForPointer(dx: 0, dy: min(max(dy, min(0, height - rect.maxY)), max(0, -rect.minY)))
    }

    private func panForPointer(dx: CGFloat, dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }
        edgePanned = true
        let proposed = CGSize(width: viewportOffset.width + dx, height: viewportOffset.height + dy)
        let next = constrainedViewportOffset(proposed, scale: viewportScale)
        if next != viewportOffset {
            viewportOffset = next
            publishViewport()
        }
    }

    private func panViewport(by translation: CGPoint) {
        let proposed = CGSize(width: viewportOffset.width + translation.x,
                              height: viewportOffset.height + translation.y)
        let next = constrainedViewportOffset(proposed, scale: viewportScale)
        guard next != viewportOffset else { return }
        viewportOffset = next
        publishViewport()
    }

    private func zoom(to newScale: CGFloat, focus: CGPoint) {
        let oldScale = viewportScale
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let ratio = newScale / oldScale
        let proposedOffset = CGSize(
            width: focus.x - center.x -
                (focus.x - center.x - viewportOffset.width) * ratio,
            height: focus.y - center.y -
                (focus.y - center.y - viewportOffset.height) * ratio
        )
        viewportScale = newScale
        viewportOffset = constrainedViewportOffset(proposedOffset,
                                                   scale: newScale)
        publishViewport()
    }

    private func normalized(_ point: CGPoint) -> (Float, Float)? {
        guard let renderRect = renderRect(), renderRect.contains(point) else { return nil }
        return (Float((point.x - renderRect.minX) / renderRect.width),
                Float((point.y - renderRect.minY) / renderRect.height))
    }

    private func renderRect() -> CGRect? {
        RemoteVideoGeometry.transformedRect(
            containerSize: bounds.size,
            videoSize: videoSize,
            scale: viewportScale,
            offset: viewportOffset
        )
    }

    private func baseRenderRect() -> CGRect? {
        RemoteVideoGeometry.aspectFitRect(containerSize: bounds.size,
                                          videoSize: videoSize)
    }

    private func constrainedViewportOffset(_ offset: CGSize,
                                           scale: CGFloat) -> CGSize {
        guard let baseRect = baseRenderRect() else { return offset }
        let horizontalInset = edgePanned && scale > 1.001 ? RemoteVideoGeometry.pointerInset : 0
        let maximumX = max(0, baseRect.width * (scale - 1) / 2) + horizontalInset
        var minimumX = -maximumX
        var minimumY = -max(0, baseRect.height * (scale - 1) / 2)
        var maximumY = -minimumY
        if edgePanned {
            // Reserve 20% of the unobscured height at any zoom; keep the entire
            // image visible when its height is below that minimum.
            let availableHeight = keyboardGeometry?.visibleHeight(in: self) ?? bounds.height
            let visibleHeight = min(baseRect.height * scale, availableHeight * minimumVisibleHeightFraction)
            let halfHeight = baseRect.height * scale / 2
            minimumY = visibleHeight - baseRect.midY - halfHeight
            maximumY = availableHeight - visibleHeight - baseRect.midY + halfHeight

            if followMouse != nil {
                let rightLimit = bounds.width - safeAreaInsets.right
                let pad = followMousePadding
                let halfWidth = baseRect.width * scale / 2
                let minVisibleWidth = min(baseRect.width * scale,
                                          rightLimit * minimumVisibleHeightFraction)
                let targetRight = max(minVisibleWidth, rightLimit - pad.width)
                let followMinX = targetRight - baseRect.midX - halfWidth
                minimumX = min(minimumX, followMinX)
            }
        }
        return CGSize(
            width: min(max(offset.width, minimumX), maximumX),
            height: min(max(offset.height, minimumY), maximumY)
        )
    }

    private func publishViewport() {
        onViewportChanged?(viewportScale, viewportOffset)
        layoutFollowMouse()
    }
}
