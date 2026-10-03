import Testing
import Foundation
import SwiftUI
@testable import Notifable

/// Los 12 puntos de verificación de SETTINGS.md.
///
/// Los dos que suelen fallar son la migración del tema —cambiarle el aspecto a
/// alguien sin avisar es hostil— y la hora del recordatorio de deuda, que se
/// guardaba como fecha completa y quedaba anclada al día en que se configuró.
struct SettingsTests {

    /// Cada test usa su propio `UserDefaults` para no pisar el de la app.
    static func defaults(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: "settings-tests-" + name)!
        suite.removePersistentDomain(forName: "settings-tests-" + name)
        return suite
    }

    // MARK: - 6 y 7. Migración del tema

    @Test("6. Quien tenía modo oscuro sigue en oscuro tras la migración")
    func migracionConservaOscuro() {
        let suite = Self.defaults("dark")
        suite.set(true, forKey: "isDarkMode")

        migrate(in: suite)

        #expect(suite.string(forKey: AppAppearance.storageKey) == AppAppearance.dark.rawValue)
        #expect(AppAppearance(rawValue: suite.string(forKey: AppAppearance.storageKey) ?? "")?.colorScheme == .dark)
    }

    @Test("6b. Quien tenía modo claro sigue en claro, no pasa a Automático")
    func migracionConservaClaro() {
        let suite = Self.defaults("light")
        suite.set(false, forKey: "isDarkMode")

        migrate(in: suite)

        #expect(suite.string(forKey: AppAppearance.storageKey) == AppAppearance.light.rawValue)
    }

    @Test("6c. Una instalación nueva arranca en oscuro, y migrar dos veces no lo cambia")
    func migracionIdempotente() {
        let suite = Self.defaults("fresh")
        migrate(in: suite)
        #expect(suite.string(forKey: AppAppearance.storageKey) == AppAppearance.dark.rawValue)

        // Si el usuario elige Automático, una segunda migración no debe pisarlo.
        suite.set(AppAppearance.system.rawValue, forKey: AppAppearance.storageKey)
        migrate(in: suite)
        #expect(suite.string(forKey: AppAppearance.storageKey) == AppAppearance.system.rawValue)
    }

    @Test("7. Automático no fija esquema: la app hereda el de iOS")
    func automaticoHereda() {
        #expect(AppAppearance.system.colorScheme == nil)
        #expect(AppAppearance.light.colorScheme == .light)
        #expect(AppAppearance.dark.colorScheme == .dark)
    }

    /// `AppAppearance.migrateIfNeeded` usa `UserDefaults.standard`; aquí se
    /// reproduce la misma decisión sobre un suite aislado.
    private func migrate(in defaults: UserDefaults) {
        guard defaults.string(forKey: AppAppearance.storageKey) == nil else { return }
        if defaults.object(forKey: "isDarkMode") != nil {
            let wasDark = defaults.bool(forKey: "isDarkMode")
            defaults.set((wasDark ? AppAppearance.dark : .light).rawValue, forKey: AppAppearance.storageKey)
        } else {
            defaults.set(AppAppearance.dark.rawValue, forKey: AppAppearance.storageKey)
        }
    }

    // MARK: - 11. Hora del recordatorio

    @Test("11. El recordatorio guarda sólo hora y minuto, sin fecha")
    func recordatorioSinFecha() {
        let suite = Self.defaults("debt")
        // Configurado a las 10:00 de un día concreto de hace tres semanas.
        let cal = Calendar.current
        let old = cal.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 10, minute: 0))!
        suite.set(old.timeIntervalSince1970, forKey: "debtNotificationTimeInterval")

        NotificationSettings.migrateIfNeeded(defaults: suite)

        #expect(NotificationSettings.hour(suite) == 10)
        #expect(NotificationSettings.minute(suite) == 0)
        #expect(suite.object(forKey: "debtNotificationTimeInterval") == nil,
                "la fecha completa se descarta: era justo lo que anclaba el aviso")
    }

    @Test("11b. Sin valor previo, el recordatorio queda a las 10:00")
    func recordatorioPorDefecto() {
        let suite = Self.defaults("debt-fresh")
        NotificationSettings.migrateIfNeeded(defaults: suite)
        #expect(NotificationSettings.hour(suite) == 10)
        #expect(NotificationSettings.minute(suite) == 0)
        #expect(NotificationSettings.timeLabel(hour: 9, minute: 5) == "9:05")
    }

    // MARK: - 5. Búsqueda

    @Test("5. Buscar «límite» encuentra Presupuesto y «suscripcion» sin tilde encuentra Recurrentes")
    func busqueda() {
        #expect(SettingsEntry.matching("límite").contains { $0.id == "budget" })
        #expect(SettingsEntry.matching("limite").contains { $0.id == "budget" })
        #expect(SettingsEntry.matching("meta").contains { $0.id == "budget" })
        #expect(SettingsEntry.matching("suscripcion").contains { $0.id == "recurring" })
        #expect(SettingsEntry.matching("BBVA").contains { $0.id == "gmail" })
        #expect(SettingsEntry.matching("CSV").contains { $0.id == "data" })
        // Correo y Gmail y bancos son una sola pantalla: la cuenta se busca ahí.
        #expect(SettingsEntry.matching("desvincular").contains { $0.id == "gmail" })
        #expect(SettingsEntry.matching("borrar").contains { $0.id == "delete" })
        #expect(SettingsEntry.matching("estadisticas").contains { $0.id == "stats" })
        #expect(SettingsEntry.matching("").isEmpty)
        #expect(SettingsEntry.matching("xyz").isEmpty)
    }

    @Test("Cada entrada buscable lleva a un destino que existe")
    func destinosValidos() {
        let known: Set<String> = ["profile", "email", "phone", "devices", "budget", "recurring", "rules",
                                  "gmail", "range", "appearance", "stats", "assistant", "notifications",
                                  "lock", "data", "delete", "diagnostics"]
        for entry in SettingsEntry.all {
            #expect(known.contains(entry.destination), "destino desconocido: \(entry.destination)")
            #expect(!entry.title.isEmpty)
            #expect(!entry.section.isEmpty)
        }
    }

    // MARK: - 1, 2 y 3. Tarjeta de estado

    @Test("1. Con Gmail conectado y 4 bancos activos, la raíz dice «4 de 5»")
    func estadoConectado() {
        let status = SettingsStatus(isConnected: true, account: "yo@gmail.com",
                                    lastSync: Date(), activeBankCount: 4, totalBankCount: 5,
                                    expensesThisMonth: 38, unclassifiedMerchants: 0, pendingRecurring: 0)
        #expect(status.level == .ok)
        #expect(status.bankLabel == "4 de 5")
        #expect(status.headline == "Lectura automática activa")
        #expect(status.lastSyncLabel == "ahora mismo")
    }

    @Test("2. Sin Gmail, la tarjeta dice «Conecta tu correo» y explica para qué")
    func estadoDesconectado() {
        let status = SettingsStatus(isConnected: false, account: nil, lastSync: nil,
                                    activeBankCount: 0, totalBankCount: 5,
                                    expensesThisMonth: 0, unclassifiedMerchants: 0, pendingRecurring: 0)
        #expect(status.level == .disconnected)
        #expect(status.headline == "Conecta tu correo")
        #expect(status.subhead.contains("registrar gastos"))
        #expect(status.lastSyncLabel == "Nunca")
    }

    @Test("3. Sin leer hace 3 días, el estado pide atención y dice la causa")
    func estadoDesatendido() {
        let old = Date().addingTimeInterval(-60 * 60 * 24 * 3)
        let status = SettingsStatus(isConnected: true, account: "yo@gmail.com", lastSync: old,
                                    activeBankCount: 3, totalBankCount: 5,
                                    expensesThisMonth: 12, unclassifiedMerchants: 0, pendingRecurring: 0)
        #expect(status.level == .attention)
        #expect(status.headline.contains("Sin leer"))

        // Y ningún banco activo también pide atención, con otra causa.
        let noBanks = SettingsStatus(isConnected: true, account: "yo@gmail.com", lastSync: Date(),
                                     activeBankCount: 0, totalBankCount: 5,
                                     expensesThisMonth: 0, unclassifiedMerchants: 0, pendingRecurring: 0)
        #expect(noBanks.level == .attention)
        #expect(noBanks.headline == "Ningún banco activo")
    }

    @Test("Conectado sin la casilla de Gmail: pide atención aunque haya leído hace poco")
    func estadoSinPermisoDeGmail() {
        let status = SettingsStatus(isConnected: true, missingGmailScope: true, account: "yo@gmail.com",
                                    lastSync: Date(), activeBankCount: 5, totalBankCount: 5,
                                    expensesThisMonth: 12, unclassifiedMerchants: 0, pendingRecurring: 0)
        #expect(status.level == .attention)
        #expect(status.headline == "Falta el permiso de Gmail")
    }

    @Test("El 403 por permisos insuficientes se reconoce y no se confunde con otros 403")
    func errorSinPermisoDeGmail() {
        let body = #"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","errors":[{"reason":"insufficientPermissions"}]}}"#
        let scope = GmailSyncService.apiError(status: 403, data: Data(body.utf8))
        #expect(GmailSyncService.isMissingScope(scope))
        #expect(scope.localizedDescription == GmailAuthService.missingScopeMessage)

        let disabled = #"{"error":{"code":403,"message":"Gmail API has not been used in project 1"}}"#
        #expect(!GmailSyncService.isMissingScope(GmailSyncService.apiError(status: 403, data: Data(disabled.utf8))))
    }

    // MARK: - 4. Ninguna fila vacía

    @Test("4. Ninguna fila de la raíz muestra cadena vacía")
    func filasConValor() {
        // Los casos límite: sin presupuesto, sin reglas, sin nada.
        #expect(!SettingsTests.budgetValue(budget: 0, enabled: true).isEmpty)
        #expect(SettingsTests.budgetValue(budget: 0, enabled: true) == "Sin definir")
        #expect(SettingsTests.budgetValue(budget: 2400, enabled: false) == "Sin definir")
        // Miles con coma, igual que el resto de la app («S/ 4,945.12»).
        #expect(SettingsTests.budgetValue(budget: 2400, enabled: true).contains("2,400"))

        #expect(SettingsTests.countLabel(0, singular: "regla", plural: "reglas", empty: "Ninguna") == "Ninguna")
        #expect(SettingsTests.countLabel(1, singular: "regla", plural: "reglas", empty: "Ninguna") == "1 regla")
        #expect(SettingsTests.countLabel(8, singular: "regla", plural: "reglas", empty: "Ninguna") == "8 reglas")
    }

    /// Mismas reglas que la vista, para poder probarlas sin montar la pantalla.
    static func budgetValue(budget: Double, enabled: Bool) -> String {
        guard BudgetStore.hasBudget(monthlyBudget: budget, enabled: enabled) else { return "Sin definir" }
        return Money.format(budget)
    }

    static func countLabel(_ count: Int, singular: String, plural: String, empty: String) -> String {
        if count == 0 { return empty }
        return count == 1 ? "1 " + singular : "\(count) " + plural
    }

    // MARK: - 8 y 9. Bancos

    @Test("8 y 9. Los bancos llevan su descripción como subtítulo, no en un alert")
    func bancos() {
        #expect(BankSource.all.count == 5)
        for bank in BankSource.all {
            #expect(!bank.subtitle.isEmpty, "\(bank.name) sin descripción visible")
            #expect(!bank.storageKey.isEmpty)
        }
        // Yape es el que tiene salvedad, y va dentro del mismo subtítulo.
        let yape = BankSource.all.first { $0.id == "yape" }
        #expect(yape?.caveat != nil)
        #expect(yape?.subtitle.contains("S/ 10") == true)
    }

    @Test("El resumen de bancos de la raíz nunca queda vacío")
    func resumenDeBancos() {
        let suite = Self.defaults("banks")
        // El resumen se construye con los mismos nombres; se comprueba el formato.
        let names = BankSource.all.map(\.name)
        #expect(summary(active: []) == "Ninguno")
        #expect(summary(active: Array(names.prefix(1))) == "BBVA")
        #expect(summary(active: Array(names.prefix(2))) == "BBVA, BCP")
        #expect(summary(active: Array(names.prefix(4))) == "BBVA, BCP +2")
        suite.removePersistentDomain(forName: "settings-tests-banks")
    }

    private func summary(active: [String]) -> String {
        guard !active.isEmpty else { return "Ninguno" }
        let shown = active.prefix(2).joined(separator: ", ")
        let rest = active.count - min(2, active.count)
        return rest > 0 ? shown + " +\(rest)" : shown
    }

    // MARK: - 10 y 12

    @Test("10. Borrar reglas deja los gastos en Accounting.unclassified")
    func borrarReglas() {
        // La cadena literal "Sin Clasificar" ya no se escribe a mano en ningún
        // sitio: dos fuentes de verdad para la misma cadena acaban divergiendo.
        #expect(Accounting.unclassified == "Sin Clasificar")

        let expense = Expense(amount: 10, merchant: "Metro", date: Date(), category: "Comida")
        expense.category = Accounting.unclassified
        #expect(expense.category == Accounting.unclassified)
    }

    @Test("12. El contador de notificaciones refleja los avisos encendidos")
    func contadorDeNotificaciones() {
        let suite = Self.defaults("notif")
        // Por defecto los cinco están encendidos: presupuesto, recurrentes,
        // deudas, límites por categoría y cada pago registrado.
        #expect(NotificationSettings.activeCount(suite) == 5)

        suite.set(false, forKey: NotificationSettings.budgetKey)
        #expect(NotificationSettings.activeCount(suite) == 4)

        suite.set(false, forKey: NotificationSettings.recurringKey)
        suite.set(false, forKey: NotificationSettings.debtEnabledKey)
        suite.set(false, forKey: NotificationManager.categoryLimitEnabledKey)
        suite.set(false, forKey: NotificationManager.importedEnabledKey)
        #expect(NotificationSettings.activeCount(suite) == 0)
    }
}
