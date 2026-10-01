import Foundation

struct BBVAParser: BankEmailParser {
    
    var bankName: String {
        return "BBVA"
    }
    
    var senderEmails: [String] {
        return ["procesos@bbva.com.pe"]
    }
    
    func parse(cleanText: String) -> Expense? {
        if let expense = parseReversal(cleanText) { return expense }
        if let expense = parseATMWithdrawal(cleanText) { return expense }
        if let expense = parseCardlessWithdrawal(cleanText) { return expense }
        if let expense = parsePlinSent(cleanText) { return expense }
        if let expense = parseBBVATransfer(cleanText) { return expense }
        if let expense = parseBBVAAutomaticPayment(cleanText) { return expense }
        if let expense = parseBBVAServicePayment(cleanText) { return expense }
        if let expense = parseBBVAStandard(cleanText) { return expense }
        return nil
    }
    
    private func parsePlinSent(_ cleanText: String) -> Expense? {
        let plinPattern = "Plineaste\\s+(S/|\\$|PEN|USD)\\s*([0-9.,]+)\\s+a\\s+(.*?)\\s+(?:Detalles|Celular|Destino)"
        guard let plinRegex = try? NSRegularExpression(pattern: plinPattern, options: []),
              let match = plinRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) else {
            return nil
        }
        
        var currency = "PEN"
        var amount: Double = 0
        var merchant = "Desconocido"
        var expenseDate = Date()
        
        if let curRange = Range(match.range(at: 1), in: cleanText) {
            let curStr = String(cleanText[curRange])
            currency = (curStr == "$" || curStr == "USD") ? "USD" : "PEN"
        }
        if let amtRange = Range(match.range(at: 2), in: cleanText) {
            amount = Money.parse(String(cleanText[amtRange])) ?? 0
        }
        if let merRange = Range(match.range(at: 3), in: cleanText) {
            let extracted = String(cleanText[merRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            merchant = "PLIN - \(extracted)"
        }
        
        let plinDatePattern = "Fecha y hora:\\s*([0-9]{1,2}\\s+de\\s+[a-zA-Z]+,\\s*[0-9]{4}\\s+[0-9]{2}:[0-9]{2})"
        if let dateRegex = try? NSRegularExpression(pattern: plinDatePattern, options: []),
           let dateMatch = dateRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) {
            if let dateRange = Range(dateMatch.range(at: 1), in: cleanText) {
                // Convertir a números a mano en vez de dejarle el nombre del mes a
                // DateFormatter (ver nota en parseBBVATransfer): evita depender de
                // que ICU reconozca "septiembre" con esa ortografía exacta.
                var dStr = String(cleanText[dateRange]).lowercased()
                let months = ["enero": "01", "febrero": "02", "marzo": "03", "abril": "04", "mayo": "05", "junio": "06", "julio": "07", "agosto": "08", "septiembre": "09", "setiembre": "09", "octubre": "10", "noviembre": "11", "diciembre": "12"]
                for (name, num) in months { dStr = dStr.replacingOccurrences(of: name, with: num) }
                dStr = dStr.replacingOccurrences(of: " de ", with: " ")
                dStr = dStr.replacingOccurrences(of: ",", with: "")
                let formatter = DateFormatter()
                formatter.timeZone = BankEmailTime.zone
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "dd MM yyyy HH:mm"
                if let parsed = formatter.date(from: dStr) {
                    expenseDate = parsed
                }
            }
        }
        
        return Expense(amount: amount, merchant: merchant, date: expenseDate, category: "Sin Clasificar", currency: currency)
    }
    
    private func parseBBVATransfer(_ cleanText: String) -> Expense? {
        // «Transferencia interbancaria» (a otro banco, ej. BCP) usa la misma
        // constancia: «Importe cargado», «Fecha y hora de la operación» y
        // «Nombre del beneficiario», pero sin «Concepto» detrás del nombre.
        guard cleanText.contains("Transferir a terceros BBVA") || cleanText.contains("TRANSF. A CTAS. TERCEROS")
                || cleanText.contains("Transferencia interbancaria") else {
            return nil
        }
        
        var amount: Double = 0
        let amountPattern = "Importe cargado\\s*S/\\s*([0-9.,]+)"
        if let amountRegex = try? NSRegularExpression(pattern: amountPattern, options: []),
           let amtMatch = amountRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let range = Range(amtMatch.range(at: 1), in: cleanText) {
            let amountStr = String(cleanText[range]).replacingOccurrences(of: ",", with: "")
            amount = Double(amountStr) ?? 0
        } else {
            let altAmountPattern = "Importe transferido\\s*S/\\s*([0-9.,]+)"
            if let altRegex = try? NSRegularExpression(pattern: altAmountPattern, options: []),
               let amtMatch = altRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
               let range = Range(amtMatch.range(at: 1), in: cleanText) {
                let amountStr = String(cleanText[range]).replacingOccurrences(of: ",", with: "")
                amount = Double(amountStr) ?? 0
            } else {
                return nil
            }
        }
        
        var merchant = "BBVA - Transferencia a terceros"
        let merchantPattern = "Nombre del beneficiario\\s*(.*?)\\s*(?:Concepto|Esta cuenta|Recuerda)"
        if let merchantRegex = try? NSRegularExpression(pattern: merchantPattern, options: []),
           let match = merchantRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let range = Range(match.range(at: 1), in: cleanText) {
            let extracted = String(cleanText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            merchant = "BBVA - \(extracted)"
        }
        
        var expenseDate = Date()
        let datePattern = "Fecha y hora de la operaci[oó]n.*?([0-9]{1,2})\\s*(?:de\\s*)?([a-zA-Z]+)(?:,\\s*|\\s+de\\s+|\\s+)([0-9]{4})\\s*(?:-|a\\s+las)?\\s*([0-9]{2}:[0-9]{2}(?::[0-9]{2})?)"
        if let dateRegex = try? NSRegularExpression(pattern: datePattern, options: []),
           let dateMatch = dateRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) {
            
            let dayRange = Range(dateMatch.range(at: 1), in: cleanText)!
            let monthRange = Range(dateMatch.range(at: 2), in: cleanText)!
            let yearRange = Range(dateMatch.range(at: 3), in: cleanText)!
            let timeRange = Range(dateMatch.range(at: 4), in: cleanText)!
            
            let day = String(cleanText[dayRange])
            let monthWord = String(cleanText[monthRange]).lowercased()
            let year = String(cleanText[yearRange])
            let time = String(cleanText[timeRange])
            
            // Antes esto convertía "setiembre" a "septiembre" y se lo pasaba a
            // DateFormatter con locale es_PE esperando que MMMM lo reconociera —
            // pero el nombre oficial del mes en es_PE es justo "setiembre", así
            // que la conversión rompía el parseo de setiembre para atrás:
            // `formatter.date(from:)` devolvía nil y la fecha quedaba en "ahora".
            // Con un diccionario propio a números no depende de qué ortografía
            // tenga ICU para el mes (mismo enfoque que BCPParser/YapeParser).
            let months = ["enero": "01", "febrero": "02", "marzo": "03", "abril": "04", "mayo": "05", "junio": "06", "julio": "07", "agosto": "08", "septiembre": "09", "setiembre": "09", "octubre": "10", "noviembre": "11", "diciembre": "12"]
            let month = months[monthWord] ?? monthWord
            
            let formatter = DateFormatter()
            
            formatter.timeZone = BankEmailTime.zone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            
            // Si la hora tiene segundos
            if time.count > 5 {
                formatter.dateFormat = "dd MM yyyy HH:mm:ss"
            } else {
                formatter.dateFormat = "dd MM yyyy HH:mm"
            }
            
            let dateStr = "\(day) \(month) \(year) \(time)"
            if let parsed = formatter.date(from: dateStr) {
                expenseDate = parsed
            }
        }
        
        var cardLastDigits: String? = nil
        let cardPattern = "Cuenta de origen\\s*(?:•\\s*)?([0-9]{4})"
        if let cardRegex = try? NSRegularExpression(pattern: cardPattern, options: []),
           let cMatch = cardRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)),
           let range = Range(cMatch.range(at: 1), in: cleanText) {
            cardLastDigits = String(cleanText[range])
        }
        
        return Expense(amount: amount, merchant: merchant, date: expenseDate, category: "Sin Clasificar", currency: "PEN", cardLastDigits: cardLastDigits)
    }
    
    private func parseBBVAStandard(_ cleanText: String) -> Expense? {
        let merchantPattern = "Comercio:\\s*(.*?)(?=\\s+Monto:)"
        guard let merchantRegex = try? NSRegularExpression(pattern: merchantPattern, options: []),
              let match = merchantRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) else {
            return nil
        }
        
        var merchant = "Desconocido"
        if let range = Range(match.range(at: 1), in: cleanText) {
            merchant = String(cleanText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        var amount: Double = 0
        let amountPattern = "Monto:\\s*([0-9.,]+)"
        if let amountRegex = try? NSRegularExpression(pattern: amountPattern, options: []),
           let amtMatch = amountRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) {
            if let range = Range(amtMatch.range(at: 1), in: cleanText) {
                amount = Money.parse(String(cleanText[range])) ?? 0
            }
        }
        
        var currency = "PEN"
        let currencyPattern = "Moneda:\\s*([A-Za-z]+)"
        if let currencyRegex = try? NSRegularExpression(pattern: currencyPattern, options: []),
           let curMatch = currencyRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) {
            if let range = Range(curMatch.range(at: 1), in: cleanText) {
                currency = String(cleanText[range]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            }
        }
        
        var expenseDate = Date()
        let datePattern = "Fecha:\\s*([0-9]{2}/[0-9]{2}/[0-9]{4})"
        let timePattern = "Hora:\\s*([0-9]{2}:[0-9]{2}:[0-9]{2})"
        var dateString = ""
        var timeString = ""
        
        if let dateRegex = try? NSRegularExpression(pattern: datePattern, options: []),
           let dMatch = dateRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) {
            if let range = Range(dMatch.range(at: 1), in: cleanText) {
                dateString = String(cleanText[range])
            }
        }
        if let timeRegex = try? NSRegularExpression(pattern: timePattern, options: []),
           let tMatch = timeRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) {
            if let range = Range(tMatch.range(at: 1), in: cleanText) {
                timeString = String(cleanText[range])
            }
        }
        
        if !dateString.isEmpty && !timeString.isEmpty {
            let formatter = DateFormatter()
            formatter.timeZone = BankEmailTime.zone
            formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
            if let parsedDate = formatter.date(from: "\(dateString) \(timeString)") {
                expenseDate = parsedDate
            }
        }
        
        var cardLastDigits: String? = nil
        let cardPattern = "tarjeta terminada en\\s*\\*?([0-9]{4})"
        if let cardRegex = try? NSRegularExpression(pattern: cardPattern, options: []),
           let cMatch = cardRegex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) {
            if let range = Range(cMatch.range(at: 1), in: cleanText) {
                cardLastDigits = String(cleanText[range])
            }
        }
        
        return Expense(amount: amount, merchant: merchant, date: expenseDate, category: "Sin Clasificar", currency: currency, cardLastDigits: cardLastDigits)
    }
    
    private func parseBBVAAutomaticPayment(_ cleanText: String) -> Expense? {
        if !cleanText.contains("Pago autom") {
            return nil
        }
        
        var amount: Double = 0
        var currency = "PEN"
        let amountPattern = "Importe cargado\\s+(S/\\.|\\$|PEN|USD)\\s*([0-9.,]+)"
        if let regex = try? NSRegularExpression(pattern: amountPattern, options: []),
           let match = regex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) {
            let curRange = Range(match.range(at: 1), in: cleanText)!
            let curStr = String(cleanText[curRange])
            currency = (curStr == "$" || curStr == "USD") ? "USD" : "PEN"
            
            let amtRange = Range(match.range(at: 2), in: cleanText)!
            amount = Money.parse(String(cleanText[amtRange])) ?? 0
        } else {
            return nil
        }
        
        var merchant = "Pago automático"
        let merchantPattern = "Nombre de servicio\\s+(.*?)(?=\\s+(?:Dato|Descripci|Fecha))"
        if let regex = try? NSRegularExpression(pattern: merchantPattern, options: []),
           let match = regex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) {
            let merRange = Range(match.range(at: 1), in: cleanText)!
            merchant = String(cleanText[merRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        var expenseDate = Date()
        let datePattern = "Fecha y hora de la operaci.*?n\\s*([0-9]{1,2}\\s+[a-zA-Z]+\\s+[0-9]{4}\\s+[0-9]{2}:[0-9]{2})"
        if let regex = try? NSRegularExpression(pattern: datePattern, options: []),
           let match = regex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) {
            let dateRange = Range(match.range(at: 1), in: cleanText)!
            // Limpiar múltiples espacios que puedan haberse generado
            var dateStr = String(cleanText[dateRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let regexSpace = try? NSRegularExpression(pattern: "\\s+", options: []) {
                dateStr = regexSpace.stringByReplacingMatches(in: dateStr, options: [], range: NSRange(location: 0, length: dateStr.utf16.count), withTemplate: " ")
            }
            
            // Mismo motivo que en parseBBVATransfer: nombre de mes a número a
            // mano, sin depender del MMMM+locale de DateFormatter.
            dateStr = dateStr.lowercased()
            let months = ["enero": "01", "febrero": "02", "marzo": "03", "abril": "04", "mayo": "05", "junio": "06", "julio": "07", "agosto": "08", "septiembre": "09", "setiembre": "09", "octubre": "10", "noviembre": "11", "diciembre": "12"]
            for (name, num) in months { dateStr = dateStr.replacingOccurrences(of: name, with: num) }
            
            let formatter = DateFormatter()
            
            formatter.timeZone = BankEmailTime.zone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "dd MM yyyy HH:mm"
            if let parsedDate = formatter.date(from: dateStr) {
                expenseDate = parsedDate
            }
        }
        
        var cardLastDigits: String? = nil
        let cardPattern = "Cargo en tarjeta\\s*(?:•\\s*)?([0-9]{4})"
        if let regex = try? NSRegularExpression(pattern: cardPattern, options: []),
           let match = regex.firstMatch(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)) {
            let cardRange = Range(match.range(at: 1), in: cleanText)!
            cardLastDigits = String(cleanText[cardRange])
        }
        
        // As it's an automatic payment, maybe mark it as subscription by default?
        return Expense(amount: amount, merchant: merchant, date: expenseDate, category: "Sin Clasificar", isSubscription: true, currency: currency, cardLastDigits: cardLastDigits)
    }

    /// Constancia «Pagar servicio» (pago manual desde la app: recargas, luz,
    /// agua…). Mismo formato que el pago automático, pero sin "Pago autom", con
    /// "S/ " sin punto, fecha "14 setiembre, 2026 08:59" y cargo en cuenta.
    private func parseBBVAServicePayment(_ cleanText: String) -> Expense? {
        guard cleanText.contains("Pagar servicio") || cleanText.contains("Pago de servicio") else {
            return nil
        }
        let fullRange = NSRange(location: 0, length: cleanText.utf16.count)

        let amountPattern = "Importe cargado\\s*(S/\\.?|US\\$|\\$|PEN|USD)\\s*([0-9.,]+)"
        guard let amountRegex = try? NSRegularExpression(pattern: amountPattern, options: []),
              let amtMatch = amountRegex.firstMatch(in: cleanText, options: [], range: fullRange),
              let curRange = Range(amtMatch.range(at: 1), in: cleanText),
              let amtRange = Range(amtMatch.range(at: 2), in: cleanText),
              let amount = Double(String(cleanText[amtRange]).replacingOccurrences(of: ",", with: "")) else {
            return nil
        }
        let curStr = String(cleanText[curRange])
        let currency = curStr.contains("$") || curStr == "USD" ? "USD" : "PEN"

        var merchant = "BBVA - Pago de servicio"
        let merchantPattern = "Nombre de servicio\\s+(.*?)(?=\\s+(?:Descripci|Dato|C[OoÓó][Dd][IiÍí][Gg][Oo]|Fecha|Recuerda))"
        if let regex = try? NSRegularExpression(pattern: merchantPattern, options: []),
           let match = regex.firstMatch(in: cleanText, options: [], range: fullRange),
           let range = Range(match.range(at: 1), in: cleanText) {
            let extracted = String(cleanText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !extracted.isEmpty { merchant = extracted }
        }

        var expenseDate = Date()
        let datePattern = "Fecha y hora de la operaci[oó]n\\s*([0-9]{1,2})\\s+(?:de\\s+)?([a-zA-Z]+),?\\s+(?:de\\s+)?([0-9]{4})\\s*(?:-|a\\s+las)?\\s*([0-9]{2}:[0-9]{2})"
        if let regex = try? NSRegularExpression(pattern: datePattern, options: []),
           let match = regex.firstMatch(in: cleanText, options: [], range: fullRange),
           let dayRange = Range(match.range(at: 1), in: cleanText),
           let monthRange = Range(match.range(at: 2), in: cleanText),
           let yearRange = Range(match.range(at: 3), in: cleanText),
           let timeRange = Range(match.range(at: 4), in: cleanText) {
            let months = ["enero": "01", "febrero": "02", "marzo": "03", "abril": "04", "mayo": "05", "junio": "06", "julio": "07", "agosto": "08", "septiembre": "09", "setiembre": "09", "octubre": "10", "noviembre": "11", "diciembre": "12"]
            if let month = months[String(cleanText[monthRange]).lowercased()] {
                let formatter = DateFormatter()
                formatter.timeZone = BankEmailTime.zone
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "dd MM yyyy HH:mm"
                if let parsed = formatter.date(from: "\(cleanText[dayRange]) \(month) \(cleanText[yearRange]) \(cleanText[timeRange])") {
                    expenseDate = parsed
                }
            }
        }

        var cardLastDigits: String? = nil
        let cardPattern = "Cargo en (?:cuenta|tarjeta)\\s*(?:•\\s*)?([0-9]{4})"
        if let regex = try? NSRegularExpression(pattern: cardPattern, options: []),
           let match = regex.firstMatch(in: cleanText, options: [], range: fullRange),
           let range = Range(match.range(at: 1), in: cleanText) {
            cardLastDigits = String(cleanText[range])
        }

        return Expense(amount: amount, merchant: merchant, date: expenseDate, category: "Sin Clasificar", currency: currency, cardLastDigits: cardLastDigits)
    }

    // MARK: - Retiros de efectivo

    /// Un retiro no es un gasto: el dinero pasa de BBVA a tu efectivo, y lo
    /// que gastes en efectivo es lo que cuenta. El comercio lleva el prefijo
    /// `AccountResolver.withdrawalPrefix` y `TransferDetector` lo marca siempre
    /// como traslado BBVA → Efectivo.

    /// «Constancia de Retiro en ATM» (formato antiguo): «Retiro de efectivo»,
    /// «Monto de retiro S/ 70.00», «Número de tarjeta · 8156». Trae también
    /// «Número de cuenta · 2368», pero la que cuenta es la tarjeta: es el
    /// número con el que llegan sus otros movimientos.
    private func parseATMWithdrawal(_ cleanText: String) -> Expense? {
        guard cleanText.contains("Retiro de efectivo"),
              let (currency, amount) = Self.money(after: "Monto de retiro", in: cleanText) else { return nil }
        let date = Self.operationDate(in: cleanText) ?? Date()
        let card = Self.capture("N[uú]mero de tarjeta\\s*[·•*]?\\s*([0-9]{4})", in: cleanText)
        return Expense(amount: amount, merchant: AccountResolver.withdrawalPrefix + "Cajero", date: date,
                       category: "Sin Clasificar", currency: currency, cardLastDigits: card)
    }

    /// «Constancia Retiro sin tarjeta»: llega al **generar** la clave («Estado:
    /// Por cobrar»), no al cobrarla. Se registra con esa fecha; si caduca sin
    /// cobrarse, se borra a mano. «Cuenta de Origen: Cuenta Digital *2368».
    private func parseCardlessWithdrawal(_ cleanText: String) -> Expense? {
        guard let (currency, amount) = Self.money(after: "retiro sin tarjeta de", in: cleanText) else { return nil }
        let date = Self.operationDate(in: cleanText) ?? Date()
        let account = Self.capture("Cuenta de Origen:?\\s*[^0-9]{0,30}?\\*?\\s*([0-9]{4})", in: cleanText)
        return Expense(amount: amount, merchant: AccountResolver.withdrawalPrefix + "Sin tarjeta", date: date,
                       category: "Sin Clasificar", currency: currency, cardLastDigits: account)
    }

    /// "S/ 200", "S/  70.00", "US$ 50.00" justo después de `label`.
    private static func money(after label: String, in text: String) -> (currency: String, amount: Double)? {
        let pattern = NSRegularExpression.escapedPattern(for: label) + "\\s*(S/\\.?|US\\$|\\$)\\s*([0-9][0-9.,]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              let curRange = Range(match.range(at: 1), in: text),
              let amtRange = Range(match.range(at: 2), in: text),
              let amount = Double(String(text[amtRange]).replacingOccurrences(of: ",", with: "")) else { return nil }
        return (text[curRange].contains("$") ? "USD" : "PEN", amount)
    }

    /// «Fecha y hora de la operación(:) 16 de setiembre de 2026 21:14» o
    /// «25 de julio, 2026 07:57:29». Los segundos, si vienen, se ignoran.
    private static func operationDate(in text: String) -> Date? {
        let pattern = "Fecha y hora de la operaci[oó]n:?\\s*([0-9]{1,2})\\s+de\\s+([a-zA-Z]+),?\\s+(?:de\\s+)?([0-9]{4})\\s+([0-9]{2}:[0-9]{2})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              let day = Range(match.range(at: 1), in: text), let monthName = Range(match.range(at: 2), in: text),
              let year = Range(match.range(at: 3), in: text), let time = Range(match.range(at: 4), in: text) else { return nil }
        let months = ["enero": "01", "febrero": "02", "marzo": "03", "abril": "04", "mayo": "05", "junio": "06", "julio": "07", "agosto": "08", "septiembre": "09", "setiembre": "09", "octubre": "10", "noviembre": "11", "diciembre": "12"]
        guard let month = months[text[monthName].lowercased()] else { return nil }
        let formatter = DateFormatter()
        formatter.timeZone = BankEmailTime.zone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MM yyyy HH:mm"
        return formatter.date(from: "\(text[day]) \(month) \(text[year]) \(text[time])")
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: - Anulaciones

    /// «La compra con tu tarjeta BBVA ha sido anulada»: Comercio REVERSO
    /// TOTAL, Monto, Moneda, Fecha, Hora y «Últimos dígitos de tarjeta
    /// *8156». Sin dos puntos tras cada rótulo, al revés que el consumo.
    ///
    /// No es un gasto: sale como aviso (`isReversal`) para que el usuario
    /// elija qué compra se anuló (`ReversalMatcher`).
    private func parseReversal(_ cleanText: String) -> Expense? {
        guard cleanText.contains("ha sido anulada"),
              let amountText = Self.capture("Monto:?\\s*(?:S/\\.?\\s*)?([0-9][0-9.,]*)", in: cleanText),
              let amount = Double(amountText.replacingOccurrences(of: ",", with: "")) else { return nil }

        let currencyCode = Self.capture("Moneda:?\\s*([A-Z]{3})", in: cleanText)
        let currency = currencyCode == "USD" ? "USD" : "PEN"
        let label = Self.capture("Comercio:?\\s*(.*?)\\s+Monto", in: cleanText)?
            .trimmingCharacters(in: .whitespaces)
        let card = Self.capture("tarjeta:?\\s*\\*?\\s*([0-9]{4})", in: cleanText)

        var date = Date()
        if let day = Self.capture("Fecha:?\\s*([0-9]{2}/[0-9]{2}/[0-9]{4})", in: cleanText) {
            let time = Self.capture("Hora:?\\s*([0-9]{2}:[0-9]{2}(?::[0-9]{2})?)", in: cleanText) ?? "00:00"
            let formatter = DateFormatter()
            formatter.timeZone = BankEmailTime.zone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = time.count > 5 ? "dd/MM/yyyy HH:mm:ss" : "dd/MM/yyyy HH:mm"
            date = formatter.date(from: day + " " + time) ?? date
        }

        let expense = Expense(amount: amount,
                              merchant: ReversalMatcher.merchantPrefix + (label?.isEmpty == false ? label! : "Compra"),
                              date: date, category: "Sin Clasificar", currency: currency,
                              cardLastDigits: card)
        expense.isReversal = true
        return expense
    }
}
