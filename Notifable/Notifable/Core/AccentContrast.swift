import SwiftUI
import UIKit

// MARK: - Texto legible sobre el acento

/// Botones, pastillas y círculos rellenos con el color del tema.
///
/// El texto blanco sólo se lee bien sobre los acentos oscuros: con la fórmula
/// de WCAG, de los 16 temas básicos y los 10 Pro únicamente Azul, Carbón y
/// algunas variantes de Perla y Glaciar llegan a 4.5:1. Sobre Menta, Aurora,
/// Abismo, Arena, Naranja o los pasteles el blanco no pasa de 2:1.
///
/// Así que, para cada acento:
/// - si el blanco ya cumple 4.5:1, queda como está;
/// - si es un acento claro (la tinta oscura llega a 7:1), el texto pasa a
///   tinta oscura y el relleno no se toca: Menta sigue siendo menta;
/// - si es un acento medio (Nebulosa, Morado, Rojo, Salvia, Alba…), el
///   relleno se oscurece lo justo para que el blanco cumpla, sin cambiar su
///   tono.
///
/// Los dos son colores dinámicos: se resuelven con el modo claro/oscuro de
/// donde se pintan, así que valen también para los acentos de sistema que
/// cambian entre modos.
extension Color {

    /// El relleno de un botón con este color, ajustado si hace falta.
    var readableFill: Color {
        Color(UIColor { traits in
            AccentContrast.resolve(UIColor(self).resolvedColor(with: traits)).fill
        })
    }

    /// El texto (y los íconos) sobre `readableFill`.
    var readableText: Color {
        Color(UIColor { traits in
            AccentContrast.resolve(UIColor(self).resolvedColor(with: traits)).text
        })
    }
}

extension AppThemeColor {
    /// El acento como relleno de botón (ver `Color.readableFill`).
    var buttonFill: Color { color.readableFill }
    /// El texto sobre `buttonFill`: blanco o tinta oscura.
    var buttonText: Color { color.readableText }
}

enum AccentContrast {

    /// AA para texto normal: la etiqueta de un botón es de 13–17 pt, no
    /// cuenta como texto grande.
    static let minimum = 4.5
    /// A partir de aquí la tinta oscura se lee holgada y el acento se queda
    /// con su color; por debajo es un tono medio y conviene oscurecerlo.
    static let comfortableInk = 7.0

    /// La tinta oscura: casi negra, con un toque frío que no se ve sucio
    /// sobre los pasteles.
    static let ink = UIColor(red: 0.067, green: 0.067, blue: 0.086, alpha: 1)   // #111116

    private struct Key: Hashable { let r: Int, g: Int, b: Int }
    nonisolated(unsafe) private static var cache: [Key: (fill: UIColor, text: UIColor)] = [:]
    private static let lock = NSLock()

    static func resolve(_ color: UIColor) -> (fill: UIColor, text: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let key = Key(r: Int(r * 255), g: Int(g * 255), b: Int(b * 255))
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let result = compute(r: r, g: g, b: b, alpha: a)
        cache[key] = result
        return result
    }

    private static func compute(r: CGFloat, g: CGFloat, b: CGFloat, alpha: CGFloat) -> (fill: UIColor, text: UIColor) {
        let original = UIColor(red: r, green: g, blue: b, alpha: alpha)
        let lum = luminance(r, g, b)
        if ratio(1, lum) >= minimum { return (original, .white) }
        if ratio(lum, luminance(of: ink)) >= comfortableInk { return (original, ink) }

        // Tono medio: se baja la luminosidad (HSL) hasta que el blanco cumpla.
        var (h, s, l) = hsl(r, g, b)
        var fill = original
        for _ in 0..<50 {
            l = max(0, l - 0.01)
            let (nr, ng, nb) = rgb(h, s, l)
            fill = UIColor(red: nr, green: ng, blue: nb, alpha: alpha)
            if ratio(1, luminance(nr, ng, nb)) >= minimum { break }
        }
        return (fill, .white)
    }

    // MARK: - WCAG

    static func ratio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Double {
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    static func luminance(of color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return luminance(r, g, b)
    }

    // MARK: - HSL

    private static func hsl(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2, d = mx - mn
        guard d > 0 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: CGFloat
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return (h, s, l)
    }

    private static func rgb(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ t: CGFloat) -> CGFloat {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (hue(h + 1 / 3), hue(h), hue(h - 1 / 3))
    }
}
