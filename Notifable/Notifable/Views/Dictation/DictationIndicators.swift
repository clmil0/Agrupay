import SwiftUI

/// El micrófono central de la escucha, con su halo que late (`micGlow`).
struct DictationMicButton: View {
    var isActive: Bool

    private var accent: AppThemeColor { .current }

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = (t.truncatingRemainder(dividingBy: 2)) / 2

            ZStack {
                if isActive {
                    Circle()
                        .fill(accent.color.opacity(0.34 * (1 - pulse)))
                        .frame(width: 52 + 28 * pulse, height: 52 + 28 * pulse)
                }
                Circle()
                    .fill(accent.buttonFill)
                    .frame(width: 52, height: 52)
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accent.buttonText)
            }
            .frame(width: 60, height: 60)
        }
    }
}

// MARK: - 1a · Barras de volumen

/// Dieciocho barras que laten, cada una a su ritmo, y crecen con el volumen
/// real del micrófono. En silencio quedan casi planas.
struct DictationBars: View {
    var level: Double
    var isActive: Bool
    /// La vista previa de Apariencia usa una versión chica, con menos barras.
    var count: Int = 18
    var height: CGFloat = 56
    var spacing: CGFloat = 4

    private var accent: AppThemeColor { .current }

    /// Duraciones y desfases del diseño: ningún par de barras va en fase.
    private static let durations: [Double] = [0.82, 0.64, 0.95, 0.71, 0.88, 0.58, 1.02, 0.76, 0.66, 0.92, 0.70, 0.84, 0.60, 0.98, 0.74, 0.86, 0.62, 0.90]
    private static let delays: [Double] = [0, 0.12, 0.05, 0.28, 0.16, 0.34, 0.09, 0.22, 0.40, 0.02, 0.30, 0.18, 0.44, 0.07, 0.26, 0.14, 0.36, 0.20]

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Aun callado, una respiración mínima dice «te estoy oyendo».
            let gain = isActive ? 0.22 + 0.78 * min(1, level * 1.3) : 0

            HStack(spacing: spacing) {
                ForEach(0..<min(count, Self.durations.count), id: \.self) { i in
                    let phase = (t + Self.delays[i]) / Self.durations[i] * 2 * .pi
                    let wave = 0.5 - 0.5 * cos(phase)
                    let height = 0.12 + 0.88 * wave * gain

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(accent.color)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(min(6, self.height * 0.2), self.height * height))
                }
            }
            .frame(height: self.height)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 1c · Blob orgánico

/// Dos formas que cambian de contorno y giran detrás del micrófono. Se
/// hinchan un poco con la voz.
struct DictationBlob: View {
    var level: Double
    var isActive: Bool
    var size: CGFloat = 60

    private var accent: AppThemeColor { .current }

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let swell = 1 + 0.16 * min(1, level * 1.3)

            ZStack {
                BlobShape(phase: t / 5.5 * 2 * .pi)
                    .fill(LinearGradient(colors: [accent.color, Color(red: 0.50, green: 0.85, blue: 0.74)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .opacity(0.34)
                    .frame(width: size * 1.2, height: size * 1.2)
                    .rotationEffect(.radians(t / 5.5 * 2 * .pi))
                    .scaleEffect(swell)

                BlobShape(phase: -t / 4 * 2 * .pi + 1.7)
                    .fill(LinearGradient(colors: [accent.color, Color(red: 0.55, green: 0.75, blue: 0.95)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .opacity(0.5)
                    .frame(width: size * 0.93, height: size * 0.93)
                    .rotationEffect(.radians(-t / 4 * 2 * .pi))
                    .scaleEffect(1 + (swell - 1) * 0.6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Un círculo con el radio ondulado por dos senos: se lee como algo vivo, no
/// como una figura geométrica que rota.
struct BlobShape: Shape {
    var phase: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let base = min(rect.width, rect.height) / 2
        let steps = 72
        var path = Path()

        for step in 0...steps {
            let angle = Double(step) / Double(steps) * 2 * .pi
            let wobble = 0.07 * sin(3 * angle + phase) + 0.05 * sin(2 * angle - phase * 1.3)
            let r = base * (0.9 + wobble)
            let point = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
