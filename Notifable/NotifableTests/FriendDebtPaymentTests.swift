import Foundation
import Testing
@testable import Notifable

/// El emparejador de «ya te pagué»: qué envíos pagan solos, cuáles preguntan
/// y cuáles se ignoran.
struct FriendDebtPaymentTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let joseph = "u-joseph"
    private let payee = AccountResolver.payeeKey("JOSEPH M.")

    private func share(_ id: String, amount: Double, paid: Double = 0, creditor: String? = nil,
                       daysAgo: Double = 3, currency: String = "PEN") -> OwedShare {
        OwedShare(id: id, creditor: creditor ?? joseph, debtKey: "k-" + id, merchant: "Pizza",
                  occurredOn: now.addingTimeInterval(-daysAgo * 86_400), amount: amount, currency: currency,
                  paidAmount: paid, isPaid: false, createdAt: now.addingTimeInterval(-daysAgo * 86_400), paidAt: nil)
    }

    private func send(_ key: String, _ amount: Double, to name: String = "JOSEPH M.",
                      daysAgo: Double = 1, currency: String = "PEN") -> DebtPaymentCandidate {
        DebtPaymentCandidate(key: key, payeeKey: AccountResolver.payeeKey(name), payeeName: name, via: .yape,
                             amount: amount, currency: currency, date: now.addingTimeInterval(-daysAgo * 86_400))
    }

    private func match(_ candidates: [DebtPaymentCandidate], _ shares: [OwedShare],
                       links: [String: String] = [:], rejected: Set<String> = [],
                       handled: Set<String> = []) -> DebtPaymentMatcher.Result {
        DebtPaymentMatcher.match(candidates: candidates, shares: shares, links: links,
                                 rejectedLinks: rejected, handled: handled,
                                 friendNames: [joseph: ["Joseph Mottoccanche", "Joseph"], "u-vale": ["Vale"]],
                                 now: now)
    }

    @Test("Vinculado y monto exacto: se paga solo")
    func vinculadoExacto() {
        let result = match([send("s1", 50)], [share("d1", amount: 50)], links: [payee: joseph])
        #expect(result.autos.map(\.share.id) == ["d1"])
        #expect(result.suggestions.isEmpty)
    }

    @Test("Vinculado con otro monto: pregunta, no paga")
    func vinculadoOtroMonto() {
        let result = match([send("s1", 30)], [share("d1", amount: 50)], links: [payee: joseph])
        #expect(result.autos.isEmpty)
        #expect(result.suggestions.first?.needsLink == false)
    }

    @Test("El monto exacto va a la deuda que coincide, no a la más antigua")
    func eligeLaExacta() {
        let shares = [share("vieja", amount: 80, daysAgo: 10), share("pizza", amount: 50)]
        let result = match([send("s1", 50)], shares, links: [payee: joseph])
        #expect(result.autos.first?.share.id == "pizza")
    }

    @Test("Una deuda pagada sola no se vuelve a usar en el mismo pase")
    func noPagaDosVeces() {
        let result = match([send("s1", 50), send("s2", 50, daysAgo: 0.5)], [share("d1", amount: 50)],
                           links: [payee: joseph])
        #expect(result.autos.count == 1)
    }

    @Test("Sin vincular y con nombre parecido: pregunta si es él")
    func sinVincularPregunta() {
        let result = match([send("s1", 50)], [share("d1", amount: 50)])
        #expect(result.autos.isEmpty)
        #expect(result.suggestions.first?.needsLink == true)
        #expect(result.suggestions.first?.friendID == joseph)
    }

    @Test("Sin vincular, otro nombre y otro monto: nada")
    func desconocidoSeIgnora() {
        let result = match([send("s1", 12, to: "BODEGA DON LUCHO")], [share("d1", amount: 50)])
        #expect(result.suggestions.isEmpty)
    }

    @Test("Dijiste que no es él: no vuelve a preguntar")
    func rechazoNoInsiste() {
        let rejected: Set = [DebtPaymentMatcher.rejectKey(payee: payee, friend: joseph)]
        let result = match([send("s1", 50)], [share("d1", amount: 50)], rejected: rejected)
        #expect(result.suggestions.isEmpty)
    }

    @Test("Ya decidido, otra moneda o de antes de la deuda: se ignora")
    func filtros() {
        let shares = [share("d1", amount: 50, daysAgo: 3)]
        #expect(match([send("s1", 50)], shares, links: [payee: joseph], handled: ["s1"]).autos.isEmpty)
        #expect(match([send("s1", 50, currency: "USD")], shares, links: [payee: joseph]).autos.isEmpty)
        #expect(match([send("s1", 50, daysAgo: 9)], shares, links: [payee: joseph]).autos.isEmpty)
    }

    @Test("Nombres: «VALERIA GOMEZ» se parece a «Vale»; «Ana» no a «Juan»")
    func nombres() {
        #expect(DebtPaymentMatcher.namesMatch(payee: "VALERIA GOMEZ", friend: ["Vale"]))
        #expect(DebtPaymentMatcher.namesMatch(payee: "JOSEPH M.", friend: ["Joseph Mottoccanche"]))
        #expect(DebtPaymentMatcher.namesMatch(payee: "José Pérez", friend: ["jose"]))
        #expect(!DebtPaymentMatcher.namesMatch(payee: "Juan Pérez", friend: ["Ana"]))
    }
}
