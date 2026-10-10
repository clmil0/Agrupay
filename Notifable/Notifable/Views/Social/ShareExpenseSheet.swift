import SwiftData
import SwiftUI

/// «Compartir gasto» («Soluciones de cobro», 01): con quién y cuánto pone
/// cada uno, en la misma hoja y primero.
///
/// Tu parte va arriba y no cuenta como deuda: de una cena de S/ 120 entre
/// cuatro te deben S/ 90. Alguien sin la app entra en la misma fila de
/// personas. «Avisarles ahora» viene encendido, pero apagarlo sólo anota.
struct ShareExpenseSheet: View {
    let expense: Expense
    /// El aviso que se enseña al volver: «Compartido con 3 personas».
    var onDone: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var friendsManager = FriendsManager.shared
    @State private var offline = OfflineDebts.shared
    @State private var receivables = FriendReceivables.shared

    /// Personas elegidas, en el orden en que se eligieron.
    @State private var selected: [String] = []
    @State private var amounts: [String: String] = [:]
    @State private var mineText = ""
    /// Tu parte la escribiste tú: ya no se recalcula al cambiar las demás.
    @State private var mineEdited = false
    /// Sales del reparto: no pones nada y todo el gasto se le cobra a los
    /// demás (pagaste tú por ellos).
    @State private var includesMe = true
    @State private var notify = true
    @State private var isSaving = false
    @State private var errorText: String?
    @State private var addingContact = false
    @State private var whatsAppQueue: [ReceivableShare] = []
    @State private var didLoad = false

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    private var debtKey: String { TransactionKey.key(for: expense) }
    private var total: Double { expense.amount }
    private var currency: String { expense.currency }
    private func format(_ value: Double) -> String { Money.format(value, currency: currency) }

    /// Lo que ya tiene este gasto: al editar, quien ya pagó algo no se puede
    /// sacar ni bajar de lo que pagó.
    private var existing: [ReceivableShare] { receivables.shares(forDebtKey: debtKey) }
    private func paid(by person: String) -> Double {
        existing.first { $0.debtor == person }?.paidAmount ?? 0
    }

    private var friends: [Friend] { friendsManager.friends }
    private var contacts: [OfflineContact] { offline.contacts }

    private var others: Double { Money.sum(selected) { amounts[$0].flatMap(Money.parse) ?? 0 } }
    private var mine: Double { includesMe ? Money.parse(mineText) ?? 0 : 0 }
    private var assigned: Double { Money.normalized(others + mine) }
    private var balanced: Bool { Money.cents(assigned) == Money.cents(total) }
    private var everyoneHasAmount: Bool {
        selected.allSatisfy { person in
            let value = amounts[person].flatMap(Money.parse) ?? 0
            return Money.cents(value) > 0 && Money.cents(value) >= Money.cents(paid(by: person))
        }
    }
    private var canSave: Bool { !isSaving && balanced && everyoneHasAmount && (!selected.isEmpty || expense.isShared) }

    var body: some View {
        NavigationStack {
            Group {
                if whatsAppQueue.isEmpty { form } else { whatsAppStep }
            }
            .background(palette.background)
            .navigationTitle(whatsAppQueue.isEmpty ? "Compartir gasto" : "Avisar por WhatsApp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(whatsAppQueue.isEmpty ? "Cancelar" : "Listo") { dismiss() }
                }
            }
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(palette.background)
        .sheet(isPresented: $addingContact) {
            AddOfflineContactSheet { contact in
                toggle(contact.personID, forceOn: true)
            }
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            load()
        }
        .trackScreen("share_expense", feature: .paymentReminder)
    }

    // MARK: - Formulario

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                peopleSection
                amountsSection
                notifySection
                if let errorText {
                    ShellNote(icon: "exclamationmark.circle", text: errorText)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { saveBar }
    }

    private var header: some View {
        HStack(spacing: 12) {
            MovementIcon(icon: MovementStyle.icon(for: expense),
                         color: MovementStyle.color(for: expense, accent: accent.color, scheme: scheme))
            VStack(alignment: .leading, spacing: 2) {
                Text(Accounting.displayName(expense.merchant))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                Text(expense.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()
                    .locale(Locale(identifier: "es_ES"))))
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
            }
            Spacer(minLength: 8)
            Text(format(total))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(palette.label)
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
    }

    // MARK: Con quién

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShellSectionHeader(title: "Con quién")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(friends) { friend in
                        chip(id: friend.id, friend: friend, caption: friend.name)
                    }
                    ForEach(contacts) { contact in
                        chip(id: contact.personID, friend: friendsManager.friend(with: contact.personID),
                             caption: contact.name + " · Sin app")
                    }
                    addContactChip
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .padding(.horizontal, -2)
            if friends.isEmpty {
                Text(SupabaseAuthManager.shared.needsGoogleAccount
                     ? "Para compartir con amigos de la app conecta tu cuenta de Google en Amigos. Con quien no tiene la app puedes compartir igual."
                     : "Todavía no tienes amigos en la app. Puedes compartir con alguien sin la app.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chip(id: String, friend: Friend, caption: String) -> some View {
        let isOn = selected.contains(id)
        let locked = isOn && Money.cents(paid(by: id)) > 0
        return Button {
            guard !locked else { return }
            toggle(id)
        } label: {
            VStack(spacing: 6) {
                FriendAvatar(friend: friend)
                    .overlay(Circle().stroke(isOn ? accent.color : .clear, lineWidth: 2.5).padding(-4))
                    .padding(4)
                Text(caption)
                    .font(.system(size: 11.5, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? palette.label : palette.secondaryLabel)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 72)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint(locked ? "Ya te pagó una parte: no se puede quitar" : "")
    }

    private var addContactChip: some View {
        Button { addingContact = true } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(accent.onSurface(scheme))
                    .frame(width: 44, height: 44)
                    .overlay(Circle().strokeBorder(accent.color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .padding(4)
                Text("Alguien sin la app")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 72)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Cuánto pone cada uno

    private var amountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ShellSectionHeader(title: "Cuánto pone cada uno")
                Button("Partes iguales") {
                    withAnimation(.easeInOut(duration: 0.2)) { splitEvenly() }
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(accent.onSurface(scheme))
                .buttonStyle(.plain)
                .disabled(selected.isEmpty)
            }

            VStack(spacing: 0) {
                if includesMe {
                    personRow(friend: nil, name: "Tú", tag: "Tu parte", text: Binding(
                        get: { mineText },
                        set: { mineText = TransactionDraft.sanitizedAmount($0); mineEdited = true }),
                        // Sin nadie más no hay a quién pasarle tu parte.
                        onRemove: selected.isEmpty ? nil : { setIncludesMe(false) },
                        reservesRemoveSpace: true)
                } else {
                    excludedMeRow
                }
                ForEach(selected, id: \.self) { person in
                    Rectangle().fill(palette.separator).frame(height: 0.5).padding(.leading, 60)
                    let friend = friendsManager.friend(with: person)
                    personRow(friend: friend, name: friend.name,
                              tag: OfflineDebts.isContact(person) ? "Sin la app" : nil,
                              text: Binding(
                                get: { amounts[person] ?? "" },
                                set: { setAmount($0, for: person) }),
                              // Quien ya pagó algo no se saca, igual que en su ícono de arriba.
                              onRemove: Money.cents(paid(by: person)) > 0 ? nil : { toggle(person) },
                              reservesRemoveSpace: true)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                footer
            }
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
        }
    }

    /// `onRemove` pone la «x» roja a la izquierda: otra forma de sacar a
    /// alguien del reparto (o a ti), además de volver a tocar su ícono
    /// arriba. `reservesRemoveSpace` guarda su hueco aunque no haya «x», para
    /// que los avatares queden en columna.
    private func personRow(friend: Friend?, name: String, tag: String?, text: Binding<String>,
                           onRemove: (() -> Void)? = nil, reservesRemoveSpace: Bool = false) -> some View {
        HStack(spacing: 10) {
            if let onRemove {
                RemoveFromSplitButton(name: name, action: onRemove)
            } else if reservesRemoveSpace {
                Color.clear.frame(width: RemoveFromSplitButton.size, height: RemoveFromSplitButton.size)
            }
            if let friend {
                FriendAvatar(friend: friend, size: 36)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent.buttonText)
                    .frame(width: 36, height: 36)
                    .background(accent.buttonFill, in: Circle())
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                if let tag {
                    Text(tag)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                Text(currency == "USD" ? "$" : "S/")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize()
                TextField("0.00", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 72)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(palette.neutralSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .fixedSize()
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
    }

    /// Te sacaste del reparto: todo el gasto se cobra a los demás.
    private var excludedMeRow: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: RemoveFromSplitButton.size, height: RemoveFromSplitButton.size)
            Image(systemName: "person.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.secondaryLabel)
                .frame(width: 36, height: 36)
                .background(palette.neutralSurface, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Tú")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)
                    .strikethrough()
                Text("No pones nada")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryLabel)
            }
            Spacer(minLength: 6)
            Button { setIncludesMe(true) } label: {
                Label("Incluirme", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent.onSurface(scheme))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(accent.color.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .transition(.opacity)
    }

    private var footer: some View {
        let diff = Money.subtract(total, assigned)
        return HStack {
            Text("Te deben " + format(others))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.positive)
            Spacer()
            Text(balanced ? "Repartido " + format(assigned) + " de " + format(total)
                 : Money.cents(diff) > 0 ? "Falta repartir " + format(diff)
                 : "Te pasaste " + format(abs(diff)))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(balanced ? palette.secondaryLabel : palette.warning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .top) { Rectangle().fill(palette.separator).frame(height: 0.5) }
    }

    // MARK: Avisar

    private var notifySection: some View {
        Toggle(isOn: $notify) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Avisarles ahora")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.label)
                Text(notifyDetail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(accent.color)
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
    }

    private var notifyDetail: String {
        guard notify else { return "Solo se anota. Puedes recordarles después desde Cobros." }
        let appNames = selected.filter { !OfflineDebts.isContact($0) }.map { friendsManager.friend(with: $0).name }
        let contactNames = selected.filter(OfflineDebts.isContact).map { friendsManager.friend(with: $0).name }
        var parts: [String] = []
        if !appNames.isEmpty {
            parts.append(Self.list(appNames) + (appNames.count == 1 ? " recibe" : " reciben") + " una notificación.")
        }
        if !contactNames.isEmpty {
            parts.append("A " + Self.list(contactNames) + " le llega por WhatsApp.")
        }
        return parts.isEmpty ? "Cada uno recibe lo que le toca." : parts.joined(separator: " ")
    }

    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " y " + names.last!
    }

    private var saveBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(palette.hairline).frame(height: 0.5)
            Button { Task { await save() } } label: {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView().tint(accent.buttonText).controlSize(.small)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                    }
                    Text("Guardar")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(accent.buttonText)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(accent.buttonFill.opacity(canSave ? 1 : 0.4),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(palette.background)
    }

    // MARK: - WhatsApp, uno por uno

    private var whatsAppStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Quedó anotado. Abre WhatsApp para mandarle a cada uno lo que le toca.")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(whatsAppQueue) { share in
                    let friend = friendsManager.friend(with: share.debtor)
                    HStack(spacing: 12) {
                        FriendAvatar(friend: friend, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friend.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(palette.label)
                            Text(Money.format(share.remaining, currency: share.currency))
                                .font(.system(size: 12.5))
                                .foregroundStyle(palette.secondaryLabel)
                        }
                        Spacer()
                        let sent = share.sentToday || offline.debts.contains {
                            OfflineDebts.sharePrefix + $0.id == share.id
                                && $0.reminders.contains(where: Calendar.current.isDateInToday)
                        }
                        Button(sent ? "Enviado" : "WhatsApp") { offline.remindByWhatsApp(share) }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(sent ? palette.secondaryLabel : accent.buttonText)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(sent ? AnyShapeStyle(palette.track) : AnyShapeStyle(accent.buttonFill), in: Capsule())
                            .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(16)
        }
    }

    // MARK: - Lógica

    private func load() {
        let current = existing.filter { $0.status != .archived }
        if let own = expense.ownShare, !current.isEmpty {
            selected = current.map(\.debtor)
            for share in current { amounts[share.debtor] = Money.decimalText(share.amount) }
            mineText = Money.decimalText(own)
            mineEdited = true
            includesMe = Money.cents(own) > 0
            // Al editar un reparto no se vuelve a avisar salvo que lo pidas.
            notify = false
        } else {
            mineText = Money.decimalText(total)
        }
    }

    private func toggle(_ person: String, forceOn: Bool = false) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if let index = selected.firstIndex(of: person) {
                guard !forceOn else { return }
                selected.remove(at: index)
                amounts[person] = nil
                // Sin nadie más, el gasto vuelve a ser tuyo entero.
                if selected.isEmpty { includesMe = true }
            } else {
                selected.append(person)
            }
            splitEvenly()
        }
    }

    /// Partes iguales contándote a ti (si estás). Los céntimos que no se
    /// dividen exacto van a tu parte o, si saliste, a la primera persona,
    /// para que siempre cuadre con el total.
    private func splitEvenly() {
        let people = selected.count + (includesMe ? 1 : 0)
        guard people > 0 else { return }
        let totalCents = Money.cents(total)
        let each = totalCents / people
        let rest = totalCents - each * people
        for (index, person) in selected.enumerated() {
            let cents = !includesMe && index == 0 ? each + rest : each
            amounts[person] = Money.decimalText(Money.value(cents))
        }
        mineText = includesMe ? Money.decimalText(Money.value(each + rest)) : "0"
        mineEdited = false
    }

    private func setIncludesMe(_ value: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            includesMe = value
            splitEvenly()
        }
    }

    private func setAmount(_ input: String, for person: String) {
        amounts[person] = TransactionDraft.sanitizedAmount(input)
        // Mientras no toques tu parte, tu parte es lo que queda.
        if includesMe && !mineEdited {
            mineText = Money.decimalText(Money.clampedToZero(Money.subtract(total, others)))
        }
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        errorText = nil
        defer { isSaving = false }

        var byPerson: [String: Double] = [:]
        for person in selected {
            if let value = amounts[person].flatMap(Money.parse), Money.cents(value) > 0 { byPerson[person] = value }
        }
        let outcome = await ExpenseSharing.shared.share(expense, mine: mine, amounts: byPerson, notify: notify)
        if let failed = outcome.failed {
            errorText = "No se pudo guardar. " + failed
            return
        }
        Analytics.track(.featureUsed, ["feature": AppFeature.paymentReminder.rawValue, "action": "shared",
                                       "people": byPerson.count, "notify": notify,
                                       "offline": byPerson.keys.filter(OfflineDebts.isContact).count])

        let message = byPerson.isEmpty ? "Ya no está compartido"
            : byPerson.count == 1 ? "Compartido con " + friendsManager.friend(with: byPerson.keys.first!).name
            : "Compartido con \(byPerson.count) personas"
        onDone?(message)

        if outcome.whatsApp.count == 1, let only = outcome.whatsApp.first {
            offline.remindByWhatsApp(only)
            dismiss()
        } else if outcome.whatsApp.count > 1 {
            withAnimation(.easeInOut(duration: 0.2)) { whatsAppQueue = outcome.whatsApp }
        } else {
            dismiss()
        }
    }
}

/// «Alguien sin la app»: nombre y, si quieres, su celular para abrir su chat.
struct AddOfflineContactSheet: View {
    let onAdd: (OfflineContact) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var phone = ""
    @FocusState private var focused: Bool

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    private var canAdd: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                field("Nombre", text: $name, keyboard: .default)
                    .focused($focused)
                field("Celular · opcional", text: $phone, keyboard: .phonePad)
                Text("Solo se guarda en tu teléfono. Con el celular, WhatsApp se abre directo en su chat.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(palette.background)
            .navigationTitle("Alguien sin la app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Agregar") {
                        let contact = OfflineDebts.shared.addContact(name: name, phone: phone)
                        onAdd(contact)
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
            .onAppear { focused = true }
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.height(300)])
        .presentationCornerRadius(28)
        .presentationBackground(palette.background)
    }

    private func field(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(keyboard == .default ? .words : .never)
            .font(.system(size: 16))
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
    }
}

/// La «x» roja de una fila del reparto: un círculo suave del color de
/// borrar, chico pero con 44 pt de toque.
private struct RemoveFromSplitButton: View {
    static let size: CGFloat = 24

    let name: String
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(palette.negative)
                .frame(width: Self.size, height: Self.size)
                .background(palette.negative.opacity(0.14), in: Circle())
                .overlay(Circle().stroke(palette.negative.opacity(0.25), lineWidth: 0.5))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: Self.size, height: Self.size)
        .accessibilityLabel(name == "Tú" ? "Quitarme del reparto" : "Quitar a " + name + " del reparto")
    }
}
