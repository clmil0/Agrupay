#if DEBUG
import Foundation
import SwiftData

/// Modo QA: datos inventados para probar en el simulador sin tocar Gmail ni
/// la nube. Sólo existe en DEBUG y sólo se enciende con el argumento de
/// arranque `-qaFakeData`.
///
/// - La base se siembra con gastos falsos la primera vez (o con `-qaReset`).
/// - Gmail no se llama: la lista y el cuerpo de los correos salen de
///   `emails`, yapeos inventados que pasan por el lector real (`YapeParser`)
///   y por la deduplicación real de `GmailSyncService`.
/// - No arrancan el respaldo en la nube, Amigos ni los recordatorios: nada
///   de esto puede salir del teléfono.
enum QAMode {

    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-qaFakeData") }
    private static var wantsReset: Bool { ProcessInfo.processInfo.arguments.contains("-qaReset") }

    /// Token de mentira: nunca se manda a ningún servidor, porque en modo QA
    /// no se hace ninguna petición a Google.
    static let fakeToken = "qa-fake-token"

    // MARK: - Arranque

    @MainActor
    static func prepare(container: ModelContainer) {
        guard isOn else { return }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "hasSeenOnboarding")
        defaults.set(false, forKey: AppLock.enabledKey)

        let context = container.mainContext
        let count = (try? context.fetchCount(FetchDescriptor<Expense>())) ?? 0
        guard count == 0 || wantsReset else { return }

        try? context.delete(model: Expense.self)
        try? context.delete(model: Income.self)
        for key in ["processedEmailIDs", DeletedEmails.key, DeletedEmails.declinedKey, "lastSyncDate", MerchantRules.key] {
            defaults.removeObject(forKey: key)
        }
        seed(in: context)
        try? context.save()
        // Un límite ya pasado: el globo de Categorías y el numerito del ícono.
        CategoryBudgetStore.shared.save(CategoryBudget(category: "Comida", amount: 50))
        Diagnostics.shared.log("QA: base sembrada con datos falsos")
    }

    // MARK: - Amigos falsos

    /// Amigos, lo que te comparten y cobros inventados, sólo en memoria: el
    /// modo QA no abre sesión en Supabase. `-qaCobro intense` o `-qaCobro soft`
    /// añade un cobro de Vale que llega «ahora» en cada arranque.
    @MainActor
    static func seedSocial() {
        guard isOn else { return }
        func look(_ breed: Int, species: String? = nil) -> PenguinLook {
            var look = PenguinLook()
            look.breed = breed
            look.coat = PenguinBreed.all[breed].coat
            look.beak = PenguinBreed.all[breed].beak
            look.accent = PenguinBreed.all[breed].accent
            look.species = species
            return look
        }
        let friends = FriendsManager.shared
        friends.friends = [
            Friend(id: "qa-vale", displayName: "Vale", status: "Mes tranquilo", penguin: look(1)),
            Friend(id: "qa-alejo", displayName: "Alejo", status: "Ahorrando para volver a Cusco", penguin: look(5)),
            Friend(id: "qa-diego", displayName: "Diego", status: "Modo ahorro", penguin: look(6)),
        ]
        func row(_ id: String, _ total: Double, _ categories: [(String, Double)]) -> FriendShareRow {
            FriendShareRow(id: "qa-share-" + id, sharerID: id, viewerID: "qa-me",
                           shareTotal: true, shareCategories: categories.map(\.0), totalAmount: total,
                           categoryTotals: categories.map { .init(name: $0.0, amount: $0.1) },
                           viewerStatus: "accepted", updatedAt: "")
        }
        friends.acceptedIncoming = [
            row("qa-alejo", 4017.21, [("Comida", 1275), ("Transporte", 353), ("Supermercado", 33),
                                      ("Entretenimiento", 210), ("Salud", 95)]),
            row("qa-vale", 4247.27, [("Transporte", 803)]),
            row("qa-diego", 2340.10, [("Comida", 640), ("Servicios", 188)]),
        ]

        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-qaCobro"),
              arguments.indices.contains(flag + 1),
              let intensity = PaymentReminder.Intensity(rawValue: arguments[flag + 1]) else { return }
        PaymentReminders.shared.seedForQA([
            PaymentReminder(id: "qa-cobro-vale", fromUser: "qa-vale", merchant: "Pizzería Mamma Mia",
                            occurredOn: daysAgo(6), amount: 42.50, currency: "PEN",
                            message: "Lo de la pizza del viernes", createdAt: Date(), intensity: intensity)
        ])
    }

    // MARK: - Gastos a mano

    private static func daysAgo(_ days: Int, hour: Int = 13) -> Date {
        let cal = Period.calendar
        let day = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: Date())) ?? Date()
        return cal.date(byAdding: .hour, value: hour, to: day) ?? day
    }

    /// Del mes en curso a tres meses atrás. Días elegidos para caer en meses
    /// distintos casi siempre: lo que importa es tener pendientes antiguos del
    /// mismo comercio («Los anteriores»).
    private static func seed(in context: ModelContext) {
        let pending = Accounting.unclassified
        let rows: [(String, Double, Int, String)] = [
            // Sin clasificar, varios meses del mismo comercio.
            ("TAMBO+ MIRAFLORES", 12.50, 1, pending),
            ("TAMBO+ MIRAFLORES", 8.90, 3, pending),
            ("TAMBO+ MIRAFLORES", 15.00, 5, pending),
            ("TAMBO+ MIRAFLORES", 6.40, 35, pending),
            ("TAMBO+ MIRAFLORES", 9.99, 40, pending),
            ("TAMBO+ MIRAFLORES", 22.10, 70, pending),
            ("UBER *TRIP", 18.70, 2, pending),
            ("UBER *TRIP", 24.30, 4, pending),
            ("UBER *TRIP", 31.00, 45, pending),
            ("CINEPLANET SALAVERRY", 42.00, 6, pending),
            // Ya clasificados: no deben tocarse.
            ("RAPPI", 35.00, 2, "Comida"),
            ("RAPPI", 27.50, 38, "Comida"),
            ("TAMBO+ MIRAFLORES", 5.00, 50, "Comida"),
        ]
        for (merchant, amount, days, category) in rows {
            let expense = Expense(amount: amount, merchant: merchant, date: daysAgo(days), category: category)
            expense.sourceBank = "BBVA"
            expense.cardLastDigits = "4821"
            context.insert(expense)
        }

        // Un pago dividido con una parte sin clasificar: no debe poder
        // borrarse suelta desde Pendientes.
        let parent = Expense(amount: 90, merchant: "PLAZA VEA SURCO", date: daysAgo(3), category: pending)
        context.insert(parent)
        try? context.save()
        ExpenseSplit.apply([SplitPart(amount: 60, category: "Supermercado", tags: []),
                            SplitPart(amount: 30, category: pending, tags: [])],
                           to: parent, in: context)

        // Un cobro pendiente: la tarjeta Amigos enseña «te deben» y su ojito.
        let debt = Expense(amount: 150, merchant: "PARRILLAS EL GAUCHO", date: daysAgo(4), category: "Comida")
        debt.isDebt = true
        context.insert(debt)

        // Un gasto en dólares, para las cifras mixtas.
        context.insert(Expense(amount: 20, merchant: "NETFLIX.COM", date: daysAgo(8),
                               category: pending, currency: "USD", fxRateAtCapture: 3.75))
    }

    // MARK: - Gmail falso

    struct FakeEmail {
        let id: String
        let receivedAt: Date
        let body: String
    }

    /// Yapeos inventados con la plantilla estándar. El de S/ 1,250.00 está a
    /// propósito: separador de miles en el monto.
    static var emails: [FakeEmail] {
        let items: [(String, String, Int)] = [
            ("qa-yape-01", "25.50", 1),
            ("qa-yape-02", "18.00", 9),
            ("qa-yape-03", "30.00", 33),
            ("qa-yape-04", "12.00", 64),
            ("qa-yape-05", "1,250.00", 12),
        ]
        let names = ["qa-yape-01": "Bodega Don Lucho", "qa-yape-02": "Bodega Don Lucho",
                     "qa-yape-03": "Bodega Don Lucho", "qa-yape-04": "Bodega Don Lucho",
                     "qa-yape-05": "Inmobiliaria Sol"]
        return items.map { id, amount, days in
            let date = daysAgo(days, hour: 13)
            return FakeEmail(id: id, receivedAt: date, body: yapeBody(amount: amount, to: names[id] ?? "Ana", date: date))
        }
    }

    private static func yapeBody(amount: String, to name: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "dd MMMM yyyy - hh:mm a"
        let when = f.string(from: date).lowercased()
            .replacingOccurrences(of: "a. m.", with: "am").replacingOccurrences(of: "p. m.", with: "pm")
        return """
        ¡Yapeaste!
        Monto de yapeo S/ \(amount)
        Nombre del Beneficiario \(name)
        N° de operación 0\(abs(name.hashValue % 9_000_000) + 1_000_000)
        Fecha y Hora de la operación \(when)
        Celular del Beneficiario *** *** 209
        """
    }

    /// Lo que devolvería la búsqueda de Gmail para ese rango.
    static func messageList(startDate: Date?, endDate: Date?, lastSync: Date?) -> [[String: Any]] {
        let from = startDate ?? lastSync.map { $0.addingTimeInterval(-3600) }
        let until = endDate.map { Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: $0) ?? $0 }
        return emails
            .filter { mail in
                (from.map { mail.receivedAt >= $0 } ?? true) && (until.map { mail.receivedAt <= $0 } ?? true)
            }
            .map { ["id": $0.id] }
    }

    static func email(id: String) -> FakeEmail? {
        emails.first { $0.id == id }
    }
}
#endif
