import Foundation

struct YapeParser: BankEmailParser {
    
    var bankName: String {
        return "Yape"
    }
    
    var senderEmails: [String] {
        return ["notificaciones@yape.pe", "notificaciones@notificacionesbcp.com.pe"]
    }
    
    func parse(cleanText: String) -> Expense? {
        if let yapeExpense = parseStandardYape(cleanText: cleanText) {
            return yapeExpense
        }

        if let servicePayment = parseServicePayment(cleanText: cleanText) {
            return servicePayment
        }

        if let bcpPlinExpense = parseBCPPlin(cleanText: cleanText) {
            return bcpPlinExpense
        }

        return nil
    }

    /// "Tu yapeo de servicio ha sido confirmado" (recargas, pago de servicios):
    /// plantilla distinta a la transferencia estándar — "Monto total" en vez de
    /// "Monto de yapeo", "Empresa:"/"Servicio:" en vez de "Nombre del
    /// Beneficiario". Sus campos vienen separados por líneas de guiones en la
    /// parte de texto plano del correo (el HTML usa <hr>), así que el corte del
    /// nombre de la empresa tiene que tolerarlos.
    private func parseServicePayment(cleanText: String) -> Expense? {
        guard cleanText.contains("Monto total"), cleanText.contains("Detalle del servicio") else {
            return nil
        }

        let amountPattern = "Monto total\\s*S/\\s*([0-9.,]+)"
        guard let amountRegex = try? NSRegularExpression(pattern: amountPattern, options: [.dotMatchesLineSeparators]),
              let amountMatch = amountRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
              let amountRange = Range(amountMatch.range(at: 1), in: cleanText) else {
            return nil
        }
        let amountStr = String(cleanText[amountRange]).replacingOccurrences(of: ",", with: "")
        let amount = Double(amountStr) ?? 0

        var merchant = "YAPE - Servicio"
        let merchantPattern = "Empresa:\\s*(.*?)(?:\\s*-{2,})?\\s*Servicio:"
        if let merchantRegex = try? NSRegularExpression(pattern: merchantPattern, options: [.dotMatchesLineSeparators]),
           let merchantMatch = merchantRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let merchantRange = Range(merchantMatch.range(at: 1), in: cleanText) {
            let extracted = String(cleanText[merchantRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            merchant = "YAPE - \(extracted)"
        }

        var expenseDate = Date()
        let datePattern = "Fecha y hora:\\s*([0-9]{1,2})\\s+([a-zA-Z]+)\\.?,\\s*([0-9]{4})\\s*-\\s*([0-9]{2}:[0-9]{2})\\s*([ap]m)"
        if let dateRegex = try? NSRegularExpression(pattern: datePattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let dateMatch = dateRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let dayRange = Range(dateMatch.range(at: 1), in: cleanText),
           let monthRange = Range(dateMatch.range(at: 2), in: cleanText),
           let yearRange = Range(dateMatch.range(at: 3), in: cleanText),
           let timeRange = Range(dateMatch.range(at: 4), in: cleanText),
           let ampmRange = Range(dateMatch.range(at: 5), in: cleanText) {
            let day = String(cleanText[dayRange])
            let monthWord = String(cleanText[monthRange]).lowercased()
            let year = String(cleanText[yearRange])
            let time = String(cleanText[timeRange])
            let ampm = String(cleanText[ampmRange]).lowercased()

            let months = ["ene": "01", "feb": "02", "mar": "03", "abr": "04", "may": "05", "jun": "06", "jul": "07", "ago": "08", "set": "09", "sep": "09", "oct": "10", "nov": "11", "dic": "12"]
            if let month = months[monthWord] {
                let dateStr = "\(day) \(month) \(year) \(time)\(ampm)"
                let formatter = DateFormatter()
                formatter.timeZone = BankEmailTime.zone
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "dd MM yyyy hh:mma"
                if let parsed = formatter.date(from: dateStr) {
                    expenseDate = parsed
                }
            }
        }

        return Expense(amount: amount, merchant: merchant, date: expenseDate, category: "Sin Clasificar", currency: "PEN")
    }
    
    private func parseStandardYape(cleanText: String) -> Expense? {
        // Amount
        let amountPattern = "Monto de yapeo[^a-zA-Z0-9]*\\s*S/\\s*([0-9.,]+)"
        guard let amountRegex = try? NSRegularExpression(pattern: amountPattern, options: [.dotMatchesLineSeparators]),
              let amountMatch = amountRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
              let amountRange = Range(amountMatch.range(at: 1), in: cleanText) else {
            return nil
        }
        // "1,250.00": la coma es de miles. Cambiarla por punto daba "1.250.00",
        // que no es un número, y el gasto se guardaba en cero.
        let amount = Money.parse(String(cleanText[amountRange])) ?? 0
        
        // Merchant
        var merchant = "Desconocido"
        let merchantPattern = "Nombre del Beneficiario\\s*(.*?)\\s*N[°º] de operaci[oó]n"
        if let merchantRegex = try? NSRegularExpression(pattern: merchantPattern, options: [.dotMatchesLineSeparators]),
           let merchantMatch = merchantRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let merchantRange = Range(merchantMatch.range(at: 1), in: cleanText) {
            let extracted = String(cleanText[merchantRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            merchant = "YAPE - \(extracted)"
        }
        
        // Date
        var expenseDate = Date()
        let datePattern = "Fecha y Hora de la operaci[oó]n\\s*(.*?)\\s*Celular del Beneficiario"
        if let dateRegex = try? NSRegularExpression(pattern: datePattern, options: [.dotMatchesLineSeparators]),
           let dateMatch = dateRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let dateRange = Range(dateMatch.range(at: 1), in: cleanText) {
            let dateStr = String(cleanText[dateRange])
            
            var dStr = dateStr.lowercased()
            let months = ["enero": "01", "febrero": "02", "marzo": "03", "abril": "04", "mayo": "05", "junio": "06", "julio": "07", "agosto": "08", "septiembre": "09", "octubre": "10", "noviembre": "11", "diciembre": "12"]
            for (m, num) in months {
                dStr = dStr.replacingOccurrences(of: m, with: num)
            }
            dStr = dStr.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "")
            
            let formatter = DateFormatter()
            
            formatter.timeZone = BankEmailTime.zone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "ddMMyyyy-hh:mma"
            if let parsed = formatter.date(from: dStr) {
                expenseDate = parsed
            }
        }
        
        return Expense(amount: amount, merchant: merchant, date: expenseDate, category: "Sin Clasificar", currency: "PEN")
    }

    private func parseBCPPlin(cleanText: String) -> Expense? {
        guard cleanText.contains("Consumo Tarjeta de D") || cleanText.contains("Realizaste un consumo") else {
            return nil
        }
        
        var merchant = "Desconocido"
        let merchantPattern = "Empresa\\s*(.*?)\\s*N[uú]mero de operaci[oó]n"
        if let merchantRegex = try? NSRegularExpression(pattern: merchantPattern, options: [.dotMatchesLineSeparators]),
           let merchantMatch = merchantRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let merchantRange = Range(merchantMatch.range(at: 1), in: cleanText) {
            merchant = String(cleanText[merchantRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let altMerchantPattern = "en\\s+([^.]+)\\.\\s*Por tu seguridad"
            if let altRegex = try? NSRegularExpression(pattern: altMerchantPattern, options: [.dotMatchesLineSeparators]),
               let altMatch = altRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
               let altRange = Range(altMatch.range(at: 1), in: cleanText) {
                merchant = String(cleanText[altRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        let upperMerchant = merchant.uppercased()
        guard upperMerchant.hasPrefix("PLIN-") || upperMerchant.hasPrefix("PLIN ") else {
            return nil
        }
        
        let amountPattern = "Total del consumo\\s*S/\\s*([0-9.,]+)"
        guard let amountRegex = try? NSRegularExpression(pattern: amountPattern, options: [.dotMatchesLineSeparators]),
              let amountMatch = amountRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
              let amountRange = Range(amountMatch.range(at: 1), in: cleanText) else {
            return nil
        }
        let amountStr = String(cleanText[amountRange]).replacingOccurrences(of: ",", with: "")
        let amount = Double(amountStr) ?? 0
        
        var cardLastDigits: String? = nil
        let cardPattern = "Tarjeta de D[ée]bito\\s*\\*+([0-9]{4})"
        if let cardRegex = try? NSRegularExpression(pattern: cardPattern, options: [.dotMatchesLineSeparators]),
           let cardMatch = cardRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let cardRange = Range(cardMatch.range(at: 1), in: cleanText) {
            cardLastDigits = String(cleanText[cardRange])
        }
        
        var expenseDate = Date()
        let datePattern = "Fecha y hora\\s*([0-9]{2}\\s*de\\s*[a-zA-Z]+\\s*de\\s*[0-9]{4}\\s*-\\s*[0-9]{2}:[0-9]{2}\\s*[APM]{2})"
        if let dateRegex = try? NSRegularExpression(pattern: datePattern, options: [.dotMatchesLineSeparators]),
           let dateMatch = dateRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let dateRange = Range(dateMatch.range(at: 1), in: cleanText) {
            let dateStr = String(cleanText[dateRange])
            
            var dStr = dateStr.lowercased()
            let months = ["enero": "01", "febrero": "02", "marzo": "03", "abril": "04", "mayo": "05", "junio": "06", "julio": "07", "agosto": "08", "septiembre": "09", "setiembre": "09", "octubre": "10", "noviembre": "11", "diciembre": "12"]
            for (m, num) in months {
                dStr = dStr.replacingOccurrences(of: m, with: num)
            }
            dStr = dStr.replacingOccurrences(of: " de ", with: "")
            dStr = dStr.replacingOccurrences(of: " - ", with: "-")
            dStr = dStr.replacingOccurrences(of: " ", with: "") // e.g. 03092026-01:14pm
            
            let formatter = DateFormatter()
            
            formatter.timeZone = BankEmailTime.zone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "ddMMyyyy-hh:mma"
            if let parsed = formatter.date(from: dStr) {
                expenseDate = parsed
            }
        }
        
        let extracted = merchant.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        let finalMerchant = "YAPE - \(extracted)"
        
        return Expense(amount: amount, merchant: finalMerchant, date: expenseDate, category: "Sin Clasificar", currency: "PEN", cardLastDigits: cardLastDigits)
    }
}
