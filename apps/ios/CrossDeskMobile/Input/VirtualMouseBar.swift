import SwiftUI
import UIKit

struct VirtualMouseBar: View {
    static let size = CGSize(width: 140, height: 68)
    let input: RemoteMouseInput
    let center: CGPoint
    let constrain: (CGPoint) -> CGPoint
    let moved: (CGPoint) -> Void
    @GestureState private var translation = CGSize.zero

    private func translated(by offset: CGSize) -> CGPoint {
        constrain(CGPoint(x: center.x + offset.width, y: center.y + offset.height))
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.gray)
                .frame(width: 28, height: 3)
                .frame(width: Self.size.width, height: 20)
                .contentShape(Rectangle())
                .accessibilityLabel(NSLocalizedString("拖动虚拟鼠标", comment: ""))
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($translation) { value, state, _ in state = value.translation }
                    .onEnded { value in moved(translated(by: value.translation)) })
            VirtualMouseKeys(input: input)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(Color(red: 212 / 255, green: 218 / 255, blue: 226 / 255), lineWidth: 0.5)
            .allowsHitTesting(false))
        .position(translated(by: translation))
    }
}

private struct VirtualMouseKeys: UIViewRepresentable {
    let input: RemoteMouseInput

    func makeUIView(context: Context) -> VirtualMouseBarView {
        VirtualMouseBarView(input: input)
    }

    func updateUIView(_ view: VirtualMouseBarView, context: Context) {}

    static func dismantleUIView(_ view: VirtualMouseBarView, coordinator: ()) {
        view.input.releaseAll()
    }
}

final class VirtualMouseBarView: UIView {
    let input: RemoteMouseInput
    private let keys: [VirtualMouseKey]

    init(input: RemoteMouseInput) {
        self.input = input
        keys = [VirtualMouseKey(kind: .left, input: input),
                VirtualMouseKey(kind: .wheel, input: input),
                VirtualMouseKey(kind: .right, input: input)]
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        keys.forEach(addSubview)
        input.didCancel = { [weak self] in self?.keys.forEach { $0.cancelTracking() } }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, bounds.width - 8) / 3
        for (index, key) in keys.enumerated() {
            key.frame = CGRect(x: 4 + CGFloat(index) * width, y: 2,
                               width: width, height: max(0, bounds.height - 4))
        }
    }
}

private final class VirtualMouseKey: UIView {
    enum Kind { case left, wheel, right }
    private let kind: Kind
    private let input: RemoteMouseInput
    /// Moves the cursor 1:1 with the finger, for controls attached to the cursor.
    private let exactDrag: Bool
    private let face = UIView()
    private let faceMask = CAShapeLayer()
    private let wheelIcon = VirtualMouseWheelView()
    private var trackedTouch: UITouch?
    private var lastPoint = CGPoint.zero
    private var remainder: CGFloat = 0
    private var travel: CGFloat = 0
    private var startTime: TimeInterval = 0

    init(kind: Kind, input: RemoteMouseInput, exactDrag: Bool = false) {
        self.kind = kind
        self.input = input
        self.exactDrag = exactDrag
        super.init(frame: .zero)
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = kind == .wheel ? [.adjustable] : [.button]
        accessibilityLabel = kind == .left ? NSLocalizedString("鼠标左键", comment: "") : kind == .right ? NSLocalizedString("鼠标右键", comment: "") : NSLocalizedString("鼠标滚轮", comment: "")
        accessibilityHint = kind == .wheel ? NSLocalizedString("上下滑动滚动，轻点为中键", comment: "") : NSLocalizedString("按住并拖动，可滑出按键范围，松开结束拖拽", comment: "")
        face.isUserInteractionEnabled = false
        face.layer.mask = faceMask
        addSubview(face)
        wheelIcon.isHidden = kind != .wheel
        wheelIcon.isUserInteractionEnabled = false
        addSubview(wheelIcon)
        highlight(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        // All three controls keep a 44 × 44 pt hit area; only the wheel's face
        // narrows to 18 pt. Empty gutters separate it from the two paddles.
        face.frame = kind == .wheel
            ? CGRect(x: (bounds.width - 18) / 2, y: (bounds.height - 30) / 2, width: 18, height: 30)
            : bounds.insetBy(dx: 1, dy: 2)
        let leftRadius: CGFloat = kind == .left ? 14 : 6
        let rightRadius: CGFloat = kind == .right ? 14 : 6
        faceMask.frame = face.bounds
        faceMask.path = facePath(in: face.bounds, leftRadius: leftRadius, rightRadius: rightRadius).cgPath
        wheelIcon.frame = face.frame.insetBy(dx: 3, dy: 3)
    }

    private func facePath(in rect: CGRect, leftRadius: CGFloat, rightRadius: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let left = min(leftRadius, rect.height / 2, rect.width / 2)
        let right = min(rightRadius, rect.height / 2, rect.width / 2)
        path.move(to: CGPoint(x: rect.minX + left, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - right, y: rect.minY))
        path.addArc(withCenter: CGPoint(x: rect.maxX - right, y: rect.minY + right),
                    radius: right, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - right))
        path.addArc(withCenter: CGPoint(x: rect.maxX - right, y: rect.maxY - right),
                    radius: right, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + left, y: rect.maxY))
        path.addArc(withCenter: CGPoint(x: rect.minX + left, y: rect.maxY - left),
                    radius: left, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + left))
        path.addArc(withCenter: CGPoint(x: rect.minX + left, y: rect.minY + left),
                    radius: left, startAngle: .pi, endAngle: .pi * 1.5, clockwise: true)
        path.close()
        return path
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, let touch = touches.first else { return }
        if kind == .left, input.leftLocked {
            // Pressing the left button ends a locked drag.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            input.toggleLeftLock()
            return
        }
        trackedTouch = touch
        lastPoint = touch.location(in: window)
        remainder = 0
        travel = 0
        startTime = touch.timestamp
        highlight(true)
        if kind != .wheel { input.setVirtualButton(left: kind == .left, down: true) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let point = touch.location(in: window)
        let delta = CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y)
        lastPoint = point
        travel += hypot(delta.x, delta.y)
        if kind != .wheel {
            input.drag(dx: Float(delta.x), dy: Float(delta.y), exact: exactDrag)
            return
        }
        wheelIcon.advance(by: delta.y)
        remainder += delta.y
        let ticks = Int(remainder / 10)
        if ticks != 0 {
            // UIKit keeps delivering this touch outside the 44 pt key. Finger
            // down maps to negative wheel units (scroll down) on the desktop.
            for _ in 0..<min(abs(ticks), 32) { input.scroll(ticks > 0 ? -1 : 1) }
            remainder -= CGFloat(ticks) * 10
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        // A short tap on the wheel is a middle click, like pressing a real wheel.
        let middleClick = kind == .wheel && travel < 4 && touch.timestamp - startTime < 0.3
        cancelTracking()
        if middleClick {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            input.clickMiddle()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelTracking() }

    func cancelTracking() {
        if trackedTouch != nil, kind != .wheel {
            input.setVirtualButton(left: kind == .left, down: false)
        }
        trackedTouch = nil
        remainder = 0
        highlight(false)
    }

    override func accessibilityActivate() -> Bool {
        if kind == .wheel { accessibilityIncrement() }
        else {
            input.setVirtualButton(left: kind == .left, down: true)
            input.setVirtualButton(left: kind == .left, down: false)
        }
        return true
    }
    override func accessibilityIncrement() {
        if kind == .wheel { wheelIcon.advance(by: 10); input.scroll(-1) }
    }
    override func accessibilityDecrement() {
        if kind == .wheel { wheelIcon.advance(by: -10); input.scroll(1) }
    }

    private func highlight(_ pressed: Bool) {
        face.backgroundColor = pressed ? UIColor(red: 46 / 255, green: 122 / 255, blue: 219 / 255, alpha: 1)
            : UIColor(red: 237 / 255, green: 240 / 255, blue: 244 / 255, alpha: 1)
        wheelIcon.strokeColor = pressed ? .white
            : UIColor(red: 48 / 255, green: 54 / 255, blue: 64 / 255, alpha: 0.72)
    }
}

/// A clipped conveyor of wheel treads: follows touch movement and stops on lift.
private final class VirtualMouseWheelView: UIView {
    var strokeColor = UIColor.black { didSet { setNeedsDisplay() } }
    private var phase: CGFloat = 2
    private let pitch: CGFloat = 5

    init() {
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func advance(by distance: CGFloat) {
        phase = (phase + distance * 0.65).truncatingRemainder(dividingBy: pitch)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        UIBezierPath(roundedRect: bounds, cornerRadius: 2).addClip()
        context.setFillColor(strokeColor.cgColor)
        for index in -1...6 {
            let y = CGFloat(index) * pitch + phase
            context.fill(CGRect(x: 0, y: y, width: bounds.width, height: 1.5))
        }
    }
}

// MARK: - Shared virtual mouse parts

/// Toggles a held left button so a single finger can drag files or select text.
/// It requires a deliberate long press, so brushing past it does nothing.
private final class VirtualMouseLockButton: UIButton {
    let input: RemoteMouseInput

    init(input: RemoteMouseInput) {
        self.input = input
        super.init(frame: .zero)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.minimumPressDuration = 0.45
        addGestureRecognizer(press)
        accessibilityLabel = NSLocalizedString("拖拽锁定", comment: "")
        accessibilityHint = NSLocalizedString("长按切换；锁定后单指滑动即为按住左键拖动", comment: "")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        toggle()
    }

    override func accessibilityActivate() -> Bool {
        toggle()
        return true
    }

    private func toggle() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        input.toggleLeftLock()
    }

    func refresh() {
        let locked = input.leftLocked
        let configuration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        setImage(UIImage(systemName: locked ? "lock.fill" : "lock.open",
                         withConfiguration: configuration), for: .normal)
        tintColor = locked ? .white : UIColor(white: 1, alpha: 0.78)
        backgroundColor = locked
            ? UIColor(red: 46 / 255, green: 122 / 255, blue: 219 / 255, alpha: 1)
            : UIColor(white: 1, alpha: 0.14)
        accessibilityValue = locked ? NSLocalizedString("已锁定", comment: "")
            : NSLocalizedString("未锁定", comment: "")
    }
}

/// A touch area that moves the cursor without pressing a button. A short tap
/// clicks; a short two-finger tap right-clicks.
private final class VirtualMousePad: UIView {
    enum Style { case mouseBody, trackpad }

    let input: RemoteMouseInput
    private let exact: Bool
    private let style: Style
    var onTap: (() -> Void)?
    var onSecondaryTap: (() -> Void)?
    private let icon = UIImageView()
    private var trackedTouch: UITouch?
    private var lastPoint = CGPoint.zero
    private var startTime: TimeInterval = 0
    private var travel: CGFloat = 0
    private var maximumTouches = 0

    init(input: RemoteMouseInput, exact: Bool, style: Style) {
        self.input = input
        self.exact = exact
        self.style = style
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = style == .trackpad ? UIColor(white: 1, alpha: 0.08) : .clear
        layer.cornerRadius = style == .trackpad ? 12 : 0
        layer.cornerCurve = .continuous
        icon.image = UIImage(systemName: style == .mouseBody
                             ? "arrow.up.and.down.and.arrow.left.and.right"
                             : "hand.point.up.left")
        icon.tintColor = UIColor(white: 1, alpha: 0.5)
        icon.contentMode = .scaleAspectFit
        icon.isUserInteractionEnabled = false
        addSubview(icon)
        isAccessibilityElement = true
        accessibilityTraits = [.allowsDirectInteraction]
        accessibilityLabel = style == .mouseBody ? NSLocalizedString("拖动移动光标", comment: "")
            : NSLocalizedString("触控板", comment: "")
        accessibilityHint = NSLocalizedString("滑动移动光标，轻点为左键，双指轻点为右键", comment: "")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(20, bounds.height * 0.3)
        let centerY = bounds.midY
        icon.frame = CGRect(x: bounds.midX - side / 2, y: centerY - side / 2,
                            width: side, height: side)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        maximumTouches = max(maximumTouches, event?.touches(for: self)?.count ?? touches.count)
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        lastPoint = touch.location(in: window)
        startTime = touch.timestamp
        travel = 0
        input.beginNudge()
        highlight(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let point = touch.location(in: window)
        let delta = CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y)
        lastPoint = point
        travel += hypot(delta.x, delta.y)
        if input.hasVirtualButton {
            // A held or locked button turns body movement into a drag.
            input.drag(dx: Float(delta.x), dy: Float(delta.y), exact: exact)
        } else {
            input.nudge(dx: Float(delta.x), dy: Float(delta.y), exact: exact)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let tapped = travel < 8 && touch.timestamp - startTime < 0.3
        let fingers = maximumTouches
        cancelTracking()
        guard tapped, !input.hasVirtualButton else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if fingers >= 2 { onSecondaryTap?() } else { onTap?() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelTracking()
    }

    func cancelTracking() {
        if trackedTouch != nil { input.endNudge() }
        trackedTouch = nil
        maximumTouches = 0
        highlight(false)
    }

    private func highlight(_ active: Bool) {
        switch style {
        case .mouseBody:
            backgroundColor = active ? UIColor(white: 1, alpha: 0.08) : .clear
        case .trackpad:
            backgroundColor = UIColor(white: 1, alpha: active ? 0.16 : 0.08)
        }
        icon.tintColor = UIColor(white: 1, alpha: active ? 0.8 : 0.5)
    }
}

// MARK: - Cursor-following mouse

/// A mouse-shaped control fused with the pointer: the shell's top-left corner
/// extends into a pointed tail whose tip is the remote cursor's hotspot.
/// Dragging the body moves the cursor 1:1, so the buttons always stay under
/// the finger and the finger never covers the cursor. Holding a button while
/// sliding drags, so no separate drag lock is needed.
final class FollowMouseView: UIView {
    static let baseSize = CGSize(width: 104, height: 120)
    /// Default distance from the hotspot to the body's top-left corner, at 1x.
    static let tipOffset: CGFloat = 12

    let input: RemoteMouseInput
    /// The cursor hotspot in this view's coordinates; normally up-left of the body.
    var tip = CGPoint(x: -FollowMouseView.tipOffset, y: -FollowMouseView.tipOffset) {
        didSet { if tip != oldValue { updateShell() } }
    }
    private let leftKey: VirtualMouseKey
    private let wheelKey: VirtualMouseKey
    private let rightKey: VirtualMouseKey
    private let body: VirtualMousePad
    private let shell = CAShapeLayer()
    private let tipMarker = CAShapeLayer()

    init(input: RemoteMouseInput) {
        self.input = input
        leftKey = VirtualMouseKey(kind: .left, input: input, exactDrag: true)
        wheelKey = VirtualMouseKey(kind: .wheel, input: input, exactDrag: true)
        rightKey = VirtualMouseKey(kind: .right, input: input, exactDrag: true)
        body = VirtualMousePad(input: input, exact: true, style: .mouseBody)
        super.init(frame: CGRect(origin: .zero, size: Self.baseSize))
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        // The tail is drawn outside the bounds; never clip it.
        clipsToBounds = false
        shell.fillColor = UIColor(white: 0.09, alpha: 0.9).cgColor
        shell.strokeColor = UIColor(white: 1, alpha: 0.24).cgColor
        shell.lineWidth = 1
        shell.lineJoin = .round
        shell.shadowColor = UIColor.black.cgColor
        shell.shadowOpacity = 0.35
        shell.shadowRadius = 8
        shell.shadowOffset = CGSize(width: 0, height: 3)
        layer.insertSublayer(shell, at: 0)
        let parts: [UIView] = [body, leftKey, wheelKey, rightKey]
        parts.forEach(addSubview)
        // A crisp white arrowhead marks the exact click point, like a cursor tip.
        tipMarker.fillColor = UIColor.white.cgColor
        tipMarker.strokeColor = UIColor.black.withAlphaComponent(0.85).cgColor
        tipMarker.lineWidth = 1
        tipMarker.lineJoin = .round
        layer.addSublayer(tipMarker)
        body.onTap = { [weak input] in input?.click(left: true) }
        body.onSecondaryTap = { [weak input] in input?.click(left: false) }
        input.didCancel = { [weak self] in self?.cancelTracking() }
        input.lockChanged = nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var cornerRadius: CGFloat { min(26, bounds.width * 0.26, bounds.height / 2) }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Touches on the tail or outside the rounded body reach the remote screen.
        UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = bounds.height
        let inset = max(4, width * 0.045)
        let topHeight = height * 0.46
        let wheelWidth = max(22, width * 0.22)
        let keyWidth = max(0, (width - wheelWidth - 2 * inset) / 2)
        leftKey.frame = CGRect(x: inset, y: inset, width: keyWidth, height: topHeight - inset)
        wheelKey.frame = CGRect(x: inset + keyWidth, y: inset,
                                width: wheelWidth, height: topHeight - inset)
        rightKey.frame = CGRect(x: inset + keyWidth + wheelWidth, y: inset,
                                width: keyWidth, height: topHeight - inset)
        body.frame = CGRect(x: 0, y: topHeight, width: width, height: height - topHeight)
        updateShell()
    }

    /// One closed outline: the rounded body with its top-left corner replaced by
    /// a tail that runs to the hotspot.
    private func updateShell() {
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }
        let r = cornerRadius
        let path = UIBezierPath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: r, y: 0))
        path.addLine(to: CGPoint(x: width - r, y: 0))
        path.addArc(withCenter: CGPoint(x: width - r, y: r), radius: r,
                    startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: width, y: height - r))
        path.addArc(withCenter: CGPoint(x: width - r, y: height - r), radius: r,
                    startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: r, y: height))
        path.addArc(withCenter: CGPoint(x: r, y: height - r), radius: r,
                    startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: 0, y: r))
        path.close()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shell.frame = bounds
        shell.path = path.cgPath
        shell.shadowPath = path.cgPath
        let marker = UIBezierPath()
        let size = max(8, Self.tipOffset * 0.85 * width / Self.baseSize.width)
        marker.move(to: tip)
        marker.addLine(to: CGPoint(x: tip.x + size, y: tip.y + size * 0.42))
        marker.addLine(to: CGPoint(x: tip.x + size * 0.42, y: tip.y + size))
        marker.close()
        tipMarker.frame = bounds
        tipMarker.path = marker.cgPath
        CATransaction.commit()
    }

    func cancelTracking() {
        [leftKey, wheelKey, rightKey].forEach { $0.cancelTracking() }
        body.cancelTracking()
    }
}

// MARK: - Floating trackpad

struct VirtualTrackpadPanel: View {
    static let baseSize = CGSize(width: 212, height: 160)

    static func size(scale: CGFloat) -> CGSize {
        CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
    }

    let input: RemoteMouseInput
    let scale: CGFloat
    let center: CGPoint
    let constrain: (CGPoint) -> CGPoint
    let moved: (CGPoint) -> Void
    @GestureState private var translation = CGSize.zero

    private func translated(by offset: CGSize) -> CGPoint {
        constrain(CGPoint(x: center.x + offset.width, y: center.y + offset.height))
    }

    var body: some View {
        let size = Self.size(scale: scale)
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.55))
                .frame(width: 32, height: 4)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .contentShape(Rectangle())
                .accessibilityLabel(NSLocalizedString("拖动虚拟鼠标", comment: ""))
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($translation) { value, state, _ in state = value.translation }
                    .onEnded { value in moved(translated(by: value.translation)) })
            VirtualTrackpadKeys(input: input)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
        .frame(width: size.width, height: size.height)
        .background(Color.black.opacity(0.78),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
            .allowsHitTesting(false))
        .position(translated(by: translation))
    }
}

private struct VirtualTrackpadKeys: UIViewRepresentable {
    let input: RemoteMouseInput

    func makeUIView(context: Context) -> VirtualTrackpadView {
        VirtualTrackpadView(input: input)
    }

    func updateUIView(_ view: VirtualTrackpadView, context: Context) {}

    static func dismantleUIView(_ view: VirtualTrackpadView, coordinator: ()) {
        view.input.releaseAll()
    }
}

final class VirtualTrackpadView: UIView {
    let input: RemoteMouseInput
    private let pad: VirtualMousePad
    private let keys: [VirtualMouseKey]
    private let lockButton: VirtualMouseLockButton

    init(input: RemoteMouseInput) {
        self.input = input
        pad = VirtualMousePad(input: input, exact: false, style: .trackpad)
        keys = [VirtualMouseKey(kind: .left, input: input),
                VirtualMouseKey(kind: .wheel, input: input),
                VirtualMouseKey(kind: .right, input: input)]
        lockButton = VirtualMouseLockButton(input: input)
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        addSubview(pad)
        keys.forEach(addSubview)
        addSubview(lockButton)
        pad.onTap = { [weak input] in input?.click(left: true) }
        pad.onSecondaryTap = { [weak input] in input?.click(left: false) }
        input.didCancel = { [weak self] in self?.cancelTracking() }
        input.lockChanged = { [weak self] in self?.lockButton.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rowHeight = min(46, bounds.height * 0.36)
        pad.frame = CGRect(x: 0, y: 0, width: bounds.width,
                           height: max(0, bounds.height - rowHeight - 4))
        let wheelWidth: CGFloat = 30
        let keyWidth = max(0, (bounds.width - wheelWidth) / 2)
        let rowY = bounds.height - rowHeight
        keys[0].frame = CGRect(x: 0, y: rowY, width: keyWidth, height: rowHeight)
        keys[1].frame = CGRect(x: keyWidth, y: rowY, width: wheelWidth, height: rowHeight)
        keys[2].frame = CGRect(x: keyWidth + wheelWidth, y: rowY, width: keyWidth, height: rowHeight)
        let lockSide: CGFloat = 28
        lockButton.frame = CGRect(x: bounds.width - lockSide - 6, y: 6,
                                  width: lockSide, height: lockSide)
    }

    func cancelTracking() {
        keys.forEach { $0.cancelTracking() }
        pad.cancelTracking()
        lockButton.refresh()
    }
}
