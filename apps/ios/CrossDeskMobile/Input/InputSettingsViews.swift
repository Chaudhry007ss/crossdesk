import SwiftUI

/// Touch and virtual-mouse settings shown in the session's floating menu.
struct FloatingInputSettings: View {
    @ObservedObject var session: RemoteSessionModel
    @ObservedObject private var preferences = InputPreferences.shared
    let showGestureGuide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(NSLocalizedString("控制模式", comment: ""), selection: $session.mouseControlMode) {
                ForEach(MouseControlMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(session.mouseControlMode.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            InputSliderRow(title: NSLocalizedString("指针速度", comment: ""),
                           value: $preferences.pointerSpeed,
                           range: InputPreferences.pointerSpeedRange)
            Toggle(NSLocalizedString("指针加速", comment: ""), isOn: $preferences.pointerAcceleration)
            InputSliderRow(title: NSLocalizedString("滚动速度", comment: ""),
                           value: $preferences.scrollSpeed,
                           range: InputPreferences.scrollSpeedRange)
            Toggle(NSLocalizedString("自然滚动", comment: ""), isOn: $preferences.naturalScrolling)
            Toggle(NSLocalizedString("滚动惯性", comment: ""), isOn: $preferences.scrollMomentum)
            Toggle(NSLocalizedString("键盘悬浮按钮", comment: ""), isOn: $preferences.keyboardButtonVisible)

            Divider()
            Text(NSLocalizedString("虚拟鼠标", comment: ""))
                .font(.caption.weight(.semibold))
            VirtualMouseStylePickers(preferences: preferences)

            Button(action: showGestureGuide) {
                Label(NSLocalizedString("手势说明", comment: ""), systemImage: "questionmark.circle")
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
            }
            .buttonStyle(.bordered)
        }
        .font(.footnote)
        .controlSize(.small)
    }
}

/// Settings-screen form section with the same preferences.
struct InputSettingsSection: View {
    @ObservedObject var session: RemoteSessionModel
    @ObservedObject private var preferences = InputPreferences.shared

    var body: some View {
        Section {
            Picker(NSLocalizedString("控制模式", comment: ""), selection: $session.mouseControlMode) {
                ForEach(MouseControlMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            InputSliderRow(title: NSLocalizedString("指针速度", comment: ""),
                           value: $preferences.pointerSpeed,
                           range: InputPreferences.pointerSpeedRange)
            Toggle(NSLocalizedString("指针加速", comment: ""), isOn: $preferences.pointerAcceleration)
            InputSliderRow(title: NSLocalizedString("滚动速度", comment: ""),
                           value: $preferences.scrollSpeed,
                           range: InputPreferences.scrollSpeedRange)
            Toggle(NSLocalizedString("自然滚动", comment: ""), isOn: $preferences.naturalScrolling)
            Toggle(NSLocalizedString("滚动惯性", comment: ""), isOn: $preferences.scrollMomentum)
            Toggle(NSLocalizedString("键盘悬浮按钮", comment: ""), isOn: $preferences.keyboardButtonVisible)
        } header: {
            Text(NSLocalizedString("鼠标控制", comment: ""))
        } footer: {
            Text(session.mouseControlMode.detail)
        }

        Section {
            VirtualMouseStylePickers(preferences: preferences)
            Button(NSLocalizedString("重新显示手势说明", comment: "")) {
                preferences.gestureGuideShown = false
            }
            .disabled(!preferences.gestureGuideShown)
        } header: {
            Text(NSLocalizedString("虚拟鼠标", comment: ""))
        } footer: {
            Text(NSLocalizedString("跟随光标：鼠标贴在远程光标旁，拖动鼠标身体即可移动光标。触控板：悬浮的小触控板。", comment: ""))
        }
    }
}

private struct VirtualMouseStylePickers: View {
    @ObservedObject var preferences: InputPreferences

    var body: some View {
        Picker(NSLocalizedString("样式", comment: ""), selection: $preferences.virtualMouseStyle) {
            ForEach(VirtualMouseStyle.allCases) { style in
                Text(style.title).tag(style)
            }
        }
        .pickerStyle(.segmented)
        Picker(NSLocalizedString("大小", comment: ""), selection: $preferences.virtualMouseScale) {
            Text(NSLocalizedString("小", comment: "")).tag(InputPreferences.mouseScales[0])
            Text(NSLocalizedString("中", comment: "")).tag(InputPreferences.mouseScales[1])
            Text(NSLocalizedString("大", comment: "")).tag(InputPreferences.mouseScales[2])
        }
        .pickerStyle(.segmented)
        InputSliderRow(title: NSLocalizedString("不透明度", comment: ""),
                       value: $preferences.virtualMouseOpacity,
                       range: InputPreferences.opacityRange,
                       format: { String(format: "%.0f%%", $0 * 100) })
    }
}

private struct InputSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.1f×", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
        }
    }
}

/// First-run overlay listing the gestures for each control mode.
struct RemoteGestureGuide: View {
    let dismiss: () -> Void
    @State private var mode: MouseControlMode

    init(mode: MouseControlMode, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        _mode = State(initialValue: mode)
    }

    private struct Item: Identifiable {
        let symbol: String
        let gesture: String
        let action: String
        var id: String { gesture }
    }

    private var items: [Item] {
        let pointer: [Item]
        switch mode {
        case .absolute:
            pointer = [
                Item(symbol: "hand.tap", gesture: NSLocalizedString("单指轻点", comment: ""),
                     action: NSLocalizedString("在手指位置左键单击，连点两下为双击", comment: "")),
                Item(symbol: "hand.point.up.left", gesture: NSLocalizedString("单指滑动", comment: ""),
                     action: NSLocalizedString("移动指针；画面放大后为拖动画面", comment: "")),
            ]
        case .relative:
            pointer = [
                Item(symbol: "cursorarrow.rays", gesture: NSLocalizedString("单指滑动", comment: ""),
                     action: NSLocalizedString("移动光标：慢移更精准，快滑走得更远", comment: "")),
                Item(symbol: "hand.tap", gesture: NSLocalizedString("单指轻点", comment: ""),
                     action: NSLocalizedString("在光标处左键单击，连点两下为双击", comment: "")),
            ]
        }
        return pointer + [
            Item(symbol: "hand.point.up.left.fill", gesture: NSLocalizedString("单指长按", comment: ""),
                 action: NSLocalizedString("右键（有震动反馈）", comment: "")),
            Item(symbol: "hand.draw", gesture: NSLocalizedString("轻点后按住拖动", comment: ""),
                 action: NSLocalizedString("按住左键拖拽：选中文字、拖动窗口或文件", comment: "")),
            Item(symbol: "arrow.up.and.down", gesture: NSLocalizedString("双指滑动", comment: ""),
                 action: NSLocalizedString("鼠标滚轮，松手后惯性滚动", comment: "")),
            Item(symbol: "hand.raised", gesture: NSLocalizedString("双指轻点", comment: ""),
                 action: NSLocalizedString("右键", comment: "")),
            Item(symbol: "arrow.up.left.and.arrow.down.right", gesture: NSLocalizedString("双指捏合 / 双指双击", comment: ""),
                 action: NSLocalizedString("缩放画面 / 快速放大或还原", comment: "")),
            Item(symbol: "keyboard", gesture: NSLocalizedString("三指轻点", comment: ""),
                 action: NSLocalizedString("打开或收起键盘", comment: "")),
            Item(symbol: "rectangle.on.rectangle", gesture: NSLocalizedString("三指左右滑", comment: ""),
                 action: NSLocalizedString("切换显示器", comment: "")),
            Item(symbol: "computermouse", gesture: NSLocalizedString("虚拟鼠标", comment: ""),
                 action: NSLocalizedString("拖动鼠标身体移动光标；按住左键再滑动即拖拽；轻点滚轮为中键", comment: "")),
        ]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            VStack(spacing: 12) {
                Text(NSLocalizedString("手势说明", comment: ""))
                    .font(.headline)
                Picker(NSLocalizedString("控制模式", comment: ""), selection: $mode) {
                    ForEach(MouseControlMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(.blue)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.gesture).font(.subheadline.weight(.semibold))
                                    Text(item.action).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(maxHeight: 380)
                Button(action: dismiss) {
                    Text(NSLocalizedString("知道了", comment: ""))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(18)
            .frame(maxWidth: 400)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(24)
        }
    }
}
