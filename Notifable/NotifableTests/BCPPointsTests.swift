import Testing
import Foundation
@testable import Notifable

/// «Pagaste tu tarjeta Qore con puntos» de BCP: entra como ingreso a BCP.
/// Plantilla real con nombre, operación y tarjeta inventados.
struct BCPPointsTests {

    static let plain = "Hola Ana,  Has canjeado 1,500 puntos para pagar S/ 37.50 de tu tarjeta.  "
        + "Te mostramos el detalle de tu operación *00000001* hecha el *05/10/2026* a las *12:43 p. m.*  "
        + "Tarjeta pagada *VISA PLATINUM BCP QORE* Número de tarjeta ***** **** **** 1111*   "
        + "*Con este canje has ahorrado S/ 37.50*  Sigue disfrutando los beneficios de Qore"

    static let html = "           Hola Ana,                   Has canjeado 1,500 puntos para pagar S/ 37.50 de tu tarjeta.    "
        + "       Te mostramos el detalle de tu operación  00000001  hecha el  05/10/2026  a las  12:43 p. m.        "
        + "        Tarjeta pagada                 VISA PLATINUM BCP QORE                 Número de tarjeta    "
        + "             **** **** **** 1111                    Con este canje has ahorrado S/ 37.50   "

    @Test(arguments: [plain, html])
    func canjeDePuntosEsIngresoABCP(text: String) throws {
        #expect(BCPParser().parse(cleanText: text) == nil)
        let income = try #require(BCPParser().parseIncome(cleanText: text))
        #expect(income.amount == 37.50)
        #expect(income.currency == "PEN")
        #expect(income.source == "BCP")
        #expect(income.title == "Canje de puntos Qore")
        #expect(income.notes == "Pago de la tarjeta ****1111 con puntos")
        #expect(AccountResolver.originKey(incomeSource: income.source, fromEmail: true) == AccountResolver.originKey(.bcp))

        var lima = Calendar(identifier: .gregorian)
        lima.timeZone = TimeZone(identifier: "America/Lima")!
        let parts = lima.dateComponents([.year, .month, .day, .hour, .minute], from: income.date)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 5)
        #expect(parts.hour == 12 && parts.minute == 43)
    }

    @Test func ningunOtroLectorLoToma() {
        for parser in [BBVAParser(), YapeParser(), InterbankParser(), ScotiabankParser(), AppleParser()] as [BankEmailParser] {
            #expect(parser.parse(cleanText: Self.plain) == nil)
            #expect(parser.parseIncome(cleanText: Self.plain) == nil)
        }
    }
}
