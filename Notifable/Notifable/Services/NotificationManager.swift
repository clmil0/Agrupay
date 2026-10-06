import Foundation
import SwiftData
import UIKit
import UserNotifications

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() {}

    /// Se pide al arrancar (con el onboarding ya visto). Antes sólo lo pedía
    /// el menú de marcar "por cobrar", y esa llamada se fue con el rediseño de
    /// las filas: en una instalación nueva el permiso no se pedía nunca, así
    /// que iOS descartaba en silencio todos los avisos.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                Diagnostics.shared.log("Notificaciones: error pidiendo permiso: \(error.localizedDescription)")
            } else {
                Diagnostics.shared.log("Notificaciones: permiso \(granted ? "concedido" : "denegado")")
            }
            // Los recordatorios de un amigo llegan por APNs: sin token
            // registrado no hay a dónde mandarlos.
            if granted { PaymentReminders.registerForPushIfAllowed() }
        }
    }

    /// Sin delegado, iOS no muestra nada si la app está abierta, y el aviso de
    /// límite se dispara justo al registrar un gasto: casi siempre con la app
    /// en primer plano.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Un cobro con la app abierta: se pide ya, y si es intenso sale su
        // modal sin esperar al tiempo real.
        if notification.request.content.userInfo["reminderId"] != nil {
            Task { @MainActor in await PaymentReminders.shared.refresh() }
        }
        completionHandler([.banner, .list, .sound])
    }

    /// Tocar un aviso lo lleva a donde corresponde: los recordatorios de un
    /// amigo, a Amigos. El enlace viaja en el propio aviso (`deepLink`), así
    /// que el servidor puede mandar a otra parte sin tocar la app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let type = Self.analyticsType(of: response.notification.request.identifier, info: info)
        Analytics.track(.notificationOpened, ["type": type])
        Task { @MainActor in AppOpenTracker.note("notification", ["notification": type]) }
        if info["reminderId"] != nil {
            Task { @MainActor in await PaymentReminders.shared.refresh() }
        }
        if let link = info["deepLink"] as? String, let url = URL(string: link) {
            DispatchQueue.main.async { UIApplication.shared.open(url) }
        }
        completionHandler()
    }

    // MARK: - Vigilancia

    private var container: ModelContainer?
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?

    /// Igual que `WidgetSnapshotWriter`: escucha cada guardado de SwiftData y
    /// recalcula los avisos que dependen de los datos (cobros pendientes y
    /// límites por categoría). Así da igual si el gasto llegó del correo, de
    /// Siri o del formulario; ninguna vista tiene que acordarse de avisar.
    @MainActor
    func start(container: ModelContainer) {
        UNUserNotificationCenter.current().delegate = self
        guard self.container == nil else { return }
        self.container = container

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { note in
            // La caché de amigos no cambia ningún aviso (`SocialCacheSave`).
            guard !SocialCacheSave.isCacheOnly(note) else { return }
            Task { @MainActor in NotificationManager.shared.scheduleRefresh() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { _ in
            Task { @MainActor in NotificationManager.shared.scheduleRefresh() }
        })
        scheduleRefresh()
    }

    /// Vuelve a contar avisos y el numerito del ícono (al volver a la app o
    /// al cambiar un límite, que no pasa por SwiftData).
    @MainActor
    func recount() { scheduleRefresh() }

    @MainActor
    private func scheduleRefresh() {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            await ScrollActivity.idle()   // lee la base en el hilo principal
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    @MainActor
    private func refreshNow() {
        guard let context = container?.mainContext else { return }
        let defaults = UserDefaults.standard

        let debtDescriptor = FetchDescriptor<Expense>(predicate: #Predicate { $0.isDebt == true })
        let hasDebts = ((try? context.fetchCount(debtDescriptor)) ?? 0) > 0
        updateDebtNotification(hasDebts: hasDebts)

        let month = Period(granularity: .mes, reference: Date())
        let range = month.interval
        let start = range.start, end = range.end
        let monthDescriptor = FetchDescriptor<Expense>(predicate: #Predicate { $0.date >= start && $0.date < end })
        let monthExpenses = (try? context.fetch(monthDescriptor)) ?? []
        let spent = Accounting.totals(expenses: monthExpenses, incomes: [], period: month,
                                      usdToPen: ExchangeRateService.storedRate).spent
        updateBudgetNotice(spent: spent, month: month)

        // El numerito del ícono: los pendientes de este mes, como la tarjeta.
        let unclassifiedName = Accounting.unclassified
        let pending = monthExpenses.filter {
            $0.category == unclassifiedName && !$0.isTransfer && !$0.isVoided && !$0.isReversal && !$0.isSplit
        }.count

        let budgets = CategoryBudgetStore.shared.budgets.values.filter(\.hasLimit)
        let limitsEnabled = defaults.object(forKey: NotificationManager.categoryLimitEnabledKey) as? Bool ?? true
        guard !budgets.isEmpty else {
            AppBadge.update(pending: pending, overLimits: 0)
            return
        }

        // El ciclo actual y el anterior (por el sobrante) caben de sobra en
        // dos años, aunque el límite sea anual.
        let since = Calendar.current.date(byAdding: .year, value: -2, to: Date()) ?? .distantPast
        let descriptor = FetchDescriptor<Expense>(predicate: #Predicate { $0.date >= since })
        let snapshots = ((try? context.fetch(descriptor)) ?? []).map(\.accountingSnapshot)
        let rate = ExchangeRateService.storedRate
        let statuses = budgets.map { budget in
            CategoryLimits.status(category: budget.category, budget: budget,
                                  expenses: snapshots, on: Date(), usdToPen: rate)
        }
        updateCategoryLimitNotices(statuses, enabled: limitsEnabled)
        AppBadge.update(pending: pending, overLimits: statuses.filter(\.isOver).count)
    }
    
    /// Qué aviso se tocó, sin nada de su texto.
    static func analyticsType(of identifier: String, info: [AnyHashable: Any]) -> String {
        if info["reminderId"] != nil { return "payment_reminder" }
        if identifier.hasPrefix("imported-") { return "imported" }
        if identifier.hasPrefix("categoryLimit-") { return "category_limit" }
        switch identifier {
        case debtReminderID:      return "debt_reminder"
        case recurringReminderID: return "recurring"
        case budgetNoticeID:      return "budget"
        default:                  return "other"
        }
    }

    static let debtReminderID = "dailyDebtReminder"
    static let recurringReminderID = "recurringPendingReminder"

    func updateDebtNotification(hasDebts: Bool) {
        let center = UNUserNotificationCenter.current()
        // Sólo el suyo: `removeAllPendingNotificationRequests` borraba también
        // el recordatorio de recurrentes.
        center.removePendingNotificationRequests(withIdentifiers: [NotificationManager.debtReminderID])

        // El interruptor de Ajustes se respeta aquí y no en cada llamador:
        // varios lo ignoraban y volvían a programar el aviso ya apagado.
        let enabled = UserDefaults.standard.object(forKey: NotificationSettings.debtEnabledKey) as? Bool ?? true
        if hasDebts && enabled {
            let content = UNMutableNotificationContent()
            content.title = "Tienes cobros pendientes"
            content.body = "Hay dinero que aún no te devuelven. ¡Revisa tu resumen!"
            content.sound = .default
            
            // Hora y minuto, no una fecha completa: antes se guardaba un
            // `timeIntervalSince1970` y el recordatorio quedaba anclado al día
            // en que se configuró.
            var dateComponents = DateComponents()
            dateComponents.hour = NotificationSettings.hour()
            dateComponents.minute = NotificationSettings.minute()
            // El día lo elige el usuario en Notificaciones (`4j`); antes era
            // el día de la semana (o del mes) en que tocó el ajuste.
            let frequency = UserDefaults.standard.string(forKey: NotificationSettings.debtFrequencyKey) ?? "Diario"
            if frequency == "Semanal" {
                dateComponents.weekday = NotificationSettings.weekday()
            } else if frequency == "Mensual" {
                dateComponents.day = NotificationSettings.monthDay()
            }
            
            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(identifier: NotificationManager.debtReminderID, content: content, trigger: trigger)
            
            center.add(request) { error in
                if let error = error {
                    print("Error programando notificación de deuda: \(error.localizedDescription)")
                } else {
                    print("Notificación de deuda programada para: \(dateComponents) (\(frequency))")
                }
            }
        } else {
            print("No hay deudas. Notificaciones canceladas.")
        }
    }

    // MARK: - Presupuesto del mes

    private static let budgetNoticeID = "monthlyBudgetNotice"
    private static let budgetStateKey = "budgetNoticeState"

    /// Hasta dónde llegó el mes, de menos a más grave. Se avisa sólo al
    /// **subir** de nivel, una vez por mes: pasar del ritmo y después del 80%
    /// son dos avisos; registrar diez gastos más ya en el 80% no es ninguno.
    enum BudgetNoticeLevel: Int {
        case none = 0, overPace, near, over
    }

    /// Umbral del aviso "cerca", el mismo que promete Ajustes.
    static let budgetNearFraction = 0.8
    /// El ritmo sólo se juzga pasados unos días: el día 1 cualquier gasto ya
    /// va "por encima" de lo esperado, y avisar de eso es ruido.
    static let paceMinimumDays = 5
    /// Holgura sobre lo esperado antes de llamarlo "por encima del ritmo".
    static let paceTolerance = 1.1

    static func budgetLevel(for pace: Pace) -> BudgetNoticeLevel {
        if Money.cents(pace.spent) > Money.cents(pace.target) { return .over }
        if pace.usedFraction >= budgetNearFraction { return .near }
        if pace.period.elapsedDays >= paceMinimumDays,
           Money.cents(pace.spent) > Money.cents(Money.multiply(pace.expectedSpent, by: paceTolerance)) {
            return .overPace
        }
        return .none
    }

    func updateBudgetNotice(spent: Double, month: Period, defaults: UserDefaults = .standard) {
        let enabled = defaults.object(forKey: NotificationSettings.budgetKey) as? Bool ?? true
        let budgetEnabled = defaults.object(forKey: BudgetStore.enabledKey) as? Bool ?? true
        let monthlyBudget = defaults.double(forKey: BudgetStore.monthlyBudgetKey)

        guard enabled,
              let pace = BudgetStore.pace(monthlyBudget: monthlyBudget, enabled: budgetEnabled,
                                          for: month, spent: spent) else {
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: [NotificationManager.budgetNoticeID])
            return
        }

        // Marca = inicio del mes + nivel más alto ya avisado. Un mes nuevo
        // arranca de cero; si un gasto se borra y el nivel baja, no se
        // vuelve a avisar del mismo nivel dentro del mes.
        let monthStamp = String(Int(month.interval.start.timeIntervalSince1970))
        let saved = (defaults.string(forKey: NotificationManager.budgetStateKey) ?? "").split(separator: "|")
        let notified = saved.count == 2 && saved[0] == monthStamp ? Int(saved[1]) ?? 0 : 0

        let level = NotificationManager.budgetLevel(for: pace)
        guard level.rawValue > notified else { return }
        defaults.set(monthStamp + "|" + String(level.rawValue), forKey: NotificationManager.budgetStateKey)

        let content = UNMutableNotificationContent()
        switch level {
        case .over:
            content.title = "Pasaste tu presupuesto del mes"
            content.body = "Llevas " + Money.format(pace.spent) + " de " + Money.format(pace.target)
                + ": " + Money.format(Money.subtract(pace.spent, pace.target)) + " arriba."
        case .near:
            content.title = "Llevas el \(pace.usedPercent)% de tu presupuesto"
            // `remainingDays` no cuenta hoy: el último día del mes vale 0.
            let days = pace.period.remainingDays + 1
            content.body = "Te quedan " + Money.format(pace.remaining) + " para "
                + (days == 1 ? "hoy, el último día del mes." : "los \(days) días que quedan del mes.")
        case .overPace:
            content.title = "Vas por encima de tu ritmo"
            content.body = pace.message
        case .none:
            return
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: NotificationManager.budgetNoticeID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Diagnostics.shared.log("Notificaciones: error en aviso de presupuesto: \(error.localizedDescription)") }
        }
    }

    // MARK: - Límites por categoría

    static let categoryLimitEnabledKey = "categoryLimitAlerts"
    private static let categoryLimitStateKey = "categoryLimitNoticeState"
    private static func categoryLimitID(_ category: String) -> String { "categoryLimit-" + category }

    /// Aviso del límite de una categoría.
    ///
    /// El color de la lista ya cuenta la historia cuando la app está abierta;
    /// esto es para cuando no lo está. Se manda **una vez por ciclo y por
    /// estado**: al cruzar el umbral y al pasarse. Repetirlo cada vez que se
    /// registra un gasto convertiría el aviso en ruido, y un aviso que se
    /// ignora es peor que ninguno.
    func updateCategoryLimitNotices(_ statuses: [CategoryLimitStatus],
                                    enabled: Bool,
                                    defaults: UserDefaults = .standard) {
        let center = UNUserNotificationCenter.current()

        guard enabled else {
            let ids = statuses.map { NotificationManager.categoryLimitID($0.category) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
            defaults.removeObject(forKey: NotificationManager.categoryLimitStateKey)
            return
        }

        var state = defaults.dictionary(forKey: NotificationManager.categoryLimitStateKey) as? [String: String] ?? [:]

        for status in statuses where status.hasLimit {
            let level = status.level
            guard level == .cerca || level == .pasado else {
                state[status.category] = nil
                continue
            }

            // La marca lleva el inicio del ciclo: el mes siguiente vuelve a
            // avisar aunque el estado sea el mismo.
            let stamp = String(Int(status.cycleStart.timeIntervalSince1970)) + "|" + (level == .pasado ? "pasado" : "cerca")
            guard state[status.category] != stamp else { continue }
            state[status.category] = stamp

            let content = UNMutableNotificationContent()
            if level == .pasado {
                content.title = status.category + " pasó su límite"
                content.body = Money.formatCompact(status.overBy) + " arriba de "
                    + Money.formatCompact(status.limit) + ". El límite avisa, no bloquea: puedes seguir registrando."
            } else {
                content.title = status.category + " va por " + Money.formatPercent(status.spent, of: status.limit)
                content.body = "Quedan " + Money.formatCompact(status.remaining)
                    + " para el resto del ciclo (" + status.daysLeftLabel + ")."
            }
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: NotificationManager.categoryLimitID(status.category),
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            )
            center.add(request) { error in
                if let error { print("Error programando aviso de límite: \(error.localizedDescription)") }
            }
        }

        defaults.set(state, forKey: NotificationManager.categoryLimitStateKey)
    }

    // MARK: - Movimiento registrado

    /// Encendido por defecto: es el aviso que enseña que la app sigue leyendo
    /// el correo aunque no la abras.
    static let importedEnabledKey = "notifyImportedMovements"

    /// Un aviso por cada gasto o ingreso que la app registra del correo.
    ///
    /// Uno por movimiento y sin resumir, igual que el del banco: lo que se
    /// quiere comprobar de un vistazo es «esto que acabo de pagar, ¿quedó
    /// anotado?». Llega en silencio (`passive`) porque el banco ya sonó.
    func notifyImported(title: String, amount: Double, currency: String, isIncome: Bool,
                        defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: NotificationManager.importedEnabledKey) as? Bool ?? true else { return }

        let content = UNMutableNotificationContent()
        content.title = isIncome ? "Ingreso registrado" : "Gasto registrado"
        content.body = (isIncome ? "+" : "–") + Money.format(amount, currency: currency)
            + " · " + Accounting.displayName(title)
        content.sound = .default
        content.interruptionLevel = .passive

        let request = UNNotificationRequest(identifier: "imported-" + UUID().uuidString,
                                            content: content, trigger: nil)
        Analytics.track(.notificationSent, ["type": "imported"])
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Diagnostics.shared.log("Notificaciones: error en aviso de movimiento: \(error.localizedDescription)") }
        }
    }

    /// Recordatorio de gastos recurrentes vencidos.
    ///
    /// Sin esto las pendientes se acumulan sin que nadie las vea, y el mes se ve
    /// más barato de lo que es: no cuentan en ningún total hasta confirmarlas.
    func updateRecurringReminder(count: Int, total: Double, merchant: String?, enabled: Bool) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [NotificationManager.recurringReminderID])
        guard enabled, count > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Gastos programados para hoy"
        if count == 1, let merchant {
            content.body = merchant + " " + Money.format(total)
                + " programado para hoy. Confirma o ajusta el monto."
        } else {
            content.body = "\(count) gastos por " + Money.format(total)
                + " esperan tu confirmación. No cuentan en tu mes hasta que los aceptes."
        }
        content.sound = .default

        // A media mañana del mismo día; si ya pasó la hora, en un minuto.
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 10
        comps.minute = 0
        let fireDate = cal.date(from: comps) ?? Date()
        let interval = max(60, fireDate.timeIntervalSinceNow)

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: NotificationManager.recurringReminderID,
                                            content: content, trigger: trigger)
        center.add(request) { error in
            if let error { print("Error programando recordatorio de recurrentes: \(error.localizedDescription)") }
        }
    }
}
