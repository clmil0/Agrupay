import Foundation
import SwiftData

// MARK: - Instituciones

/// Bancos y billeteras que la app sabe dibujar. `tarjeta` es una tarjeta cuyo
/// banco no dijo el correo (un recibo de Apple, por ejemplo); `efectivo`, lo
/// anotado a mano.
enum Institution: String, CaseIterable {
    case yape, plin, bbva, bcp, interbank, scotiabank, efectivo, tarjeta

    /// Desde el nombre que usan los parsers y el formulario ("BBVA", "Yape",
    /// "Efectivo"…). `nil` para lo que no es una cuenta ("Transferencia",
    /// "Otro", "Apple").
    init?(name: String) {
        switch AccountResolver.folded(name) {
        case "yape":                                  self = .yape
        case "plin":                                  self = .plin
        case "bbva", "bbva continental":              self = .bbva
        case "bcp", "banco de credito", "banco de credito del peru": self = .bcp
        case "interbank":                             self = .interbank
        case "scotiabank", "scotia":                  self = .scotiabank
        case "efectivo":                              self = .efectivo
        default:                                      return nil
        }
    }

    var name: String {
        switch self {
        case .yape:       return "Yape"
        case .plin:       return "Plin"
        case .bbva:       return "BBVA"
        case .bcp:        return "BCP"
        case .interbank:  return "Interbank"
        case .scotiabank: return "Scotiabank"
        case .efectivo:   return "Efectivo"
        case .tarjeta:    return "Tarjeta"
        }
    }

    /// El logo en `Assets.xcassets`. Sin logo, se dibuja `symbol`.
    var logoAsset: String? {
        switch self {
        case .efectivo, .tarjeta: return nil
        default:                  return rawValue + "_icon"
        }
    }

    var symbol: String {
        switch self {
        case .efectivo: return "banknote"
        case .tarjeta:  return "creditcard"
        default:        return "building.columns"
        }
    }
}

// MARK: - Resolución

/// De qué cuenta sale un movimiento y a quién va.
///
/// Hay dos clases de cuenta, con prefijo en la clave:
/// - **Origen** (`o:`): la tarjeta o billetera con la que pagaste. Banco +
///   últimos cuatro cuando el correo los trae —un BBVA de débito y uno de
///   crédito son dos orígenes—; el banco solo cuando no (`o:bbva`).
/// - **Destinatario** (`p:`): a quién le mandaste un Yape, un Plin o una
///   transferencia, por el nombre **exacto** que trae el correo. Si ese
///   nombre es tuyo —tu Plin, tu otra cuenta—, lo que le mandas es un
///   traslado y no un gasto (`TransferDetector`).
///
/// Todo sale de `sourceBank`, `cardLastDigits` y el prefijo del comercio: no
/// hay relaciones que se rompan cuando «Volver a leer el correo» borra y
/// rearma los gastos.
enum AccountResolver {

    static let originPrefix = "o:"
    static let payeePrefix = "p:"
    /// El comercio de un retiro de efectivo ("RETIRO - Cajero"): siempre es
    /// traslado de la tarjeta o cuenta a tu efectivo.
    static let withdrawalPrefix = "RETIRO - "

    static func isCashWithdrawal(merchant: String) -> Bool { merchant.hasPrefix(withdrawalPrefix) }

    static func isOrigin(_ key: String) -> Bool { key.hasPrefix(originPrefix) }
    static func isPayee(_ key: String) -> Bool { key.hasPrefix(payeePrefix) }

    static func originKey(_ institution: Institution, digits: String? = nil) -> String {
        originPrefix + institution.rawValue + (digits.map { ":" + $0 } ?? "")
    }

    /// Institución y dígitos de una clave de origen. `nil` si no es de origen.
    static func parts(of key: String) -> (institution: Institution, digits: String?)? {
        guard isOrigin(key) else { return nil }
        let pieces = key.dropFirst(originPrefix.count).split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = pieces.first, let institution = Institution(rawValue: first) else { return nil }
        return (institution, pieces.count > 1 ? pieces[1] : nil)
    }

    // MARK: Origen

    /// - Parameters:
    ///   - sourceBank: el `bankName` del parser, si se guardó.
    ///   - fromEmail: `false` para lo anotado a mano. Ahí `sourceBank` es la
    ///     fuente elegida en el formulario (Efectivo, Yape, Plin…);
    ///     "Transferencia" u "Otro" no son una cuenta y dan `nil` (sólo en
    ///     «Todas»). Lo anotado antes de guardar la fuente cae en Efectivo.
    static func originKey(sourceBank: String?,
                          merchant: String,
                          cardLastDigits: String?,
                          fromEmail: Bool) -> String? {
        let digits = cardLastDigits.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        if !fromEmail {
            guard let sourceBank else { return originKey(.efectivo) }
            return Institution(name: sourceBank).map { originKey($0) }
        }

        let bank = sourceBank ?? inferredBank(merchant: merchant)
        switch bank {
        case "Yape"?:
            // `YapeParser` también lee los Plin pagados con la tarjeta de
            // débito BCP ("YAPE - …" con dígitos): ésos salen de BCP.
            return digits != nil ? originKey(.bcp, digits: digits) : originKey(.yape)
        case .some(let name):
            if let institution = Institution(name: name) {
                return originKey(institution, digits: digits)
            }
            // "Apple" u otro emisor que no es banco: sólo sabemos la tarjeta.
            return originKey(.tarjeta, digits: digits)
        case nil:
            return originKey(.tarjeta, digits: digits)
        }
    }

    /// Para lo importado antes de que existiera `sourceBank`. El Plin es el
    /// único ambiguo —BBVA y Scotiabank escriben igual el comercio—: se
    /// asume BBVA, que es quien más los manda, y releer el correo lo corrige.
    static func inferredBank(merchant: String) -> String? {
        if merchant.hasPrefix("YAPE - ") { return "Yape" }
        if merchant.hasPrefix("PLIN - ") { return "BBVA" }
        if merchant.hasPrefix("BBVA - ") { return "BBVA" }
        if merchant.hasPrefix("BCP - ") { return "BCP" }
        if merchant.lowercased().contains("apple") { return "Apple" }
        return nil
    }

    /// Un ingreso: del correo sólo llegan Yapes recibidos; a mano, la fuente
    /// elegida (Yape, Plin, Efectivo). "Transferencia" u "Otro" no son una
    /// cuenta: sólo aparecen en «Todas».
    ///
    /// - Note: "Plin" devuelve `o:plin`, que **no es una cuenta**: Plin siempre
    ///   sale de un banco. `AccountCatalog.resolve` lo cambia por el banco del
    ///   último Plin enviado.
    static func originKey(incomeSource source: String, fromEmail: Bool) -> String? {
        if let institution = Institution(name: source) { return originKey(institution) }
        return fromEmail ? originKey(.yape) : nil
    }

    // MARK: Destinatario

    /// Los prefijos con los que los parsers escriben un envío a una persona.
    static let payeePrefixes: [(prefix: String, via: Institution)] = [
        ("YAPE - ", .yape), ("PLIN - ", .plin), ("BBVA - ", .bbva), ("BCP - ", .bcp)
    ]

    /// Los nombres de relleno que ponen los parsers cuando el correo no trae
    /// uno: no son una persona.
    private static let placeholderNames: Set<String> = [
        "desconocido", "transferencia a terceros", "transferencia", "pago de servicio", "servicio"
    ]

    /// A quién va un gasto, y por dónde. `nil` si es un comercio sin prefijo.
    static func payee(merchant: String) -> (name: String, via: Institution)? {
        for (prefix, via) in payeePrefixes where merchant.hasPrefix(prefix) {
            let name = merchant.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !placeholderNames.contains(folded(name)) else { return nil }
            return (name, via)
        }
        return nil
    }

    /// Quién mandó un ingreso del correo ("Enviado por …"). Los anotados a
    /// mano llevan un título libre ("Sueldo"), no un remitente.
    static func sender(title: String?, fromEmail: Bool) -> String? {
        guard fromEmail, let title = title?.trimmingCharacters(in: .whitespaces),
              !title.isEmpty, !placeholderNames.contains(folded(title)) else { return nil }
        return title
    }

    /// El mismo nombre, escrito igual salvo mayúsculas, tildes y espacios, es
    /// la misma cuenta. Nada más flexible: «tiene que ser exactamente el
    /// mismo nombre» — dos Juan Pérez distintos no pueden fundirse.
    static func payeeKey(_ name: String) -> String {
        payeePrefix + folded(name).uppercased()
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_PE"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}

extension Expense {
    /// Un Plin enviado, sea cual sea el banco: "PLIN - …" (BBVA, Scotiabank)
    /// o el Plin con débito BCP, que `YapeParser` guarda como "YAPE - …" con
    /// tarjeta. Marca de qué banco salen tus Plin.
    var isPlinSend: Bool {
        merchant.hasPrefix("PLIN - ")
            || (merchant.hasPrefix("YAPE - ") && (originKey?.hasPrefix(AccountResolver.originKey(.bcp)) ?? false))
    }

    var originKey: String? {
        AccountResolver.originKey(sourceBank: sourceBank, merchant: merchant,
                                  cardLastDigits: cardLastDigits, fromEmail: emailID != nil)
    }

    /// El Plin con débito BCP llega como "YAPE - …": se corrige a Plin, que
    /// es por donde de verdad le llegó.
    var payee: (name: String, via: Institution)? {
        guard let payee = AccountResolver.payee(merchant: merchant) else { return nil }
        return isPlinSend ? (payee.name, .plin) : payee
    }
    var payeeKey: String? { payee.map { AccountResolver.payeeKey($0.name) } }

    var isCashWithdrawal: Bool { AccountResolver.isCashWithdrawal(merchant: merchant) }
}

extension Income {
    var originKey: String? {
        AccountResolver.originKey(incomeSource: source, fromEmail: emailID != nil)
    }

    var senderName: String? { AccountResolver.sender(title: title, fromEmail: emailID != nil) }
    var senderKey: String? { senderName.map(AccountResolver.payeeKey) }
}

// MARK: - Catálogo detectado

/// Una cuenta que apareció en tus movimientos.
struct DetectedAccount: Identifiable, Hashable {
    let key: String
    /// El nombre tal como lo trae el correo ("BBVA", "JOSEPH M.").
    let detectedName: String
    let institution: Institution?
    let digits: String?
    /// Para destinatarios: por dónde les llegó (Yape, Plin, transferencia).
    let via: Institution?
    /// Para destinatarios: los últimos dígitos del celular, si algún correo
    /// los trajo. Se muestran junto al nombre; la cuenta sigue siendo el
    /// nombre exacto.
    var phone: String?
    /// "Débito" o "Crédito", si algún correo de esa tarjeta lo dijo.
    var cardKind: String?
    var count: Int
    var latest: Date

    var id: String { key }
    var isOrigin: Bool { AccountResolver.isOrigin(key) }
}

/// Lo que va y viene de cada cuenta, para el carrusel y para «Tus cuentas».
struct AccountTouch {
    var origin: String?
    var payee: (name: String, via: Institution?)?
    var date: Date
    var cardKind: String? = nil
    var payeePhone: String? = nil
    var isPlinSend: Bool = false
}

struct AccountCatalog {
    private(set) var accounts: [String: DetectedAccount] = [:]
    /// Origen sin dígitos → la única tarjeta de ese banco, o su única de
    /// débito si hay varias. Un Plin de BBVA no dice con qué tarjeta salió.
    private(set) var aliases: [String: String] = [:]

    /// De qué banco salió cada Plin enviado, por fecha: a dónde llega un Plin
    /// recibido.
    private(set) var plinSends: [(date: Date, origin: String)] = []

    init(touches: [AccountTouch]) {
        plinSends = touches.compactMap { touch in
            guard touch.isPlinSend, let origin = touch.origin else { return nil }
            return (touch.date, origin)
        }
        .sorted { $0.date < $1.date }

        for var touch in touches {
            touch.origin = touch.origin.flatMap { Self.resolvePlin($0, at: touch.date, sends: plinSends) }
            if let origin = touch.origin, let parts = AccountResolver.parts(of: origin) {
                add(key: origin, name: parts.institution.name, institution: parts.institution,
                    digits: parts.digits, via: nil, date: touch.date)
                if let kind = touch.cardKind, accounts[origin]?.cardKind == nil {
                    accounts[origin]?.cardKind = kind
                }
            }
            if let payee = touch.payee {
                let key = AccountResolver.payeeKey(payee.name)
                add(key: key, name: payee.name, institution: nil,
                    digits: nil, via: payee.via, date: touch.date)
                // El celular del envío más reciente: si cambió de número, vale el último.
                if let phone = touch.payeePhone, let account = accounts[key],
                   account.phone == nil || touch.date >= account.latest {
                    accounts[key]?.phone = phone
                }
            }
        }

        // Una tarjeta sin banco (un recibo de Apple) con los mismos cuatro
        // dígitos que una de banco es esa misma tarjeta.
        for loose in accounts.values where loose.isOrigin && loose.institution == .tarjeta {
            guard let digits = loose.digits else { continue }
            let owners = accounts.values.filter {
                $0.isOrigin && $0.institution != .tarjeta && $0.digits == digits
            }
            guard owners.count == 1, let owner = owners.first else { continue }
            merge(loose.key, into: owner.key)
        }

        let origins = accounts.values.filter(\.isOrigin)
        for bare in origins where bare.digits == nil {
            guard let institution = bare.institution else { continue }
            let cards = origins.filter { $0.institution == institution && $0.digits != nil }
            // Con varias, la de débito si es una sola: un Plin o una
            // transferencia sale de la cuenta, y la cuenta es la de débito.
            let debit = cards.filter { $0.cardKind == "Débito" || $0.cardKind == "Cuenta" }
            guard let card = cards.count == 1 ? cards.first : (debit.count == 1 ? debit.first : nil) else { continue }
            merge(bare.key, into: card.key)
        }
    }

    private mutating func merge(_ key: String, into target: String) {
        guard let moved = accounts[key], var kept = accounts[target] else { return }
        kept.count += moved.count
        kept.cardKind = kept.cardKind ?? moved.cardKind
        kept.latest = max(kept.latest, moved.latest)
        accounts[target] = kept
        accounts[key] = nil
        aliases[key] = target
    }

    init(expenses: [Expense], incomes: [Income]) {
        var touches: [AccountTouch] = []
        touches.reserveCapacity(expenses.count + incomes.count)
        // Las partes de un pago dividido repiten su origen: contarlas haría
        // pasar un solo pago por tres.
        for e in expenses where e.splitOf == nil {
            touches.append(AccountTouch(origin: e.originKey,
                                        payee: e.payee.map { ($0.name, $0.via) },
                                        date: e.date,
                                        cardKind: e.cardKind,
                                        payeePhone: e.payeePhone,
                                        isPlinSend: e.isPlinSend))
        }
        for i in incomes {
            touches.append(AccountTouch(origin: i.originKey,
                                        payee: i.senderName.map { ($0, nil) },
                                        date: i.date))
        }
        self.init(touches: touches)
    }

    private mutating func add(key: String, name: String, institution: Institution?,
                              digits: String?, via: Institution?, date: Date) {
        if var existing = accounts[key] {
            existing.count += 1
            existing.latest = max(existing.latest, date)
            accounts[key] = existing
        } else {
            accounts[key] = DetectedAccount(key: key, detectedName: name, institution: institution,
                                            digits: digits, via: via, count: 1, latest: date)
        }
    }

    func canonical(_ key: String) -> String { aliases[key] ?? key }

    /// La cuenta de un movimiento ya en el carrusel: «Plin» pasa a su banco y
    /// todo se une a su tarjeta. `nil` si no cae en ninguna (sólo «Todas»).
    func resolve(_ key: String?, at date: Date) -> String? {
        key.flatMap { Self.resolvePlin($0, at: date, sends: plinSends) }.map(canonical)
    }

    /// Plin no es una cuenta: un Plin recibido va al banco del último Plin
    /// **enviado** hasta esa fecha —si antes no hubo ninguno, al primero
    /// después—. Así un ingreso de marzo no se muda de banco porque en junio
    /// empezaste a plinear desde otro. Sin ningún Plin enviado, a ninguno.
    static func resolvePlin(_ key: String, at date: Date,
                            sends: [(date: Date, origin: String)]) -> String? {
        guard key == AccountResolver.originKey(.plin) else { return key }
        return sends.last(where: { $0.date <= date })?.origin ?? sends.first?.origin
    }
}

// MARK: - Preferencias

/// Lo que decidiste en «Tus cuentas»: cuáles son tuyas, cómo se llaman y en
/// qué orden van en el carrusel.
///
/// Sólo se guarda lo que difiere del valor por defecto: un origen es tuyo
/// —llegó a tu correo, es tu tarjeta—; un destinatario no, hasta que lo
/// marques.
struct AccountPreferences: Codable, Equatable {
    var names: [String: String] = [:]
    var mine: [String: Bool] = [:]
    var order: [String] = []

    func isMine(_ key: String) -> Bool {
        mine[key] ?? AccountResolver.isOrigin(key)
    }

    /// Los destinatarios que son cuentas tuyas: lo que les llega es traslado.
    var minePayees: Set<String> {
        Set(mine.compactMap { key, isMine in
            isMine && AccountResolver.isPayee(key) ? key : nil
        })
    }

    /// El que le diste; si no, el detectado, con el tipo de tarjeta cuando se
    /// sabe: dos BBVA se leen «BBVA Débito» y «BBVA Crédito».
    func name(for account: DetectedAccount) -> String {
        if let custom = names[account.key], !custom.isEmpty { return custom }
        if let kind = account.cardKind { return account.detectedName + " " + kind }
        return account.detectedName
    }

    /// Las cuentas tuyas en el orden del carrusel: primero las que ordenaste,
    /// luego el resto por número de movimientos.
    func carousel(from catalog: AccountCatalog) -> [DetectedAccount] {
        let mineAccounts = catalog.accounts.values.filter { isMine($0.key) }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return mineAccounts.sorted { a, b in
            switch (rank[a.key], rank[b.key]) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):
                if a.count != b.count { return a.count > b.count }
                return a.key < b.key
            }
        }
    }
}

final class AccountBook: ObservableObject {

    static let shared = AccountBook()
    static let key = "moneyAccounts"

    @Published private(set) var preferences: AccountPreferences

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = Self.load(from: defaults)
    }

    /// Un JSON en texto, no `Data`: así viaja tal cual en el respaldo de
    /// configuración (`AppPreferences`, tipo `.string`).
    private static func load(from defaults: UserDefaults) -> AccountPreferences {
        defaults.string(forKey: key)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(AccountPreferences.self, from: $0) }
            ?? AccountPreferences()
    }

    /// Tras restaurar un respaldo, que escribe directo en `UserDefaults`.
    func reload() {
        preferences = Self.load(from: defaults)
    }

    func replace(with preferences: AccountPreferences) {
        guard preferences != self.preferences else { return }
        self.preferences = preferences
        persist()
    }

    /// Empezar de cero (Configuración › Borrar datos).
    func removeAll() {
        preferences = AccountPreferences()
        defaults.removeObject(forKey: Self.key)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(preferences),
           let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: Self.key)
        }
    }
}

// MARK: - Traslados

/// Decide qué movimientos son traslados entre tus cuentas.
///
/// La regla es una sola: **si el dinero va a una cuenta tuya, no es gasto**.
/// Un Yape a tu Plin, un Plin de BBVA a tu Yape, una transferencia a tu otra
/// cuenta: el correo del gasto llega igual, pero el dinero sigue siendo tuyo y
/// contarlo duplicaría el gasto cuando lo uses desde la otra cuenta. La app no
/// lleva saldos; sólo evita contar dos veces.
///
/// Y del otro lado, lo que te llega desde un nombre tuyo tampoco es ingreso:
/// es el mismo dinero cambiando de sitio.
///
/// El resultado se guarda en `isTransfer` —para que las consultas lo puedan
/// filtrar y `Accounting` lo lea en el snapshot— y se recalcula entero cada
/// vez que cambian tus cuentas o entra correo nuevo.
enum TransferDetector {

    /// Un gasto y un ingreso del mismo traslado llegan con segundos o minutos
    /// de diferencia (Plin de BBVA → Yape recibido).
    static let pairingWindow: TimeInterval = 30 * 60

    static func isTransfer(payeeKey: String?, minePayees: Set<String>, isCashWithdrawal: Bool = false) -> Bool {
        // Un retiro siempre: el dinero pasa a tu efectivo.
        if isCashWithdrawal { return true }
        guard let payeeKey else { return false }
        return minePayees.contains(payeeKey)
    }

    /// Recalcula `isTransfer` en todo el historial. Devuelve cuántos cambiaron.
    /// Sirve con cualquier `ModelContext`; la lectura de Gmail lo llama con
    /// uno de fondo y le pasa las preferencias leídas en el hilo principal.
    @discardableResult
    static func apply(in context: ModelContext, preferences: AccountPreferences = AccountBook.shared.preferences) -> Int {
        let mine = preferences.minePayees
        var changed = 0

        let expenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
        for expense in expenses {
            let value = isTransfer(payeeKey: expense.payeeKey, minePayees: mine,
                                   isCashWithdrawal: expense.isCashWithdrawal)
            if expense.isTransfer != value { expense.isTransfer = value; changed += 1 }
        }

        let incomes = (try? context.fetch(FetchDescriptor<Income>())) ?? []
        for income in incomes {
            // Un abono a una deuda ya tiene su sitio en la contabilidad.
            let value = income.debtReference == nil
                && isTransfer(payeeKey: income.senderKey, minePayees: mine)
            if income.isTransfer != value { income.isTransfer = value; changed += 1 }
        }

        if changed > 0 { try? context.save() }
        return changed
    }

    // MARK: Emparejado

    struct Leg {
        let id: UUID
        let cents: Int
        let currency: String
        let date: Date
    }

    /// Une cada salida con la entrada del mismo monto y moneda más cercana en
    /// el tiempo, dentro de `pairingWindow`. Cada entrada se usa una vez.
    /// Devuelve `id del gasto → id del ingreso`.
    static func pairs(outgoing: [Leg], incoming: [Leg], window: TimeInterval = pairingWindow) -> [UUID: UUID] {
        var available = incoming
        var result: [UUID: UUID] = [:]
        for out in outgoing.sorted(by: { $0.date < $1.date }) {
            let candidates = available.enumerated().filter { _, leg in
                leg.cents == out.cents && leg.currency == out.currency
                    && abs(leg.date.timeIntervalSince(out.date)) <= window
            }
            guard let best = candidates.min(by: {
                abs($0.element.date.timeIntervalSince(out.date)) < abs($1.element.date.timeIntervalSince(out.date))
            }) else { continue }
            result[out.id] = best.element.id
            available.remove(at: best.offset)
        }
        return result
    }
}
