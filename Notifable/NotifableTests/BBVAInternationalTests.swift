import Testing
import Foundation
@testable import Notifable

/// La transferencia al exterior de BBVA y la boleta electrónica con la que
/// BBVA cobra su comisión. Plantillas reales con nombres, cuentas y códigos
/// inventados.
struct BBVAInternationalTests {

    static let transferPlain = "[image: BBVA] ¡Hola, Ana!  *Tu transferencia al exterior a Carlos Ruiz fue completada con éxito*   "
        + "Importe transferido: *$139.60*   Importe abonado: *$139.60* El banco de destino e intermediarios podrían haber "
        + "aplicado gastos adicionales y haberlos descontado del importe a recibir.  *Enviada* BBVA *Recibida* Banco corresponsal "
        + "*Completada* Banco de destino Consulta y revisa el estado de tu transferencia.  *Más detalles de la operación*  "
        + "Fecha de llegada *5 de octubre de 2026* Gastos adicionales *$0.00* Número de liquidación *0000001* "
        + "Referencia *0000001000000000* Cuenta de origen *Cuenta Ahorro \u{2022}1111* Banco corresponsal *Banco Corresponsal N.A.* "
        + "Banco de destino *Bbva Mexico S.A. BANKMXMMXXX \u{2022}2222* *Muchas gracias,* El equipo de BBVA."

    /// Lo que queda del HTML sin etiquetas: sin asteriscos y con espacios duros.
    static let transferHTML = "  ¡Hola, Ana!   Tu transferencia al exterior a Carlos Ruiz\u{00A0}fue completada con éxito   "
        + "\u{00A0}\u{00A0}Importe transferido:\u{00A0}$139.60   \u{00A0}\u{00A0}Importe abonado:\u{00A0}$139.60   "
        + "Más detalles de la operación   Fecha de llegada 5 de octubre de 2026   Gastos adicionales $0.00   "
        + "Cuenta de origen Cuenta Ahorro\u{00A0}\u{2022}1111   Banco de destino Bbva Mexico S.A.\u{00A0}BANKMXMMXXX\u{00A0}\u{2022}2222"

    static let feePlain = "[image: undefined]  *Hola ANA PEREZ GOMEZ,*  *Este es tu comprobante electrónico por el pago de intereses y/o* "
        + "*comisiones que realizaste*  Conoce los datos más importantes de este documento informativo:  "
        + "*Tipo de comprobante:* BOLETA DE VENTA ELECTRÓNICA  *Número:* BN00-00000001  *Monto:* USD 72.00  "
        + "*Fecha de Emisión:* 2026-10-05  Recuerda que:  Te enviamos este documento por disposición de SUNAT y no representa ningún pago adicional al que ya realizaste."

    static let feeHTML = "  Hola ANA PEREZ GOMEZ,  Este  es  tu  comprobante  electrónico  por  el  pago  de  intereses y/o  "
        + "comisiones que realizaste  Conoce los datos más importantes de este documento informativo:  "
        + "Tipo de comprobante:            BOLETA DE VENTA ELECTRÓNICA  Número: BN00-00000001  Monto: USD 72.00  "
        + "Fecha de Emisión: 2026-10-05  Recuerda que:"

    private func lima(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Lima")!
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    // MARK: - Transferencia al exterior

    @Test(arguments: [transferPlain, transferHTML])
    func transferenciaAlExterior(text: String) throws {
        let expense = try #require(BBVAParser().parse(cleanText: text))
        #expect(expense.amount == 139.60)
        #expect(expense.currency == "USD")
        #expect(expense.merchant == "BBVA - Carlos Ruiz")
        #expect(expense.cardLastDigits == "1111")
        let parts = lima(expense.date)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 5)

        GmailSyncService.applyAccountDetails(to: expense, bankName: "BBVA", cleanText: text)
        #expect(expense.cardKind == "Cuenta")
        // «Bbva Mexico» no es una cuenta BBVA de aquí.
        #expect(expense.destinationWallet == nil)
        #expect(expense.payee?.name == "Carlos Ruiz")
    }

    // MARK: - Boleta de comisiones

    @Test(arguments: [feePlain, feeHTML])
    func boletaDeComision(text: String) throws {
        let expense = try #require(BBVAParser().parse(cleanText: text))
        #expect(expense.amount == 72)
        #expect(expense.currency == "USD")
        #expect(expense.merchant == "Comisiones e intereses BBVA")
        #expect(expense.payee == nil)
        let parts = lima(expense.date)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 5)
    }

    @Test(arguments: [transferPlain, feePlain])
    func losDemasLectoresNoLosToman(text: String) {
        #expect(BCPParser().parse(cleanText: text) == nil)
        #expect(YapeParser().parse(cleanText: text) == nil)
        #expect(InterbankParser().parse(cleanText: text) == nil)
        #expect(ScotiabankParser().parse(cleanText: text) == nil)
        #expect(AppleParser().parse(cleanText: text) == nil)
    }
}
