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
