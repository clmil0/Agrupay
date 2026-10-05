import SwiftUI

// MARK: - Perfil Pro en Social

/// Cómo se ve mi tarjeta en Social, más allá del personaje: la cabecera
/// (básica o un cielo Pro), el aura y el fondo del avatar, el marco de la
/// tarjeta y la animación con la que entra mi perfil cuando un amigo lo abre.
///
/// Viaja a `profiles.social_style` (SQL v15) para que mis amigos lo vean.
/// `pro` dice si yo era Pro al subirlo: sin él, del otro lado sólo se pinta la
/// cabecera básica, aunque las elecciones Pro sigan guardadas aquí para
/// cuando vuelva.
///
/// Las claves van en inglés y cortas porque son lo que lee la app de un amigo
/// que quizá tiene otra versión: un valor que no conoce cae al de por
/// defecto, en vez de romper el perfil entero.
struct SocialStyle: Codable, Hashable {

    enum Aura: String, Codable, CaseIterable { case none, theme, halo, gold }
    enum AvatarBackground: String, Codable, CaseIterable { case plain, theme, sphere, gold }
    enum Frame: String, Codable, CaseIterable { case none, glow, gold }
    enum Entrance: String, Codable, CaseIterable { case none, flash, hop, stars }

    /// Si el dueño era Pro al subirlo.
    var pro = false
    /// Cabecera básica, índice en `SocialBanner.allCases`.
    var banner: Int?
    /// El tema Pro elegido (`ProTheme.key`): el del cielo y el que tiñe
    /// aura, fondo y marco. `nil` = todavía ninguno (Nebulosa).
    var theme: String?
    /// Si la cabecera es el cielo de `theme` o la básica de `banner`.
    /// `nil` = todavía no se eligió: con un fondo Pro puesto en Apariencia,
    /// la cabecera es ese cielo (ver `withDefaults`).
    var skyHeader: Bool?
    var aura: Aura = .none
    var background: AvatarBackground = .plain
    var frame: Frame = .none
    var entrance: Entrance = .none

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pro = (try? c.decodeIfPresent(Bool.self, forKey: .pro)) ?? false
        banner = try? c.decodeIfPresent(Int.self, forKey: .banner)
        theme = try? c.decodeIfPresent(String.self, forKey: .theme)
        skyHeader = try? c.decodeIfPresent(Bool.self, forKey: .skyHeader)
        aura = (try? c.decodeIfPresent(Aura.self, forKey: .aura)) ?? .none
        background = (try? c.decodeIfPresent(AvatarBackground.self, forKey: .background)) ?? .plain
        frame = (try? c.decodeIfPresent(Frame.self, forKey: .frame)) ?? .none
        entrance = (try? c.decodeIfPresent(Entrance.self, forKey: .entrance)) ?? .none
    }

    /// El cielo Pro que se pinta en la cabecera, sólo si el dueño es Pro.
    var proTheme: ProTheme? {
        guard pro, skyHeader == true else { return nil }
        return tintTheme
    }

    /// El tema que tiñe aura, fondo y marco, aunque la cabecera sea básica.
    var tintTheme: ProTheme { theme.flatMap(ProTheme.withKey) ?? .nebula }

    /// Lo que no elegí, tomado de mi fondo Pro de Apariencia: su tema, y su
    /// cielo como cabecera. Si sigue el fondo, cambiar de tema en Apariencia
    /// cambia también la cabecera; elegir una en el editor lo fija.
    func withDefaults(_ ambient: ProTheme?) -> SocialStyle {
        var value = self
        if value.theme == nil { value.theme = ambient?.key }
        if value.skyHeader == nil { value.skyHeader = ambient != nil }
        return value
    }

    /// Lo que se ve de verdad: sin Pro, todo lo Pro se apaga.
    var shown: SocialStyle {
        guard !pro else { return self }
        var plain = SocialStyle()
        plain.banner = banner
        return plain
    }
}

extension ProTheme {
    /// Clave estable, la que viaja al servidor: el `rawValue` es el nombre en
    /// castellano y podría cambiar de redacción.
    var key: String { String(describing: self) }

    static func withKey(_ key: String) -> ProTheme? {
        allCases.first { $0.key == key }
    }

    /// Los colores del cielo de la cabecera. Fijos y sin la variante de
    /// Apariencia: el cielo de un amigo se ve igual en mi teléfono que en el
    /// suyo, y mi «Matiz» no tiene por qué girarlo.
    fileprivate var skyHex: (base: UInt32, accent: UInt32, ink: UInt32, a: UInt32, b: UInt32, c: UInt32) {
        switch self {
        case .nebula:   return (0x06061A, 0x8B5CF6, 0x5B3FC4, 0xC084FC, 0x6D28D9, 0x8B5CF6)
        case .obsidian: return (0x0B0A08, 0xD4AF61, 0x8A5514, 0xB8892F, 0xF6E7B8, 0xD4AF61)
        case .aurora:   return (0x04110F, 0x34D399, 0x1E7A63, 0x10B981, 0xA5F3FC, 0x34D399)
        case .sunset:   return (0x1A0B14, 0xFB7185, 0xA1315A, 0xFB7185, 0xFDBA74, 0x3B0F2E)
        case .abyss:    return (0x03141A, 0x22D3EE, 0x1B5A9C, 0x22D3EE, 0x0E7490, 0xCFFAFE)
        case .pearl:    return (0xFBF8FB, 0x7B5BE6, 0x5B3FC4, 0xF5C6E0, 0xC8B8FF, 0xA6E6D4)
        case .dawn:     return (0xFFF8F1, 0xF2683C, 0xB2431A, 0xFDBA74, 0xFFD9C2, 0xFFF4D6)
        case .glacier:  return (0xF2F7FC, 0x1F6FD1, 0x14569F, 0xBFDDF7, 0x6FA9E8, 0xFFFFFF)
        case .ivory:    return (0xFAF6EC, 0xB8892F, 0x8A5514, 0xF6E7B8, 0xD4AF61, 0xFFFFFF)
        case .sage:     return (0xF5F8F3, 0x3E9A6E, 0x1E6B50, 0xCFE6C8, 0x7FBF95, 0xFFF6D6)
        }
    }

    var skyBase: Color { Color(hex: skyHex.base) }
    /// El acento fijo del tema (anillos, marco, borde de la tarjeta).
    var skyAccent: Color { Color(hex: skyHex.accent) }
    /// El acento como texto sobre claro: el chip «Perfil Pro · Aurora».
    var skyInk: Color { Color(hex: skyHex.ink) }
    var skyA: Color { Color(hex: skyHex.a) }
    var skyB: Color { Color(hex: skyHex.b) }
    var skyC: Color { Color(hex: skyHex.c) }
}

// MARK: - Oro

enum SocialGold {
    static let ring: [Color] = [0x8C6A2F, 0xE9D29A, 0xB8892F, 0xF6E7B8, 0x9A7430, 0x8C6A2F].map { Color(hex: $0) }
    static let tint = Color(hex: 0xD4AF61)
    static let sphere = RadialGradient(colors: [0xFFFFFF, 0xF6E7B8, 0xD4AF61, 0xB8892F].map { Color(hex: $0) },
                                       center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 60)
}

// MARK: - Cabecera

/// La cabecera de un perfil: el cielo Pro si lo tiene, si no la básica.
struct SocialHeaderView: View {
    let style: SocialStyle
    var animated = true

    var body: some View {
        if let theme = style.shown.proTheme {
            ProSkyBanner(theme: theme, animated: animated)
        } else {
            SocialBannerView(index: style.banner)
        }
    }
}

/// El cielo de un tema Pro en pequeño, para cabeceras y la tira del feed:
/// tres manchas de color que derivan despacio, estrellas que titilan y el
/// detalle propio de cada tema (el sol de Atardecer, la cinta de Aurora…).
///
/// Sin `blur`: las manchas son degradados radiales que ya se apagan solos, y
/// un desenfoque que se mueve se recalcula en cada fotograma. Con «Reducir
/// movimiento», o `animated == false` (las muestras de la galería), queda
/// quieto.
struct ProSkyBanner: View {
    let theme: ProTheme
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated || reduceMotion)) { context in
            let t = animated && !reduceMotion ? context.date.timeIntervalSinceReferenceDate : 0
            Canvas { gc, size in draw(&gc, size: size, t: t) }
        }
        .background(theme.skyBase)
        .clipped()
        .accessibilityHidden(true)
    }

    /// Ida y vuelta suave entre 0 y 1 (como `alternate` en CSS).
    private func swing(_ t: Double, _ period: Double) -> Double {
        0.5 - 0.5 * cos(t / period * .pi)
    }

    private func blob(_ gc: inout GraphicsContext, center: CGPoint, rx: CGFloat, ry: CGFloat,
                      color: Color, alpha: Double) {
        var g = gc
        g.translateBy(x: center.x, y: center.y)
        g.scaleBy(x: 1, y: ry / max(rx, 1))
        g.fill(Path(ellipseIn: CGRect(x: -rx, y: -rx, width: rx * 2, height: rx * 2)),
               with: .radialGradient(Gradient(colors: [color.opacity(alpha), color.opacity(0)]),
                                     center: .zero, startRadius: 0, endRadius: rx))
    }

    private func draw(_ gc: inout GraphicsContext, size: CGSize, t: Double) {
        let w = size.width, h = size.height

        // Las tres manchas, con el mismo vaivén que el diseño (9, 12 y 10 s).
        let a = swing(t, 9), b = swing(t, 12), c = swing(t, 10)
        blob(&gc, center: CGPoint(x: w * (0.255 + 0.135 * a), y: h * (0.25 + 0.19 * a)),
             rx: w * 0.375 * (1 + 0.15 * a), ry: h * 0.95 * (1 + 0.15 * a), color: theme.skyA, alpha: 0.87)
        blob(&gc, center: CGPoint(x: w * (0.815 - 0.13 * b), y: h * (0.5 + 0.136 * b)),
             rx: w * 0.325 * (1.1 - 0.15 * b), ry: h * 0.85 * (1.1 - 0.15 * b), color: theme.skyB, alpha: 0.8)
        blob(&gc, center: CGPoint(x: w * (0.53 - 0.07 * c), y: h * (0.95 - 0.144 * c)),
             rx: w * 0.25, ry: h * 0.6, color: theme.skyC, alpha: 0.67)

        special(&gc, size: size, t: t)

        // Estrellas: dos rejillas desfasadas, como el fondo del diseño.
        let twinkle = 0.35 + 0.55 * (0.5 - 0.5 * cos(t / 1.8 * .pi))
        let dot: Color = theme.isLight ? theme.skyAccent.opacity(0.53) : .white.opacity(0.85)
        var stars = Path()
        for (sx, sy, ox, oy, r) in [(37.0, 29.0, 5.0, 7.0, 1.0), (61.0, 47.0, 19.0, 23.0, 1.3)] {
            var x = ox
            while x < w {
                var y = oy
                while y < h {
                    stars.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    y += sy
                }
                x += sx
            }
        }
        gc.fill(stars, with: .color(dot.opacity(twinkle)))
    }

    private func special(_ gc: inout GraphicsContext, size: CGSize, t: Double) {
        let w = size.width, h = size.height
        switch theme {
        case .sunset:
            let pulse = 1 + 0.08 * (0.5 - 0.5 * cos(t / 2 * .pi))
            let r = h * 0.45 * pulse
            let center = CGPoint(x: w / 2, y: h * 1.38 - h * 0.45)
            gc.fill(Path(ellipseIn: CGRect(x: center.x - r * 1.6, y: center.y - r * 1.6, width: r * 3.2, height: r * 3.2)),
                    with: .radialGradient(Gradient(colors: [Color(hex: 0xFB7185, opacity: 0.45), Color(hex: 0xFB7185, opacity: 0)]),
                                          center: center, startRadius: r * 0.8, endRadius: r * 1.6))
            gc.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                    with: .radialGradient(Gradient(colors: [Color(hex: 0xFDE68A), Color(hex: 0xFB7185)]),
                                          center: CGPoint(x: center.x, y: center.y - r * 0.3), startRadius: 0, endRadius: r * 1.4))
            // El agua: líneas finas y un velo hacia abajo.
            let top = h * 0.7
            gc.fill(Path(CGRect(x: 0, y: top, width: w, height: h - top)),
                    with: .linearGradient(Gradient(colors: [Color(hex: 0x1A0B14, opacity: 0), Color(hex: 0x1A0B14, opacity: 0.67)]),
                                          startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: h)))
            var lines = Path()
            for y in stride(from: top + 6, to: h, by: 7) { lines.addRect(CGRect(x: 0, y: y, width: w, height: 1)) }
            gc.fill(lines, with: .color(Color(hex: 0xFFF1E6, opacity: 0.22)))
        case .aurora:
            let k = swing(t, 7)
            var g = gc
            g.translateBy(x: w * (-0.08 + 0.16 * k), y: h * 0.41)
            g.concatenate(CGAffineTransform(a: 1, b: tan(-(8 - 5 * k) * .pi / 180), c: 0, d: 1, tx: 0, ty: 0))
            let rect = CGRect(x: -w * 0.2, y: -h * 0.19, width: w * 1.4, height: h * 0.38)
            g.fill(Path(rect), with: .linearGradient(
                Gradient(stops: [.init(color: .clear, location: 0),
                                 .init(color: Color(hex: 0x34D399, opacity: 0.6), location: 0.25),
                                 .init(color: Color(hex: 0xA5F3FC, opacity: 0.67), location: 0.5),
                                 .init(color: Color(hex: 0x10B981, opacity: 0.6), location: 0.75),
                                 .init(color: .clear, location: 1)]),
                startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
        case .obsidian, .ivory:
            let rect = CGRect(x: w - 140, y: -50, width: 170, height: 170)
            gc.fill(Path(ellipseIn: rect.insetBy(dx: -18, dy: -18)),
                    with: .radialGradient(Gradient(colors: [Color(hex: 0xD4AF61, opacity: 0), Color(hex: 0xD4AF61, opacity: 0.25), Color(hex: 0xD4AF61, opacity: 0)]),
                                          center: CGPoint(x: rect.midX, y: rect.midY), startRadius: 60, endRadius: 103))
            gc.stroke(Path(ellipseIn: rect), with: .color(Color(hex: 0xE9D29A, opacity: 0.53)), lineWidth: 1.5)
        case .glacier:
            gc.fill(Path(CGRect(origin: .zero, size: size)), with: .conicGradient(
                Gradient(stops: [.init(color: .white.opacity(0), location: 0),
                                 .init(color: .white.opacity(0.53), location: 0.08),
                                 .init(color: .white.opacity(0), location: 0.16),
                                 .init(color: Color(hex: 0x6FA9E8, opacity: 0.2), location: 0.30),
                                 .init(color: .white.opacity(0), location: 0.45),
                                 .init(color: .white.opacity(0.4), location: 0.60),
                                 .init(color: .white.opacity(0), location: 0.70),
                                 .init(color: .white.opacity(0), location: 1)]),
                center: CGPoint(x: w * 0.7, y: h * 0.4), angle: .degrees(200 - 90)))
        case .pearl:
            var g = gc
            g.blendMode = .multiply
            let side = w * 1.6
            g.translateBy(x: w / 2, y: h / 2)
            g.rotate(by: .degrees((t / 14).truncatingRemainder(dividingBy: 1) * 360))
            g.fill(Path(CGRect(x: -side / 2, y: -side / 2, width: side, height: side)), with: .conicGradient(
                Gradient(colors: [0xF5C6E0, 0xC8B8FF, 0xA6E6D4, 0xF5C6E0].map { Color(hex: $0, opacity: 0.4) }),
                center: .zero))
        default:
            break
        }
    }
}

// MARK: - Avatar con aura

/// El avatar de un perfil con su aura (un anillo que gira) y su fondo.
/// Lo usan mi tarjeta, la vista previa del editor y la ficha de un amigo.
struct StyledAvatar<Avatar: View>: View {
    let size: CGFloat
    let style: SocialStyle
    /// El color del hueco entre el anillo y el avatar: el de la superficie
    /// donde se apoya, para que el anillo parezca despegado.
    var gap: Color
    /// Si el anillo gira. En listas y el feed va quieto.
    var spins = true
    /// Cuándo empezó la entrada «Saltito»; `nil` = quieto.
    var hopStart: Date? = nil
    @ViewBuilder let avatar: (AnyShapeStyle?) -> Avatar

    var body: some View {
        let shown = style.shown
        ZStack {
            if let ring = SocialRing(aura: shown.aura, theme: shown.tintTheme, spins: spins) {
                SocialRingView(ring: ring, size: size, gap: gap)
            }
            HopEffect(start: shown.entrance == .hop ? hopStart : nil) {
                avatar(Self.background(shown))
            }
        }
        .frame(width: size, height: size)
    }

    static func background(_ style: SocialStyle) -> AnyShapeStyle? {
        let theme = style.tintTheme
        switch style.background {
        case .plain: return nil
        case .theme:
            return AnyShapeStyle(LinearGradient(colors: [theme.skyA, theme.skyBase],
                                                startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1)))
        case .sphere: return AnyShapeStyle(theme.swatch)
        case .gold: return AnyShapeStyle(SocialGold.sphere)
        }
    }
}

/// Los colores y el brillo de un aura.
struct SocialRing: Equatable {
    var colors: [Color]
    var spins: Bool
    var glow: Color?

    init?(aura: SocialStyle.Aura, theme: ProTheme, spins: Bool) {
        let accent = theme.skyAccent
        switch aura {
        case .none: return nil
        case .gold:
            colors = SocialGold.ring
            glow = spins ? SocialGold.tint.opacity(0.4) : nil
        case .halo:
            colors = [accent.opacity(0), accent, accent.opacity(0), accent, accent.opacity(0)]
            glow = accent.opacity(0.53)
        case .theme:
            colors = [accent, theme.skyB, accent, theme.skyA, accent]
            glow = spins ? accent.opacity(0.33) : nil
        }
        self.spins = spins
    }

    /// El anillo quieto del tema de un amigo Pro, en listas y el feed.
    static func friend(_ style: SocialStyle?) -> SocialRing? {
        guard let style, style.pro else { return nil }
        return SocialRing(aura: .theme, theme: style.tintTheme, spins: false)
    }
}

struct SocialRingView: View {
    let ring: SocialRing
    let size: CGFloat
    let gap: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false
    @State private var breathing = false

    private var width: CGFloat { size >= 80 ? 3.5 : size >= 40 ? 2.5 : 1.5 }
    private var gapWidth: CGFloat { size >= 80 ? 3 : size >= 40 ? 2 : 1 }

    var body: some View {
        let moves = ring.spins && !reduceMotion
        ZStack {
            Circle()
                .fill(AngularGradient(colors: ring.colors, center: .center))
                .rotationEffect(.degrees(turning ? 360 : 0))
                .frame(width: size + (width + gapWidth) * 2, height: size + (width + gapWidth) * 2)
                .shadow(color: ring.glow ?? .clear, radius: ring.glow == nil ? 0 : size * 0.14)
                .opacity(ring.glow != nil && moves && breathing ? 0.8 : 1)
            Circle()
                .fill(gap)
                .frame(width: size + gapWidth * 2, height: size + gapWidth * 2)
        }
        .onAppear {
            guard moves else { return }
            withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) { turning = true }
            if ring.glow != nil {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { breathing = true }
            }
        }
    }
}

// MARK: - Marco de la tarjeta

extension View {
    /// El marco de mi tarjeta: un borde de 2 pt que gira con el acento del
    /// tema (o de oro) y un resplandor suave. Sin marco, el hairline de
    /// siempre.
    func socialFrame(_ style: SocialStyle, radius: CGFloat, hairline: Color) -> some View {
        modifier(SocialFrameModifier(style: style.shown, radius: radius, hairline: hairline))
    }
}

private struct SocialFrameModifier: ViewModifier {
    let style: SocialStyle
    let radius: CGFloat
    let hairline: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    private var colors: [Color] {
        let theme = style.tintTheme
        if style.frame == .gold { return SocialGold.ring }
        return [theme.skyAccent, theme.skyB, theme.skyAccent.opacity(0), theme.skyAccent.opacity(0),
                theme.skyA, theme.skyAccent]
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if style.frame == .none {
            content
                .clipShape(shape)
                .overlay(shape.stroke(hairline, lineWidth: 0.5))
        } else {
            let tint = style.frame == .gold ? SocialGold.tint : style.tintTheme.skyAccent
            content
                .clipShape(shape)
                .padding(2)
                .background {
                    GeometryReader { geo in
                        let side = max(geo.size.width, geo.size.height) * 1.7
                        ZStack {
                            tint
                            Rectangle()
                                .fill(AngularGradient(colors: colors, center: .center))
                                .frame(width: side, height: side)
                                .rotationEffect(.degrees(turning ? 360 : 0))
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius + 1.5, style: .continuous))
                }
                .shadow(color: tint.opacity(0.25), radius: 13, y: 8)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { turning = true }
                }
        }
    }
}

// MARK: - Entrada

/// Un reloj que corre sólo mientras dura una animación de entrada: así el
/// `TimelineView` no sigue pidiendo fotogramas cuando ya terminó.
private struct EntranceClock<Content: View>: View {
    let start: Date?
    let duration: Double
    @ViewBuilder let content: (Double?) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var running = false

    var body: some View {
        TimelineView(.animation(paused: !running)) { context in
            content(running ? start.map { context.date.timeIntervalSince($0) } : nil)
        }
        .task(id: start) {
            guard let start, !reduceMotion else { running = false; return }
            running = true
            let left = duration - Date().timeIntervalSince(start)
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            running = false
        }
    }
}

/// «Saltito»: el avatar se agacha, salta 9 pt y aterriza.
private struct HopEffect<Content: View>: View {
    let start: Date?
    @ViewBuilder let content: Content

    var body: some View {
        if start == nil {
            content
        } else {
            EntranceClock(start: start, duration: 1.1) { elapsed in
                let (dy, sx, sy) = Self.pose(elapsed.map { ($0 - 0.45) / 0.62 } ?? -1)
                content
                    .scaleEffect(x: sx, y: sy, anchor: .bottom)
                    .offset(y: dy)
            }
        }
    }

    /// Los fotogramas clave del diseño (0, 18, 42, 66, 82 y 100 %).
    static func pose(_ p: Double) -> (CGFloat, CGFloat, CGFloat) {
        guard p > 0, p < 1 else { return (0, 1, 1) }
        let keys: [(Double, CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 1, 1), (0.18, 0, 1.1, 0.88), (0.42, -9, 0.94, 1.08),
            (0.66, 0, 1.08, 0.92), (0.82, 0, 0.98, 1.02), (1, 0, 1, 1)
        ]
        for i in 1..<keys.count where p <= keys[i].0 {
            let (p0, y0, x0, s0) = keys[i - 1], (p1, y1, x1, s1) = keys[i]
            let k = CGFloat((p - p0) / (p1 - p0))
            let e = k * k * (3 - 2 * k)
            return (y0 + (y1 - y0) * e, x0 + (x1 - x0) * e, s0 + (s1 - s0) * e)
        }
        return (0, 1, 1)
    }
}

/// «Destello» y «Estrellas»: lo que pasa sobre la cabecera al abrir un perfil.
/// «Saltito» lo hace el propio avatar (`StyledAvatar.hopStart`).
struct SocialEntranceOverlay: View {
    let style: SocialStyle
    let start: Date?

    private static let spots: [(CGFloat, CGFloat, CGFloat)] = [
        (0.12, 0.30, 18), (0.28, 0.62, 12), (0.46, 0.22, 15), (0.64, 0.58, 20),
        (0.80, 0.28, 13), (0.90, 0.66, 11), (0.36, 0.78, 10)
    ]

    var body: some View {
        let shown = style.shown
        switch shown.entrance {
        case .flash:
            EntranceClock(start: start, duration: 1.5) { elapsed in
                GeometryReader { geo in
                    if let elapsed {
                        let p = min(1, max(0, (elapsed - 0.35) / 1.1))
                        let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
                        LinearGradient(colors: [.white.opacity(0), .white.opacity(0.75), .white.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.3, height: geo.size.height * 2)
                            .rotationEffect(.degrees(18))
                            .offset(x: geo.size.width * 0.3 * (-1.4 + 5.6 * e), y: -geo.size.height * 0.5)
                    }
                }
                .clipped()
            }
            .allowsHitTesting(false)
        case .stars:
            let theme = shown.tintTheme
            EntranceClock(start: start, duration: 2.3) { elapsed in
                GeometryReader { geo in
                    if let elapsed {
                        ForEach(Self.spots.indices, id: \.self) { i in
                            let (x, y, s) = Self.spots[i]
                            let p = (elapsed - 0.25 - Double(i) * 0.09) / 1.4
                            let (opacity, scale, lift) = Self.star(p)
                            Image(systemName: "sparkle")
                                .font(.system(size: s, weight: .bold))
                                .foregroundStyle(theme.isLight ? theme.skyInk : .white)
                                .shadow(color: theme.skyAccent, radius: 4)
                                .scaleEffect(scale)
                                .opacity(opacity)
                                .position(x: geo.size.width * x + s / 2, y: geo.size.height * y + s / 2 + lift)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        case .none, .hop:
            EmptyView()
        }
    }

    /// 0 % invisible y chica, 35 % entera y algo grande, 100 % se apaga subiendo.
    private static func star(_ p: Double) -> (Double, CGFloat, CGFloat) {
        guard p > 0 else { return (0, 0.2, 0) }
        guard p < 1 else { return (0, 0.6, -10) }
        if p < 0.35 {
            let k = p / 0.35
            return (k, 0.2 + 0.95 * k, 0)
        }
        let k = (p - 0.35) / 0.65
        return (1 - k, 1.15 - 0.55 * k, -10 * k)
    }
}
