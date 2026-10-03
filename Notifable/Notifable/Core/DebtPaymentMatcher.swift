import Foundation

/// Una parte de deuda que **yo** le debo a un amigo (`debt_shares`, lado del
/// deudor): «le debes S/ 50 a Joseph de la pizza».
struct OwedShare: Identifiable, Equatable {
    let id: String
    /// Quien cobra: el `id` del amigo.
    let creditor: String
    let debtKey: String
    let merchant: String
    let occurredOn: Date?
    let amount: Double
    let currency: String
    var paidAmount: Double
    var isPaid: Bool
    let createdAt: Date
    var paidAt: Date?
    /// Quien cobra la perdonó (`close_debt_share`, v14). Cuenta como cerrada:
    /// `isPaid` también va en `true`, así que nada intenta pagarla.
    var isForgiven: Bool = false
    var closedAt: Date? = nil

    var remaining: Double { Money.clampedToZero(Money.subtract(amount, paidAmount)) }
    var isOpen: Bool { !isPaid && Money.cents(remaining) > 0 }
}

/// Un Yape, Plin o transferencia que **yo** mandé: lo único que puede ser el
/// pago de una deuda. Sale de un `Expense` con destinatario.
struct DebtPaymentCandidate: Equatable {
    /// `TransactionKey` del gasto: es lo que el servidor guarda como
    /// `source_key`, así que releer el correo no paga dos veces.
    let key: String
    let payeeKey: String
    /// Tal como lo trae el correo: «JOSEPH M.».
    let payeeName: String
    let via: Institution
    let amount: Double
    let currency: String
    let date: Date
}

/// Decide qué envíos pagan qué deudas, en el teléfono de quien paga.
///
/// Tres casos, del más seguro al menos:
/// 1. **Destinatario ya vinculado** a ese amigo y **monto exacto** de lo que
///    falta → se paga solo (con aviso y «Deshacer»).
/// 2. Destinatario vinculado pero **otro monto** → se pregunta: abono
///    parcial, salda todo, o no es para eso.
/// 3. Destinatario **sin vincular**, con un amigo al que le debo y cuyo
///    nombre se parece o cuyo monto coincide → se pregunta «¿JOSEPH M. es
///    Joseph?». Nunca se vincula solo: dos personas pueden llamarse igual.
enum DebtPaymentMatcher {

    /// Un envío anterior a la deuda puede ser su pago —se paga la pizza en la
    /// mesa y el recordatorio sale después—, pero no uno de semanas antes.
    static let slackBeforeDebt: TimeInterval = 2 * 86_400
    /// Más atrás no se busca: un Yape de hace dos meses no es de esta deuda.
    static let lookback: TimeInterval = 45 * 86_400

    struct Auto: Equatable {
        let candidate: DebtPaymentCandidate
        let share: OwedShare
    }

    struct Suggestion: Identifiable, Equatable {
        let candidate: DebtPaymentCandidate
        let friendID: String
        /// Las deudas abiertas con ese amigo que podría estar pagando, la más
        /// probable primero (monto exacto, luego la más antigua).
        let shares: [OwedShare]
        /// El destinatario todavía no está vinculado a ese amigo: aceptar
        /// también lo vincula.
        let needsLink: Bool
        var id: String { candidate.key }
    }

    struct Result: Equatable {
        var autos: [Auto] = []
        var suggestions: [Suggestion] = []
    }

    /// - Parameters:
    ///   - links: destinatario (`p:…`) → amigo, lo que el usuario confirmó.
    ///   - rejectedLinks: «destinatario|amigo» que el usuario dijo que no son
    ///     la misma persona: no se vuelve a preguntar.
    ///   - handled: envíos ya decididos (pagados o descartados).
    ///   - friendNames: amigo → nombres por los que se le conoce (el suyo y
    ///     el apodo que le puse).
    static func match(candidates: [DebtPaymentCandidate],
                      shares: [OwedShare],
                      links: [String: String],
                      rejectedLinks: Set<String>,
                      handled: Set<String>,
                      friendNames: [String: [String]],
                      now: Date = Date()) -> Result {
        var result = Result()
        var open = shares.filter(\.isOpen)
        guard !open.isEmpty else { return result }

        let pending = candidates
            .filter { !handled.contains($0.key) && $0.date >= now.addingTimeInterval(-lookback) }
            .sorted { $0.date < $1.date }

        for candidate in pending {
            let fits = { (share: OwedShare) -> Bool in
                share.isOpen && share.currency == candidate.currency
                    && candidate.date >= (share.occurredOn ?? share.createdAt).addingTimeInterval(-slackBeforeDebt)
            }

            if let friend = links[candidate.payeeKey] {
                let theirs = ranked(open.filter { $0.creditor == friend && fits($0) }, for: candidate)
                guard let best = theirs.first else { continue }
                if Money.cents(best.remaining) == Money.cents(candidate.amount) {
                    result.autos.append(Auto(candidate: candidate, share: best))
                    // Ya pagada: el siguiente envío no puede volver a usarla.
                    if let index = open.firstIndex(where: { $0.id == best.id }) {
                        open[index].paidAmount = open[index].amount
                        open[index].isPaid = true
                    }
                } else {
                    result.suggestions.append(Suggestion(candidate: candidate, friendID: friend,
                                                         shares: theirs, needsLink: false))
                }
                continue
            }

            // Sin vincular: el amigo con deuda abierta que mejor encaje.
            var best: (friend: String, shares: [OwedShare], score: Int)?
            for friend in Set(open.map(\.creditor)).sorted() {
                // Un amigo ya vinculado a otro destinatario puede tener otra
                // cuenta; pero si dijiste que no es él, no se insiste.
                guard !rejectedLinks.contains(rejectKey(payee: candidate.payeeKey, friend: friend)) else { continue }
                let theirs = ranked(open.filter { $0.creditor == friend && fits($0) }, for: candidate)
                guard let first = theirs.first else { continue }
                let exact = Money.cents(first.remaining) == Money.cents(candidate.amount)
                let named = namesMatch(payee: candidate.payeeName, friend: friendNames[friend] ?? [])
                guard exact || named else { continue }
                // El nombre pesa más que el monto: S/ 50 le yapea cualquiera.
                let score = (named ? 2 : 0) + (exact ? 1 : 0)
                if best == nil || score > best!.score { best = (friend, theirs, score) }
            }
            if let best {
                result.suggestions.append(Suggestion(candidate: candidate, friendID: best.friend,
                                                     shares: best.shares, needsLink: true))
            }
        }
        return result
    }

    static func rejectKey(payee: String, friend: String) -> String { payee + "|" + friend }

    /// Monto exacto primero; luego la más antigua.
    private static func ranked(_ shares: [OwedShare], for candidate: DebtPaymentCandidate) -> [OwedShare] {
        shares.sorted { a, b in
            let ea = Money.cents(a.remaining) == Money.cents(candidate.amount)
            let eb = Money.cents(b.remaining) == Money.cents(candidate.amount)
            if ea != eb { return ea }
            return a.createdAt < b.createdAt
        }
    }

    /// «VALERIA GOMEZ» se parece a «Vale»; «JOSEPH M.» a «Joseph Mottoccanche».
    /// Basta con que una palabra de al menos tres letras de un lado empiece
    /// como una del otro. Es sólo para **preguntar**, nunca para vincular.
    static func namesMatch(payee: String, friend names: [String]) -> Bool {
        let payeeWords = words(payee)
        for name in names {
            for word in words(name) {
                for other in payeeWords where other.hasPrefix(word) || word.hasPrefix(other) {
                    return true
                }
            }
        }
        return false
    }

    private static func words(_ text: String) -> [String] {
        AccountResolver.folded(text)
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count >= 3 }
    }
}
