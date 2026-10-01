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
}
