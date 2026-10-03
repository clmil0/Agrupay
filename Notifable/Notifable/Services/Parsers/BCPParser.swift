import Foundation

struct BCPParser: BankEmailParser {
    
    var bankName: String {
        return "BCP"
    }
    
    var senderEmails: [String] {
        return ["notificaciones@notificacionesbcp.com.pe"]
    }
    
    func parse(cleanText: String) -> Expense? {
        if let refund = parseRefund(cleanText) { return refund }
        if let transfer = parseTransfer(cleanText) { return transfer }

        // Asegurarnos que es un consumo de tarjeta de débito
        guard cleanText.contains("Consumo Tarjeta de D") || cleanText.contains("Realizaste un consumo") else {
            return nil
        }
        
        // Extraer Monto
        // Buscar: "Total del consumo S/ 42.00" o "$ 8.03" (consumo en dólares
        // con la tarjeta de crédito). En texto plano el valor viene entre
        // asteriscos: "Total del consumo *$ 8.03*".
        guard let money = Self.capture2("Total del consumo[\\s*]*(S/\\.?|US\\$|\\$)\\s*([0-9][0-9.,]*)", in: cleanText) else {
            return nil
        }
        let amount = Double(money.1.replacingOccurrences(of: ",", with: "")) ?? 0
        let currency = money.0.contains("$") ? "USD" : "PEN"
        
        // Extraer Empresa
        // Buscar: "Empresa PLIN-DANIELA ADRIANA DO Número de operación"
        var merchant = "Desconocido"
        let merchantPattern = "Empresa\\s*(.*?)\\s*N[uú]mero de operaci[oó]n"
        if let merchantRegex = try? NSRegularExpression(pattern: merchantPattern, options: [.dotMatchesLineSeparators]),
           let merchantMatch = merchantRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let merchantRange = Range(merchantMatch.range(at: 1), in: cleanText) {
            // Texto plano: "*STEAMGAMES.COM <http://STEAMGAMES.COM> 4259522985*".
            merchant = String(cleanText[merchantRange])
                .replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "*")))
        } else {
            // Patrón alternativo de empresa ("... con tu Tarjeta de Débito BCP en [EMPRESA]. Por tu...")
            let altMerchantPattern = "en\\s+([^.]+)\\.\\s*Por tu seguridad"
            if let altRegex = try? NSRegularExpression(pattern: altMerchantPattern, options: [.dotMatchesLineSeparators]),
               let altMatch = altRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
               let altRange = Range(altMatch.range(at: 1), in: cleanText) {
                merchant = String(cleanText[altRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // Extraer últimos dígitos de la tarjeta. Cubre débito y crédito: un
        // "Realizaste un consumo... con tu Tarjeta de Crédito BCP" no traía
        // los dígitos porque este regex sólo buscaba "Débito".
        var cardLastDigits: String? = nil
        let cardPattern = "Tarjeta de (?:D[ée]bito|Cr[ée]dito)\\s*\\*+([0-9]{4})"
        if let cardRegex = try? NSRegularExpression(pattern: cardPattern, options: [.dotMatchesLineSeparators]),
           let cardMatch = cardRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let cardRange = Range(cardMatch.range(at: 1), in: cleanText) {
            cardLastDigits = String(cleanText[cardRange])
        }
        
        // Extraer Fecha y Hora
        // Buscar: "Fecha y hora 03 de setiembre de 2026 - 01:14 PM"
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
        } else if let parsed = Self.operationDate(in: cleanText) {
            // "Fecha y hora *01 de octubre de 2026 - 08:14 PM*" (texto plano).
            expenseDate = parsed
        }
        
        // Si es un PLIN, rechazamos el parseo aquí para que YapeParser lo capture y lo cuente como Yape.
        let upperMerchant = merchant.uppercased()
        if upperMerchant.hasPrefix("PLIN-") || upperMerchant.hasPrefix("PLIN ") {
            return nil
        }
        
        return Expense(amount: amount, merchant: merchant, date: expenseDate, category: "Sin Clasificar", currency: currency, cardLastDigits: cardLastDigits)
    }

    /// "Constancia de recepción de Yapeo a celular BCP": dinero que **entra**,
    /// no un gasto. Es el único correo de BCP que representa un ingreso.
    func parseIncome(cleanText: String) -> Income? {
        guard cleanText.contains("Monto recibido") else {
            return nil
        }

        let amountPattern = "Monto recibido\\s*S/\\s*([0-9.,]+)"
        guard let amountRegex = try? NSRegularExpression(pattern: amountPattern, options: [.dotMatchesLineSeparators]),
              let amountMatch = amountRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
              let amountRange = Range(amountMatch.range(at: 1), in: cleanText) else {
            return nil
        }
        let amountStr = String(cleanText[amountRange]).replacingOccurrences(of: ",", with: "")
        let amount = Double(amountStr) ?? 0

        var sender = "Desconocido"
        let senderPattern = "Enviado por\\s*(.*?)\\s*¿No reconoces"
        if let senderRegex = try? NSRegularExpression(pattern: senderPattern, options: [.dotMatchesLineSeparators]),
           let senderMatch = senderRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let senderRange = Range(senderMatch.range(at: 1), in: cleanText) {
            sender = String(cleanText[senderRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var incomeDate = Date()
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
            dStr = dStr.replacingOccurrences(of: " ", with: "")

            let formatter = DateFormatter()

            formatter.timeZone = BankEmailTime.zone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "ddMMyyyy-hh:mma"
            if let parsed = formatter.date(from: dStr) {
                incomeDate = parsed
            }
        }

        return Income(amount: amount, currency: "PEN", source: "Yape", title: sender, date: incomeDate)
    }

    // MARK: - Devoluciones

    /// «Realizamos una devolución de una operación a tu Tarjeta de Débito
    /// BCP»: Total devuelto, Fecha y hora, Número de Tarjeta, Nombre del
    /// Comercio y Número de operación. En la parte de texto plano cada valor
    /// viene entre asteriscos (`*S/ 2.50*`, `*************3601*`); sin ellos
    /// en el HTML.
    ///
    /// Igual que la anulación de BBVA, no es un gasto: sale como aviso
    /// (`isReversal`) para que el usuario elija qué compra se devolvió
    /// (`ReversalMatcher`). El comercio se escribe como el del consumo —un
    /// «PLIN-» pasa a «YAPE - », como en `YapeParser.parseBCPPlin`— para que
    /// la compra de ese comercio salga sugerida.
    private func parseRefund(_ cleanText: String) -> Expense? {
        guard cleanText.range(of: "devoluci[oó]n", options: [.regularExpression, .caseInsensitive]) != nil,
              let money = Self.capture2("(?:Total devuelto|devuelto el monto de)[\\s*]*(S/\\.?|US\\$|\\$)\\s*([0-9][0-9.,]*)", in: cleanText),
              let amount = Double(money.1.replacingOccurrences(of: ",", with: "")) else { return nil }
        let currency = money.0.contains("$") ? "USD" : "PEN"

        var label = Self.capture("Nombre del Comercio[\\s*]*(.*?)[\\s*]*N[uú]mero de operaci", in: cleanText)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let upper = label.uppercased()
        if upper.hasPrefix("PLIN-") || upper.hasPrefix("PLIN ") {
            label = "YAPE - " + label.dropFirst(5).trimmingCharacters(in: .whitespaces)
        }
        let card = Self.capture("N[uú]mero de Tarjeta[\\s*]*([0-9]{4})", in: cleanText)

        let date = Self.operationDate(in: cleanText) ?? Date()

        let expense = Expense(amount: amount,
                              merchant: ReversalMatcher.merchantPrefix + (label.isEmpty ? "Devolución" : label),
                              date: date, category: "Sin Clasificar", currency: currency,
                              cardLastDigits: card)
        expense.isReversal = true
        return expense
    }

    // MARK: - Transferencias

    /// «Constancia de Transferencia a Otros Bancos»: «Realizaste una
    /// transferencia de S/ 424.05 desde tu Cuenta de ahorros», con Monto
    /// enviado, Comisión, Total cobrado, Enviado a (nombre y `**** 0144`),
    /// Banco destino y Desde (`Cuenta de ahorros **** 5092`). En texto plano
    /// cada valor viene entre asteriscos; en el HTML, sin ellos.
    ///
    /// Es un envío a una persona como un Yape o un Plin: el comercio es
    /// «BCP - <nombre>» para que el destinatario sea una cuenta
    /// (`AccountResolver.payee`). El correo no dice si esa cuenta es tuya —el
    /// nombre del titular no basta—: pasa a traslado cuando el usuario la
    /// marca como suya en «Tus cuentas» (`TransferDetector`).
    private func parseTransfer(_ cleanText: String) -> Expense? {
        guard cleanText.range(of: "Realizaste una transferencia", options: .caseInsensitive) != nil,
              // Total cobrado primero: incluye la comisión, cuando la hay.
              let money = ["Total cobrado", "Monto enviado"].lazy.compactMap({
                  Self.capture2($0 + "[\\s*]*(S/\\.?|US\\$|\\$)\\s*([0-9][0-9.,]*)", in: cleanText)
              }).first,
              let amount = Money.parse(money.1) else { return nil }
        let currency = money.0.contains("$") ? "USD" : "PEN"

        // El nombre acaba donde empiezan los dígitos enmascarados de su
        // cuenta o, si no vienen, el siguiente campo.
        let name = Self.capture("Enviado a[\\s*]*(.+?)[\\s*]*(?:[0-9]{4}\\s*)?(?:Banco destino|Moneda|Tipo de env)", in: cleanText)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let account = Self.capture("Desde[\\s*]+(?:Cuenta|Tarjeta)[^0-9*]{0,30}?[\\s*]*([0-9]{4})", in: cleanText)

        return Expense(amount: amount,
                       merchant: "BCP - " + (name.isEmpty ? "Transferencia" : name),
                       date: Self.operationDate(in: cleanText) ?? Date(),
                       category: "Sin Clasificar", currency: currency,
                       cardLastDigits: account)
    }

    /// «Fecha y hora 28 de septiembre de 2026 - 08:34 PM». La constancia de
    /// transferencia separa «P M» con un espacio duro, y en texto plano el
    /// valor viene entre asteriscos.
    private static func operationDate(in text: String) -> Date? {
        let pattern = "Fecha y hora[\\s*]*([0-9]{1,2})\\s+de\\s+([a-zA-Z]+)\\s+de\\s+([0-9]{4})\\s*-\\s*([0-9]{1,2}:[0-9]{2})[\\s\\u00A0]*([AP])[\\s\\u00A0]*M"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else { return nil }
        let parts = (1...5).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        let months = ["enero": "01", "febrero": "02", "marzo": "03", "abril": "04", "mayo": "05", "junio": "06", "julio": "07", "agosto": "08", "septiembre": "09", "setiembre": "09", "octubre": "10", "noviembre": "11", "diciembre": "12"]
        guard parts.count == 5, let month = months[parts[1].lowercased()] else { return nil }
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
