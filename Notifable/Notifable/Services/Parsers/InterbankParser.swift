import Foundation

/// Interbank manda tres avisos que son gasto, de dos remitentes:
/// - `servicioalcliente@netinterbank.com.pe`: «Constancia de Pago Plin» y
///   «Constancia de transferencia».
/// - `pagoautomatico@notificaciones.interbank.pe`: «Cargo exitoso Pago
///   Automático» (un recibo afiliado: Claro, Luz del Sur…).
///
/// La parte de texto plano trae los campos uno detrás de otro («Destinatario
/// JUAN PEREZ Destino Plin Monto y moneda S/ 1.00»); el HTML sin etiquetas,
/// lo mismo con más espacios. A veces los valores llegan entre asteriscos.
struct InterbankParser: BankEmailParser {

    var bankName: String {
        return "Interbank"
    }

    var senderEmails: [String] {
        return ["servicioalcliente@netinterbank.com.pe", "pagoautomatico@notificaciones.interbank.pe"]
    }

    func parse(cleanText: String) -> Expense? {
        if let expense = parsePlinSent(cleanText) { return expense }
        if let expense = parseTransfer(cleanText) { return expense }
        if let expense = parseAutomaticPayment(cleanText) { return expense }
        return nil
    }

    // MARK: - Plin

    /// «Constancia de Pago Plin»: Cuenta cargo (`Cuenta Simple Soles 898
    /// 1234567890`), Destinatario, Destino y Monto y moneda. Como los Plin de
    /// BBVA y Scotiabank, el comercio es «PLIN - <persona>».
    private func parsePlinSent(_ cleanText: String) -> Expense? {
        guard cleanText.range(of: "Constancia de Pago Plin", options: .caseInsensitive) != nil,
              let (currency, amount) = Self.money(after: "Monto y moneda", in: cleanText) else { return nil }

        let name = Self.capture("Destinatario[\\s*]*(.+?)[\\s*]*(?:Destino|Monto y moneda)", in: cleanText)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return Expense(amount: amount,
                       merchant: "PLIN - " + (name.isEmpty ? "Desconocido" : name),
                       date: Self.operationDate(in: cleanText) ?? Date(),
                       category: "Sin Clasificar", currency: currency,
                       cardLastDigits: Self.chargedAccount(in: cleanText))
    }

    // MARK: - Transferencias

    /// «Constancia de transferencia»: Cuenta a cargo, Cuenta destino (banco y
    /// número), Tipo de operación, Monto y moneda, Comisión y Monto total. No
    /// trae el nombre del titular de destino, así que la cuenta se nombra por
    /// su banco y sus cuatro últimos dígitos («INTERBANK - Cuenta BBVA
    /// Continental *1234»): si es tuya, se marca en «Tus cuentas» y pasa a
    /// traslado (`TransferDetector`).
    private func parseTransfer(_ cleanText: String) -> Expense? {
        guard cleanText.range(of: "Constancia de transferencia", options: .caseInsensitive) != nil,
              cleanText.range(of: "Cuenta a cargo", options: .caseInsensitive) != nil,
              // Monto total primero: incluye la comisión, cuando la hay.
              let (currency, amount) = Self.money(after: "Monto total", in: cleanText)
                ?? Self.money(after: "Monto y moneda", in: cleanText) else { return nil }

        var label = "Transferencia"
        if let destination = Self.capture2("Cuenta destino[\\s*]*(.*?)[\\s*]*([0-9][0-9 -]{5,})[\\s*]*(?:Tipo de operaci|Monto)", in: cleanText) {
            let bank = destination.0.trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = destination.1.filter(\.isNumber)
            label = (bank.isEmpty ? "Cuenta" : "Cuenta \(bank)") + " *" + digits.suffix(4)
        }

        return Expense(amount: amount,
                       merchant: "INTERBANK - " + label,
                       date: Self.operationDate(in: cleanText) ?? Date(),
                       category: "Sin Clasificar", currency: currency,
                       cardLastDigits: Self.chargedAccount(in: cleanText))
    }

    // MARK: - Pago Automático

    /// «¡El pago de tu servicio afiliado a Pago Automático se ha realizado con
    /// éxito!»: Empresa (`009 - CLARO`), Servicio, Código cliente, Monto
    /// cobrado y Fecha de pago (sólo el día). No dice de qué cuenta o tarjeta
    /// salió. Es un recibo que se repite: va como suscripción, igual que el
    /// pago automático de BBVA.
    private func parseAutomaticPayment(_ cleanText: String) -> Expense? {
        guard cleanText.range(of: "Pago Autom[aá]tico", options: [.regularExpression, .caseInsensitive]) != nil,
              let (currency, amount) = Self.money(after: "Monto cobrado:?", in: cleanText) else { return nil }

        // «Empresa: 009 - CLARO    - Servicio: 01 - CLARO»: sin el código.
        let company = Self.capture("Empresa:?[\\s*]*(?:[0-9]+\\s*-\\s*)?(.+?)[\\s*-]*Servicio:", in: cleanText)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var date = Date()
        if let day = Self.capture("Fecha de pago:?[\\s*]*([0-9]{1,2}/[0-9]{1,2}/[0-9]{4})", in: cleanText) {
            let formatter = DateFormatter()
            formatter.timeZone = BankEmailTime.zone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            // Sin hora en el correo: mediodía, para que el día no cambie al
            // verlo desde otra zona horaria.
            formatter.dateFormat = "dd/MM/yyyy HH:mm"
            date = formatter.date(from: day + " 12:00") ?? date
        }

        return Expense(amount: amount,
                       merchant: company.isEmpty ? "Pago automático" : company,
                       date: date, category: "Sin Clasificar",
                       isSubscription: true, currency: currency)
    }

    // MARK: - Campos comunes

    /// «Monto y moneda S/ 1.00», «Monto cobrado: S/ 39.90», «US$ 12.00».
    private static func money(after label: String, in text: String) -> (String, Double)? {
        guard let money = capture2(label + "[\\s*]*(S/\\.?|US\\$|\\$)\\s*([0-9][0-9.,]*)", in: text),
              let amount = Money.parse(money.1) else { return nil }
        return (money.0.contains("$") ? "USD" : "PEN", amount)
    }

    /// Los cuatro últimos dígitos de la cuenta de la que salió el dinero:
    /// «Cuenta cargo Cuenta Simple Soles 898 1234567890» (Plin) o «Cuenta a
    /// cargo Cuenta Simple 898 1234567890» (transferencia).
    private static func chargedAccount(in text: String) -> String? {
        guard let number = capture("Cuenta (?:a )?cargo[\\s*]*[^0-9]{0,40}?([0-9][0-9 ]{3,})", in: text) else { return nil }
        let digits = number.filter(\.isNumber)
        return digits.count >= 4 ? String(digits.suffix(4)) : nil
    }

    /// «Fecha y hora 05 Oct 2026 10:56 PM». El mes viene abreviado; se
    /// aceptan las abreviaturas en inglés y en español («Set», «Ago», «Dic»).
    private static func operationDate(in text: String) -> Date? {
        let pattern = "Fecha y hora[\\s*]*([0-9]{1,2})\\s+([A-Za-z]{3,})\\.?\\s+([0-9]{4})\\s+([0-9]{1,2}:[0-9]{2})[\\s\\u00A0]*([AP])\\.?[\\s\\u00A0]*M"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else { return nil }
        let parts = (1...5).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        let months = ["ene": "01", "jan": "01", "feb": "02", "mar": "03", "abr": "04", "apr": "04",
                      "may": "05", "jun": "06", "jul": "07", "ago": "08", "aug": "08", "set": "09",
                      "sep": "09", "oct": "10", "nov": "11", "dic": "12", "dec": "12"]
        guard parts.count == 5, let month = months[String(parts[1].lowercased().prefix(3))] else { return nil }
        let formatter = DateFormatter()
        formatter.timeZone = BankEmailTime.zone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MM yyyy h:mm a"
        return formatter.date(from: "\(parts[0]) \(month) \(parts[2]) \(parts[3]) \(parts[4].uppercased())M")
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func capture2(_ pattern: String, in text: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              let first = Range(match.range(at: 1), in: text),
              let second = Range(match.range(at: 2), in: text) else { return nil }
        return (String(text[first]), String(text[second]))
    }
}
