import Foundation

/// Tipo de movimiento. Ya existe en `AddExpenseView.swift`; se conserva el nombre.
enum TransactionType: String, CaseIterable, Identifiable {
    case gasto = "Gasto"
    case ingreso = "Ingreso"
    var id: String { rawValue }
}

/// Estado del formulario de alta de movimiento, con validación explícita.
///
/// Reemplaza los 11 `@State` sueltos de `AddExpenseView` por un solo valor.
/// El objetivo del rediseño es que el botón **nunca** acepte un toque sin
/// hacer nada: `validation` dice siempre qué falta, y la vista lo muestra.
struct TransactionDraft {

    var type: TransactionType = .gasto

    /// Texto crudo del teclado numérico. Nunca se guarda: se parsea con
    /// `Money.parse(_:)` y se normaliza a céntimos.
    var amountText: String = ""
    var currency: String = "PEN"
    var date: Date = Date()

    /// Descripción opcional, debajo del nombre en ambos formularios.
    var notes: String = ""

    // Gasto
    var merchant: String = ""
    var category: String = "Otros"
    var isSubscription: Bool = false

    /// De dónde sale (gasto) o a dónde llega (ingreso): Efectivo, Yape,
    /// Plin, Transferencia u Otro. En un gasto queda en `sourceBank`, para
    /// que caiga en su tarjeta del carrusel de Movimientos.
    var source: String = "Efectivo"

    // Ingreso
    var title: String = ""
    var isDebtPayment: Bool = false

    /// La deuda elegida y **su saldo en el momento de elegirla**.
    ///
    /// El saldo se captura en vez de leerse del modelo cada vez, y esa es la
    /// diferencia que evita toda una familia de errores: `Expense.payments` es
    /// una relación viva, así que en cuanto se construye el `Income` con
    /// `debtReference` el saldo del objeto ya descuenta el abono que se está
    /// registrando. Leyéndolo en vivo, el formulario se contradecía a sí mismo
    /// justo después de guardar —el monto se pintaba en rojo por "exceso" y el
    /// aviso de "queda saldado" aparecía sin motivo— durante el momento que la
    /// hoja tarda en cerrarse. Un formulario describe lo que el usuario está
    /// escribiendo; no puede cambiar de opinión por algo que él ya confirmó.
    private(set) var selectedDebt: Expense? = nil
    private(set) var selectedDebtOutstanding: Double = 0

    /// Marca manual: el usuario decide que este abono deja saldada la deuda
    /// aunque no cubra el saldo completo, perdonando lo que falte en vez de
    /// dejarlo pendiente. Sin esto, la única forma de saldar era pagar
    /// exacto — pagar de más ya está bloqueado por validación.
    var forceCancelsDebt: Bool = false

    /// Único camino para elegir deuda: así el saldo nunca queda sin capturar.
    mutating func selectDebt(_ debt: Expense?) {
        selectedDebt = debt
        selectedDebtOutstanding = debt.map { Accounting.outstanding(of: $0) } ?? 0
        // Saldar es una decisión sobre ESTA deuda; cambiar de elegida no debe
        // arrastrarla a la siguiente.
        forceCancelsDebt = false
    }

    // MARK: - Monto

    var amount: Double { Money.parse(amountText) ?? 0 }

    var hasAmount: Bool { Money.cents(amount) > 0 }

    /// Saldo de la deuda elegida, en su propia moneda. Es el capturado al
    /// elegirla, no el que tenga el objeto ahora mismo.
    var debtOutstanding: Double? {
        selectedDebt == nil ? nil : selectedDebtOutstanding
    }

    /// Cuánto se pasa el abono del saldo. `nil` si no aplica.
    var excessOverDebt: Double? {
        guard isDebtPayment, let debt = selectedDebt, let saldo = debtOutstanding else { return nil }
        guard debt.currency == currency else { return nil }
        let excess = Money.subtract(amount, saldo)
        return Money.cents(excess) > 0 ? excess : nil
    }

    /// Saldo que quedaría tras el abono.
    var debtRemainder: Double? {
        guard let saldo = debtOutstanding else { return nil }
        return Money.clampedToZero(Money.subtract(saldo, amount))
    }

    /// El abono cancela la deuda: solo, si cubre el saldo completo, o a
    /// propósito, si el usuario marcó `forceCancelsDebt` para perdonar lo que
    /// falte y no dejarlo pendiente.
    var cancelsDebt: Bool {
        guard isDebtPayment, let remainder = debtRemainder else { return false }
        return Money.isZero(remainder) || forceCancelsDebt
    }

    // MARK: - Validación

    enum Validation: Equatable {
        case ready
        /// Texto exacto que va en el botón deshabilitado.
        case blocked(String)
        /// Error que se muestra bajo el monto, en rojo.
        case invalid(String)

        var isReady: Bool { self == .ready }
    }

    var validation: Validation {
        if amountText.isEmpty || Money.cents(amount) == 0 {
            return .blocked("Escribe un monto")
        }
        if Money.cents(amount) < 0 {
            return .invalid("El monto debe ser positivo")
        }
        // Techo de cordura: un dedo resbalado no debe crear un gasto de millones.
        if Money.cents(amount) > 100_000_000 {
            return .invalid("Monto demasiado alto. Revisa las cifras.")
        }
        // El título y la categoría son opcionales: sin categoría el gasto
        // queda en Pendientes, igual que lo que llega del banco sin regla.
        if type == .ingreso, isDebtPayment {
            guard let debt = selectedDebt else {
                return .blocked("Elige qué te están devolviendo")
            }
            guard debt.currency == currency else {
                return .invalid("Lo que te deben está en \(debt.currency). Cambia la moneda del cobro.")
            }
            if let excess = excessOverDebt {
                return .invalid("Supera lo que te deben en " + Money.format(excess, currency: currency))
            }
        }
        if date > Date().addingTimeInterval(60 * 60 * 24) {
            return .invalid("La fecha está en el futuro")
        }
        return .ready
    }

    /// Etiqueta del botón principal cuando está habilitado.
    var actionTitle: String {
        let formatted = Money.format(amount, currency: currency)
        switch (type, isDebtPayment, cancelsDebt) {
        case (.gasto, _, _):        return "Añadir gasto de " + formatted
        case (.ingreso, true, true): return "Registrar " + formatted + " y saldar el cobro"
        case (.ingreso, true, false): return "Registrar cobro de " + formatted
        case (.ingreso, false, _):  return "Añadir ingreso de " + formatted
        }
    }

    // MARK: - Teclado numérico

    /// Aplica una tecla al texto del monto. Impide dos separadores decimales
    /// y más de dos decimales — el `TextField` con `.decimalPad` anterior
    /// aceptaba "1.2.3", que `Double(_:)` convertía en `nil` y el `guard`
    /// descartaba en silencio.
    mutating func press(_ key: KeypadKey) {
        switch key {
        case .digit(let d):
            if let dot = amountText.firstIndex(of: ".") {
                let decimals = amountText.distance(from: dot, to: amountText.endIndex) - 1
                guard decimals < 2 else { return }
            }
            guard amountText.replacingOccurrences(of: ".", with: "").count < 9 else { return }
            if amountText == "0" { amountText = String(d) } else { amountText.append(String(d)) }
        case .decimal:
            guard !amountText.contains(".") else { return }
            amountText = amountText.isEmpty ? "0." : amountText + "."
        case .backspace:
            guard !amountText.isEmpty else { return }
            amountText.removeLast()
        }
    }

    enum KeypadKey: Hashable {
        case digit(Int)
        case decimal
        case backspace
    }

    /// Filtra lo que se teclea en el monto cuando la entrada es el teclado del
    /// sistema (`.decimalPad`) y no el propio.
    ///
    /// El teclado propio validaba tecla a tecla; el del sistema no puede, así
    /// que las mismas tres reglas se aplican aquí sobre el texto completo: un
    /// solo separador decimal, como mucho dos decimales y tope de nueve dígitos
    /// enteros. Sin esto vuelve el "1.2.3" que `Money.parse` no sabe leer y que
    /// el `guard` de guardar descartaba en silencio.
    ///
    /// Acepta coma **y** punto —el `.decimalPad` enseña el separador del idioma
    /// del teléfono, que no siempre es el mismo— y normaliza a punto, que es lo
    /// que el resto del código espera.
    static func sanitizedAmount(_ input: String) -> String {
        var result = ""
        var hasSeparator = false
        var decimals = 0
        var integerDigits = 0

        for character in input {
            if character.isNumber {
                if hasSeparator {
                    guard decimals < 2 else { continue }
                    decimals += 1
                } else {
                    guard integerDigits < 9 else { continue }
                    integerDigits += 1
                }
                result.append(character)
            } else if character == "." || character == "," {
                guard !hasSeparator else { continue }
                hasSeparator = true
                // ".5" se escribe solo como "0.5": el separador nunca abre el texto.
                if result.isEmpty { result = "0" }
                result.append(".")
            }
        }
        return result
    }

    /// Monto mostrado en el hero. Vacío muestra "0.00" en color terciario.
    var displayAmount: String {
        guard !amountText.isEmpty else { return "0.00" }
        return amountText
    }

    // MARK: - Persistencia

    /// Crea el `Expense`. Sólo llamar con `validation == .ready`.
    func makeExpense() -> Expense? {
        guard validation.isReady, type == .gasto else { return nil }
        // El orden de los parámetros es el del `init` del modelo.
        let expense = Expense(
            amount: Money.normalized(amount),
            // Sin título, el nombre de la categoría: «Comida» se lee mejor
            // en la lista que un comercio vacío. Sin ninguno de los dos, «Gasto».
            merchant: !merchant.trimmed.isEmpty ? merchant.trimmed
                : (category.trimmed.isEmpty ? "Gasto" : category.trimmed),
            date: date,
            category: category.trimmed.isEmpty ? Accounting.unclassified : category.trimmed,
            notes: notes.trimmed.isEmpty ? nil : notes.trimmed,
            isSubscription: isSubscription,
            currency: currency
        )
        expense.sourceBank = source
        return expense
    }

    /// Todo lo que hace falta para guardar un cobro, resuelto **de una vez**.
    ///
    /// Existe por un bug real: `Income(debtReference: debt)` engancha el cobro
    /// a `debt.payments` en el mismo instante en que se construye. Desde ese
    /// momento `debtOutstanding` ya descuenta este abono, y con él `cancelsDebt`
    /// y `excessOverDebt` pasan a estar mal. `AddTransactionSheet` leía
    /// `draft.cancelsDebt` **después** de crear el ingreso, así que el abono se
    /// contaba dos veces —una en el saldo, otra como monto— y la condición que
    /// de verdad se evaluaba era «saldo_después ≤ monto». Con 500 y dos abonos
    /// de 200: (500−400)=100 ≤ 200 → la deuda se daba por saldada con 400, y de
    /// paso el monto se pintaba en rojo por "exceso".
    ///
    /// Devolviendo la decisión junto al ingreso, no queda ningún orden posible
    /// en el que la vista pueda leer un saldo ya contaminado.
    struct Resolution {
        let income: Income
        let debt: Expense?
        /// Si con este cobro la deuda queda saldada.
        let cancelsDebt: Bool
    }

    /// Crea el `Income` y decide si salda. El monto se limita al saldo por si
    /// la validación se salta desde otro punto de entrada (doble red).
    func resolveIncome() -> Resolution? {
        guard validation.isReady, type == .ingreso else { return nil }
        let debt = isDebtPayment ? selectedDebt : nil

        // Se leen antes de construir el `Income`: después ya estarían contando
        // este mismo abono.
        let cancels = cancelsDebt
        let finalAmount = debt == nil
            ? Money.normalized(amount)
            : min(Money.normalized(amount), selectedDebtOutstanding)
        guard Money.cents(finalAmount) > 0 else { return nil }

        let income = Income(
            amount: finalAmount,
            currency: currency,
            source: source,
            title: title.trimmed.isEmpty ? nil : title.trimmed,
            date: date,
            notes: notes.trimmed.isEmpty ? nil : notes.trimmed,
            debtReference: debt,
            isFinalDebtPayment: cancels
        )
        return Resolution(income: income, debt: debt, cancelsDebt: cancels)
    }

    /// - Warning: sólo para quien no necesite saber si la deuda queda saldada.
    ///   Si vas a decidir algo sobre la deuda, usa `resolveIncome()`: leer
    ///   `cancelsDebt` después de llamar aquí da un resultado equivocado.
    func makeIncome() -> Income? {
        resolveIncome()?.income
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Money {

    /// Parsea texto escrito por una persona. Acepta coma o punto como decimal,
    /// separadores de miles, espacios y símbolos de moneda.
    ///
    /// `Double(amountText.replacingOccurrences(of: ",", with: "."))` fallaba con
    /// "1.234,56" (formato local) y con "1 200".
    static func parse(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        for token in ["S/", "US$", "$", "PEN", "USD", " ", "\u{00A0}"] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        let lastComma = s.lastIndex(of: ",")
        let lastDot = s.lastIndex(of: ".")
        switch (lastComma, lastDot) {
        case let (c?, d?):
            // El separador más a la derecha es el decimal; el otro es de miles.
            if c > d {
                s = s.replacingOccurrences(of: ".", with: "")
                s = s.replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        case (.some(let c), .none):
            // Coma de miles ("1,250", "1,250,000") o decimal ("45,50"): una
            // coma seguida de exactamente tres cifras, o varias comas, son miles.
            let decimals = s.distance(from: c, to: s.endIndex) - 1
            if s.filter({ $0 == "," }).count > 1 || decimals == 3 {
                s = s.replacingOccurrences(of: ",", with: "")
            } else {
                s = s.replacingOccurrences(of: ",", with: ".")
            }
        case (.none, .some(let d)):
            // Punto usado como separador de miles: "1.200" sin decimales.
            let decimals = s.distance(from: d, to: s.endIndex) - 1
            if decimals == 3 && s.filter({ $0 == "." }).count == 1 && s.count > 4 {
                s = s.replacingOccurrences(of: ".", with: "")
            }
        case (.none, .none):
            break
        }
        guard let value = Double(s), value.isFinite else { return nil }
        return normalized(value)
    }
}
