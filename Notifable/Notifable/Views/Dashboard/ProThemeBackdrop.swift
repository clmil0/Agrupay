import SwiftUI

/// El fondo animado de los temas Pro del Resumen (`3b`–`3e`).
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

    /// La variante y la intensidad del cielo elegidas en Apariencia; también
    /// para redibujar al moverlas con «Reducir movimiento» (sin animación).
    @AppStorage(ProTheme.skyIntensityKey) private var intensity = 1.0
    @AppStorage("proThemeTone.Nebulosa") private var nebulaTone = ""
    @AppStorage("proThemeTone.Obsidiana") private var obsidianTone = ""
    @AppStorage("proThemeTone.Aurora") private var auroraTone = ""
    @AppStorage("proThemeTone.Atardecer") private var sunsetTone = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || scenePhase != .active)) { context in
                let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                ZStack(alignment: .top) {
                    theme.base
                    Group {
                        switch theme {
                        case .nebula:   NebulaSky(t: t, size: size, calm: calm)
                        case .obsidian: ObsidianSky(t: t, size: size)
                        case .aurora:   AuroraSky(t: t, size: size)
                        case .sunset:   SunsetSky(t: t, size: size)
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
    }

    private var toneName: String {
        switch theme {
        case .nebula:   return nebulaTone
        case .obsidian: return obsidianTone
        case .aurora:   return auroraTone
        case .sunset:   return sunsetTone
        }
    }

    /// Una onda suave entre 0 y 1 con el periodo dado.
    static func wave(_ t: Double, period: Double, phase: Double = 0) -> Double {
        0.5 + 0.5 * sin((t / period + phase) * 2 * .pi)
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
