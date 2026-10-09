import Foundation
import UIKit

/// Alguien sin la app («Diego, sin la app»). Vive sólo en este teléfono y en
/// su respaldo: el servidor no sabe que existe.
struct OfflineContact: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    /// Celular para abrir WhatsApp directo en su chat. Opcional: sin él,
    /// WhatsApp pregunta a quién mandarlo.
    var phone: String?

    /// Cómo aparece donde se mezcla con los amigos (`ReceivableShare.debtor`,
    /// `FriendsManager.friend(with:)`).
    var personID: String { OfflineDebts.personPrefix + id }
}

/// Lo que te debe alguien sin la app por un gasto compartido. La misma forma
/// que una parte del servidor, para que Cobros los muestre en la misma lista.
struct OfflineDebt: Codable, Identifiable, Equatable {
    let id: String
    let contactID: String
    let debtKey: String
    var merchant: String
    var occurredOn: Date?
    var amount: Double
    var currency: String
    var paidAmount: Double = 0
    var status: String = "open"
    var createdAt: Date = Date()
    var closedOn: Date?
    var via: String?
    /// Cada día en que se le cobró por WhatsApp.
    var reminders: [Date] = []
}

/// Personas sin la app y sus deudas.
///
/// Se guardan en `UserDefaults` (un JSON) y viajan en el respaldo
/// (`ConfigBackupManager.decisionExtras`). Cobrarles es abrir WhatsApp con el
/// monto escrito: la app sólo anota cuándo se hizo.
@MainActor
@Observable
final class OfflineDebts {

    static let shared = OfflineDebts()

    /// `ReceivableShare.debtor` de alguien sin la app.
    nonisolated static let personPrefix = "contact:"
    /// `ReceivableShare.id` de una deuda local.
    nonisolated static let sharePrefix = "local:"

    nonisolated static func isContact(_ personID: String) -> Bool { personID.hasPrefix(personPrefix) }

    private(set) var contacts: [OfflineContact] = []
    private(set) var debts: [OfflineDebt] = []

    nonisolated private static let storageKey = "offlineDebts.v1"

    fileprivate struct Stored: Codable, Sendable {
        var contacts: [OfflineContact]
        var debts: [OfflineDebt]
    }

    private init() { load() }

    // MARK: - Personas

    func contact(personID: String) -> OfflineContact? {
        let id = personID.hasPrefix(Self.personPrefix) ? String(personID.dropFirst(Self.personPrefix.count)) : personID
        return contacts.first { $0.id == id }
    }

    /// Crea a alguien nuevo o, si ya hay uno que se llama igual, lo reutiliza
    /// (y le pone el celular si ahora lo trae).
    @discardableResult
    func addContact(name: String, phone: String?) -> OfflineContact {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = phone.map(Self.digits).flatMap { $0.isEmpty ? nil : $0 }
        if let index = contacts.firstIndex(where: { $0.name.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            if let phone { contacts[index].phone = phone; persist() }
            return contacts[index]
        }
        let contact = OfflineContact(id: UUID().uuidString, name: clean, phone: phone)
        contacts.append(contact)
        persist()
        return contact
    }

    func updatePhone(_ contact: OfflineContact, phone: String?) {
        guard let index = contacts.firstIndex(where: { $0.id == contact.id }) else { return }
        contacts[index].phone = phone.map(Self.digits).flatMap { $0.isEmpty ? nil : $0 }
        persist()
    }

    // MARK: - Deudas

    /// Lo que Cobros dibuja, con la misma forma que lo del servidor.
    var receivables: [ReceivableShare] {
        debts.compactMap { debt in
            guard contacts.contains(where: { $0.id == debt.contactID }) else { return nil }
            return ReceivableShare(id: Self.sharePrefix + debt.id,
                                   debtor: Self.personPrefix + debt.contactID,
                                   debtKey: debt.debtKey, merchant: debt.merchant,
                                   occurredOn: debt.occurredOn, amount: debt.amount,
                                   currency: debt.currency, paidAmount: debt.paidAmount,
                                   status: ReceivableShare.Status(rawValue: debt.status) ?? .open,
                                   createdAt: debt.createdAt, closedOn: debt.closedOn,
                                   via: debt.via, reminders: debt.reminders)
        }
    }

    /// Deja las partes de este gasto como dice `amounts` (contacto → monto).
    /// Quien salió sin haber pagado nada se borra; quien ya abonó se queda.
    func setShares(debtKey: String, merchant: String, occurredOn: Date?, currency: String,
                   amounts: [String: Double]) {
        for (contactID, amount) in amounts where Money.cents(amount) > 0 {
            if let index = debts.firstIndex(where: { $0.debtKey == debtKey && $0.contactID == contactID }) {
                if debts[index].status == "open" {
                    debts[index].amount = max(Money.normalized(amount), debts[index].paidAmount)
                }
                debts[index].merchant = merchant
                debts[index].occurredOn = occurredOn
            } else {
                debts.append(OfflineDebt(id: UUID().uuidString, contactID: contactID, debtKey: debtKey,
                                         merchant: merchant, occurredOn: occurredOn,
                                         amount: Money.normalized(amount), currency: currency))
            }
        }
        debts.removeAll { debt in
            debt.debtKey == debtKey && amounts[debt.contactID].map({ Money.cents($0) <= 0 }) != false
                && debt.status == "open" && Money.cents(debt.paidAmount) == 0
        }
        persist()
    }

    func rekey(from old: String, to new: String) {
        guard debts.contains(where: { $0.debtKey == old }) else { return }
        debts = debts.map { debt in
            guard debt.debtKey == old else { return debt }
            var moved = OfflineDebt(id: debt.id, contactID: debt.contactID, debtKey: new, merchant: debt.merchant,
                                    occurredOn: debt.occurredOn, amount: debt.amount, currency: debt.currency)
            moved.paidAmount = debt.paidAmount
            moved.status = debt.status
            moved.createdAt = debt.createdAt
            moved.closedOn = debt.closedOn
            moved.via = debt.via
            moved.reminders = debt.reminders
            return moved
        }
        persist()
    }

    func removeDebts(debtKey: String) {
        let before = debts.count
        debts.removeAll { $0.debtKey == debtKey }
        if debts.count != before { persist() }
    }

    /// Lo que registra «Registrar pago». Devuelve lo aplicado.
    @discardableResult
    func recordPayment(shareID: String, amount: Double, via: String) -> Double? {
        guard let index = index(of: shareID) else { return nil }
        let remaining = Money.clampedToZero(Money.subtract(debts[index].amount, debts[index].paidAmount))
        let applied = min(Money.normalized(amount), remaining)
        guard Money.cents(applied) > 0 else { return nil }
        debts[index].paidAmount = Money.normalized(debts[index].paidAmount + applied)
        debts[index].via = via
        if Money.cents(Money.subtract(debts[index].amount, debts[index].paidAmount)) == 0 {
            debts[index].status = "paid"
            debts[index].closedOn = Date()
        }
        persist()
        return applied
    }

    func forgive(shareID: String) {
        guard let index = index(of: shareID) else { return }
        debts[index].status = "forgiven"
        debts[index].closedOn = Date()
        persist()
    }

    /// Se le escribió por WhatsApp hoy.
    func logReminder(shareID: String) {
        guard let index = index(of: shareID) else { return }
        let calendar = Calendar.current
        if !debts[index].reminders.contains(where: { calendar.isDateInToday($0) }) {
            debts[index].reminders.append(Date())
            persist()
        }
    }

    private func index(of shareID: String) -> Int? {
        let id = shareID.hasPrefix(Self.sharePrefix) ? String(shareID.dropFirst(Self.sharePrefix.count)) : shareID
        return debts.firstIndex { $0.id == id }
    }

    // MARK: - WhatsApp

    /// `wa.me` con el texto ya escrito. Un celular peruano de 9 dígitos se
    /// completa con el 51.
    static func whatsAppURL(phone: String?, text: String) -> URL? {
        var components = URLComponents(string: "https://wa.me/")
        if let phone, !phone.isEmpty {
            let digits = Self.digits(phone)
            components?.path = "/" + (digits.count == 9 ? "51" + digits : digits)
        }
        components?.queryItems = [URLQueryItem(name: "text", value: text)]
        return components?.url
    }

    /// «Hola Diego, de Cevichería El Muelle (8 oct) te toca S/ 30.00.»
    static func message(name: String, merchant: String, date: Date?, amount: Double, currency: String) -> String {
        var text = "Hola \(name), de " + merchant
        if let date {
            text += " (" + date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_ES"))) + ")"
        }
        text += " te toca " + Money.format(amount, currency: currency) + ". Te lo anoté en AgruPay."
        return text
    }

    /// Abre WhatsApp para cobrarle y lo anota como cobrado hoy.
    func remindByWhatsApp(_ share: ReceivableShare) {
        guard let contact = contact(personID: share.debtor) else { return }
        let text = Self.message(name: contact.name, merchant: share.merchant, date: share.occurredOn,
                                amount: share.remaining, currency: share.currency)
        guard let url = Self.whatsAppURL(phone: contact.phone, text: text) else { return }
        UIApplication.shared.open(url)
        logReminder(shareID: share.id)
    }

    // MARK: - Guardado

    private static func digits(_ text: String) -> String { text.filter(\.isNumber) }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        contacts = stored.contacts
        debts = stored.debts
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Stored(contacts: contacts, debts: debts)) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Para el respaldo: el JSON tal cual, leído de `UserDefaults` para poder
    /// llamarse fuera del actor principal.
    nonisolated static func exportJSON() -> String? {
        UserDefaults.standard.data(forKey: storageKey).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Restaurar: se suman las personas y deudas que no estén ya aquí.
    nonisolated static func mergeJSON(_ text: String) {
        guard let incoming = try? JSONDecoder().decode(Stored.self, from: Data(text.utf8)) else { return }
        let defaults = UserDefaults.standard
        var current = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored(contacts: [], debts: [])
        for contact in incoming.contacts where !current.contacts.contains(where: { $0.id == contact.id }) {
            current.contacts.append(contact)
        }
        for debt in incoming.debts where !current.debts.contains(where: { $0.id == debt.id }) {
            current.debts.append(debt)
        }
        if let data = try? JSONEncoder().encode(current) { defaults.set(data, forKey: storageKey) }
        Task { @MainActor in OfflineDebts.shared.load() }
    }

    #if DEBUG
    func seedForQA(contacts: [OfflineContact], debts: [OfflineDebt]) {
        self.contacts = contacts
        self.debts = debts
    }
    #endif
}
