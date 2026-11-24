import Combine
import Foundation

/// Shared by the video surface and the virtual buttons. Coordinates always
/// refer to the remote cursor, never to the floating controls' screen location.
final class RemoteMouseInput {
    var send: ((Float, Float, Int, Int) -> Void)?
    var didCancel: (() -> Void)?
    /// Notifies the visible virtual mouse that the drag lock changed.
    var lockChanged: (() -> Void)?
    /// Routes cursor motion through the touch surface so edge panning stays
    /// consistent. The flag requests 1:1 screen-point motion instead of the
    /// trackpad gain, keeping a cursor-following mouse under the finger.
    var relativeMotion: ((Float, Float, Bool) -> Void)?
    var viewportSize = CGSize(width: 0, height: 0)
    private(set) var x: Float = 0.5
    private(set) var y: Float = 0.5
    private(set) var revision: UInt64 = 0
    private var gestureLeft = false
    private var virtualLeft = false
    private var virtualRight = false
    /// The left button stays pressed until the lock is toggled off.
    private(set) var leftLocked = false
    /// A virtual mouse body is moving the cursor without pressing a button.
    private(set) var isNudging = false
    var hasVirtualButton: Bool { virtualLeft || virtualRight }

    func position(x: Float, y: Float) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }

    func drag(dx: Float, dy: Float, exact: Bool = false) {
        guard hasVirtualButton, viewportSize.width > 0, viewportSize.height > 0 else { return }
        moveCursor(dx: dx, dy: dy, exact: exact)
        emit(0)
    }

    func beginNudge() { isNudging = true }
    func endNudge() { isNudging = false }

    /// Moves the cursor from a virtual mouse body or trackpad without pressing a button.
    func nudge(dx: Float, dy: Float, exact: Bool) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        moveCursor(dx: dx, dy: dy, exact: exact)
        emit(0)
    }

    private func moveCursor(dx: Float, dy: Float, exact: Bool) {
        if let relativeMotion {
            relativeMotion(dx, dy, exact)
        } else {
            let gain: Float = exact ? 1 : 1.35
            position(x: x + dx / Float(viewportSize.width) * gain,
                     y: y + dy / Float(viewportSize.height) * gain)
        }
    }

    func setGestureLeft(_ down: Bool) {
        guard !(down && hasVirtualButton), gestureLeft != down else { return }
        gestureLeft = down
        emit(down ? 1 : 2)
    }

    func setVirtualButton(left: Bool, down: Bool) {
        guard (left ? virtualLeft : virtualRight) != down else { return }
        if down {
            setGestureLeft(false)
            revision &+= 1
        }
        if left { virtualLeft = down } else { virtualRight = down }
        emit(left ? (down ? 1 : 2) : (down ? 3 : 4))
        if left, !down, leftLocked {
            leftLocked = false
            lockChanged?()
        }
    }

    /// Clicks at the current cursor, for taps on a virtual mouse body or trackpad.
    func click(left: Bool) {
        guard !hasVirtualButton else { return }
        setVirtualButton(left: left, down: true)
        setVirtualButton(left: left, down: false)
    }

    func clickMiddle() {
        guard !hasVirtualButton else { return }
        setGestureLeft(false)
        emit(5)
        emit(6)
    }

    func toggleLeftLock() {
        if leftLocked {
            leftLocked = false
            setVirtualButton(left: true, down: false)
        } else {
            setVirtualButton(left: true, down: true)
            leftLocked = virtualLeft
        }
        lockChanged?()
    }

    func scroll(_ direction: Int) {
        guard direction != 0 else { return }
        emit(7, wheel: direction > 0 ? 1 : -1)
    }

    func releaseAll() {
        setGestureLeft(false)
        setVirtualButton(left: true, down: false)
        setVirtualButton(left: false, down: false)
        isNudging = false
        if leftLocked {
            leftLocked = false
            lockChanged?()
        }
        revision &+= 1
        didCancel?()
    }

    private func emit(_ flag: Int, wheel: Int = 0) { send?(x, y, flag, wheel) }
}

enum VirtualMouseStyle: String, CaseIterable, Identifiable {
    /// A mouse-shaped control attached to the remote cursor.
    case cursorFollow
    /// A small floating trackpad with buttons.
    case trackpad
    /// The original three-button bar.
    case classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cursorFollow: return NSLocalizedString("跟随光标", comment: "")
        case .trackpad: return NSLocalizedString("触控板", comment: "")
        case .classic: return NSLocalizedString("经典横条", comment: "")
        }
    }
}

/// Local touch and virtual-mouse preferences. Values are read when gestures
/// run, so changes apply immediately without restarting the session.
final class InputPreferences: ObservableObject {
    static let shared = InputPreferences()

    static let pointerSpeedRange: ClosedRange<Double> = 0.4...2.5
    static let scrollSpeedRange: ClosedRange<Double> = 0.5...2.5
    static let opacityRange: ClosedRange<Double> = 0.35...1
    static let mouseScales: [Double] = [0.85, 1, 1.2]

    private enum Key {
        static let pointerSpeed = "crossdesk.mobile.input.pointer-speed"
        static let pointerAcceleration = "crossdesk.mobile.input.pointer-acceleration"
        static let scrollSpeed = "crossdesk.mobile.input.scroll-speed"
        static let naturalScrolling = "crossdesk.mobile.input.natural-scrolling"
        static let scrollMomentum = "crossdesk.mobile.input.scroll-momentum"
        static let mouseStyle = "crossdesk.mobile.input.virtual-mouse-style"
        static let mouseOpacity = "crossdesk.mobile.input.virtual-mouse-opacity"
        static let mouseScale = "crossdesk.mobile.input.virtual-mouse-scale"
        static let guideShown = "crossdesk.mobile.input.gesture-guide-shown"
    }

    private let defaults: UserDefaults

    @Published var pointerSpeed: Double {
        didSet { defaults.set(pointerSpeed, forKey: Key.pointerSpeed) }
    }
    @Published var pointerAcceleration: Bool {
        didSet { defaults.set(pointerAcceleration, forKey: Key.pointerAcceleration) }
    }
    @Published var scrollSpeed: Double {
        didSet { defaults.set(scrollSpeed, forKey: Key.scrollSpeed) }
    }
    @Published var naturalScrolling: Bool {
        didSet { defaults.set(naturalScrolling, forKey: Key.naturalScrolling) }
    }
    @Published var scrollMomentum: Bool {
        didSet { defaults.set(scrollMomentum, forKey: Key.scrollMomentum) }
    }
    @Published var virtualMouseStyle: VirtualMouseStyle {
        didSet { defaults.set(virtualMouseStyle.rawValue, forKey: Key.mouseStyle) }
    }
    @Published var virtualMouseOpacity: Double {
        didSet { defaults.set(virtualMouseOpacity, forKey: Key.mouseOpacity) }
    }
    @Published var virtualMouseScale: Double {
        didSet { defaults.set(virtualMouseScale, forKey: Key.mouseScale) }
    }
    @Published var gestureGuideShown: Bool {
        didSet { defaults.set(gestureGuideShown, forKey: Key.guideShown) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func double(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            guard let value = defaults.object(forKey: key) as? Double, value.isFinite else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        pointerSpeed = double(Key.pointerSpeed, 1, Self.pointerSpeedRange)
        pointerAcceleration = bool(Key.pointerAcceleration, true)
        scrollSpeed = double(Key.scrollSpeed, 1, Self.scrollSpeedRange)
        naturalScrolling = bool(Key.naturalScrolling, true)
        scrollMomentum = bool(Key.scrollMomentum, true)
        virtualMouseStyle = defaults.string(forKey: Key.mouseStyle)
            .flatMap(VirtualMouseStyle.init(rawValue:)) ?? .cursorFollow
        virtualMouseOpacity = double(Key.mouseOpacity, 0.82, Self.opacityRange)
        virtualMouseScale = double(Key.mouseScale, 1, 0.85...1.2)
        gestureGuideShown = bool(Key.guideShown, false)
    }
}
