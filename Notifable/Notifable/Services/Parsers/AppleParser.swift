import Foundation

struct AppleParser: BankEmailParser {
    
    var bankName: String {
        return "Apple"
    }
    
    var senderEmails: [String] {
        return ["no_reply@email.apple.com"]
    }
    
    func parse(cleanText: String) -> Expense? {
        if !cleanText.contains("Factura") && !cleanText.contains("Recibo de Apple") {
            return nil
        }
        
        var amount: Double = 0
        var currency = "PEN"
        
        // Regex para buscar S/ 89.90
        let amountPattern = "(S/|PEN|USD|\\$)\\s*([0-9.,]+)"
        if let regex = try? NSRegularExpression(pattern: amountPattern, options: []),
           let match = regex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) {
            
            let curRange = Range(match.range(at: 1), in: cleanText)!
            let curStr = String(cleanText[curRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            currency = (curStr == "$" || curStr == "USD") ? "USD" : "PEN"
            
            let amtRange = Range(match.range(at: 2), in: cleanText)!
            amount = Money.parse(String(cleanText[amtRange])) ?? 0
        } else {
            return nil
        }
        
        var cardLastDigits: String? = nil
        let cardPattern = "(?:Visa|Mastercard|Amex).*?([0-9]{4})"
        if let regex = try? NSRegularExpression(pattern: cardPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) {
            let cardRange = Range(match.range(at: 1), in: cleanText)!
            cardLastDigits = String(cleanText[cardRange])
        }
        
        var expenseDate = Date()
        // Sólo la fecha de la factura, no la de la próxima renovación (que
        // también tiene forma "N de mes de AAAA" pero aparece después en el
        // correo — "Factura 2 de septiembre..." va antes que "Se renovará
        // el 2 de octubre...", así que el primer match es siempre el correcto).
        let datePattern = "([0-9]{1,2})\\s+de\\s+([a-zA-Z]+)\\s+de\\s+([0-9]{4})"
        if let regex = try? NSRegularExpression(pattern: datePattern, options: []),
           let match = regex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) {
            let dayRange = Range(match.range(at: 1), in: cleanText)!
            let monthRange = Range(match.range(at: 2), in: cleanText)!
            let yearRange = Range(match.range(at: 3), in: cleanText)!
            let day = String(cleanText[dayRange])
            let monthWord = String(cleanText[monthRange]).lowercased()
            let year = String(cleanText[yearRange])
            
            // Nombre de mes a número a mano, no vía DateFormatter+MMMM+locale:
            // ICU en es_PE reconoce "setiembre", y Apple manda "septiembre" en
            // sus facturas — dejar que DateFormatter decida cuál acepta es
            // justo el bug que ya se vio en BBVAParser (la fecha caía a "ahora"
            // en silencio). Este diccionario cubre las dos ortografías.
            let months = ["enero": "01", "febrero": "02", "marzo": "03", "abril": "04", "mayo": "05", "junio": "06", "julio": "07", "agosto": "08", "septiembre": "09", "setiembre": "09", "octubre": "10", "noviembre": "11", "diciembre": "12"]
            let month = months[monthWord] ?? monthWord
            
            let formatter = DateFormatter()
            
            formatter.timeZone = BankEmailTime.zone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "dd MM yyyy"
            if let parsed = formatter.date(from: "\(day) \(month) \(year)") {
                expenseDate = parsed
            }
        }
        
        var merchant = "Apple"
        
        // Intentar extraer el nombre de la app (generalmente aparece después del correo y antes de 'Se renovará' o del monto)
        let merchantPattern = "Cuenta\\s*de\\s*Apple:\\s*[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\s+(.*?)\\s+(?:Se renovar|S/|PEN|USD|\\$)"
        if let regex = try? NSRegularExpression(pattern: merchantPattern, options: []),
           let match = regex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) {
            let merchantRange = Range(match.range(at: 1), in: cleanText)!
            let rawMerchant = String(cleanText[merchantRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Limpiar múltiples espacios seguidos
            if let regexSpace = try? NSRegularExpression(pattern: "\\s{2,}", options: []) {
                merchant = regexSpace.stringByReplacingMatches(in: rawMerchant, options: [], range: NSRange(location: 0, length: rawMerchant.utf16.count), withTemplate: " - ")
            } else {
                merchant = rawMerchant
            }
        }
        
        return Expense(amount: amount, merchant: merchant, date: expenseDate, category: "Suscripciones", isSubscription: true, currency: currency, cardLastDigits: cardLastDigits)
    }
}
