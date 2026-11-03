import SwiftUI

/// The glow palette: each card gets one hue that bleeds from its edges or its core.
enum Glow: CaseIterable {
    case magenta, violet, blue, ember, sage, lime, graphite

    var color: Color {
        switch self {
        case .magenta: Color(red: 0.86, green: 0.27, blue: 0.62)
        case .violet: Color(red: 0.55, green: 0.38, blue: 0.98)
        case .blue: Color(red: 0.25, green: 0.38, blue: 1.0)
        case .ember: Color(red: 0.94, green: 0.40, blue: 0.24)
        case .sage: Color(red: 0.43, green: 0.58, blue: 0.53)
        case .lime: Color(red: 0.60, green: 0.82, blue: 0.28)
        case .graphite: Color(white: 0.42)
        }
    }
}

enum Theme {
    static let background = Color(red: 0.02, green: 0.02, blue: 0.03)
    static let surface = Color.white.opacity(0.05)
    static let hairline = Color.white.opacity(0.09)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.36)
    static let accent = Color(red: 0.84, green: 0.96, blue: 0.35)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.38)
    static let radius: CGFloat = 30
}

// MARK: - Glow card

enum GlowStyle { case rim, core, plain }

struct GlowCard<Content: View>: View {
    var glow: Glow = .graphite
    var style: GlowStyle = .core
    var padding: CGFloat = 22
    /// Mole is working for this card (a scan): its light breathes until the work ends.
    var busy = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { GlowSurface(glow: glow, style: style, busy: busy) }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.03), .white.opacity(0.08)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .shadow(color: style == .plain ? .clear : glow.color.opacity(0.22), radius: 28, y: 10)
            .accessibilityElement(children: .contain)
            .reveal()
    }
}

struct GlowSurface: View {
    let glow: Glow
    let style: GlowStyle
    var busy = false
    /// The light fills in once when the card appears (a page visit, a new panel), then holds
    /// still: a one-off animation, so nothing redraws while the window idles.
    @ViewState private var lit = Motion.reduced
    /// While busy the dark core thins and returns, so the light swells in from the edges and recedes.
    @ViewState private var breath = false

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)
            ZStack {
                switch style {
                case .rim:
                    // Coloured edges with a dark, soft core.
                    glow.color.opacity(lit ? 1 : 0.25)
                    // The dark core starts over the whole card and settles, so the colour creeps in from the edges.
                    if geo.size.height < 200 {
                        // A short card (a prompt, the deleted-app panel, a selection bar): a round core would
                        // cover its top and bottom and light only the ends, so the core follows the card's shape.
                        // Two soft-edged bands, across and down; where they cross is the core.
                        let fade = min(geo.size.height * 0.45, 48)
                        Color.black.opacity(0.8)
                            .mask(Self.band(fade / max(geo.size.width, 1), .leading, .trailing))
                            .mask(Self.band(fade / max(geo.size.height, 1), .top, .bottom))
                            .scaleEffect(lit ? 1 : 1.5)
                    } else {
                        RadialGradient(colors: [.black.opacity(0.92), .black.opacity(0.55), .clear],
                                       center: .init(x: 0.5, y: 0.55), startRadius: 0, endRadius: side * 0.55)
                            .blur(radius: 18)
                            .scaleEffect(lit ? 1 : 2.2, anchor: .init(x: 0.5, y: 0.55))
                            .opacity(breath ? 0.5 : 1)
                    }
                case .core:
                    // Dark card lit from inside.
                    Color(white: 0.06)
                    RadialGradient(colors: [glow.color.opacity(0.95), glow.color.opacity(0.35), .clear],
                                   center: .init(x: 0.62, y: 0.78), startRadius: 0, endRadius: side * 0.62)
                        .blur(radius: 30)
                        .scaleEffect(lit ? 1 : 0.25, anchor: .init(x: 0.62, y: 0.78))
                        .opacity(lit ? 1 : 0)
                case .plain:
                    Color.white.opacity(0.045)
                }
                LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center)
            }
        }
        .onAppear {
            guard !lit else { return }
            withAnimation(.easeOut(duration: 1.4).delay(0.08)) { lit = true }
        }
        // Repeats only while the work lasts, then settles; Reduce Motion keeps it still.
        .onChange(of: busy, initial: true) { _, busy in
            guard !Motion.reduced else { return }
            withAnimation(busy ? .easeInOut(duration: 1.8).repeatForever(autoreverses: true) : .easeOut(duration: 0.8)) { breath = busy }
        }
    }

    /// Clear at both ends, solid in between, with an eased fade `edge` (a fraction of the length) long.
    private static func band(_ edge: CGFloat, _ start: UnitPoint, _ end: UnitPoint) -> LinearGradient {
        let e = min(edge, 0.45)
        return LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.5), location: e * 0.55),
                                      .init(color: .black, location: e), .init(color: .black, location: 1 - e),
                                      .init(color: .black.opacity(0.5), location: 1 - e * 0.55), .init(color: .clear, location: 1)],
                              startPoint: start, endPoint: end)
    }
}

// MARK: - Background

/// A faint dot grid like the reference screens: one small tile repeated by the GPU, so the
/// window never redraws thousands of dots.
struct DotGrid: View {
    private static let tile: NSImage = {
        let spacing: CGFloat = 16, dot: CGFloat = 1.4
        return NSImage(size: NSSize(width: spacing, height: spacing), flipped: false) { _ in
            NSColor.white.withAlphaComponent(0.07).setFill()
            NSBezierPath(ovalIn: NSRect(x: spacing / 2, y: spacing / 2, width: dot, height: dot)).fill()
            return true
        }
    }()

    var body: some View {
        Image(nsImage: Self.tile).resizable(resizingMode: .tile).allowsHitTesting(false)
    }
}

/// Two large soft colour pools behind the whole window; the main one takes the page's hue.
/// Radial gradients instead of blurred circles: the same look at a fraction of the cost.
struct AmbientBackground: View {
    var tint: Glow = .violet

    var body: some View {
        ZStack {
            Theme.background
            pool(tint.color, opacity: 0.28, radius: 470).offset(x: 360, y: -300)
            pool(Glow.blue.color, opacity: 0.16, radius: 430).offset(x: -420, y: 340)
            DotGrid()
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.2), value: tint)
    }

    private func pool(_ color: Color, opacity: Double, radius: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(opacity * 0.45), .clear],
                                 center: .center, startRadius: 0, endRadius: radius))
            .frame(width: radius * 2, height: radius * 2)
    }
}

// MARK: - Buttons

/// A capsule outline drawn as a circular rounded rectangle. Capsule().strokeBorder leaves short
/// hairlines at both ends when the window is drawn offscreen (review snapshots); this does not.
struct Pill: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        return RoundedRectangle(cornerRadius: min(r.width, r.height) / 2, style: .circular).path(in: r)
    }

    func inset(by amount: CGFloat) -> Pill { Pill(inset: inset + amount) }
}

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        PillBody(kind: kind, fill: fill, configuration: configuration)
    }

    private var fill: Color {
        switch kind {
        case .primary: .white
        case .secondary: .white.opacity(0.08)
        case .danger: Theme.danger.opacity(0.9)
        }
    }
}

private struct PillBody: View {
    let kind: PillButtonStyle.Kind
    let fill: Color
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @ViewState private var hover = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18)
            .frame(height: 36)
            .foregroundStyle(kind == .primary ? Color.black : Color.white)
            .background {
                Capsule().fill(fill)
                if kind == .secondary { Pill().strokeBorder(.white.opacity(0.14), lineWidth: 1) }
            }
            .brightness(hover && enabled ? (kind == .primary ? -0.06 : 0.06) : 0)
            .opacity(!enabled ? 0.38 : configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
            .animation(Motion.quick, value: hover)
            .contentShape(Capsule())
            .onHover { hover = $0 }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { .init() }
    static var pillSecondary: PillButtonStyle { .init(kind: .secondary) }
    static var pillDanger: PillButtonStyle { .init(kind: .danger) }
}

struct CircleIconButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @ViewState private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(hover && enabled ? 0.14 : 0.08)))
                .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hover = $0 }
        .animation(Motion.quick, value: hover)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A capsule segmented control in the app's style; the white pill slides to the choice.
struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(String, Value)]
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.1) { title, value in
                let on = selection == value
                Button { withAnimation(Motion.quick) { selection = value } } label: {
                    Text(title).font(.system(size: 12.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.black : .white.opacity(0.75))
                        .padding(.horizontal, 14).frame(height: 30)
                        .background { if on { Capsule().fill(.white).matchedGeometryEffect(id: "pill", in: pill) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(.white.opacity(0.07)))
        .overlay(Pill().strokeBorder(Theme.hairline))
    }
}

/// A small rounded tag ("Would clean", "Admin", "Skipped").
struct Tag: View {
    let text: String
    var color: Color = .white

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .foregroundStyle(color.opacity(0.9))
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Typography helpers

extension View {
    func cardTitle() -> some View {
        font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.primaryText)
    }

    func caption() -> some View {
        font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
    }
}

extension Int64 {
    var bytesText: String { ByteSize.format(self) }
}

/// SwiftUI's `State` property wrapper without the `@State` macro, whose plugin ships only with
/// Xcode. Command Line Tools alone can then build the app.
typealias ViewState<Value> = SwiftUI.State<Value>
