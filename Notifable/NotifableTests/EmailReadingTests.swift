import Testing
import Foundation
@testable import Notifable

/// Lo que va del correo al gasto antes de que lo vea un lector: los correos
/// que fallan no se pierden, el HTML se traduce entero, el Quoted-Printable
/// no se aplica dos veces y la hora del banco es la de Perú.
@Suite(.serialized)
struct EmailReadingTests {

    // MARK: - Correos que no se pudieron descargar

    private func freshDefaults() -> UserDefaults {
        let name = "EmailReadingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func fallidoQuedaPendienteYSaleAlLeerse() {
        let d = freshDefaults()
        #expect(FailedEmails.record(failed: ["a"], attempted: ["a", "b"], gone: [], defaults: d) == 1)
        #expect(FailedEmails.load(d) == ["a": 1])
        // Siguiente lectura: vuelve a fallar, cuenta el intento.
        FailedEmails.record(failed: ["a"], attempted: ["a"], gone: [], defaults: d)
        #expect(FailedEmails.load(d)["a"] == 2)
        // Por fin se descarga: sale de la lista.
        #expect(FailedEmails.record(failed: [], attempted: ["a"], gone: [], defaults: d) == 0)
        #expect(FailedEmails.load(d).isEmpty)
    }

    @Test func seDejaDeReintentarTrasElTope() {
        let d = freshDefaults()
        for _ in 1..<FailedEmails.maxAttempts {
            FailedEmails.record(failed: ["a"], attempted: ["a"], gone: [], defaults: d)
        }
        #expect(FailedEmails.load(d)["a"] == FailedEmails.maxAttempts - 1)
        FailedEmails.record(failed: ["a"], attempted: ["a"], gone: [], defaults: d)
        #expect(FailedEmails.load(d).isEmpty)
    }

    @Test func borradoEnGmailNoSeReintenta() {
        let d = freshDefaults()
        #expect(FailedEmails.record(failed: ["a", "b"], attempted: ["a", "b"], gone: ["a"], defaults: d) == 1)
        #expect(FailedEmails.load(d) == ["b": 1])
    }

    @Test func otrosPendientesNoSeTocan() {
        let d = freshDefaults()
        FailedEmails.record(failed: ["viejo"], attempted: ["viejo"], gone: [], defaults: d)
        // Una lectura que no lo intentó no lo borra ni le suma.
        FailedEmails.record(failed: ["nuevo"], attempted: ["nuevo", "otro"], gone: [], defaults: d)
        #expect(FailedEmails.load(d) == ["viejo": 1, "nuevo": 1])
    }

    // MARK: - HTML

    @Test func entidadesConNombreYNumericas() {
        #expect(GmailSyncService.decodeHTMLEntities("Operaci&#243;n") == "Operación")
        #expect(GmailSyncService.decodeHTMLEntities("Operaci&#xF3;n") == "Operación")
        #expect(GmailSyncService.decodeHTMLEntities("&Aacute;REA &amp; CA&Ntilde;A") == "ÁREA & CAÑA")
        #expect(GmailSyncService.decodeHTMLEntities("S/&nbsp;10.00 S/&#160;5") == "S/ 10.00 S/ 5")
        #expect(GmailSyncService.decodeHTMLEntities("&bull; Monto") == " Monto")
    }

    @Test func entidadDesconocidaSeQuedaIgual() {
        #expect(GmailSyncService.decodeHTMLEntities("a &foo; b & c") == "a &foo; b & c")
        // `&amp;lt;` es el texto «&lt;», no «<».
        #expect(GmailSyncService.decodeHTMLEntities("&amp;lt;") == "&lt;")
    }

    // MARK: - Quoted-Printable

    @Test func textoYaDecodificadoNoSeToca() {
        #expect(!GmailSyncService.looksQuotedPrintable("https://bcp.com/?id=AB12 Monto S/ 10.00"))
        #expect(GmailSyncService.looksQuotedPrintable("Operaci=C3=B3n de pago=\nrealizada"))
        #expect(GmailSyncService.looksQuotedPrintable("<td class=3D\"x\">"))
    }

    // MARK: - Hora del banco

    @Test func horaDelBancoEsLaDePeruAunqueElTelefonoEsteFuera() throws {
        let original = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Europe/Madrid")!
        defer { NSTimeZone.default = original }

        let text = "Realizaste una transferencia de S/ 10.00 desde tu Cuenta de ahorros "
            + "Total cobrado S/ 10.00 Enviado a JUAN PEREZ **** 0144 Banco destino Interbank "
            + "Fecha y hora 28 de septiembre de 2026 - 08:34 PM"
        let expense = try #require(BCPParser().parse(cleanText: text))

        // 20:34 en Lima (UTC−5) son las 01:34 UTC del 29.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute], from: expense.date)
        #expect(parts.year == 2026 && parts.month == 9 && parts.day == 29)
        #expect(parts.hour == 1 && parts.minute == 34)
    }

    // MARK: - Consumo con tarjeta de crédito en dólares

    @Test func consumoEnDolaresConTarjetaDeCredito() throws {
        // Lo que queda del HTML del correo de BCP sin etiquetas.
        let text = "Hola   Alejandro Gabriel,   Realizaste un consumo de   $ 8.03   con tu   Tarjeta de Crédito BCP   en   STEAMGAMES.COM   4259522985.   "
            + "Por tu seguridad, te enviamos los datos de tu operación.   Monto   Total del consumo   $ 8.03   "
            + "Datos de la operación   Operación realizada   Consumo Tarjeta de Crédito   Fecha y hora   01 de octubre de 2026 - 08:14 PM   "
            + "Número de Tarjeta de Crédito   ************3753   Empresa   STEAMGAMES.COM   4259522985   Número de operación   0000577330"
        let expense = try #require(BCPParser().parse(cleanText: text))
        #expect(expense.amount == 8.03)
        #expect(expense.currency == "USD")
        #expect(expense.merchant == "STEAMGAMES.COM 4259522985")
        #expect(expense.cardLastDigits == "3753")
    }

    @Test func consumoEnDolaresEnTextoPlano() throws {
        // La parte text/plain trae cada valor entre asteriscos.
        let text = "Realizaste un consumo de *$ 23.60* con tu *Tarjeta de Crédito BCP* en *ANTHROPIC* CLAUDE SUB.* "
            + "Por tu seguridad, te enviamos los *datos de tu operación.* *Monto* Total del consumo *$ 23.60* "
            + "Operación realizada *Consumo Tarjeta de Crédito* Fecha y hora *01 de octubre de 2026 - 06:50 PM* "
            + "Número de Tarjeta de Crédito *************3753* Empresa *ANTHROPIC* CLAUDE SUB* Número de operación *0000079120*"
        let expense = try #require(BCPParser().parse(cleanText: text))
        #expect(expense.amount == 23.60)
        #expect(expense.currency == "USD")
        #expect(expense.merchant == "ANTHROPIC* CLAUDE SUB")
        #expect(expense.cardLastDigits == "3753")

        var lima = Calendar(identifier: .gregorian)
        lima.timeZone = TimeZone(identifier: "America/Lima")!
        let parts = lima.dateComponents([.day, .hour, .minute], from: expense.date)
        #expect(parts.day == 1 && parts.hour == 18 && parts.minute == 50)
    }

    @Test func consumoEnSolesSigueEnSoles() throws {
        let text = "Realizaste un consumo de S/ 42.00 con tu Tarjeta de Débito BCP Total del consumo S/ 42.00 "
            + "Empresa PLAZA VEA Número de operación 123"
        let expense = try #require(BCPParser().parse(cleanText: text))
        #expect(expense.amount == 42)
        #expect(expense.currency == "PEN")
    }
}
