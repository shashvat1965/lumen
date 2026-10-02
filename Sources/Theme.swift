import SwiftUI
import AppKit

/// "Instrument Glass": dark tinted glass, hairlines, one signal color (Ion),
/// warm amber for light. Geist for type, tabular figures for values.
enum T {
    static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
    }
    static let panel = hex(0x0B0D12)
    static let well = Color.black.opacity(0.35)
    static let hairline = Color.white.opacity(0.08)
    static let text = hex(0xEDEEF2)
    static let text2 = hex(0xB6B9C2)
    static let text3 = hex(0x868A95)
    static let ion = hex(0x6BE3F5)
    static let warm = hex(0xFFB54A)
    static let xdr = hex(0xFF6B3D)
    static let ok = hex(0x4ADE9A)
    static let warn = hex(0xF5C04A)
    static let bad = hex(0xFF5C6C)
    static let hdr = hex(0xB79BFF)
    static let onAccent = hex(0x05080C)

    static func f(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font {
        let name = switch w {
        case .medium: "Geist-Medium"
        case .semibold: "Geist-SemiBold"
        case .bold, .heavy, .black: "Geist-Bold"
        default: "Geist-Regular"
        }
        return .custom(name, size: size)
    }
    static func mono(_ size: CGFloat) -> Font { .custom("GeistMono-Regular", size: size) }

    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.8)
}

// MARK: - Surfaces

struct Card<Content: View>: View {
    @AppStorage("cardFill") private var fill = 0.045
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(fill)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(T.hairline, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
    }
}

/// Our own blur, tagged so ClearWindow leaves it alone.
final class LumenBlurView: NSVisualEffectView {}

struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = LumenBlurView()
        v.material = .hudWindow
        // The --window preview composites over an in-window wallpaper.
        v.blendingMode = CommandLine.arguments.contains("--window") ? .withinWindow : .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct PanelBackground: ViewModifier {
    @AppStorage("blur") private var blur = true
    @AppStorage("panelTint") private var tint = 0.55
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if blur { Blur() }
                    T.panel.opacity(tint)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func panel(radius: CGFloat = 16) -> some View { modifier(PanelBackground(radius: radius)) }
}

// MARK: - Controls

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct PillStyle: ButtonStyle {
    var prominent = false
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(T.f(11.5, .medium))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .foregroundStyle(prominent ? T.onAccent : T.text)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(prominent ? T.ion : Color.white.opacity(hover ? 0.10 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(prominent ? .clear : T.hairline))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

/// Label for a Menu that looks like our pill buttons.
struct PillMenuLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Text(text).font(T.f(11.5, .medium)).monospacedDigit()
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(T.text3)
        }
        .padding(.horizontal, 9).frame(height: 24)
        .foregroundStyle(T.text)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(T.hairline))
    }
}

extension Menu {
    func pill() -> some View { self.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize() }
}

struct LSwitch: View {
    @Binding var isOn: Bool
    var disabled = false
    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? T.ion : T.well)
                .overlay(Capsule().strokeBorder(Color.white.opacity(isOn ? 0 : 0.10)))
            Circle().fill(isOn ? T.onAccent : Color.white.opacity(0.85))
                .frame(width: 14, height: 14).padding(2)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
        }
        .frame(width: 30, height: 18)
        .opacity(disabled ? 0.4 : 1)
        .contentShape(Capsule())
        .onTapGesture { guard !disabled else { return }; withAnimation(T.spring) { isOn.toggle() } }
    }
}

struct Segmented<V: Hashable>: View {
    let options: [(String, V)]
    @Binding var selection: V
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.1) { label, value in
                let sel = value == selection
                Text(label).font(T.f(11.5, .medium))
                    .foregroundStyle(sel ? T.text : T.text2)
                    .padding(.horizontal, 11).frame(height: 22)
                    .background {
                        if sel {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.10))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)))
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(T.spring) { selection = value } }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.well))
    }
}

/// Thumbless Control Center–style level bar with optional dim and XDR zones.
struct LevelBar: View {
    var value: Double
    var zones: Display.Zones? = nil
    var icon: String? = nil
    var label: String? = nil
    var height: CGFloat = 28
    var tint: Color = T.warm
    var interactive = true
    var onChange: (Double) -> Void = { _ in }
    @State private var hover = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let xdrX = CGFloat(zones?.xdr ?? 1) * w
            let fillW = max(height, CGFloat(value) * w)
            let boosted = fillW > xdrX + 0.5
            ZStack(alignment: .leading) {
                Rectangle().fill(T.well)
                if xdrX < w {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(width: w - xdrX).offset(x: xdrX)
                }
                Rectangle()
                    .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: min(fillW, xdrX))
                if boosted {
                    Rectangle()
                        .fill(LinearGradient(colors: [T.warm, T.xdr], startPoint: .leading, endPoint: .trailing))
                        .frame(width: fillW - xdrX).offset(x: xdrX)
                        .shadow(color: T.xdr.opacity(0.7), radius: 8)
                }
                if let z = zones {
                    ForEach([z.dim, z.xdr].filter { $0 > 0 && $0 < 1 }, id: \.self) { m in
                        Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1).offset(x: CGFloat(m) * w)
                    }
                }
                HStack(spacing: 0) {
                    if let icon {
                        Image(systemName: icon).font(.system(size: height * 0.42, weight: .semibold))
                            .foregroundStyle(T.onAccent.opacity(0.85)).frame(width: height)
                    }
                    Spacer(minLength: 0)
                    if let label {
                        Text(label).font(T.f(11.5, .medium)).monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(fillW > w - 46 ? T.onAccent : T.text2)
                            .padding(.trailing, 10)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard interactive else { return }
                let v = min(max(g.location.x / w, 0), 1)
                if let z = zones, z.xdr < 1, (value < z.xdr) != (v < z.xdr) {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                onChange(v)
            })
        }
        .frame(height: hover && interactive ? height + 2 : height)
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
    }
}

/// Small slider: 6 pt track, white thumb.
struct MiniSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double? = nil
    var tint: Color = T.ion
    var onEnd: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 14
            let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(T.well).frame(height: 6)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.06)))
                Capsule().fill(tint).frame(width: max(6, 7 + CGFloat(t) * w), height: 6)
                Circle().fill(Color.white).frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    .offset(x: CGFloat(t) * w)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    var v = range.lowerBound + min(max((g.location.x - 7) / w, 0), 1) * (range.upperBound - range.lowerBound)
                    if let step { v = (v / step).rounded() * step }
                    value = v
                }
                .onEnded { _ in onEnd?() })
        }
        .frame(height: 16)
    }
}

struct Tile: View {
    let icon: String
    let title: String
    let isOn: Bool
    var tint: Color = T.ion
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn ? tint : T.text2)
                Spacer(minLength: 0)
                Text(title).font(T.f(11.5, .medium)).foregroundStyle(isOn ? T.text : T.text2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isOn ? tint.opacity(0.16) : Color.white.opacity(hover ? 0.07 : 0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isOn ? tint.opacity(0.4) : T.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

/// 30 pt list row that expands its content inline.
struct DrillRow<Content: View>: View {
    let icon: String
    let title: String
    var value: String? = nil
    var valueTint: Color = T.text2
    @Binding var open: Bool
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { open.toggle() } } label: {
                HStack(spacing: 9) {
                    Image(systemName: icon).font(.system(size: 12)).foregroundStyle(T.text2).frame(width: 16)
                    Text(title).font(T.f(12.5)).foregroundStyle(T.text)
                    Spacer(minLength: 6)
                    if let value { Text(value).font(T.f(12.5, .medium)).monospacedDigit().foregroundStyle(valueTint).lineLimit(1) }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(T.text3)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .offset(x: hover && !open ? 2 : 0)
                }
                .padding(.horizontal, 6)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hover ? 0.05 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -6)
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            if open {
                content.padding(.leading, 25).padding(.bottom, 4)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }
}

struct SwitchRow: View {
    let icon: String
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var disabled = false
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(T.text2).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(T.f(12.5)).foregroundStyle(T.text)
                if let detail { Text(detail).font(T.f(11)).foregroundStyle(T.text3) }
            }
            Spacer(minLength: 8)
            LSwitch(isOn: $isOn, disabled: disabled)
        }
        .frame(minHeight: 28)
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(T.f(11, .medium)).foregroundStyle(T.text3) }
}

struct Dot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 6, height: 6).shadow(color: color.opacity(0.8), radius: 3) }
}

/// Fades the top/bottom edge of scrolling content instead of showing a scrollbar.
struct EdgeFade: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        content.mask {
            if active {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 12)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 12)
                }
            } else { Color.black }
        }
    }
}
