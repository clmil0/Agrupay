import SwiftUI
import SwiftData

/// `6b` — Configurar categoría.
///
/// Antes esta pantalla no existía: una categoría se podía crear y borrar, nada
/// más. No tenía color propio, no tenía límite, y borrar dejaba los gastos en
/// `Sin Clasificar` sin decir cuántos eran.
///
/// Los cambios se guardan al salir del campo, no al pulsar "Listo": "Listo" sólo
/// cierra. La excepción es una categoría **nueva**, que no se escribe hasta que
/// se confirma — si no, salir con el botón de atrás dejaría una categoría vacía.
struct CategorySettingsView: View {

    let category: String
    var isNew: Bool = false
    let history: [Expense]
    /// Se llama con el nombre final (puede haber cambiado) al confirmar.
    var onDone: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    @AppStorage("period") private var period = Period()

    @StateObject private var budgets = CategoryBudgetStore.shared
    @StateObject private var catalog = CategoryCatalog.shared
    @StateObject private var rates = ExchangeRateService.shared

    @State private var name = ""
    @State private var colorID: String?
    @State private var icon: String?
    @State private var draft: CategoryBudget?
    @State private var showingIcons = false
    @State private var showingLimit = false
    @State private var showingMerge = false
    @State private var showingAddMerchant = false
    @State private var confirmingDelete = false
    @State private var infoTopic: BehaviourInfo?
    @State private var merchants: [String] = []
    @State private var loaded = false
    /// No-nil mientras renombrar/fusionar/eliminar recorre todo el historial
    /// de la categoría — sin esto no hay ningún aviso de que el toque se
    /// registró (`Batching`).
    @State private var processingLabel: String?

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var palette: Palette { Palette(scheme) }

    /// Nombre con el que está guardada ahora mismo; cambia al renombrar.
    @State private var currentName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                identity
                limitCard
                // Sin límite no hay nada a lo que avisar ni sobrante que pasar:
                // la sección aparece recién al ponerlo.
                if activeBudget != nil {
                    behaviourSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                merchantsSection
                if !isNew && !CategoryCatalog.isSystem(currentName) {
                    destructiveSection
                }
            }
            .padding(.vertical, 16)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: activeBudget != nil)
        }
        .background(palette.background)
        .navigationTitle(isNew ? "Nueva categoría" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if processingLabel != nil {
                    ProgressView()
                } else {
                    Button("Listo") { finish() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .sheet(isPresented: $showingIcons) { iconPicker }
        .sheet(isPresented: $showingLimit) { limitEditor }
        .sheet(isPresented: $showingMerge) { mergePicker }
        .sheet(isPresented: $showingAddMerchant) { merchantPicker }
        .alert(infoTopic?.title ?? "", isPresented: Binding(get: { infoTopic != nil },
                                                          set: { if !$0 { infoTopic = nil } }),
               presenting: infoTopic) { _ in
            Button("Entendido", role: .cancel) {}
        } message: { topic in
            Text(topic.message)
        }
        .alert("¿Eliminar \(currentName)?", isPresented: $confirmingDelete) {
            Button("Cancelar", role: .cancel) {}
            Button("Eliminar", role: .destructive) { deleteCategory() }
        } message: {
            Text(deleteMessage)
        }
        .overlay {
            if let label = processingLabel {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(label)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(palette.label)
                    }
                    .padding(20)
                    .background(palette.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                }
                .transition(.opacity)
            }
        }
        .onAppear(perform: load)
    }

    // MARK: - Carga

    private func load() {
        guard !loaded else { return }
        loaded = true
        currentName = category
        name = category
        let entry = catalog.entry(for: category)
        colorID = entry?.colorID
        icon = entry?.icon
        draft = budgets.record(for: category)
        merchants = CategoryEditor.merchants(for: category)
    }

    private var referenceDate: Date { CategoryLimits.referenceDate(for: period) }
    private var snapshots: [ExpenseSnapshot] { history.map(\.accountingSnapshot) }

    private var activeName: String {
        isNew ? name : currentName
    }

    private var color: Color {
        CategoryPalette.color(for: colorID)
            ?? CategoryStyle.defaultColor(for: activeName, accent: accent.color)
    }

    private var status: CategoryLimitStatus {
        CategoryLimits.status(category: currentName,
                              budget: activeBudget,
                              expenses: snapshots,
                              on: referenceDate,
                              usdToPen: rates.usdToPenRate)
    }

    /// El límite que se está mostrando: el borrador si lo hay.
    private var activeBudget: CategoryBudget? {
        guard let draft, draft.hasLimit else { return nil }
        return draft
    }

    private var average: Double? {
        guard let budget = activeBudget else { return nil }
        return CategoryLimits.average(budget: budget,
                                      expenses: snapshots,
                                      on: referenceDate,
                                      usdToPen: rates.usdToPenRate)
    }

    // MARK: - Identidad

    private var identity: some View {
        HStack(spacing: 13) {
            // El cuadro mismo abre el selector: es lo primero que se toca
            // para cambiar el ícono. El lápiz dice que se puede.
            Button { showingIcons = true } label: {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(color.opacity(0.22))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: icon ?? CategoryStyle.defaultIcon(for: activeName))
                            .font(.title2)
                            .foregroundStyle(color)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(color, in: Circle())
                            .overlay(Circle().stroke(palette.background, lineWidth: 2))
                            .offset(x: 5, y: 5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cambiar ícono")

            VStack(alignment: .leading, spacing: 6) {
                TextField("Nombre", text: $name)
                    .font(.title.bold())
                    .foregroundStyle(palette.label)
                    .disabled(!isNew && CategoryCatalog.isSystem(currentName))
                    .onSubmit {
                        processingLabel = "Guardando…"
                        Task {
                            await renameIfNeeded()
                            processingLabel = nil
                        }
                    }

                colorRow
            }
        }
        .padding(.horizontal, 20)
    }

    private var colorRow: some View {
        HStack(spacing: 7) {
            ForEach(CategoryPalette.primary) { option in
                Button { pick(option.id) } label: {
                    Circle()
                        .fill(option.color)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .stroke(option.color, lineWidth: colorID == option.id ? 1.5 : 0)
                                .padding(-3)
                        )
                }
                .buttonStyle(.plain)
            }

            Button { showingIcons = true } label: {
                Text("Icono")
                    .font(.caption)
                    .foregroundStyle(accent.onSurface(scheme))
                    .padding(.leading, 2)
            }
            .buttonStyle(.plain)
        }
    }

    private func pick(_ id: String) {
        colorID = colorID == id ? nil : id
        persistIdentity()
    }

    // MARK: - Tarjeta del límite

    private var limitCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("LÍMITE TENTATIVO · " + (draft?.cycle.headerLabel ?? "MENSUAL"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.secondaryLabel)
                Spacer()
                if activeBudget != nil {
                    Button("Editar") { showingLimit = true }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(accent.onSurface(scheme))
                }
            }

            if activeBudget != nil {
                limitBody
            } else {
                Button { showingLimit = true } label: {
                    Text("Poner un límite")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accent.onSurface(scheme))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .background(accent.softFill(scheme))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .surfaceCard(radius: 20)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var limitBody: some View {
        let state = status

        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Money.formatCompact(state.limit))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(palette.label)
            Text(draft?.cycle.amountSuffix ?? "al mes")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryLabel)
        }

        LimitBar(fraction: state.fraction,
                 paceFraction: state.elapsedFraction,
                 color: state.level.color(palette),
                 height: 10)

        HStack {
            Text(state.longLabel)
                .font(.footnote.weight(.medium))
                .foregroundStyle(state.level.color(palette))
            Spacer()
            Text(state.daysLeftLabel)
                .font(.footnote)
                .foregroundStyle(palette.secondaryLabel)
        }

        if state.carriedOver > 0 {
            Text("Incluye " + Money.formatCompact(state.carriedOver) + " que traspasaste del ciclo anterior.")
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
        }

        averageRow
    }

    /// Sólo aparece si el límite queda por debajo del promedio real: un límite
    /// que se incumple siempre entrena al usuario a ignorar los avisos.
    @ViewBuilder
    private var averageRow: some View {
        if let average, let budget = activeBudget, budget.amount < average * 0.95 {
            let proposal = CategoryLimits.suggestedLimit(from: average)
            HStack(spacing: 10) {
                Text(averageText(average: average, limit: budget.amount))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button { useAverage(proposal) } label: {
                    Text("Usar " + String(Int(proposal)))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(palette.warning)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(palette.warning.opacity(scheme == .dark ? 0.14 : 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(palette.warning.opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    private func averageText(average: Double, limit: Double) -> String {
        "Tu promedio real de 3 ciclos es " + Money.formatCompact(average)
            + ": con " + Money.formatCompact(limit) + " te pasarías casi siempre."
    }

    private func useAverage(_ amount: Double) {
        guard var budget = draft else { return }
        budget.amount = Money.normalized(amount)
        draft = budget
        persistBudget()
    }

    // MARK: - Cómo se comporta

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("CÓMO SE COMPORTA")

            VStack(spacing: 0) {
                thresholdRow
                separator
                toggleRow(title: "Pasar lo que sobre",
                          detail: rolloverDetail,
                          info: .rollover,
                          isOn: rollsOverBinding)
            }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
        }
    }

    /// "Contar en el presupuesto" se quitó: no se entendía y, además, no
    /// cambiaba nada — sólo alimentaba `assignedTotal`, que ninguna pantalla
    /// muestra. El campo sigue en `CategoryBudget` por los respaldos.
    private var rolloverDetail: String {
        let cycle = draft?.cycle ?? .mes
        let (this, next): (String, String) = {
            switch cycle {
            case .semana:   return ("esta semana", "de la semana siguiente")
            case .quincena: return ("esta quincena", "de la quincena siguiente")
            case .mes:      return ("este mes", "del mes siguiente")
            case .anio:     return ("este año", "del año siguiente")
            }
        }()
        return "Lo que no gastes \(this) se añadirá al límite \(next). Sólo pasa una vez: no se acumula."
    }

    private var thresholdRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Avisarme al llegar al")
                        .foregroundStyle(palette.label)
                    infoButton(.threshold)
                }
                Text(draft?.alertThreshold == nil
                     ? "Sólo te avisamos si te pasas del límite"
                     : "Te enviamos una notificación al gastar ese porcentaje del límite")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Menu {
                Button("50%") { setThreshold(0.5) }
                Button("80%") { setThreshold(0.8) }
                Button("90%") { setThreshold(0.9) }
                Button("Nunca") { setThreshold(nil) }
            } label: {
                HStack(spacing: 4) {
                    Text(thresholdLabel)
                        .foregroundStyle(palette.secondaryLabel)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryLabel)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var thresholdLabel: String {
        guard let value = draft?.alertThreshold else { return "Nunca" }
        return String(Int((value * 100).rounded())) + "%"
    }

    // MARK: - Ayuda de cada opción

    enum BehaviourInfo: String, Identifiable {
        case threshold, rollover
        var id: String { rawValue }

        var title: String {
            switch self {
            case .threshold: return "Avisarme al llegar al…"
            case .rollover:  return "Pasar lo que sobre"
            }
        }

        var message: String {
            switch self {
            case .threshold:
                return "Cuando lo que gastas en esta categoría llega a ese porcentaje del límite, la categoría se marca como «cerca» y te llega una notificación. Si te pasas del límite, te avisamos otra vez.\n\nCon «Nunca» sólo recibes el aviso de que te pasaste."
            case .rollover:
                return "Si el mes pasado tu límite era S/ 500 y gastaste S/ 400, este mes tu límite será S/ 600.\n\nSólo cuenta el mes inmediatamente anterior: lo que sobra no se va sumando mes tras mes. La tarjeta del límite te muestra cuánto se traspasó."
            }
        }
    }

    /// Icono "?" junto al título. Dentro del `Toggle` también funciona: en iOS
    /// el interruptor sólo cambia al tocar el propio switch.
    private func infoButton(_ topic: BehaviourInfo) -> some View {
        Button { infoTopic = topic } label: {
            Image(systemName: "questionmark.circle")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryLabel)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Qué significa " + topic.title)
    }

    private func toggleRow(title: String, detail: String, info: BehaviourInfo, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).foregroundStyle(palette.label)
                    infoButton(info)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
            }
        }
        .tint(palette.positive)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var separator: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(height: 0.5)
            .padding(.leading, 14)
    }

    private var rollsOverBinding: Binding<Bool> {
        Binding(get: { draft?.rollsOver ?? false },
                set: { value in mutate { $0.rollsOver = value } })
    }

    private func setThreshold(_ value: Double?) {
        mutate { $0.alertThreshold = value }
    }

    /// Crea la fila si aún no existe. Con la sección oculta hasta tener
    /// límite, en la práctica siempre existe ya.
    private func mutate(_ change: (inout CategoryBudget) -> Void) {
        var budget = draft ?? CategoryBudget(category: currentName, amount: 0)
        change(&budget)
        draft = budget
        persistBudget()
    }

    // MARK: - Qué cae aquí

    private var merchantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("QUÉ CAE AQUÍ")

            VStack(alignment: .leading, spacing: 11) {
                if merchants.isEmpty {
                    Text("Ningún comercio cae aquí automáticamente todavía.")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryLabel)
                } else {
                    merchantChips
                }

                Button { showingAddMerchant = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                        Text("Añadir un comercio")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(accent.onSurface(scheme))
                }
                .buttonStyle(.plain)
            }
            .surfaceCard(radius: 16, padding: 14)
            .padding(.horizontal, 16)
        }
    }

    private var merchantChips: some View {
        let shown = Array(merchants.prefix(3))
        let extra = merchants.count - shown.count
        return HStack(spacing: 7) {
            ForEach(shown, id: \.self) { merchant in
                Button { removeRule(merchant) } label: {
                    HStack(spacing: 5) {
                        Text(Accounting.displayName(merchant))
                            .lineLimit(1)
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(palette.label)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(palette.track)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(palette.track)
                    .clipShape(Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    /// Quitar el chip borra la regla; **no** reclasifica lo pasado. Mover gastos
    /// por quitar una regla sería una sorpresa desproporcionada para un toque.
    private func removeRule(_ merchant: String) {
        MerchantRules.remove(merchant)
        merchants = CategoryEditor.merchants(for: currentName)
    }

    // MARK: - Zona destructiva

    private var destructiveSection: some View {
        VStack(spacing: 0) {
            Button { showingMerge = true } label: {
                HStack {
                    Text("Fusionar con otra categoría")
                        .foregroundStyle(palette.warning)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            separator

            Button { confirmingDelete = true } label: {
                HStack {
                    Text("Eliminar categoría")
                        .foregroundStyle(palette.negative)
                    Spacer()
                    Text(expenseCountLabel)
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryLabel)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private var expenseCount: Int { CategoryEditor.expenseCount(of: currentName, in: history) }

    private var expenseCountLabel: String {
        expenseCount == 1 ? "1 gasto" : "\(expenseCount) gastos"
    }

    private var deleteMessage: String {
        expenseCount == 0
            ? "No tiene gastos. Se borrará también su límite."
            : "Sus \(expenseCount) gastos pasan a Sin Clasificar."
    }

    private func deleteCategory() {
        processingLabel = "Eliminando…"
        Task {
            await CategoryEditor.delete(currentName, in: history)
            try? modelContext.save()
            processingLabel = nil
            dismiss()
        }
    }

    // MARK: - Sheets

    private var iconPicker: some View {
        CategoryIconPicker(selected: icon ?? CategoryStyle.defaultIcon(for: activeName),
                           color: color) { chosen in
            icon = chosen
            persistIdentity()
        }
    }

    private var limitEditor: some View {
        CategoryLimitEditorView(
            category: currentName,
            color: color,
            budget: draft ?? CategoryBudget(category: currentName, amount: 0),
            history: history
        ) { saved in
            draft = saved
            persistBudget()
        }
    }

    private var mergePicker: some View {
        CategoryMergePicker(source: currentName,
                            options: mergeOptions,
                            history: history) { target in
            processingLabel = "Fusionando…"
            Task {
                await CategoryEditor.merge(currentName, into: target, in: history)
                try? modelContext.save()
                processingLabel = nil
                dismiss()
            }
        }
    }

    private var mergeOptions: [String] {
        CategoryStyle.selectable(history: history).filter { $0 != currentName }
    }

    private var merchantPicker: some View {
        MerchantRulePicker(category: currentName, history: history) { merchant in
            MerchantRules.set(currentName, for: merchant)
            merchants = CategoryEditor.merchants(for: currentName)
        }
    }

    // MARK: - Guardado

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(palette.secondaryLabel)
            .padding(.horizontal, 32)
    }

    private func renameIfNeeded() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentName, !isNew else { return }
        await CategoryEditor.rename(currentName, to: trimmed, in: history)
        try? modelContext.save()
        currentName = trimmed
        if var budget = draft {
            budget.category = trimmed
            draft = budget
        }
        merchants = CategoryEditor.merchants(for: trimmed)
    }

    private func persistIdentity() {
        guard !isNew else { return }
        catalog.save(CustomCategory(name: currentName, colorID: colorID, icon: icon))
    }

    private func persistBudget() {
        guard !isNew, var budget = draft else { return }
        budget.category = currentName
        budgets.save(budget)
    }

    /// "Listo": para una categoría existente sólo cierra —ya está todo escrito—;
    /// para una nueva es el momento en que se crea. Renombrar puede tocar todo
    /// el historial de la categoría, así que es lo único que corre en un
    /// `Task` con aviso — crear una categoría nueva no toca ningún gasto.
    private func finish() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isNew {
            catalog.save(CustomCategory(name: trimmed, colorID: colorID, icon: icon))
            if var budget = draft {
                budget.category = trimmed
                budgets.save(budget)
            }
            onDone?(trimmed)
            dismiss()
        } else {
            processingLabel = "Guardando…"
            Task {
                await renameIfNeeded()
                processingLabel = nil
                onDone?(currentName)
                dismiss()
            }
        }
    }
}

// MARK: - Barra con marca de ritmo

/// La barra del límite. La **marca de ritmo** es la misma pieza que
/// `BudgetHeroCard`: si el relleno va por delante de la línea, vas rápido para
/// lo que queda de ciclo.
struct LimitBar: View {

    let fraction: Double
    var paceFraction: Double? = nil
    let color: Color
    var height: CGFloat = 6

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)

                Capsule()
                    .fill(color)
                    .frame(width: max(0, geo.size.width * CGFloat(min(1, max(0, fraction)))))

                if let paceFraction {
                    Rectangle()
                        .fill(palette.label.opacity(0.55))
                        .frame(width: 2, height: height + 4)
                        .offset(x: geo.size.width * CGFloat(min(1, max(0, paceFraction))) - 1)
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Selectores auxiliares

struct CategoryIconPicker: View {

    let selected: String
    let color: Color
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(CategoryIcons.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Palette(scheme).secondaryLabel)
                                .padding(.horizontal, 4)
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(group.symbols, id: \.self) { symbol in
                                    cell(symbol)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Palette(scheme).background)
            .navigationTitle("Icono")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func cell(_ symbol: String) -> some View {
        Button {
            onPick(symbol)
            dismiss()
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(symbol == selected ? color : Palette(scheme).label)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(symbol == selected ? color.opacity(0.22) : Palette(scheme).surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Fusionar antes que eliminar: mueve los gastos y suma los límites.
struct CategoryMergePicker: View {

    let source: String
    let options: [String]
    let history: [Expense]
    var onMerge: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var target: String?

    var body: some View {
        NavigationStack {
            List(options, id: \.self) { option in
                Button { target = option } label: {
                    HStack {
                        Image(systemName: CategoryStyle.icon(for: option))
                        Text(option)
                        Spacer()
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Fusionar " + source)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .alert("¿Fusionar?", isPresented: Binding(get: { target != nil },
                                                      set: { if !$0 { target = nil } })) {
                Button("Cancelar", role: .cancel) { target = nil }
                Button("Fusionar") {
                    if let target { onMerge(target) }
                    dismiss()
                }
            } message: {
                Text(message)
            }
            .appAppearance()
            .appTextSize()
        }
    }

    private var message: String {
        let count = CategoryEditor.expenseCount(of: source, in: history)
        let movements = count == 1 ? "1 gasto" : "\(count) gastos"
        return "Se moverán " + movements + " a " + (target ?? "") + ". Los límites se suman."
    }
}

/// Añadir un comercio a la categoría: crea la regla, no reclasifica lo pasado.
struct MerchantRulePicker: View {

    let category: String
    let history: [Expense]
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var merchants: [String] {
        let rules = MerchantRules.all()
        let all = Set(history.map(\.merchant)).filter { rules[$0] != category }
        let sorted = all.sorted { Accounting.displayName($0) < Accounting.displayName($1) }
        guard !search.isEmpty else { return sorted }
        return sorted.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(merchants, id: \.self) { merchant in
                Button {
                    onPick(merchant)
                    dismiss()
                } label: {
                    Text(Accounting.displayName(merchant))
                }
                .foregroundStyle(.primary)
            }
            .searchable(text: $search, prompt: "Buscar comercio")
            .navigationTitle("Añadir a " + category)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .appAppearance()
            .appTextSize()
        }
    }
}
