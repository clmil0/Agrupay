import SwiftUI

/// El fondo animado de los temas Pro del Resumen: los de noche (`3b`–`3e`
/// y Abismo) y los de día (Perla, Alba, Glaciar, Marfil y Salvia).
///
/// Va fijo detrás del dashboard: el cielo ocupa la parte de arriba —donde
/// están el monto y el gráfico— y se funde con el color base hacia abajo,
/// para que las tarjetas se lean sobre liso. Todo se dibuja con degradados y
/// un `Canvas`, sin `blur`: un desenfoque que se mueve se recalcula en cada
/// fotograma y es lo que más batería cuesta. Con «Reducir movimiento» el
/// cielo queda quieto.
///
/// `calm` es la versión de las demás pantallas: el mismo cielo, más tenue y
/// más corto, sin estrella fugaz, para que acompañe sin competir con el texto.
struct ProThemeBackdrop: View {
    let theme: ProTheme
    var calm = false
    /// Tapado por completo (el Resumen debajo de Configuración): no hace
    /// falta seguir animando lo que no se ve.
    var paused = false

    var body: some View {
        // Otro tema es otro cielo: así la variante se lee de la clave del
        // tema nuevo.
        ProThemeSkyLayer(theme: theme, calm: calm, paused: paused)
            .id(theme)
    }

    /// Una onda suave entre 0 y 1 con el periodo dado.
    static func wave(_ t: Double, period: Double, phase: Double = 0) -> Double {
        0.5 + 0.5 * sin((t / period + phase) * 2 * .pi)
    }

    /// Cuánto va de una vuelta de `period` segundos, de 0 a 1.
    static func cycle(_ t: Double, period: Double, phase: Double = 0) -> Double {
        let value = (t / period + phase).truncatingRemainder(dividingBy: 1)
        return value < 0 ? value + 1 : value
    }
}

private struct ProThemeSkyLayer: View {
    let theme: ProTheme
    let calm: Bool
    let paused: Bool

    /// La variante y la intensidad del cielo elegidas en Apariencia; también
    /// para redibujar al moverlas con «Reducir movimiento» (sin animación).
    @AppStorage(ProTheme.skyIntensityKey) private var intensity = 1.0
    @AppStorage private var toneName: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Debajo de otra pantalla de la pila: lo mismo.
    @State private var isOnScreen = true

    init(theme: ProTheme, calm: Bool, paused: Bool) {
        self.theme = theme
        self.calm = calm
        self.paused = paused
        _toneName = AppStorage(wrappedValue: "", theme.toneKey)
    }

    /// Los cielos tenues acompañan a Configuración: se detienen mientras se
    /// desliza (ver `DecorationPause`).
    private var isPaused: Bool {
        reduceMotion || scenePhase != .active || paused || !isOnScreen
            || (calm && DecorationPause.shared.isScrolling)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            TimelineView(.animation(minimumInterval: 1 / 30, paused: isPaused)) { context in
                let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                ZStack(alignment: .top) {
                    theme.base
                    Group {
                        switch theme {
                        case .nebula:   NebulaSky(t: t, size: size, calm: calm)
                        case .obsidian: ObsidianSky(t: t, size: size)
                        case .aurora:   AuroraSky(t: t, size: size)
                        case .sunset:   SunsetSky(t: t, size: size)
                        case .abyss:    AbyssSky(t: t, size: size, calm: calm)
                        case .pearl:    PearlSky(t: t, size: size, calm: calm)
                        case .dawn:     DawnSky(t: t, size: size)
                        case .glacier:  GlacierSky(t: t, size: size, calm: calm)
                        case .ivory:    IvorySky(t: t, size: size)
                        case .sage:     SageSky(t: t, size: size)
                        }
                    }
                    // La variante gira el tono del cielo igual que el de
                    // los colores; la intensidad lo apaga hacia el fondo liso.
                    .hueRotation(.degrees(theme.tone(named: toneName).degrees))
                    .opacity((calm ? 0.45 : 1) * min(max(intensity, ProTheme.skyIntensityRange.lowerBound), 1))
                    // Hacia abajo, liso: las tarjetas no compiten con el cielo.
                    LinearGradient(stops: [.init(color: theme.base.opacity(0), location: 0),
                                           .init(color: theme.base.opacity(0.9), location: 0.55),
                                           .init(color: theme.base, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: size.height * (calm ? 0.7 : 0.5))
                        .offset(y: size.height * (calm ? 0.12 : 0.5))
                }
                .frame(width: size.width, height: size.height, alignment: .top)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
    }

}

// MARK: - Estrellas

/// Estrellas fijas con titileo propio y un desplazamiento lento a la
/// izquierda. Las posiciones salen de un generador con semilla: el cielo es
/// siempre el mismo.
private struct StarField: View {
    let t: Double
    let size: CGSize
    var count = 70
    /// Hasta dónde bajan (fracción del alto).
    var depth: CGFloat = 0.55
    var tint: Color = .white
    var drift: Double = 140

    var body: some View {
        Canvas { context, canvas in
            var rng = SeededRandom(seed: 7)
            let shift = (t / drift).truncatingRemainder(dividingBy: 1) * Double(canvas.width)
            for index in 0..<count {
                let baseX = rng.next() * Double(canvas.width)
                let y = rng.next() * Double(canvas.height * depth)
                let radius = 0.5 + rng.next() * 1.1
                let period = 2.2 + rng.next() * 2.6
                let glow = 0.15 + 0.85 * ProThemeBackdrop.wave(t, period: period, phase: Double(index) * 0.13)
                var x = baseX - shift
                if x < 0 { x += Double(canvas.width) }
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.opacity = glow
                context.fill(Path(ellipseIn: rect), with: .color(tint))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 11) & 0x1F_FFFF_FFFF_FFFF) / Double(1 << 53)
    }
}

/// Una mancha de luz: un degradado radial que se desvanece solo, sin blur.
private func glow(_ color: Color, opacity: Double, diameter: CGFloat) -> some View {
    Circle()
        .fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(0)],
                             center: .center, startRadius: 0, endRadius: diameter / 2))
        .frame(width: diameter, height: diameter)
}

// MARK: - Nebulosa

/// Cielo vivo: tres nubes de color que respiran, estrellas y, cada tanto,
/// una estrella fugaz.
private struct NebulaSky: View {
    let t: Double
    let size: CGSize
    var calm = false

    var body: some View {
        let breathe = ProThemeBackdrop.wave(t, period: 14)
        ZStack(alignment: .topLeading) {
            glow(Color(hex: 0x7C3AED), opacity: 0.55, diameter: size.width * 1.05)
                .scaleEffect(1 + 0.2 * breathe)
                .position(x: size.width * 0.18 + 24 * breathe, y: size.height * 0.10 - 8 * breathe)
            glow(Color(hex: 0xDB2777), opacity: 0.42, diameter: size.width * 0.85)
                .scaleEffect(1.1 - 0.15 * ProThemeBackdrop.wave(t, period: 17, phase: 0.3))
                .position(x: size.width * 0.92, y: size.height * 0.24)
            glow(Color(hex: 0x0891B2), opacity: 0.3, diameter: size.width * 0.9)
                .scaleEffect(1 + 0.12 * ProThemeBackdrop.wave(t, period: 20, phase: 0.6))
                .position(x: size.width * 0.45, y: size.height * 0.46)

            StarField(t: t, size: size, count: calm ? 40 : 80, depth: calm ? 0.3 : 0.6,
                      tint: Color(hex: 0xE9E3FF))

            if !calm { shootingStar }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Cruza en el primer 9 % de cada vuelta de 11 s, como en el diseño.
    private var shootingStar: some View {
        let cycle = (t / 11).truncatingRemainder(dividingBy: 1)
        let progress = min(cycle / 0.09, 1)
        let visible = cycle < 0.09
        return Capsule()
            .fill(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing))
            .frame(width: 90, height: 1.6)
            .rotationEffect(.degrees(-18))
            .position(x: size.width * 0.85 - 260 * progress, y: size.height * 0.08 + 86 * progress)
            .opacity(visible ? 1 - progress * 0.6 : 0)
    }
}

// MARK: - Obsidiana

/// Negro cálido: un halo dorado quieto, grano fino y un brillo que cruza.
private struct ObsidianSky: View {
    let t: Double
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            glow(Color(hex: 0xD4AF61), opacity: 0.22 + 0.06 * ProThemeBackdrop.wave(t, period: 9),
                 diameter: size.width * 1.4)
                .position(x: size.width * 0.5, y: size.height * 0.2)

            // Grano: puntos de oro casi invisibles, en rejilla.
            Canvas { context, canvas in
                let step: CGFloat = 5
                var y: CGFloat = 0
                while y < canvas.height * 0.6 {
                    var x: CGFloat = (Int(y / step) % 2 == 0) ? 0 : step / 2
                    while x < canvas.width {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                                     with: .color(Color(hex: 0xF6E7B8).opacity(0.05)))
                        x += step
                    }
                    y += step
                }
            }

            sheen
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Quieto el 60 % del tiempo y luego cruza de izquierda a derecha.
    private var sheen: some View {
        let cycle = (t / 7).truncatingRemainder(dividingBy: 1)
        let progress = max(0, (cycle - 0.6) / 0.4)
        return LinearGradient(colors: [.clear, Color(hex: 0xF6E7B8).opacity(0.07), .clear],
                              startPoint: .leading, endPoint: .trailing)
            .frame(width: size.width * 0.5, height: size.height * 0.6)
            .rotationEffect(.degrees(-20))
            .offset(x: -size.width * 0.6 + size.width * 1.7 * progress)
    }
}

// MARK: - Aurora

/// Cintas boreales verdes y cian que se mecen sobre un cielo nocturno con
/// montañas en el horizonte.
private struct AuroraSky: View {
    let t: Double
    let size: CGSize

    private var horizon: CGFloat { min(size.height * 0.38, 330) }

    var body: some View {
        let sway = ProThemeBackdrop.wave(t, period: 16)
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: Color(hex: 0x01060D), location: 0),
                                   .init(color: Color(hex: 0x031219), location: 0.45),
                                   .init(color: Color(hex: 0x05211F), location: 0.78),
                                   .init(color: Color(hex: 0x04110F), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: horizon + 40)

            StarField(t: t, size: size, count: 55, depth: 0.4, tint: Color(hex: 0xE6FFF4), drift: 240)

            glow(Color(hex: 0x2BE3A0), opacity: 0.22, diameter: size.width * 1.2)
                .position(x: size.width * 0.55, y: horizon * 0.7)

            // Tenues: el monto va encima y tiene que leerse sin esfuerzo.
            ribbon(color1: Color(hex: 0x34D399), color2: Color(hex: 0x22D3EE), baseY: horizon * 0.22,
                   amplitude: 24, thickness: 90, phase: 0, opacity: 0.26 + 0.14 * ProThemeBackdrop.wave(t, period: 6))
                .offset(x: -28 * sway)
            ribbon(color1: Color(hex: 0x10B981), color2: Color(hex: 0xA7F3D0), baseY: horizon * 0.42,
                   amplitude: 18, thickness: 60, phase: 1.7, opacity: 0.18 + 0.12 * ProThemeBackdrop.wave(t, period: 8, phase: 0.4))
                .offset(x: 22 * sway)
            ribbon(color1: Color(hex: 0x22D3EE), color2: Color(hex: 0x818CF8), baseY: horizon * 0.1,
                   amplitude: 14, thickness: 50, phase: 3.1, opacity: 0.12 + 0.1 * ProThemeBackdrop.wave(t, period: 10, phase: 0.7))
                .offset(x: -14 * sway)

            mountains
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Una cinta: una franja ondulada con degradado vertical que se apaga
    /// por arriba y por abajo.
    private func ribbon(color1: Color, color2: Color, baseY: CGFloat, amplitude: CGFloat,
                        thickness: CGFloat, phase: Double, opacity: Double) -> some View {
        let wobble = t / 9
        return Path { path in
            let width = size.width + 80
            let steps = 24
            func y(_ x: CGFloat, _ extra: CGFloat) -> CGFloat {
                baseY + extra + amplitude * CGFloat(sin(Double(x / width) * 2.6 * .pi + phase + wobble))
            }
            path.move(to: CGPoint(x: -40, y: y(0, 0)))
            for i in 1...steps {
                let x = CGFloat(i) / CGFloat(steps) * width
                path.addLine(to: CGPoint(x: x - 40, y: y(x, 0)))
            }
            for i in stride(from: steps, through: 0, by: -1) {
                let x = CGFloat(i) / CGFloat(steps) * width
                path.addLine(to: CGPoint(x: x - 40, y: y(x, thickness)))
            }
            path.closeSubpath()
        }
        .fill(LinearGradient(stops: [.init(color: color2.opacity(0), location: 0),
                                     .init(color: color2.opacity(0.7), location: 0.3),
                                     .init(color: color1, location: 0.65),
                                     .init(color: color1.opacity(0), location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .opacity(opacity)
    }

    private var mountains: some View {
        Path { path in
            let w = size.width
            let h = horizon
            path.move(to: CGPoint(x: 0, y: h + 10))
            let peaks: [(CGFloat, CGFloat)] = [(0.08, -14), (0.18, 4), (0.3, -26), (0.42, -6), (0.55, -20),
                                               (0.66, 2), (0.78, -30), (0.9, -8), (1.0, -16)]
            for (x, dy) in peaks { path.addLine(to: CGPoint(x: w * x, y: h + dy)) }
            path.addLine(to: CGPoint(x: w, y: h + 60))
            path.addLine(to: CGPoint(x: 0, y: h + 60))
            path.closeSubpath()
        }
        .fill(LinearGradient(colors: [Color(hex: 0x010806), Color(hex: 0x04110F)],
                             startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - Atardecer

/// Cielo coral con un sol que late en el horizonte y su reflejo en el agua.
private struct SunsetSky: View {
    let t: Double
    let size: CGSize

    /// Justo bajo el chip del monto: «Últimos 7 días» cae ya sobre el agua,
    /// donde se lee bien.
    private var horizon: CGFloat { min(size.height * 0.3, 262) }

    var body: some View {
        let pulse = ProThemeBackdrop.wave(t, period: 5)
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: Color(hex: 0x120A26), location: 0),
                                   .init(color: Color(hex: 0x2A0F3A), location: 0.22),
                                   .init(color: Color(hex: 0x5A1845), location: 0.45),
                                   .init(color: Color(hex: 0x9C2E45), location: 0.64),
                                   .init(color: Color(hex: 0xD9542F), location: 0.82),
                                   .init(color: Color(hex: 0xF7954A), location: 0.96),
                                   .init(color: Color(hex: 0xFDC06A), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: horizon)

            // El sol, cortado por el horizonte, con su halo.
            ZStack {
                glow(Color(hex: 0xFDD68C), opacity: 0.55, diameter: 300)
                    .scaleEffect(1 + 0.12 * pulse)
                    .opacity(0.85 + 0.15 * pulse)
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: 0xFFF4D6), Color(hex: 0xFDE68A),
                                                  Color(hex: 0xFDBA74), Color(hex: 0xFB923C)],
                                         center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 75))
                    .frame(width: 136, height: 136)
            }
            .position(x: size.width * 0.72, y: horizon + 6)
            .mask(alignment: .top) { Rectangle().frame(height: horizon) }

            // El agua bajo el horizonte.
            LinearGradient(stops: [.init(color: Color(hex: 0x5A1A36), location: 0),
                                   .init(color: Color(hex: 0x2A0E22), location: 0.45),
                                   .init(color: Color(hex: 0x1A0B14).opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 170)
                .offset(y: horizon)

            reflections(pulse: pulse)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Las rayas de luz del sol en el agua, cada vez más cortas y tenues.
    private func reflections(pulse: Double) -> some View {
        let opacities: [Double] = [0.9, 0.7, 0.55, 0.45, 0.35, 0.25]
        return ZStack(alignment: .topLeading) {
            ForEach(Array(opacities.enumerated()), id: \.offset) { index, opacity in
                let width = 150 - CGFloat(index) * 18
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: 0xFDE68A).opacity(0), Color(hex: 0xFDE68A).opacity(opacity),
                                                  Color(hex: 0xFDE68A).opacity(0)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: width + CGFloat(8 * pulse), height: 1.6)
                    .position(x: size.width * 0.72, y: horizon + 8 + CGFloat(index) * 9)
            }
        }
    }
}

// MARK: - Piezas compartidas de los cielos nuevos

/// Una franja de luz que cruza: quieta el 60 % de la vuelta y luego pasa de
/// izquierda a derecha (`pSheen` del diseño).
private func sheen(t: Double, period: Double, width: CGFloat, height: CGFloat, colors: [Color]) -> some View {
    let progress = max(0, (ProThemeBackdrop.cycle(t, period: period) - 0.6) / 0.4)
    return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
        .frame(width: width, height: height)
        .rotationEffect(.degrees(-20))
        .offset(x: -width * 1.2 + width * 3.8 * progress)
}

/// Interpola entre fotogramas clave con una curva suave, para los latidos
/// que no son una onda simple (la campana de las medusas).
private func keyframes(_ progress: Double, _ frames: [(at: Double, value: Double)]) -> Double {
    guard let last = frames.last else { return 0 }
    for (index, frame) in frames.enumerated().dropFirst() where progress <= frame.at {
        let previous = frames[index - 1]
        let span = max(frame.at - previous.at, 0.0001)
        let x = (progress - previous.at) / span
        let eased = x * x * (3 - 2 * x)
        return previous.value + (frame.value - previous.value) * eased
    }
    return last.value
}

/// Una mancha elíptica: el degradado se estira con el marco.
private func ellipseGlow(_ color: Color, opacity: Double, fade: CGFloat = 0.7) -> some View {
    Ellipse().fill(EllipticalGradient(colors: [color.opacity(opacity), color.opacity(0)],
                                      center: .center, startRadiusFraction: 0, endRadiusFraction: fade))
}

// MARK: - Abismo

/// Aguas profundas: azul petróleo que se oscurece hacia abajo, rayos tenues
/// desde la superficie, tres medusas que laten y nieve marina que sube. La
/// medusa grande va arriba a la derecha para no pisar el monto.
private struct AbyssSky: View {
    let t: Double
    let size: CGSize
    var calm = false

    var body: some View {
        let k = size.width / 393
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: Color(hex: 0x0B4150), location: 0),
                                   .init(color: Color(hex: 0x072C36), location: 0.32),
                                   .init(color: Color(hex: 0x041B22), location: 0.65),
                                   .init(color: Color(hex: 0x03141A).opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: 560)

            ForEach(0..<3, id: \.self) { i in
                let sway = ProThemeBackdrop.wave(t, period: 14 + Double(i) * 3, phase: Double(i) * 0.2)
                LinearGradient(colors: [Color(hex: 0xA5F3FC).opacity(0.13), Color(hex: 0xA5F3FC).opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: 46 + CGFloat(i) * 10, height: 620)
                    .rotationEffect(.degrees(-24 + 4 * sway), anchor: .top)
                    .offset(x: (30 + CGFloat(i) * 120) * k + 18 * sway, y: -140)
            }

            glow(Color(hex: 0x22D3EE), opacity: 0.16, diameter: 420)
                .scaleEffect(1 + 0.2 * ProThemeBackdrop.wave(t, period: 16))
                .position(x: 320 * k, y: 140)
            glow(Color(hex: 0x0E7490), opacity: 0.3, diameter: 460)
                .scaleEffect(1.1 - 0.15 * ProThemeBackdrop.wave(t, period: 20, phase: 0.3))
                .position(x: 40 * k, y: 420)

            Jellyfish(t: t, width: 88, duration: 6, delay: 0)
                .opacity(0.95)
                .offset(x: 268 * k, y: 74)
            if !calm {
                Jellyfish(t: t, width: 52, duration: 7.5, delay: 2.5)
                    .opacity(0.6)
                    .offset(x: 34 * k, y: 330)
                Jellyfish(t: t, width: 30, duration: 5.2, delay: 1.2)
                    .opacity(0.5)
                    .offset(x: 196 * k, y: 22)
            }

            MarineSnow(t: t, size: size, count: calm ? 20 : 40)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// Una medusa: campana que se encoge y estira, tentáculos que se mecen y
/// una deriva lenta arriba y abajo. El halo es un degradado, no una sombra.
private struct Jellyfish: View {
    let t: Double
    let width: CGFloat
    let duration: Double
    let delay: Double

    private static let tentacleLengths: [CGFloat] = [1.25, 1.55, 1.0, 1.65, 1.3]

    var body: some View {
        let w = width
        let beat = ProThemeBackdrop.cycle(t + delay, period: duration)
        let scaleX = keyframes(beat, [(0, 1), (0.45, 0.84), (0.6, 1.04), (1, 1)])
        let scaleY = keyframes(beat, [(0, 1), (0.45, 1.1), (0.6, 0.95), (1, 1)])
        let drift = ProThemeBackdrop.wave(t + delay, period: duration * 2.6)
        ZStack(alignment: .topLeading) {
            glow(Color(hex: 0x22D3EE), opacity: 0.3, diameter: w * 1.7)
                .position(x: w / 2, y: w * 0.32)

            ForEach(0..<5, id: \.self) { i in
                let swing = ProThemeBackdrop.wave(t + delay, period: duration * 1.3, phase: Double(i) * 0.12)
                Rectangle()
                    .fill(LinearGradient(colors: [Color(hex: 0x67E8F9).opacity(0.55), Color(hex: 0x67E8F9).opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: i % 2 == 1 ? 1.2 : 1.8, height: w * Self.tentacleLengths[i])
                    .rotationEffect(.degrees(-5 + 11 * swing), anchor: .top)
                    .offset(x: w * (0.18 + CGFloat(i) * 0.16), y: w * 0.5)
            }
            ForEach(0..<2, id: \.self) { i in
                let swing = ProThemeBackdrop.wave(t + delay, period: duration * 1.7, phase: Double(i) * 0.25)
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(stops: [.init(color: Color(hex: 0xCFFAFE).opacity(0.45), location: 0),
                                                 .init(color: Color(hex: 0x22D3EE).opacity(0.12), location: 0.6),
                                                 .init(color: Color(hex: 0x22D3EE).opacity(0), location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 4, height: w * 0.9)
                    .rotationEffect(.degrees(-5 + 11 * swing), anchor: .top)
                    .offset(x: w * (0.38 + CGFloat(i) * 0.18), y: w * 0.52)
            }

            JellyBell()
                .fill(RadialGradient(stops: [.init(color: Color(hex: 0xE0FCFF).opacity(0.7), location: 0),
                                             .init(color: Color(hex: 0x67E8F9).opacity(0.32), location: 0.4),
                                             .init(color: Color(hex: 0x22D3EE).opacity(0.1), location: 0.72),
                                             .init(color: Color(hex: 0x22D3EE).opacity(0.04), location: 1)],
                                     center: UnitPoint(x: 0.5, y: 0.28), startRadius: 0, endRadius: w * 0.6))
                .overlay(JellyBell().stroke(Color(hex: 0xA5F3FC).opacity(0.35), lineWidth: 0.8))
                .frame(width: w, height: w * 0.62)
                .scaleEffect(x: scaleX, y: scaleY, anchor: .bottom)
        }
        .frame(width: w, height: w * 2, alignment: .topLeading)
        .offset(y: -22 * drift)
    }
}

/// La campana: cúpula alta y el borde de abajo apenas curvo.
private struct JellyBell: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let rim = rect.height * 0.82
        path.move(to: CGPoint(x: rect.minX, y: rim))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                      control1: CGPoint(x: rect.minX, y: rect.height * 0.25),
                      control2: CGPoint(x: rect.width * 0.2, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rim),
                      control1: CGPoint(x: rect.width * 0.8, y: rect.minY),
                      control2: CGPoint(x: rect.maxX, y: rect.height * 0.25))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rim),
                          control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.1))
        path.closeSubpath()
        return path
    }
}

/// Partículas que suben despacio y se apagan, como nieve marina.
private struct MarineSnow: View {
    let t: Double
    let size: CGSize
    var count = 40

    var body: some View {
        Canvas { context, canvas in
            var rng = SeededRandom(seed: 19)
            for _ in 0..<count {
                let x = rng.next() * Double(canvas.width)
                let y = 80 + rng.next() * 560
                let radius = 0.6 + rng.next() * 1.2
                let period = 14 + rng.next() * 12
                let progress = ProThemeBackdrop.cycle(t, period: period, phase: rng.next())
                let alpha = progress < 0.2 ? progress / 0.2 * 0.85 : 0.85 * (1 - (progress - 0.2) / 0.8)
                let rect = CGRect(x: x + 14 * progress - radius, y: y - 210 * progress - radius,
                                  width: radius * 2, height: radius * 2)
                context.opacity = alpha
                context.fill(Path(ellipseIn: rect), with: .color(Color(hex: 0xBAF0FA)))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Perla

/// Nácar: tres nubes pastel que respiran y se desplazan, un brillo
/// iridiscente que gira, un destello que cruza y burbujas que suben.
private struct PearlSky: View {
    let t: Double
    let size: CGSize
    var calm = false

    var body: some View {
        let w = size.width
        ZStack(alignment: .topLeading) {
            cloud(0xF5B8D8, opacity: 0.8, diameter: w * 1.05, at: CGPoint(x: w * 0.12, y: 70),
                  breathe: 9, drift: 13, phase: 0)
            cloud(0xC8B8FF, opacity: 0.85, diameter: w * 0.95, at: CGPoint(x: w * 0.92, y: 150),
                  breathe: 11, drift: 16, phase: 0.5)
            cloud(0xB8EDDC, opacity: 0.6, diameter: w * 0.8, at: CGPoint(x: w * 0.3, y: 250),
                  breathe: 13, drift: 19, phase: 0.3)

            Circle()
                .fill(AngularGradient(colors: [Color(hex: 0xFFD1E8), Color(hex: 0xD6CCFF), Color(hex: 0xC9F5E8),
                                               Color(hex: 0xFFF1C9), Color(hex: 0xFFD1E8)], center: .center))
                .frame(width: 720, height: 720)
                .mask(RadialGradient(colors: [.black, .clear], center: .center, startRadius: 0, endRadius: 360 * 0.66))
                .rotationEffect(.degrees(360 * ProThemeBackdrop.cycle(t, period: 18)))
                .opacity(0.5)
                .position(x: 200, y: 60)

            if !calm {
                sheen(t: t, period: 6, width: 200, height: 520,
                      colors: [.white.opacity(0), Color(hex: 0xFFECF8).opacity(0.75),
                               Color(hex: 0xE1F5FF).opacity(0.55), .white.opacity(0)])
                    .offset(y: -40)
                Bubbles(t: t, size: size)
            }

            StarField(t: t, size: size, count: 34, depth: 0.45, tint: .white, drift: 260)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func cloud(_ hex: UInt32, opacity: Double, diameter: CGFloat, at point: CGPoint,
                       breathe: Double, drift: Double, phase: Double) -> some View {
        let move = ProThemeBackdrop.wave(t, period: drift * 2, phase: phase)
        return glow(Color(hex: hex), opacity: opacity, diameter: diameter)
            .scaleEffect(1 + 0.2 * ProThemeBackdrop.wave(t, period: breathe, phase: phase))
            .position(x: point.x - 26 + 52 * move, y: point.y + 10 - 24 * move)
    }
}

/// Burbujas iridiscentes que suben, crecen un poco y se apagan.
private struct Bubbles: View {
    let t: Double
    let size: CGSize

    var body: some View {
        Canvas { context, canvas in
            var rng = SeededRandom(seed: 5)
            let k = canvas.width / 393
            for _ in 0..<9 {
                let x = rng.next() * 360 * Double(k)
                let radius = 6 + rng.next() * 14
                let period = 11 + rng.next() * 8
                let y = 300 + rng.next() * 160
                let progress = ProThemeBackdrop.cycle(t, period: period, phase: rng.next())
                let alpha = progress < 0.15 ? progress / 0.15 : 1 - (progress - 0.15) / 0.85
                let r = radius * (0.8 + 0.3 * progress)
                let center = CGPoint(x: x + radius, y: y + radius - 380 * progress)
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                context.opacity = alpha
                context.fill(Path(ellipseIn: rect), with: .radialGradient(
                    Gradient(stops: [.init(color: .white.opacity(0.95), location: 0),
                                     .init(color: .white.opacity(0.95), location: 0.14),
                                     .init(color: Color(hex: 0xD6CCFF).opacity(0.35), location: 0.4),
                                     .init(color: Color(hex: 0xC9F5E8).opacity(0.3), location: 0.7),
                                     .init(color: Color(hex: 0xFFD1E8).opacity(0.2), location: 1)]),
                    center: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.minY + rect.height * 0.28),
                    startRadius: 0, endRadius: r * 1.4))
                context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.95)), lineWidth: 1)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Alba

/// El Atardecer de día: cielo durazno, un sol que sube y late a la derecha
/// —sin pisar el monto— y nubes blancas que cruzan despacio.
private struct DawnSky: View {
    let t: Double
    let size: CGSize

    var body: some View {
        let w = size.width, k = w / 393
        let rise = ProThemeBackdrop.wave(t, period: 6)
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: Color(hex: 0xFFD9BE), location: 0),
                                   .init(color: Color(hex: 0xFFE6D2), location: 0.4),
                                   .init(color: Color(hex: 0xFFF8F1).opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: w, height: 420)

            ZStack {
                glow(Color(hex: 0xFFC46B), opacity: 0.6, diameter: 340)
                Circle()
                    .fill(RadialGradient(stops: [.init(color: Color(hex: 0xFFF6DC), location: 0),
                                                 .init(color: Color(hex: 0xFFE08A), location: 0.4),
                                                 .init(color: Color(hex: 0xFFB46B), location: 0.8),
                                                 .init(color: Color(hex: 0xFF9A5C), location: 1)],
                                         center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 64))
                    .frame(width: 116, height: 116)
                    .opacity(0.85)
            }
            .scaleEffect(1 + 0.06 * rise)
            .position(x: w * 0.74, y: 270 - 6 * rise)

            ellipseGlow(.white, opacity: 0.9)
                .frame(width: 220, height: 60)
                .offset(x: 20 * k - 40 + 80 * ProThemeBackdrop.wave(t, period: 36), y: 70)
            ellipseGlow(.white, opacity: 0.8)
                .frame(width: 260, height: 70)
                .offset(x: 180 * k + 40 - 80 * ProThemeBackdrop.wave(t, period: 48, phase: 0.33), y: 170)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

// MARK: - Glaciar

/// Hielo y luz: un azul profundo arriba, facetas de hielo que destellan por
/// turnos, un brillo prismático que cruza y nieve que cae despacio.
private struct GlacierSky: View {
    let t: Double
    let size: CGSize
    var calm = false

    /// Las facetas, en puntos de un ancho de 393 y el momento de su destello.
    private static let facets: [([CGPoint], Double)] = [
        ([CGPoint(x: 0, y: 0), CGPoint(x: 150, y: 0), CGPoint(x: 58, y: 250)], 0),
        ([CGPoint(x: 96, y: 0), CGPoint(x: 262, y: 0), CGPoint(x: 176, y: 320)], 1.4),
        ([CGPoint(x: 226, y: 0), CGPoint(x: 393, y: 0), CGPoint(x: 393, y: 130), CGPoint(x: 306, y: 280)], 2.8),
        ([CGPoint(x: 40, y: 0), CGPoint(x: 118, y: 0), CGPoint(x: 84, y: 150)], 4.2),
        ([CGPoint(x: 300, y: 0), CGPoint(x: 360, y: 0), CGPoint(x: 336, y: 170)], 3.3),
        ([CGPoint(x: 0, y: 0), CGPoint(x: 393, y: 0), CGPoint(x: 393, y: 34), CGPoint(x: 0, y: 96)], 5.1)
    ]

    var body: some View {
        let w = size.width, k = w / 393
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: Color(hex: 0x9EC8F0), location: 0),
                                   .init(color: Color(hex: 0xC4DDF6), location: 0.28),
                                   .init(color: Color(hex: 0xE3EFFA), location: 0.58),
                                   .init(color: Color(hex: 0xF2F7FC).opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: w, height: 480)

            glow(Color(hex: 0x6FA9E8), opacity: 0.55, diameter: 480)
                .scaleEffect(1 + 0.2 * ProThemeBackdrop.wave(t, period: 12))
                .position(x: w * 0.12, y: 40)
            glow(Color(hex: 0x9FE6F0), opacity: 0.6, diameter: 400)
                .scaleEffect(1.1 - 0.15 * ProThemeBackdrop.wave(t, period: 15, phase: 0.3))
                .position(x: w * 0.95, y: 190)

            ForEach(Self.facets.indices, id: \.self) { index in
                let (points, delay) = Self.facets[index]
                Path { path in
                    path.addLines(points.map { CGPoint(x: $0.x * k, y: $0.y) })
                    path.closeSubpath()
                }
                .fill(LinearGradient(stops: [.init(color: .white.opacity(0.8), location: 0),
                                             .init(color: Color(hex: 0xE8F6FF).opacity(0.25), location: 0.55),
                                             .init(color: .white.opacity(0), location: 1)],
                                     startPoint: UnitPoint(x: 0.63, y: 0), endPoint: UnitPoint(x: 0.37, y: 1)))
                .opacity(0.45 + 0.55 * ProThemeBackdrop.wave(t + delay, period: 6))
            }

            sheen(t: t, period: 8, width: 150, height: 420,
                  colors: [.white.opacity(0), .white.opacity(0.85), Color(hex: 0xBAE6FD).opacity(0.6), .white.opacity(0)])
                .offset(y: -20)

            Snow(t: t, size: size, count: calm ? 18 : 34)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// Copos que caen en diagonal y se apagan antes de llegar a las tarjetas.
private struct Snow: View {
    let t: Double
    let size: CGSize
    var count = 34

    var body: some View {
        Canvas { context, canvas in
            var rng = SeededRandom(seed: 11)
            for _ in 0..<count {
                let x = rng.next() * Double(canvas.width)
                let radius = 1 + rng.next() * 2.2
                let period = 9 + rng.next() * 9
                let progress = ProThemeBackdrop.cycle(t, period: period, phase: rng.next())
                let y = -30 + 560 * progress
                let fade = y < 308 ? 1 : max(0, 1 - (y - 308) / 252)
                let center = CGPoint(x: x + 34 * progress + radius, y: y + radius)
                context.opacity = fade
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius - 1.5, y: center.y - radius - 1.5,
                                                    width: radius * 2 + 3, height: radius * 2 + 3)),
                             with: .color(Color(hex: 0x1F6FD1).opacity(0.12)))
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                    width: radius * 2, height: radius * 2)),
                             with: .color(.white))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Marfil

/// La Obsidiana de día: papel crema con grano dorado, un halo de oro y el
/// mismo brillo que cruza.
private struct IvorySky: View {
    let t: Double
    let size: CGSize

    var body: some View {
        let w = size.width
        ZStack(alignment: .topLeading) {
            glow(Color(hex: 0xE9D29A), opacity: 0.55, diameter: w * 1.4)
                .scaleEffect(1 + 0.2 * ProThemeBackdrop.wave(t, period: 9))
                .position(x: w * 0.5, y: size.height * 0.2)

            // Grano: puntos de oro que se apagan hacia abajo.
            Canvas { context, canvas in
                let step: CGFloat = 5
                let depth: CGFloat = 520
                var y: CGFloat = 0
                while y < depth {
                    context.opacity = Double(1 - y / depth)
                    var x: CGFloat = (Int(y / step) % 2 == 0) ? 0 : step / 2
                    while x < canvas.width {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                                     with: .color(Color(hex: 0x9A7430).opacity(0.16)))
                        x += step
                    }
                    y += step
                }
            }

            sheen(t: t, period: 7, width: w * 0.5, height: 560,
                  colors: [.white.opacity(0), Color(hex: 0xFFF8E0).opacity(0.85), .white.opacity(0)])
                .offset(y: -40)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

// MARK: - Salvia

/// Sol entre hojas: manchas de luz cálida que titilan y sombras de hojas
/// que se mecen desde arriba.
private struct SageSky: View {
    let t: Double
    let size: CGSize

    private static let shadows: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, angle: Double)] = [
        (40, 40, 150, 90, -20), (210, 10, 180, 100, 25), (120, 150, 120, 70, 40),
        (300, 200, 140, 80, -30), (10, 260, 160, 70, 15)
    ]
    private static let lights: [(x: CGFloat, y: CGFloat, d: CGFloat)] = [
        (90, 90, 120), (270, 120, 150), (190, 260, 110), (40, 200, 90)
    ]

    var body: some View {
        let w = size.width, k = w / 393
        let sway = ProThemeBackdrop.wave(t, period: 9)
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: Color(hex: 0xDCEAD4), location: 0),
                                   .init(color: Color(hex: 0xE9F1E4), location: 0.45),
                                   .init(color: Color(hex: 0xF5F8F3).opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: w, height: 440)

            ZStack(alignment: .topLeading) {
                ForEach(Self.shadows.indices, id: \.self) { i in
                    let leaf = Self.shadows[i]
                    ellipseGlow(Color(hex: 0x285C3A), opacity: 0.13)
                        .frame(width: leaf.w, height: leaf.h)
                        .rotationEffect(.degrees(leaf.angle))
                        .offset(x: leaf.x * k, y: leaf.y)
                }
                ForEach(Self.lights.indices, id: \.self) { i in
                    let spot = Self.lights[i]
                    Circle()
                        .fill(RadialGradient(colors: [Color(hex: 0xFFF6D2).opacity(0.9), Color(hex: 0xFFF6D2).opacity(0)],
                                             center: .center, startRadius: 0, endRadius: spot.d * 0.46))
                        .frame(width: spot.d, height: spot.d)
                        .opacity(0.15 + 0.85 * ProThemeBackdrop.wave(t, period: 5 + Double(i), phase: Double(i) * 0.2))
                        .offset(x: spot.x * k, y: spot.y)
                }
            }
            .frame(width: w + 120, height: 520, alignment: .topLeading)
            .rotationEffect(.degrees(-2.2 + 4.4 * sway), anchor: UnitPoint(x: 0.5, y: -0.3))
            .offset(x: -60, y: -60)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
