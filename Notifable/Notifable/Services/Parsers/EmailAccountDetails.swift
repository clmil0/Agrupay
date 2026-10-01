import Foundation

/// Los datos de **cuenta** de un aviso, comunes a varias plantillas y aparte de
/// los parsers: a dónde fue el dinero, el celular de quien lo recibió y si la
/// tarjeta es de débito o de crédito.
///
/// Van aparte porque no deciden si el correo es un gasto —eso lo hace cada
/// parser— sino de qué cuenta a cuál se movió (`AccountResolver`), y porque
/// así se pueden leer también de correos ya importados (`GmailSyncService
/// .backfillAccountData`) sin tocar lo que el usuario ya editó del gasto.
///
/// Todo es opcional: un patrón que no encuentra nada devuelve `nil`, nunca un
/// valor inventado.
enum EmailAccountDetails {

    /// "Destino: Yape" en los envíos por Plin de BBVA. Sólo bancos y
    /// billeteras conocidos: lo que venga detrás de "Destino" en otra
    /// plantilla no se toma por una cuenta.
    static func destinationWallet(in text: String) -> String? {
        let pattern = "Destino\\s*:?\\s*(Yape|Plin|BBVA|BCP|Interbank|Scotiabank|Banco de Cr[eé]dito)"
        guard let value = firstCapture(pattern, in: text),
              let institution = Institution(name: value) else { return nil }
        return institution.name
    }

    /// Los últimos dígitos visibles del celular de quien recibió el envío.
    /// Los bancos lo enmascaran distinto:
    /// - BBVA Plin: "Celular: •7209" (el `•` ya llega quitado).
    /// - Yape: "Celular del Beneficiario *** *** 913".
    /// - Scotiabank Plin: "Enviado a: Johel Mac*** *** *** 913".
    ///
    /// Si llega el número entero, se guardan sólo los cuatro últimos: basta
    /// para distinguir y es lo que muestran los demás bancos.
    static func payeePhone(in text: String) -> String? {
        let patterns = [
            "Celular(?:\\s+del\\s+Beneficiario)?\\s*:?\\s*([•*\\s]*[0-9](?: ?[0-9])*)",
            "Enviado a:\\s*[^*]*?(\\*{3}[*\\s]*[0-9]{3,4})"
        ]
        for pattern in patterns {
            guard let raw = firstCapture(pattern, in: text) else { continue }
            let digits = raw.filter(\.isNumber)
            if digits.count >= 3 { return String(digits.suffix(4)) }
        }
        return nil
    }

    /// "Débito" o "Crédito", sólo si el correo lo dice **junto a esos mismos
    /// dígitos** ("Tarjeta de Débito ****4016"). Una mención suelta —un
    /// anuncio al pie— no cuenta.
    ///
    /// También reconoce:
    /// - «Cuenta Digital *2368», «Cuenta de origen 2368», «Cuenta de ahorros*
    ///   **** 5092» → "Cuenta": no es una
    ///   tarjeta, es la cuenta de la que salen Plin, transferencias y retiros.
    /// - El chip del retiro en cajero: «Número de tarjeta · 8156 … (EMV) VISA
    ///   CREDITO».
    static func cardKind(in text: String, digits: String?) -> String? {
        guard let digits else { return nil }
        if let value = firstCapture("Tarjeta\\s+de\\s+(D[ée]bito|Cr[ée]dito)[^0-9]{0,25}\(digits)", in: text) {
            return AccountResolver.folded(value).hasPrefix("d") ? "Débito" : "Crédito"
        }
        if firstCapture("(tarjeta)\\s*[·•*]?\\s*\(digits)", in: text) != nil,
           let chip = firstCapture("\\(EMV\\)\\s*[A-Za-z ]*?\\b(CR[EÉ]DITO|D[EÉ]BITO)\\b", in: text) {
            return AccountResolver.folded(chip).hasPrefix("d") ? "Débito" : "Crédito"
        }
        if firstCapture("\\b(Cuenta)\\s+[A-Za-zÁÉÍÓÚáéíóú ]{0,20}?:?[\\s·•*]*\(digits)", in: text) != nil {
            return "Cuenta"
        }
        return nil
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
