import Foundation

/// Lo que se entendió de una frase dictada: «Gasté 24 soles en el almuerzo».
///
/// `amount` y `title` pueden faltar: el dictado pregunta por lo que falte
/// («¿De cuánto?», «¿En qué?») en vez de inventarlo.
struct VoiceMovement: Equatable {
    enum Kind: Equatable { case gasto, ingreso }

    var kind: Kind = .gasto
    var amount: Double?
    var currency: String = "PEN"
    /// Lo que se compró o de dónde vino el dinero, ya capitalizado.
    var title: String?
    /// Sólo gastos. `Accounting.unclassified` si nada lo delata.
    var category: String = Accounting.unclassified
    /// «Yape», «Plin», «Efectivo»… si se dijo.
    var source: String?
    var date: Date = Date()

    var isComplete: Bool { amount != nil && title != nil }
}

/// Convierte lo dictado en movimientos, con reglas y sin red.
///
/// Es el respaldo de `VoiceMovementAI` (el modelo del iPhone) y el camino
/// único en los equipos sin Apple Intelligence. No pretende entender
/// cualquier cosa: cubre la forma en que la gente dicta un gasto —monto,
/// «en», qué— y deja el resto como pregunta.
enum VoiceMovementParser {

    /// Una frase puede traer varios movimientos: «24 en el almuerzo y 8 en el
    /// taxi». Se parte en cada «y» que abre un monto nuevo.
    ///
    /// - Parameters:
    ///   - categoryFor: categoría para un título ya elegido (reglas del
    ///     usuario y catálogo).
    ///   - keywordCategory: categoría de una palabra suelta de la frase, sólo
    ///     si es exactamente un comercio o rubro conocido. Es lo que permite
    ///     encontrar «cine» en medio de una frase que da vueltas.
    static func parse(_ text: String,
                      now: Date = Date(),
                      categoryFor: (String, String) -> String? = defaultCategory,
                      keywordCategory: (String) -> String? = defaultKeywordCategory) -> [VoiceMovement] {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return [] }

        return split(tokens).compactMap { chunk in
            guard var movement = movement(from: chunk, now: now, categoryFor: categoryFor,
                                          keywordCategory: keywordCategory) else { return nil }
            movement.title = movement.title.map { restoreAccents($0, from: text) }
            return movement
        }
    }

    /// Sólo el monto: para contestar «¿De cuánto?».
    static func amount(in text: String) -> Double? {
        findAmount(in: tokenize(text))?.value
    }

    /// Sólo el qué: para contestar «¿En qué?».
    static func title(in text: String) -> String? {
        var tokens = tokenize(text)
        if let found = findAmount(in: tokens) { tokens.removeSubrange(found.range) }
        return title(from: tokens).map { restoreAccents($0, from: text) }
    }

    /// Los tokens van sin tildes para comparar; el título se muestra con las
    /// que se dictaron: «Café», no «Cafe».
    private static func restoreAccents(_ title: String, from text: String) -> String {
        let fold: (String) -> String = {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_PE"))
        }
        var originals: [String: String] = [:]
        for word in text.split(whereSeparator: { !$0.isLetter }) {
            let original = String(word).lowercased()
            originals[fold(original)] = originals[fold(original)] ?? original
        }
        return title.split(separator: " ")
            .map { originals[fold(String($0))] ?? String($0).lowercased() }
            .joined(separator: " ")
            .capitalizedFirst
    }

    // MARK: - Un movimiento

    private static func movement(from tokens: [String],
                                 now: Date,
                                 categoryFor: (String, String) -> String?,
                                 keywordCategory: (String) -> String?) -> VoiceMovement? {
        var result = VoiceMovement()
        let joined = " " + tokens.joined(separator: " ") + " "

        if incomeCues.contains(where: { joined.contains(" " + $0 + " ") }) {
            result.kind = .ingreso
        }
        if tokens.contains(where: { dollarWords.contains($0) }) {
            result.currency = "USD"
        }
        result.source = tokens.lazy.compactMap { sources[$0] }.first
        result.date = date(in: tokens, now: now)

        // Todos los montos, no sólo el primero: quien se corrige («iba a
        // gastar 50, pero al final fueron 30») quiere decir el último.
        var rest = tokens
        var found: [(value: Double, range: Range<Int>)] = []
        var scan = tokens
        var offset = 0
        while let next = findAmount(in: scan) {
            found.append((next.value, (next.range.lowerBound + offset)..<(next.range.upperBound + offset)))
            offset += next.range.upperBound
            scan = Array(scan[next.range.upperBound...])
        }
        if let chosen = found.count > 1 && tokens.contains(where: { correctionCues.contains($0) })
            ? found.last : found.first {
            result.amount = chosen.value
        }
        for amount in found.reversed() { rest.removeSubrange(amount.range) }

        // La palabra que delata el gasto, esté donde esté en la frase.
        if result.kind == .gasto, let hit = keywordHit(in: rest, lookup: keywordCategory) {
            result.title = hit.title
            result.category = hit.category
            return result
        }
        result.title = title(from: rest)

        guard result.amount != nil || result.title != nil else { return nil }

        if result.kind == .gasto {
            // Sin verbos ni rellenos: «gastado» contiene «gas» y el catálogo
            // lo tomaba por Servicios.
            let whole = rest.filter { !fillerWords.contains($0) }.joined(separator: " ")
            result.category = categoryFor(result.title ?? "", whole) ?? Accounting.unclassified
        }
        return result
    }

    // MARK: - Tokens

    static func tokenize(_ text: String) -> [String] {
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_PE"))
            .lowercased()
            .replacingOccurrences(of: "s/.", with: " soles ")
            .replacingOccurrences(of: "s/", with: " soles ")
            .replacingOccurrences(of: "$", with: " dolares ")

        // Se conservan dígitos con su separador («24.50», «1,200»); el resto de
        // la puntuación se va.
        var cleaned = ""
        let chars = Array(folded)
        for (i, c) in chars.enumerated() {
            if c.isLetter || c.isNumber || c == " " {
                cleaned.append(c)
            } else if (c == "." || c == ","), i > 0, i < chars.count - 1,
                      chars[i - 1].isNumber, chars[i + 1].isNumber {
                cleaned.append(c)
            } else {
                cleaned.append(" ")
            }
        }

        // «24soles» → «24 soles».
        var spaced = ""
        var previous: Character?
        for c in cleaned {
            if let p = previous, (p.isNumber && c.isLetter) || (p.isLetter && c.isNumber) {
                spaced.append(" ")
            }
            spaced.append(c)
            previous = c
        }
        return spaced.split(separator: " ").map(String.init)
    }

    /// Parte en cada «y»/«e» seguida de un monto, siempre que lo anterior ya
    /// tenga el suyo: «me pagaron y ahora 8 en taxi» no se parte.
    private static func split(_ tokens: [String]) -> [[String]] {
        var chunks: [[String]] = []
        var current: [String] = []
        for (i, token) in tokens.enumerated() {
            let startsAmount = i + 1 < tokens.count && isAmountStart(tokens[i + 1])
            // «treinta y cinco» es un solo número, no dos movimientos.
            let insideNumber = i > 0 && i + 1 < tokens.count
                && (numberWords[tokens[i - 1]] ?? 0) >= 20
                && (numberWords[tokens[i + 1]] ?? 10) < 10
            if (token == "y" || token == "e" || token == "tambien"), startsAmount, !insideNumber,
               findAmount(in: current) != nil {
                chunks.append(current)
                current = []
                continue
            }
            current.append(token)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Monto

    private static func isAmountStart(_ token: String) -> Bool {
        parseDigits(token) != nil || numberWords[token] != nil || token == "mil"
    }

    /// Todos los montos que se dijeron, en orden. Sirve para no creerle al
    /// modelo un monto que nadie pronunció.
    static func allAmounts(in text: String) -> [Double] {
        var tokens = tokenize(text)
        var result: [Double] = []
        while let found = findAmount(in: tokens) {
            result.append(found.value)
            tokens.removeSubrange(found.range)
        }
        return result
    }

    /// El primer monto de la frase y los tokens que ocupa (incluida la moneda
    /// y los céntimos: «24 soles con 50»).
    static func findAmount(in tokens: [String]) -> (value: Double, range: Range<Int>)? {
        var i = 0
        while i < tokens.count {
            if let value = parseDigits(tokens[i]) {
                return extend(value: value, from: i, end: i + 1, tokens: tokens)
            }
            if let (value, end) = parseWords(tokens, from: i) {
                return extend(value: value, from: i, end: end, tokens: tokens)
            }
            i += 1
        }
        return nil
    }

    /// Suma la moneda y los céntimos que vengan detrás del número.
    private static func extend(value: Double, from start: Int, end: Int,
                               tokens: [String]) -> (value: Double, range: Range<Int>) {
        var total = value
        var end = end

        if end < tokens.count, currencyWords.contains(tokens[end]) { end += 1 }

        // «con 50», «y 50 céntimos», «y medio».
        if end + 1 < tokens.count, tokens[end] == "con" || tokens[end] == "y" {
            if tokens[end + 1] == "medio" {
                total += 0.5
                end += 2
            } else if let cents = parseDigits(tokens[end + 1]) ?? parseWords(tokens, from: end + 1).map({ $0.0 }),
                      cents < 100, tokens[end] == "con" || (end + 2 < tokens.count && centWords.contains(tokens[end + 2])) {
                total += cents / 100
                end += 2
                if end < tokens.count, centWords.contains(tokens[end]) { end += 1 }
            }
        }
        if end < tokens.count, currencyWords.contains(tokens[end]) { end += 1 }

        // «soles 24»: la moneda antes del número también es parte del monto.
        let begin = start > 0 && currencyWords.contains(tokens[start - 1]) ? start - 1 : start
        return (Money.normalized(total), begin..<end)
    }

    /// «24», «24.50», «24,50», «1,200», «1.200».
    static func parseDigits(_ token: String) -> Double? {
        guard let first = token.first, first.isNumber else { return nil }
        let groups = token.split(whereSeparator: { $0 == "." || $0 == "," })
        if groups.count > 1, groups.dropFirst().allSatisfy({ $0.count == 3 }), groups[0].count <= 3 {
            return Double(groups.joined())
        }
        return Double(token.replacingOccurrences(of: ",", with: "."))
    }

    /// Números dichos en palabras: «mil doscientos», «treinta y cinco».
    private static func parseWords(_ tokens: [String], from start: Int) -> (Double, Int)? {
        var total = 0.0
        var group = 0.0
        var i = start
        var consumed = false

        while i < tokens.count {
            let token = tokens[i]
            if let n = numberWords[token] {
                group += n
                consumed = true
                i += 1
            } else if token == "mil" {
                total += (group == 0 ? 1 : group) * 1000
                group = 0
                consumed = true
                i += 1
            } else if token == "y", consumed, i + 1 < tokens.count,
                      let n = numberWords[tokens[i + 1]], n < 10, group >= 20 {
                group += n
                i += 2
            } else {
                break
            }
        }
        guard consumed else { return nil }
        let value = total + group
        // «un» suelto es un artículo, no un monto: «un café».
        if value == 1, i - start == 1, ["un", "una", "uno"].contains(tokens[start]) {
            let next = i < tokens.count ? tokens[i] : ""
            guard currencyWords.contains(next) else { return nil }
        }
        return value > 0 ? (value, i) : nil
    }

    // MARK: - Qué

    /// Lo que va tras «en», «para», «por»… o, si no hay preposición, lo que
    /// queda después de quitar verbos y rellenos. Hasta tres palabras.
    static func title(from tokens: [String]) -> String? {
        let content = tokens.filter { !fillerWords.contains($0) && !incomeVerbs.contains($0) }
        let words: [String]

        if let prep = tokens.firstIndex(where: { prepositions.contains($0) }) {
            // Si antes de la preposición ya se dijo el qué («compré pan en el
            // Tambo»), ése es el título; si no, lo que sigue.
            let before = Array(tokens[..<prep]).filter { !fillerWords.contains($0) && !incomeVerbs.contains($0) }
            if !before.isEmpty {
                words = before
            } else {
                var after: [String] = []
                for token in tokens[(prep + 1)...] {
                    if articles.contains(token), after.isEmpty { continue }
                    if !after.isEmpty, stopWords.contains(token) { break }
                    if fillerWords.contains(token) { continue }
                    after.append(token)
                }
                words = after
            }
        } else {
            words = content
        }

        let picked = words.filter { !articles.contains($0) && !stopWords.contains($0) }.prefix(3)
        guard !picked.isEmpty else { return nil }
        return picked.joined(separator: " ").capitalizedFirst
    }

    /// Primero pares de palabras («plaza vea», «uber eats»), luego sueltas;
    /// la primera que el catálogo reconoce entera.
    private static func keywordHit(in tokens: [String],
                                   lookup: (String) -> String?) -> (title: String, category: String)? {
        let words = tokens.filter { !fillerWords.contains($0) && !articles.contains($0) && !stopWords.contains($0) }
        if words.count >= 2 {
            for i in 0..<(words.count - 1) {
                let pair = words[i] + " " + words[i + 1]
                if let category = lookup(pair) { return (pair.capitalizedFirst, category) }
            }
        }
        for word in words where word.count >= 3 {
            if let category = lookup(word) { return (word.capitalizedFirst, category) }
        }
        return nil
    }

    private static func date(in tokens: [String], now: Date) -> Date {
        let calendar = Calendar.current
        if tokens.contains("anteayer") || tokens.contains("antier") {
            return calendar.date(byAdding: .day, value: -2, to: now) ?? now
        }
        if tokens.contains("ayer") {
            return calendar.date(byAdding: .day, value: -1, to: now) ?? now
        }
        return now
    }

    // MARK: - Categoría

    /// Regla del usuario → sugerencia (reglas y catálogo) → catálogo sobre la
    /// frase entera («taxi» delata Transporte aunque el título sea otro).
    static func defaultCategory(title: String, whole: String) -> String? {
        if !title.isEmpty {
            if let named = categoryNamed(title) { return named }
            if let rule = MerchantRules.category(for: title), rule != Accounting.unclassified { return rule }
            if let hint = SuggestionEngine.suggest(for: title, rules: MerchantRules.all()),
               hint.category != Accounting.unclassified {
                return hint.category
            }
        }
        return MerchantCatalog.shared.category(for: whole).flatMap(CategoryCatalog.shared.builtIns.resolve)
    }

    /// Regla exacta del usuario, el nombre de una categoría dicho tal cual
    /// («en comida», «de transporte») o palabra entera del catálogo.
    static func defaultKeywordCategory(_ word: String) -> String? {
        if let rule = MerchantRules.all()[word] ?? MerchantRules.all()[word.capitalizedFirst],
           rule != Accounting.unclassified {
            return rule
        }
        if let named = categoryNamed(word) { return named }
        return MerchantCatalog.shared.exactCategory(for: word)
    }

    /// La categoría cuyo nombre es `word`, sin mirar tildes ni mayúsculas.
    /// Sin esto, «500 soles en comida» se quedaba sin clasificar: «comida» es
    /// una categoría, pero no un comercio del catálogo.
    static func categoryNamed(_ word: String) -> String? {
        let fold: (String) -> String = {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_PE"))
                .lowercased()
        }
        let target = fold(word)
        guard target.count >= 3 else { return nil }
        let singular = target.hasSuffix("s") ? String(target.dropLast()) : target
        return (CategoryStyle.defaults + CategoryCatalog.shared.names)
            .first { name in
                let folded = fold(name)
                return folded != fold(Accounting.unclassified) && (folded == target || folded == singular)
            }
    }

    // MARK: - Vocabulario

    /// Señales de que el que habla se corrigió: vale el último monto.
    private static let correctionCues: Set<String> = [
        "pero", "final", "mejor", "perdon", "corrijo", "digo", "realidad", "total", "resulta", "resulto"
    ]

    private static let numberWords: [String: Double] = [
        "cero": 0, "un": 1, "uno": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5,
        "seis": 6, "siete": 7, "ocho": 8, "nueve": 9, "diez": 10, "once": 11, "doce": 12,
        "trece": 13, "catorce": 14, "quince": 15, "dieciseis": 16, "diecisiete": 17,
        "dieciocho": 18, "diecinueve": 19, "veinte": 20, "veintiun": 21, "veintiuno": 21,
        "veintiuna": 21, "veintidos": 22, "veintitres": 23, "veinticuatro": 24,
        "veinticinco": 25, "veintiseis": 26, "veintisiete": 27, "veintiocho": 28,
        "veintinueve": 29, "treinta": 30, "cuarenta": 40, "cincuenta": 50, "sesenta": 60,
        "setenta": 70, "ochenta": 80, "noventa": 90, "cien": 100, "ciento": 100,
        "doscientos": 200, "doscientas": 200, "trescientos": 300, "trescientas": 300,
        "cuatrocientos": 400, "cuatrocientas": 400, "quinientos": 500, "quinientas": 500,
        "seiscientos": 600, "seiscientas": 600, "setecientos": 700, "setecientas": 700,
        "ochocientos": 800, "ochocientas": 800, "novecientos": 900, "novecientas": 900
    ]

    private static let currencyWords: Set<String> = [
        "sol", "soles", "lucas", "luca", "dolar", "dolares", "usd", "pen", "cocos", "coco"
    ]
    private static let dollarWords: Set<String> = ["dolar", "dolares", "usd", "cocos", "coco"]
    private static let centWords: Set<String> = ["centimos", "centimo", "centavos", "centavo"]

    private static let incomeCues: [String] = [
        "me pagaron", "me pago", "me depositaron", "me yapearon", "me plinearon",
        "me transfirieron", "me devolvieron", "me dieron", "cobre", "recibi", "ingreso",
        "sueldo", "salario", "gane", "vendi"
    ]
    private static let incomeVerbs: Set<String> = [
        "pagaron", "depositaron", "yapearon", "plinearon", "transfirieron", "devolvieron",
        "dieron", "cobre", "recibi", "gane", "vendi"
    ]

    private static let sources: [String: String] = [
        "yape": "Yape", "yapee": "Yape", "yapie": "Yape", "yapeo": "Yape",
        "plin": "Plin", "plineo": "Plin", "efectivo": "Efectivo", "cash": "Efectivo",
        "tarjeta": "Tarjeta", "transferencia": "Transferencia"
    ]

    private static let prepositions: Set<String> = ["en", "para", "por", "al", "del"]
    private static let articles: Set<String> = [
        "el", "la", "los", "las", "un", "una", "unos", "unas", "mi", "mis", "su", "sus", "lo"
    ]
    /// Cortan el título: «taxi de vuelta» → «Taxi».
    private static let stopWords: Set<String> = [
        "de", "con", "y", "e", "que", "para", "por", "porque", "pero", "en", "a"
    ]
    /// Verbos y rellenos que nunca son el qué.
    private static let fillerWords: Set<String> = [
        "gaste", "gasto", "gastamos", "pague", "pago", "pagamos", "compre", "compramos",
        "gastado", "gastar", "pagado", "pagar", "comprado", "comprar", "quiero", "queria",
        "quisiera", "he", "hemos", "ha", "hice", "hizo", "acabo", "acabe", "tuve",
        "me", "te", "se", "nos", "fue", "fueron", "son", "es", "era", "costo", "salio",
        "hoy", "ayer", "anteayer", "antier", "tambien", "ademas", "luego", "despues",
        "y", "e", "o", "ahora", "otro", "otra", "registra", "registrar", "anota", "anotar",
        "agrega", "agregar", "pon", "soles", "sol", "lucas", "luca", "dolares", "dolar",
        "centimos", "yape", "yapee", "plin", "efectivo", "cash", "tarjeta", "transferencia",
        "con", "a", "que", "eh", "este", "bueno", "pues",
        // Vueltas de quien piensa en voz alta antes de decir el gasto.
        "sea", "osea", "entonces", "mmm", "em", "ehh", "fui", "fuimos", "estaba",
        "estuve", "estuvimos", "ahi", "alli", "aca", "aqui", "como", "mas", "menos",
        "aproximadamente", "algo", "asi", "creo", "igual", "final", "resulta", "resulto",
        "dije", "digo", "pero", "nada", "ya", "si", "no", "vez", "iba", "ir", "fuera",
        "costaron", "salieron", "eran", "le", "les", "di", "dimos", "dar",
        "tengo", "tenia", "tuvimos", "mira", "oye", "sabes", "verdad", "mejor", "perdon",
        "corrijo", "realidad", "total", "cuenta", "gastito", "compra", "compras",
        "apunta", "apuntar", "mi", "mis", "unos", "unas"
    ]
}
