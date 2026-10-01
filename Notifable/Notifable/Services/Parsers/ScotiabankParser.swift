import Foundation

struct ScotiabankParser: BankEmailParser {

    var bankName: String {
        return "Scotiabank"
    }

    var senderEmails: [String] {
        return ["bancadigital@scotiabank.com.pe"]
    }

    func parse(cleanText: String) -> Expense? {
        if let expense = parsePlinTransfer(cleanText) { return expense }
        if let expense = parseQRPayment(cleanText) { return expense }
        return nil
    }

    private func parsePlinTransfer(_ cleanText: String) -> Expense? {
        guard cleanText.contains("Transferencia Plin") else {
            return nil
        }

        let amountPattern = "Monto enviado:\\s*S/\\s*([0-9.,]+)"
        guard let amountRegex = try? NSRegularExpression(pattern: amountPattern, options: [.dotMatchesLineSeparators]),
              let amountMatch = amountRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
              let amountRange = Range(amountMatch.range(at: 1), in: cleanText) else {
            return nil
        }
        let amountStr = String(cleanText[amountRange]).replacingOccurrences(of: ",", with: "")
        let amount = Double(amountStr) ?? 0

        var merchant = "PLIN - Desconocido"
        let targetPattern = "Enviado a:\\s*(.*?)\\s*Con Plin env"
        if let targetRegex = try? NSRegularExpression(pattern: targetPattern, options: [.dotMatchesLineSeparators]),
           let targetMatch = targetRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let targetRange = Range(targetMatch.range(at: 1), in: cleanText) {
            var target = String(cleanText[targetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Si el destino es una persona, debajo del nombre viene su celular
            // enmascarado ("Johel Mac*** *** *** 913"); si es un negocio, no hay
            // segunda línea. Cortamos en la primera máscara para no meter el
            // teléfono dentro del nombre del comercio/persona.
            if let nameRegex = try? NSRegularExpression(pattern: "^(.*?\\*{3})", options: []),
               let nameMatch = nameRegex.firstMatch(in: target, options: [], range: NSRange(location: 0, length: target.utf16.count)),
               let nameRange = Range(nameMatch.range(at: 1), in: target) {
                target = String(target[nameRange])
            }
            merchant = "PLIN - \(target)"
        }

        let expenseDate = extractScotiaDate(from: cleanText) ?? Date()

        return Expense(amount: amount, merchant: merchant, date: expenseDate, category: "Sin Clasificar", currency: "PEN")
    }

    private func parseQRPayment(_ cleanText: String) -> Expense? {
        guard cleanText.contains("Pago con QR") else {
            return nil
        }

        let amountPattern = "Monto:\\s*S/\\s*([0-9.,]+)"
        guard let amountRegex = try? NSRegularExpression(pattern: amountPattern, options: [.dotMatchesLineSeparators]),
              let amountMatch = amountRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
              let amountRange = Range(amountMatch.range(at: 1), in: cleanText) else {
            return nil
        }
        let amountStr = String(cleanText[amountRange]).replacingOccurrences(of: ",", with: "")
        let amount = Double(amountStr) ?? 0

        var merchant = "Desconocido"
        let merchantPattern = "Pagaste a:\\s*(.*?)\\s*Muchas gracias"
        if let merchantRegex = try? NSRegularExpression(pattern: merchantPattern, options: [.dotMatchesLineSeparators]),
           let merchantMatch = merchantRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let merchantRange = Range(merchantMatch.range(at: 1), in: cleanText) {
            merchant = String(cleanText[merchantRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var cardLastDigits: String? = nil
        let cardPattern = "Pagaste con:\\s*.*?\\*{4}\\s*\\*{4}\\s*\\*{4}\\s*([0-9]{4})"
        if let cardRegex = try? NSRegularExpression(pattern: cardPattern, options: [.dotMatchesLineSeparators]),
           let cardMatch = cardRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let cardRange = Range(cardMatch.range(at: 1), in: cleanText) {
            cardLastDigits = String(cleanText[cardRange])
        }

        let expenseDate = extractScotiaDate(from: cleanText) ?? Date()

        return Expense(amount: amount, merchant: merchant, date: expenseDate, category: "Sin Clasificar", currency: "PEN", cardLastDigits: cardLastDigits)
    }

    /// Scotia sólo manda la hora como "28 ago., 07:10 pm" en el cuerpo, sin año.
    /// Se asume el año actual y, si el resultado cae más de un día en el futuro
    /// (el correo es de diciembre pero se sincroniza ya en enero), se retrocede
    /// un año — mismo problema de "sin año" que no tienen BCP/Yape/BBVA porque
    /// esos sí incluyen el año en el texto.
    private func extractScotiaDate(from cleanText: String) -> Date? {
        let datePattern = "([0-9]{1,2})\\s+([a-zA-Z]+)\\.,\\s*([0-9]{2}:[0-9]{2})\\s*([ap]m)"
        guard let dateRegex = try? NSRegularExpression(pattern: datePattern, options: [.caseInsensitive]),
              let dateMatch = dateRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
              let dayRange = Range(dateMatch.range(at: 1), in: cleanText),
              let monthRange = Range(dateMatch.range(at: 2), in: cleanText),
              let timeRange = Range(dateMatch.range(at: 3), in: cleanText),
              let ampmRange = Range(dateMatch.range(at: 4), in: cleanText) else {
            return nil
        }

        let day = String(cleanText[dayRange])
        let monthWord = String(cleanText[monthRange]).lowercased()
        let time = String(cleanText[timeRange])
        let ampm = String(cleanText[ampmRange]).lowercased()

        let months = ["ene": "01", "feb": "02", "mar": "03", "abr": "04", "may": "05", "jun": "06", "jul": "07", "ago": "08", "sep": "09", "set": "09", "oct": "10", "nov": "11", "dic": "12"]
        guard let month = months[monthWord] else { return nil }

        let currentYear = Calendar.current.component(.year, from: Date())
        let dateStr = "\(day) \(month) \(currentYear) \(time)\(ampm)"

        let formatter = DateFormatter()

        formatter.timeZone = BankEmailTime.zone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MM yyyy hh:mma"
        guard var parsed = formatter.date(from: dateStr) else { return nil }

        if parsed > Date().addingTimeInterval(86400) {
            parsed = Calendar.current.date(byAdding: .year, value: -1, to: parsed) ?? parsed
        }

        return parsed
    }
}
