import SwiftUI
import SwiftData

/// Borrar datos por intención.
///
/// Antes esto era una lista plana de acciones irreversibles ("Borrar reglas",
/// "Borrar todos los gastos"...): cada fila era un medio, no un fin, así que
/// el usuario tenía que traducir "quiero volver a leer desde cero" a la fila
/// correcta él mismo. Aquí se elige primero QUÉ SE QUIERE CONSEGUIR y la
/// pantalla muestra, con cifras reales, qué grupos toca esa elección.
struct DeleteDataView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @Query private var expenses: [Expense]
    @Query private var incomes: [Income]
    @Query private var recurringExpenses: [RecurringExpense]
    @Query private var quickExpenses: [QuickExpense]

    @StateObject private var gmailSync = GmailSyncService.shared

    private var palette: Palette { Palette(scheme) }

    enum Intent: String, CaseIterable, Identifiable {
        case reread, reclass, range, wipe
        var id: String { rawValue }

        var title: String {
            switch self {
            case .reread:  return "Volver a leer el correo desde cero"
            case .reclass: return "Reclasificar todo a mano"
            case .range:   return "Sólo un rango de fechas"
            case .wipe:    return "Empezar de cero"
            }
        }

        var subtitle: String {
            switch self {
            case .reread:  return "Los gastos se rearman solos en la próxima lectura."
            case .reclass: return "Se van las reglas, no los gastos."
            case .range:   return "Elimina los gastos de un periodo y libera sus correos."
            case .wipe:    return "Todo lo de arriba, más automatizaciones y preferencias."
            }
        }

        var buttonLabel: String {
            switch self {
            case .reread:  return "Borrar y volver a leer"
            case .reclass: return "Borrar reglas y categorías"
            case .range:   return "Elegir el rango"
            case .wipe:    return "Borrar todo"
            }
        }

        /// Sólo `reclass` no toca ningún `Expense`: las demás borran gastos de
        /// verdad y por eso van en rojo, no en naranja.
        var deletesExpenses: Bool { self != .reclass }
    }

    @State private var selected: Intent?
    @State private var showConfirm = false
    @State private var showRangeSheet = false
    @State private var rangeStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var rangeEnd = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ForEach(Intent.allCases) { intent in
                    intentCard(intent)
                }
            }
            .padding(.vertical, 16)
        }
        .background(palette.background)
        .navigationTitle("Borrar datos")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(dialogTitle, isPresented: $showConfirm, titleVisibility: .visible) {
            Button(selected?.buttonLabel ?? "Borrar", role: .destructive) {
                if let selected { perform(selected) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(dialogMessage)
        }
        .sheet(isPresented: $showRangeSheet) {
            rangeSheet
        }
    }

    // MARK: - Cabecera

    private var header: some View {
        Text("Elige qué quieres conseguir. Cada opción muestra exactamente qué grupos toca y puedes destildar antes de confirmar.")
            .font(.subheadline)
            .foregroundStyle(palette.secondaryLabel)
            .padding(.horizontal, 20)
    }

    // MARK: - Tarjeta de intención

    @ViewBuilder
    private func intentCard(_ intent: Intent) -> some View {
        let isSelected = selected == intent
        let tint = intent.deletesExpenses ? palette.negative : palette.warning

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    selected = isSelected ? nil : intent
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? tint : palette.tertiaryLabel)
                        .font(.system(size: 20))
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(intent.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.label)
                        Text(intent.subtitle)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected {
                VStack(alignment: .leading, spacing: 10) {
                    Rectangle().fill(palette.separator).frame(height: 0.5)
                        .padding(.horizontal, 16)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(rows(for: intent), id: \.label) { row in
                            HStack {
                                Text("× " + row.label)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(tint)
                                Spacer()
                                Text("\(row.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(palette.secondaryLabel)
                            }
                        }
                        Text(intent.deletesExpenses
                             ? "Se conserva todo lo que no aparece en esta lista."
                             : "Ninguna de las filas marcadas borra gastos: sólo estado de lectura y preferencias.")
                            .font(.caption2)
                            .foregroundStyle(palette.tertiaryLabel)
                            .padding(.top, 2)
                    }
                    .padding(.horizontal, 16)

                    actionButton(for: intent, tint: tint)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }
            }
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? tint.opacity(0.4) : palette.hairline, lineWidth: isSelected ? 1 : 0.5)
        )
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func actionButton(for intent: Intent, tint: Color) -> some View {
        Button {
            if intent == .range {
                showRangeSheet = true
            } else {
                showConfirm = true
            }
        } label: {
            Text(intent.buttonLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(rows(for: intent).isEmpty && intent != .range)
    }

    // MARK: - Conteos reales

    private struct Row { let label: String; let count: Int }

    private var ruleCount: Int { MerchantRules.all().count }
    private var customCategoryCount: Int { CategoryCatalog.shared.names.count }
    private var categoryBudgetCount: Int { CategoryBudgetStore.shared.budgets.count }
    private var processedEmailCount: Int {
        (UserDefaults.standard.stringArray(forKey: "processedEmailIDs") ?? []).count
    }
    private var pendingRecoveryCount: Int {
        (UserDefaults.standard.stringArray(forKey: "pendingRecoveryIDs") ?? []).count
    }
    private var expensesWithEmail: [Expense] { expenses.filter { $0.emailID != nil } }
    /// Abonos que se van en cascada al borrar los gastos con correo (los mismos
    /// que declara `@Relationship(deleteRule: .cascade)` en `Expense.payments`).
    private var cascadingPaymentsForReread: Int {
        expensesWithEmail.reduce(0) { $0 + ($1.payments?.count ?? 0) }
    }

    private func rows(for intent: Intent) -> [Row] {
        var result: [Row] = []
        switch intent {
        case .reread:
            if !expensesWithEmail.isEmpty {
                result.append(Row(label: "Gastos importados por correo", count: expensesWithEmail.count))
            }
            if cascadingPaymentsForReread > 0 {
                result.append(Row(label: "Cobros pendientes y sus devoluciones", count: cascadingPaymentsForReread))
            }
            if processedEmailCount > 0 {
                result.append(Row(label: "Correos ya leídos (caché)", count: processedEmailCount))
            }
        case .reclass:
            if ruleCount > 0 {
                result.append(Row(label: "Reglas de comercio", count: ruleCount))
            }
            if customCategoryCount > 0 {
                result.append(Row(label: "Categorías personalizadas", count: customCategoryCount))
            }
        case .range:
            let inRange = expenses.filter { $0.date >= rangeStart && $0.date <= rangeEnd }
            if !inRange.isEmpty {
                result.append(Row(label: "Gastos en el rango elegido", count: inRange.count))
            }
        case .wipe:
            if !expenses.isEmpty { result.append(Row(label: "Gastos", count: expenses.count)) }
            if !incomes.isEmpty { result.append(Row(label: "Ingresos y devoluciones", count: incomes.count)) }
            if !recurringExpenses.isEmpty { result.append(Row(label: "Recurrentes", count: recurringExpenses.count)) }
            if !quickExpenses.isEmpty { result.append(Row(label: "Atajos rápidos", count: quickExpenses.count)) }
            if ruleCount > 0 { result.append(Row(label: "Reglas de comercio", count: ruleCount)) }
            if customCategoryCount > 0 { result.append(Row(label: "Categorías personalizadas", count: customCategoryCount)) }
            if categoryBudgetCount > 0 { result.append(Row(label: "Límites por categoría", count: categoryBudgetCount)) }
            if processedEmailCount > 0 { result.append(Row(label: "Correos en caché", count: processedEmailCount)) }
            if pendingRecoveryCount > 0 { result.append(Row(label: "Recuperables pendientes", count: pendingRecoveryCount)) }
        }
        return result
    }

    // MARK: - Confirmación

    private var dialogTitle: String {
        switch selected {
        case .reread:  return "¿Borrar y volver a leer?"
        case .reclass: return "¿Borrar reglas y categorías?"
        case .wipe:    return "¿Borrar todo?"
        case .range, .none: return ""
        }
    }

    private var dialogMessage: String {
        switch selected {
        case .reread:
            return "Los \(expensesWithEmail.count) gastos importados por correo se borran. Se rearman solos en la próxima lectura."
        case .reclass:
            return "Las \(ruleCount) reglas y \(customCategoryCount) categorías personalizadas se borran. Los \(expenses.count) gastos pasan a \(Accounting.unclassified)."
        case .wipe:
            return "Se borra todo: \(expenses.count) gastos, \(incomes.count) ingresos, tus reglas, categorías y preferencias. No se puede deshacer."
        case .range, .none:
            return ""
        }
    }

    // MARK: - Rango de fechas

    private var rangeSheet: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Desde", selection: $rangeStart, displayedComponents: .date)
                    DatePicker("Hasta", selection: $rangeEnd, displayedComponents: .date)
                } header: {
                    Text("Rango de tiempo")
                } footer: {
                    let count = expenses.filter { $0.date >= rangeStart && $0.date <= rangeEnd }.count
                    Text(count > 0
                         ? "Se eliminarán \(count) gastos dentro de este rango. Sus correos podrán volver a descargarse en la próxima sincronización."
                         : "No hay gastos en este rango todavía.")
                }

                Button(role: .destructive) {
                    deleteExpenses(from: rangeStart, to: rangeEnd)
                    showRangeSheet = false
                } label: {
                    Text("Borrar gastos del rango")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Borrar por fechas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { showRangeSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Ejecución

    private func perform(_ intent: Intent) {
        switch intent {
        case .reread:  deleteReread()
        case .reclass: deleteReclass()
        case .wipe:    deleteWipe()
        case .range:   break // Se ejecuta desde rangeSheet.
        }
        selected = nil
        NotificationManager.shared.updateDebtNotification(hasDebts: hasDebts())
        dismiss()
    }

    private func hasDebts() -> Bool {
        (try? modelContext.fetch(FetchDescriptor<Expense>()))?.contains { $0.isDebt } ?? false
    }

    /// Volver a leer desde cero: sólo los gastos que vinieron de un correo.
    /// Sus abonos se van solos por la relación en cascada.
    private func deleteReread() {
        for expense in expensesWithEmail {
            modelContext.delete(expense)
        }
        do {
            try modelContext.save()
        } catch {
            print("Error al borrar gastos de correo: \(error)")
        }
        gmailSync.resetSyncState()
    }

    /// Reclasificar a mano: se van las reglas y las categorías propias, no
    /// ningún gasto. Cada gasto que tenía categoría pasa a Sin Clasificar.
    private func deleteReclass() {
        UserDefaults.standard.removeObject(forKey: MerchantRules.key)
        CategoryCatalog.shared.removeAll()
        for expense in expenses {
            expense.category = Accounting.unclassified
        }
        do {
            try modelContext.save()
        } catch {
            print("Error al reclasificar: \(error)")
        }
    }

    private func deleteExpenses(from startDate: Date, to endDate: Date) {
        let startOfDay = Calendar.current.startOfDay(for: startDate)
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: endDate) ?? endDate

        do {
            let allExpenses = try modelContext.fetch(FetchDescriptor<Expense>())
            let expensesToDelete = allExpenses.filter { $0.date >= startOfDay && $0.date <= endOfDay }

            var emailIDsToRemove = Set<String>()
            for expense in expensesToDelete {
                if let emailID = expense.emailID {
                    emailIDsToRemove.insert(emailID)
                }
                modelContext.delete(expense)
            }
            try modelContext.save()

            if !emailIDsToRemove.isEmpty {
                var processedIDs = UserDefaults.standard.stringArray(forKey: "processedEmailIDs") ?? []
                processedIDs.removeAll { emailIDsToRemove.contains($0) }
                UserDefaults.standard.set(processedIDs, forKey: "processedEmailIDs")

                var pendingRecoveryIDs = UserDefaults.standard.stringArray(forKey: "pendingRecoveryIDs") ?? []
                pendingRecoveryIDs.removeAll { emailIDsToRemove.contains($0) }
                UserDefaults.standard.set(pendingRecoveryIDs, forKey: "pendingRecoveryIDs")
            }

            NotificationManager.shared.updateDebtNotification(hasDebts: hasDebts())
        } catch {
            print("Error al borrar los datos por rango: \(error)")
        }
    }

    /// Empezar de cero: todo lo demás, más automatizaciones y preferencias.
    private func deleteWipe() {
        // Primero pausar la sincronización: si siguiera encendida subiría este
        // teléfono ya vacío y borraría la copia en la nube.
        ConfigBackupManager.shared.pauseAfterLocalWipe()
        do {
            try modelContext.delete(model: Expense.self)
            try modelContext.delete(model: Income.self)
            try modelContext.delete(model: RecurringExpense.self)
            try modelContext.delete(model: QuickExpense.self)
            try modelContext.save()
        } catch {
            print("Error al borrar todo: \(error)")
        }

        UserDefaults.standard.removeObject(forKey: MerchantRules.key)
        CategoryCatalog.shared.removeAll()
        CategoryBudgetStore.shared.removeAll()
        TagCatalog.shared.removeAll()
        AccountBook.shared.removeAll()

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: BudgetStore.monthlyBudgetKey)
        defaults.removeObject(forKey: BudgetStore.enabledKey)
        defaults.removeObject(forKey: BudgetStore.tracksIncomeKey)
        defaults.removeObject(forKey: "processedEmailIDs")
        FailedEmails.clear(defaults)
        defaults.removeObject(forKey: "lastSyncDate")
        DeletedEmails.clear(defaults)
        for bank in BankSource.all {
            defaults.removeObject(forKey: bank.storageKey)
        }
        defaults.removeObject(forKey: NotificationSettings.budgetKey)
        defaults.removeObject(forKey: NotificationSettings.recurringKey)
        defaults.removeObject(forKey: NotificationSettings.debtEnabledKey)
        defaults.removeObject(forKey: NotificationSettings.debtHourKey)
        defaults.removeObject(forKey: NotificationSettings.debtMinuteKey)
        defaults.removeObject(forKey: AppAppearance.storageKey)

        gmailSync.resetSyncState()
    }
}
