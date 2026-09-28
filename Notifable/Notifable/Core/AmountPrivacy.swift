import SwiftUI

/// El ojito del resumen: esconde los montos del dashboard para enseñar el
/// teléfono sin enseñar cifras. Se recuerda entre aperturas.
///
/// Las vistas no deciden qué es un monto: pasan su texto por `mask`, que
/// cambia sólo las cifras que van detrás de un símbolo de moneda. Así
/// «S/ 204 · 8 movimientos» queda en «S/ ••• · 8 movimientos» y una fecha o
/// un porcentaje se ven igual.
enum AmountPrivacy {
    static let storageKey = "dashboardHidesAmounts"

    static let hiddenDigits = "•••"

    private static let pattern = try! NSRegularExpression(
        pattern: #"(S/|US\$|\$)\s*[0-9][0-9.,]*"#)

    static func mask(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, range: range,
                                                withTemplate: "$1 " + hiddenDigits)
    }
}

extension EnvironmentValues {
    /// `true` con el ojito cerrado. Lo pone el dashboard y lo heredan sus
    /// tarjetas y las hojas que abre.
    @Entry var hidesAmounts = false
}

extension String {
    /// El texto tal cual, o con los montos tapados si el ojito está cerrado.
    func masked(_ hidden: Bool) -> String {
        hidden ? AmountPrivacy.mask(self) : self
    }
}

// MARK: - Transición del ojito

extension EnvironmentValues {
    /// 0 en reposo, 1 en el punto medio del cambio. Mientras sube, los montos
    /// se desenfocan; en el pico se cambian las cifras por «•••» (o al
    /// revés) sin animación, y al bajar aparecen ya cambiadas. Así nunca se ve
    /// una cifra a medio convertir en puntos.
    @Entry var amountVeil: Double = 0

    /// `true` mientras dura el cambio del ojito. El texto cambia en seco
    /// (bajo el desenfoque) en vez de fundirse: fundido, se veían las cifras
    /// viejas detrás de los puntos mientras volvía el enfoque.
    @Entry var amountSwapping = false
}

private struct AmountVeilModifier: ViewModifier {
    @Environment(\.amountVeil) private var veil
    @Environment(\.amountSwapping) private var swapping

    func body(content: Content) -> some View {
        content
            .contentTransition(swapping ? .identity : .opacity)
            .blur(radius: 8 * veil)
            .opacity(1 - 0.6 * veil)
            .scaleEffect(1 - 0.05 * veil, anchor: .leading)
    }
}

extension View {
    /// Para cualquier texto que pase por `masked`: se desenfoca y vuelve al
    /// cambiar el ojito en vez de saltar de cifras a puntos.
    func amountVeil() -> some View {
        modifier(AmountVeilModifier())
    }
}
