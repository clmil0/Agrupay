import Foundation
import SwiftData

@Model
final class Expense {
    var id: UUID
    var amount: Double
    var merchant: String
    var date: Date
    
    // Nuevos campos
    var category: String
    var notes: String?
    var isSubscription: Bool
    var currency: String = "PEN"
    var emailID: String?
    var relatedEmailID: String?
    var isDebt: Bool = false

    /// Etiquetas libres, transversales a la categoría: un gasto de Salud puede
    /// llevar "madre" y otro "padre" sin dejar de ser Salud.
    ///
    /// Nombres y no ids, igual que `category`: es la clave en todo el proyecto
    /// y ya hay maquinaria para renombrar en cascada (`TagEditor`). Además los
    /// gastos del correo se borran y se rearman en cada relectura; una relación
    /// a entidades se rompería en cada sincronización, un `[String]` no. Quien
    /// las escribe pasa por `TagCatalog.use`, que devuelve la forma canónica.
    var tags: [String] = []
    /// La deuda se dio por saldada aunque quedara saldo: lo que no se cobró
    /// pasa a ser gasto propio. Sólo tiene sentido con `isDebt == false`.
    var debtSettled: Bool = false
    var cardLastDigits: String?

    /// El parser que lo leyó (`BankEmailParser.bankName`): "BBVA", "Yape"…
    /// Con `cardLastDigits` define de qué cuenta salió (`AccountResolver`).
    /// `nil` en lo anotado a mano y en lo importado antes de guardarlo; para
    /// ésos el origen se deduce del prefijo del comercio.
    var sourceBank: String?
    /// La billetera o banco que recibió un Plin/Yape, cuando el correo lo
    /// dice ("Destino: Yape"). Sólo para dibujar el traslado «BBVA → Yape»;
    /// que sea traslado lo decide el destinatario, no esto.
    var destinationWallet: String?
    /// Los últimos dígitos del celular de quien recibió un Plin/Yape
    /// ("Celular: •7209"). Se guarda junto al nombre: dos personas pueden
    /// llamarse igual, y el nombre a veces llega recortado.
    var payeePhone: String?
    /// "Débito" o "Crédito", cuando el correo lo dice junto a los dígitos. Da
    /// nombre a dos tarjetas del mismo banco ("BBVA Débito", "BBVA Crédito").
    var cardKind: String?
    /// Va a una cuenta tuya (`TransferDetector`): no cuenta como gasto. Se
    /// recalcula desde `AccountBook`, así que no hace falta anotarlo en
    /// `ExpenseEditStore` para que sobreviva a releer el correo.
    var isTransfer: Bool = false
    /// Aviso de que el banco **anuló** una compra («La compra con tu tarjeta
    /// ha sido anulada»). No es un gasto: espera a que el usuario elija qué
    /// compra se anuló (`ReversalMatcher`) y entonces se borra.
    var isReversal: Bool = false
    /// Compra anulada por el banco: se ve tachada y no suma en ningún total.
    var isVoided: Bool = false

    /// El pago se dividió en partes (`ExpenseSplit`): deja de sumar y queda
    /// como referencia; cuentan sus partes, cada una en su categoría. Se
    /// deduce de que existan partes que lo apunten (`ExpenseSplit.reconcile`),
    /// así que sobrevive a releer el correo sin anotarlo en `ExpenseEditStore`.
    var isSplit: Bool = false
    /// Parte de un pago dividido: la llave (`TransactionKey`) de ese pago. Las
    /// partes se crean a mano —sin correo—, así que se respaldan enteras y
    /// vuelven a encontrar su pago aunque éste se rearme con otro `UUID`.
    var splitOf: String?
    /// Orden de la parte dentro de su pago («Parte 1», «Parte 2»…).
    var splitIndex: Int = 0

    /// «Compartir gasto»: lo que pusiste tú. `nil` si no se compartió. Con
    /// valor, el gasto suma sólo esto (más lo perdonado) y el resto es lo que
    /// te deben, por persona (`FriendReceivables`). Sobrevive a releer el
    /// correo vía `ExpenseShareStore`.
    var ownShare: Double?
    /// Lo que perdonaste de las partes de los demás: pasa a ser gasto tuyo.
    var forgivenAmount: Double = 0

    /// Soles por 1 USD el día del movimiento.
    ///
    /// Sin esto, `ExchangeRateService.usdToPenRate` —un valor vivo— se aplicaba a
    /// meses ya cerrados: el total de agosto cambiaba cada vez que se refrescaba
    /// el tipo de cambio, y "vs. mes pasado" comparaba dos tipos distintos.
    /// Ver ACCOUNTING.md §9. `nil` en registros anteriores a la migración; en ese
    /// caso `Accounting` usa el tipo actual como respaldo.
    var fxRateAtCapture: Double?
    
    /// `.nullify`, no `.cascade`: en cascada, "Volver a leer el correo desde
    /// cero" —que borra los gastos para rearmarlos— se llevaba por delante los
    /// cobros que el usuario había registrado a mano, y ésos no están en
    /// ningún correo. Al anular, el cobro sobrevive y `IncomeLinkStore` lo
    /// vuelve a atar cuando el gasto reaparece.
    @Relationship(deleteRule: .nullify, inverse: \Income.debtReference) var payments: [Income]?

    /// - Warning: mezcla monedas (resta un abono de $ 40 como 40 soles) y además
    ///   no es "lo gastado" sino "lo que aún debes", dos cifras que las vistas
    ///   confundían entre sí. Usar `Accounting.outstanding(of:)` para el saldo y
    ///   `amount` para el gasto. Ver ACCOUNTING.md §2 y §5.
    @available(*, deprecated, message: "Mezcla monedas. Usa Accounting.outstanding(of:) para el saldo y amount para el gasto.")
    var unpaidAmount: Double {
        let paid = (payments ?? []).reduce(0) { $0 + $1.amount }
        return max(0, amount - paid)
    }
    
    init(amount: Double, merchant: String, date: Date = Date(), category: String = "Otros", notes: String? = nil, isSubscription: Bool = false, currency: String = "PEN", emailID: String? = nil, isDebt: Bool = false, cardLastDigits: String? = nil, fxRateAtCapture: Double? = nil) {
        self.id = UUID()
        // Céntimos enteros vía Decimal: estable también para 1.005.
        self.amount = Money.normalized(amount)
        self.merchant = merchant
        self.date = date
        self.category = category
        self.notes = notes
        self.isSubscription = isSubscription
        self.currency = currency
        self.emailID = emailID
        self.isDebt = isDebt
        self.cardLastDigits = cardLastDigits
        // Se congela el tipo de cambio del día. En soles no hace falta.
        self.fxRateAtCapture = currency == "PEN"
            ? nil
            : (fxRateAtCapture ?? ExchangeRateService.storedRate)
    }
}

extension Expense {

    /// Se compartió con amigos: tiene tu parte aparte y deudas por persona.
    var isShared: Bool { ownShare != nil }

    /// «Falta repartir»: marcado para cobrar, todavía sin personas ni montos.
    /// Es lo que antes se llamaba «Por cobrar».
    var needsSplitting: Bool { isDebt && ownShare == nil && !isSplit }

    /// Se puede compartir: un gasto real y no el pago entero de uno separado
    /// por categoría (ésos se comparten parte por parte).
    var canBeShared: Bool {
        !isSplit && !isTransfer && !isVoided && !isReversal && Money.cents(amount) > 0
    }

    /// `true` si lleva esta etiqueta. Recibe la clave ya normalizada
    /// (`TagCatalog.normalized`) porque quien filtra una lista larga la
    /// calcula una vez, no una por gasto.
    func hasTag(_ normalizedKey: String) -> Bool {
        tags.contains { TagCatalog.normalized($0) == normalizedKey }
    }

    /// Pone o quita la etiqueta y lo deja anotado para que sobreviva a
    /// "Volver a leer el correo desde cero". Un solo sitio para el gesto, que
    /// se hace desde la ficha del gasto y desde el etiquetado múltiple.
    func toggleTag(_ name: String, in modelContext: ModelContext) {
        let key = TagCatalog.normalized(name)
        guard !key.isEmpty else { return }
        if hasTag(key) {
            tags = tags.filter { TagCatalog.normalized($0) != key }
        } else {
            guard tags.count < TagCatalog.maxPerExpense,
                  let canonical = TagCatalog.shared.use(name) else { return }
            tags.append(canonical)
        }
        ExpenseEditStore.record(self, tags: tags)
        try? modelContext.save()
    }

    /// Alterna "por cobrar". Un solo sitio para la lógica que usan el botón
    /// del detalle (`ExpenseDetailsView`) y el menú contextual de Actividad
    /// Reciente: declararla saldada con un saldo pendiente no lo pone en
    /// cero (ver `debtBand`), lo único que cambia aquí es `isDebt`.
    func toggleDebt(in modelContext: ModelContext) {
        isDebt.toggle()
        // Volver a marcarla por cobrar reabre la deuda.
        if isDebt { debtSettled = false }
        ExpenseEditStore.record(self, isDebt: isDebt, debtSettled: isDebt ? false : nil)
        try? modelContext.save()
        Self.refreshDebtNotification(in: modelContext)
    }

    /// «Deuda saldada»: nadie va a devolver lo que falta, así que ese saldo
    /// queda como gasto propio. Deja de sumar a «por cobrar» igual que al
    /// desmarcarla, pero la ficha lo muestra en verde y no como pendiente.
    func settleDebt(in modelContext: ModelContext) {
        isDebt = false
        debtSettled = true
        ExpenseEditStore.record(self, isDebt: false, debtSettled: true)
        try? modelContext.save()
        Self.refreshDebtNotification(in: modelContext)
    }

    /// Borra el gasto. Si vino de un correo, su id queda anotado para que
    /// «Recuperar borrados» pueda traerlo de vuelta.
    func deleteRecordingRecovery(in modelContext: ModelContext) {
        if let emailID {
            var recoveryIDs = UserDefaults.standard.stringArray(forKey: "pendingRecoveryIDs") ?? []
            if !recoveryIDs.contains(emailID) {
                recoveryIDs.append(emailID)
                UserDefaults.standard.set(recoveryIDs, forKey: "pendingRecoveryIDs")
            }
        }
        let wasDebt = isDebt
        // Borrarlo a mano es decir que no existió (una prueba, algo mal
        // anotado): las deudas que se crearon al compartirlo —o sus partes—
        // se borran también, en el servidor y para el amigo. La relectura del
        // correo borra por otro camino y no pasa por aquí.
        var debtKeys = TransactionKey.lookupKeys(for: self)
        // Sin su pago, las partes quedarían sumando solas.
        if isSplit {
            for part in ExpenseSplit.parts(of: self, in: modelContext) {
                debtKeys += TransactionKey.lookupKeys(for: part)
                modelContext.delete(part)
            }
        }
        Task { @MainActor in
            for key in debtKeys { await FriendReceivables.shared.deleteDebts(debtKey: key) }
        }
        modelContext.delete(self)
        try? modelContext.save()
        if wasDebt { Self.refreshDebtNotification(in: modelContext) }
    }

    static func refreshDebtNotification(in modelContext: ModelContext) {
        // Fuera del fotograma en el que la fila empieza a crecer: contar las
        // deudas y reprogramar el aviso es trabajo síncrono que, hecho aquí
        // mismo, se come el primer paso de la animación de alto.
        DispatchQueue.main.async {
            let descriptor = FetchDescriptor<Expense>(predicate: #Predicate { $0.isDebt == true })
            let hasDebts = ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
            NotificationManager.shared.updateDebtNotification(hasDebts: hasDebts)
        }
    }
}
