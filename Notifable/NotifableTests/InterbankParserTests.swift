import Testing
import Foundation
@testable import Notifable

/// Los tres avisos de Interbank que son gasto: Plin enviado, transferencia y
/// Pago Automático. Los textos son los de correos reales, con los saltos de
/// línea ya cambiados por espacios como hace `parseEmailBody`.
struct InterbankParserTests {

    static let plinPlain = "[image: Interbank]  Hola, MARIA, te enviamos tu  Constancia de Pago Plin  "
        + "Te enviamos el detalle de tu operación  Código de operación  00000001  Fecha y hora  05 Oct 2026 10:56 PM  "
        + "Cuenta cargo  Cuenta Simple  Soles  898 1234567890  Destinatario  JUAN PEREZ  Destino  Plin  "
        + "Monto y moneda  S/ 1.00 [image: App]  Realiza más operaciones como esta de manera rápida y simple desde Interbank APP"

    /// Lo que queda del HTML sin etiquetas: los mismos campos con más espacios.
    static let plinHTML = "     Hola,  MARIA , te                                                 enviamos tu       "
        + "  Constancia de Pago Plin           Te enviamos el detalle de tu operación     Código de operación     "
        + "      00000001       Fecha y hora       05 Oct 2026   10:56 PM      Cuenta cargo      Cuenta Simple   "
        + "    Soles       898 1234567890      Destinatario       JUAN PEREZ      Destino       Plin     "
        + "  Monto y moneda       S/   1.00       Realiza más operaciones"

    static let transferPlain = "[image: Interbank]  Hola MARIA, te enviamos tu  Constancia de transferencia  "
        + "Código de operación  00000002  Fecha y hora  05 Oct 2026 11:00 PM  Cuenta a cargo  Cuenta Simple  898 1234567890  "
        + "Cuenta destino  BBVA Continental  01100000000000001234  Tipo de operación  Transferencia diferida  "
        + "Monto y moneda  S/ 1.00  Comisión  S/ 0.00  Monto total  S/ 1.00  Conoce más sobre tu operación  "
        + "¿En cuánto llegará mi transferencia diferida?  Tardará 2 días útiles como máximo"

    static let automaticPlain = "  *PEREZ GOMEZ MARIA * *¡El pago de tu servicio afiliado a Pago Automático se ha realizado con éxito!* "
        + "Verifica aquí los datos:     - Empresa: 009 - CLARO    - Servicio: 01 - CLARO    - Código cliente: *900000000 *    "
        + "- Monto cobrado: S/ 39.90    - Fecha de pago: 23/09/2026  *Conoce más acerca de tu Pago Automático:* "
        + "*¿Cómo verificas tu operación?* Hazlo a través de tu Banca por Internet"

    static let automaticHTML = "  PEREZ GOMEZ MARIA     ¡El pago de tu servicio afiliado a Pago Automático se ha realizado con éxito!   "
        + "  Verifica aquí los datos:       Empresa: 009 - CLARO                           Servicio: 01 - CLARO          "
        + "Código cliente:  900000000              Monto cobrado: S/ 39.90   Fecha de pago: 23/09/2026     "
        + "  Conoce más acerca de tu Pago Automático:  "

    private func lima(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Lima")!
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    // MARK: - Plin

    @Test(arguments: [plinPlain, plinHTML])
    func plinEnviado(text: String) throws {
        let expense = try #require(InterbankParser().parse(cleanText: text))
        #expect(expense.amount == 1)
        #expect(expense.currency == "PEN")
        #expect(expense.merchant == "PLIN - JUAN PEREZ")
        #expect(expense.cardLastDigits == "7890")
        let parts = lima(expense.date)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 5)
        #expect(parts.hour == 22 && parts.minute == 56)
    }

    @Test func plinVaAPlinDesdeLaCuentaInterbank() throws {
        let expense = try #require(InterbankParser().parse(cleanText: Self.plinPlain))
        GmailSyncService.applyAccountDetails(to: expense, bankName: "Interbank", cleanText: Self.plinPlain)
        #expect(expense.destinationWallet == "Plin")
        #expect(expense.cardKind == "Cuenta")
        #expect(expense.isPlinSend)
        #expect(expense.payee?.name == "JUAN PEREZ")
        #expect(expense.payee?.via == .plin)
    }

    // MARK: - Transferencia

    @Test func transferenciaAOtroBanco() throws {
        let expense = try #require(InterbankParser().parse(cleanText: Self.transferPlain))
        #expect(expense.amount == 1)
        #expect(expense.currency == "PEN")
        #expect(expense.merchant == "INTERBANK - Cuenta BBVA Continental *1234")
        #expect(expense.cardLastDigits == "7890")
        let parts = lima(expense.date)
        #expect(parts.day == 5 && parts.hour == 23 && parts.minute == 0)

        GmailSyncService.applyAccountDetails(to: expense, bankName: "Interbank", cleanText: Self.transferPlain)
        #expect(expense.destinationWallet == "BBVA")
        #expect(expense.cardKind == "Cuenta")
        #expect(expense.payee?.via == .interbank)
    }

    @Test func transferenciaCobraElMontoTotalConComision() throws {
        let text = Self.transferPlain
            .replacingOccurrences(of: "Comisión  S/ 0.00  Monto total  S/ 1.00", with: "Comisión  S/ 3.50  Monto total  S/ 4.50")
        let expense = try #require(InterbankParser().parse(cleanText: text))
        #expect(expense.amount == 4.5)
    }

    // MARK: - Pago Automático

    @Test(arguments: [automaticPlain, automaticHTML])
    func pagoAutomatico(text: String) throws {
        let expense = try #require(InterbankParser().parse(cleanText: text))
        #expect(expense.amount == 39.90)
        #expect(expense.currency == "PEN")
        #expect(expense.merchant == "CLARO")
        #expect(expense.isSubscription)
        #expect(expense.cardLastDigits == nil)
        let parts = lima(expense.date)
        #expect(parts.year == 2026 && parts.month == 9 && parts.day == 23)
    }

    // MARK: - Sin cruces con otros lectores

    @Test(arguments: [plinPlain, transferPlain, automaticPlain])
    func losDemasLectoresNoLosToman(text: String) {
        #expect(BBVAParser().parse(cleanText: text) == nil)
        #expect(BCPParser().parse(cleanText: text) == nil)
        #expect(YapeParser().parse(cleanText: text) == nil)
        #expect(ScotiabankParser().parse(cleanText: text) == nil)
        #expect(AppleParser().parse(cleanText: text) == nil)
    }
}
