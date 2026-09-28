import Foundation
import SwiftUI

/// Identidad de una categoría creada o personalizada por el usuario.
///
/// Hasta ahora una categoría era **sólo** el `String` de `Expense.category`: el
/// color y el icono salían de un `switch` fijo en `CategoryStyle` y no había
/// forma de renombrarla. Esto es lo mínimo para que `6b` pueda cambiar nombre,
/// color e icono sin tocar el modelo de datos: el nombre sigue siendo la clave,
/// y renombrar reescribe los gastos y las reglas de comercio.
struct CustomCategory: Codable, Equatable, Identifiable {

    var id: String { name }
    var name: String
    /// Identificador de `CategoryPalette`, no un `Color`: `Color` no es `Codable`
    /// de forma estable entre versiones de iOS.
    var colorID: String?
    /// SF Symbol. `nil` = el que decida `CategoryStyle` por el nombre.
    var icon: String?

    init(name: String, colorID: String? = nil, icon: String? = nil) {
        self.name = name
        self.colorID = colorID
        self.icon = icon
    }
}

/// Los colores elegibles en `6b`. Cinco, con nombre y contraste ya verificados:
/// una rueda de color libre produce categorías ilegibles en modo claro.
enum CategoryPalette {

    struct Option: Identifiable, Equatable {
        let id: String
        let label: String
        let color: Color
    }

    static let options: [Option] = [
        Option(id: "naranja", label: "Naranja", color: .orange),
        Option(id: "morado",  label: "Morado",  color: .purple),
        Option(id: "azul",    label: "Azul",    color: .blue),
        Option(id: "verde",   label: "Verde",   color: .green),
        Option(id: "rojo",    label: "Rojo",    color: Color(red: 1.0, green: 0.42, blue: 0.38)),
        Option(id: "turquesa", label: "Turquesa", color: .teal),
        Option(id: "rosa",    label: "Rosa",    color: .pink),
        Option(id: "indigo",  label: "Índigo",  color: .indigo)
    ]

    static func color(for id: String?) -> Color? {
        guard let id else { return nil }
        return options.first { $0.id == id }?.color
    }

    /// Los cinco de la fila de `6b`; el resto queda disponible por si se añade
    /// un selector completo más adelante.
    static var primary: [Option] { Array(options.prefix(5)) }
}

/// Iconos ofrecidos al personalizar. Los mismos que ya usa `CategoryStyle`
/// más un puñado de usos frecuentes, para no abrir el catálogo entero de
/// SF Symbols dentro de una pantalla de ajustes.
enum CategoryIcons {
    /// Por temas, para encontrar uno sin recorrer una sola rejilla larga.
    static let groups: [(title: String, symbols: [String])] = [
        ("Comida y bebida", [
            "fork.knife", "takeoutbag.and.cup.and.straw.fill", "cup.and.saucer.fill", "wineglass.fill",
            "mug.fill", "birthday.cake.fill", "carrot.fill", "fish.fill", "popcorn.fill", "basket.fill"
        ]),
        ("Compras", [
            "cart.fill", "bag.fill", "tshirt.fill", "shoe.fill", "handbag.fill", "gift.fill",
            "sparkles", "eyeglasses", "watch.analog", "tag.fill"
        ]),
        ("Transporte y viajes", [
            "car.fill", "bus.fill", "tram.fill", "bicycle", "scooter", "fuelpump.fill",
            "parkingsign", "airplane", "bed.double.fill", "suitcase.fill", "map.fill", "sailboat.fill"
        ]),
        ("Casa y servicios", [
            "house.fill", "bolt.fill", "drop.fill", "flame.fill", "wifi", "phone.fill",
            "iphone", "tv.fill", "sofa.fill", "lightbulb.fill", "washer.fill", "hammer.fill",
            "wrench.and.screwdriver.fill", "key.fill", "trash.fill"
        ]),
        ("Salud y cuidado", [
            "cross.case.fill", "pills.fill", "heart.fill", "stethoscope", "dumbbell.fill",
            "figure.run", "figure.yoga", "scissors", "comb.fill", "leaf.fill"
        ]),
        ("Ocio", [
            "play.tv.fill", "gamecontroller.fill", "music.note", "headphones", "film.fill",
            "ticket.fill", "theatermasks.fill", "book.fill", "camera.fill", "paintpalette.fill",
            "soccerball", "party.popper.fill"
        ]),
        ("Trabajo y estudio", [
            "graduationcap.fill", "briefcase.fill", "laptopcomputer", "desktopcomputer",
            "pencil.and.ruler.fill", "books.vertical.fill", "building.2.fill", "doc.text.fill"
        ]),
        ("Dinero", [
            "creditcard.fill", "banknote.fill", "dollarsign.circle.fill", "chart.line.uptrend.xyaxis",
            "building.columns.fill", "percent", "arrow.left.arrow.right", "lock.fill", "shield.fill"
        ]),
        ("Personas y mascotas", [
            "person.fill", "person.2.fill", "figure.stand.dress", "figure.stand", "figure.child",
            "figure.2.and.child.holdinghands", "stroller.fill", "pawprint.fill", "hare.fill"
        ]),
        ("Otros", [
            "star.fill", "flag.fill", "globe.americas.fill", "sun.max.fill", "cloud.fill",
            "questionmark.circle.fill", "ellipsis.circle.fill", "tray.full.fill"
        ])
    ]

    static let all: [String] = groups.flatMap(\.symbols)
}

/// Catálogo de categorías personalizadas.
///
/// Guarda **sólo** lo que el usuario cambió. Una categoría que nunca se tocó no
/// tiene fila aquí y sigue resolviéndose por `CategoryStyle`, así que este store
/// puede estar vacío y la app se comporta igual que antes.
final class CategoryCatalog: ObservableObject {

    static let shared = CategoryCatalog()

    static let key = "categoryCatalog"

    @Published private(set) var entries: [String: CustomCategory] = [:]

    /// Las básicas que se quitaron o renombraron. Aparte de `entries` y con su
    /// propio candado: la sincronización del correo la consulta fuera del
    /// hilo principal.
    let builtIns: BuiltInCategoryStore

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        builtIns = BuiltInCategoryStore(defaults: defaults)
        entries = Self.decode(defaults.data(forKey: Self.key) ?? Data())
    }

    func entry(for name: String) -> CustomCategory? { entries[name] }

    func color(for name: String) -> Color? { CategoryPalette.color(for: entries[name]?.colorID) }

    func icon(for name: String) -> String? { entries[name]?.icon }

    /// Categorías creadas por el usuario que aún no tienen ningún gasto: sin
    /// esto, crear una categoría desde `6a` y no asignar nada la haría
    /// desaparecer al cerrar la pantalla.
    var names: [String] { Array(entries.keys) }

    /// Guardar con el nombre de una básica que se había quitado la trae de
    /// vuelta: crear «Comida» otra vez es deshacer haberla eliminado.
    func save(_ category: CustomCategory) {
        objectWillChange.send()
        builtIns.restore(category.name)
        entries[category.name] = category
        persist()
    }

    /// Eliminar. Si era básica queda oculta —si no, volvería a salir en las
    /// listas— y el motor deja de sugerirla.
    func delete(_ name: String) {
        objectWillChange.send()
        entries[name] = nil
        builtIns.hide(name, redirectTo: nil)
        persist()
    }

    /// Fusionar: lo que el motor mandaba a `source` pasa a ir a `target`.
    func merge(_ source: String, into target: String) {
        guard source != target else { return }
        objectWillChange.send()
        entries[source] = nil
        builtIns.hide(source, redirectTo: target)
        persist()
    }

    /// Empezar de cero (Configuración › Borrar datos): todas las categorías
    /// personalizadas de una vez, no una por una, y las básicas de vuelta.
    func removeAll() {
        objectWillChange.send()
        entries = [:]
        builtIns.reset()
        persist()
    }

    func rename(_ name: String, to newName: String) {
        guard name != newName else { return }
        objectWillChange.send()
        var moved = entries[name] ?? CustomCategory(name: name)
        moved.name = newName
        entries[name] = nil
        entries[newName] = moved
        builtIns.restore(newName)
        builtIns.hide(name, redirectTo: newName)
        persist()
    }

    /// Sólo la bandeja: «Sin Clasificar» es un estado, no una categoría. Las
    /// básicas se pueden renombrar y eliminar como cualquier otra; se puede
    /// llegar a no tener ninguna.
    static func isSystem(_ name: String) -> Bool {
        name == Accounting.unclassified
    }

    private func persist() {
        let encoded = (try? JSONEncoder().encode(Array(entries.values))) ?? Data()
        defaults.set(encoded, forKey: Self.key)
    }

    private static func decode(_ data: Data) -> [String: CustomCategory] {
        guard let list = try? JSONDecoder().decode([CustomCategory].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
    }
}

// MARK: - Básicas

/// Las categorías con las que arranca la app.
///
/// Doce, pensadas para el gasto de una persona en Perú: siguen las divisiones
/// del IPC del INEI (COICOP) donde pesan —comida fuera y supermercado por
/// separado, vivienda, salud, educación, transporte— y separan lo que el
/// banco sí distingue y el usuario quiere ver aparte (suscripciones, viajes).
/// Ver `Claude outputs/categorias-por-defecto.md`.
///
/// Son sólo el punto de partida: se renombran y se eliminan como cualquier
/// otra. El motor de sugerencias sigue hablando en estos nombres y
/// `BuiltInCategoryStore.resolve` los traduce a lo que el usuario dejó.
enum BuiltInCategories {
    static let all = ["Comida", "Supermercado", "Transporte", "Casa", "Servicios", "Salud",
                      "Educación", "Entretenimiento", "Suscripciones", "Compras", "Viajes", "Otros"]

    static func contains(_ name: String) -> Bool { all.contains(name) }

    /// Si una regla de comercio hacia esta categoría marca el gasto como
    /// suscripción. Antes lo hacía «Entretenimiento»; se mantiene para las
    /// reglas que ya existían.
    static func marksSubscription(_ category: String) -> Bool {
        let builtIns = CategoryCatalog.shared.builtIns
        return ["Suscripciones", "Entretenimiento"].contains { builtIns.resolve($0) == category }
    }
}

/// Qué básicas ya no existen y adónde van ahora sus comercios.
///
/// - `hidden`: básicas eliminadas, fusionadas o renombradas. No salen en las
///   listas.
/// - `redirects`: nombre de fábrica → nombre actual («Comida» → «Restaurantes»
///   tras renombrarla o fusionarla). Sin redirección, una básica oculta hace
///   que el motor no sugiera nada: mejor Pendientes que resucitarla.
final class BuiltInCategoryStore: @unchecked Sendable {

    static let key = "categoryCatalog.builtIns"

    private struct State: Codable {
        var hidden: Set<String> = []
        var redirects: [String: String] = [:]
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var state: State

    init(defaults: UserDefaults) {
        self.defaults = defaults
        state = (defaults.data(forKey: Self.key))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    func isHidden(_ name: String) -> Bool {
        lock.withLock { state.hidden.contains(name) }
    }

    /// Las básicas que siguen en pie, en su orden.
    var visible: [String] {
        let hidden = lock.withLock { state.hidden }
        return BuiltInCategories.all.filter { !hidden.contains($0) }
    }

    /// El nombre que hoy corresponde a una categoría que sugiere el motor, o
    /// `nil` si el usuario la quitó.
    func resolve(_ name: String) -> String? {
        lock.withLock {
            var current = name
            var seen: Set<String> = []
            while let next = state.redirects[current], seen.insert(current).inserted { current = next }
            return state.hidden.contains(current) ? nil : current
        }
    }

    /// Quita `name`. Lo que apuntaba a ella (una básica renombrada antes)
    /// sigue a `target`, o se queda sin destino si se eliminó.
    func hide(_ name: String, redirectTo target: String?) {
        mutate { state in
            for (from, to) in state.redirects where to == name {
                state.redirects[from] = target
            }
            guard BuiltInCategories.contains(name) else { return }
            state.hidden.insert(name)
            state.redirects[name] = target
        }
    }

    /// Una categoría con ese nombre vuelve a existir.
    func restore(_ name: String) {
        mutate { state in
            state.hidden.remove(name)
            state.redirects[name] = nil
        }
    }

    func reset() { mutate { $0 = State() } }

    private func mutate(_ change: (inout State) -> Void) {
        let encoded: Data? = lock.withLock {
            change(&state)
            return try? JSONEncoder().encode(state)
        }
        defaults.set(encoded, forKey: Self.key)
    }
}

// MARK: - Operaciones sobre categorías

/// Renombrar, fusionar y eliminar tocan cuatro sitios a la vez —los gastos, las
/// reglas de comercio, el catálogo y el límite—. Están aquí juntas para que
/// ninguna vista haga sólo tres de las cuatro.
///
/// El `modelContext.save()` lo hace quien llama: es la vista la que sabe si el
/// usuario puede deshacer todavía.
enum CategoryEditor {

    /// Cuántos gastos caen hoy en la categoría. Es el número que `6b` enseña
    /// antes de eliminar; sin él, borrar es una apuesta.
    static func expenseCount(of category: String, in expenses: [Expense]) -> Int {
        expenses.reduce(0) { $0 + ($1.category == category ? 1 : 0) }
    }

    /// Comercios cuya regla apunta a esta categoría ("QUÉ CAE AQUÍ").
    static func merchants(for category: String,
                          defaults: UserDefaults = .standard) -> [String] {
        MerchantRules.all(defaults)
            .filter { $0.value == category }
            .keys
            .sorted { Accounting.displayName($0) < Accounting.displayName($1) }
    }

    /// `async` — quien llama corre esto dentro de un `Task` y muestra un
    /// indicador mientras dura, en vez de congelar la pantalla: una categoría
    /// con años de historial puede ser miles de gastos.
    static func rename(_ category: String,
                       to newName: String,
                       in expenses: [Expense],
                       catalog: CategoryCatalog = .shared,
                       budgets: CategoryBudgetStore = .shared,
                       defaults: UserDefaults = .standard) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != category, !CategoryCatalog.isSystem(category) else { return }

        await Batching.run(expenses.filter { $0.category == category }) { expense in
            expense.category = trimmed
        }
        for (merchant, target) in MerchantRules.all(defaults) where target == category {
            MerchantRules.set(trimmed, for: merchant, defaults: defaults)
        }
        ExpenseEditStore.replaceCategory(category, with: trimmed, defaults: defaults)
        catalog.rename(category, to: trimmed)
        budgets.rename(category, to: trimmed)
    }

    /// Mueve los gastos y **suma** los límites. Fusionar existe para no perder
    /// información: eliminar era la única salida y dejaba los gastos huérfanos.
    static func merge(_ source: String,
                      into target: String,
                      in expenses: [Expense],
                      catalog: CategoryCatalog = .shared,
                      budgets: CategoryBudgetStore = .shared,
                      defaults: UserDefaults = .standard) async {
        guard source != target else { return }

        await Batching.run(expenses.filter { $0.category == source }) { expense in
            expense.category = target
        }
        for (merchant, category) in MerchantRules.all(defaults) where category == source {
            MerchantRules.set(target, for: merchant, defaults: defaults)
        }
        ExpenseEditStore.replaceCategory(source, with: target, defaults: defaults)
        budgets.merge(source, into: target)
        catalog.merge(source, into: target)
    }

    /// Los gastos pasan a `Sin Clasificar` y las reglas del comercio se borran:
    /// dejarlas apuntando a una categoría que ya no existe haría reaparecer el
    /// nombre en la siguiente sincronización.
    static func delete(_ category: String,
                       in expenses: [Expense],
                       catalog: CategoryCatalog = .shared,
                       budgets: CategoryBudgetStore = .shared,
                       defaults: UserDefaults = .standard) async {
        guard !CategoryCatalog.isSystem(category) else { return }

        await Batching.run(expenses.filter { $0.category == category }) { expense in
            expense.category = Accounting.unclassified
        }
        for (merchant, target) in MerchantRules.all(defaults) where target == category {
            MerchantRules.remove(merchant, defaults: defaults)
        }
        ExpenseEditStore.replaceCategory(category, with: Accounting.unclassified, defaults: defaults)
        budgets.remove(category)
        catalog.delete(category)
    }
}

/// El texto de la confirmación al eliminar, el mismo en Categorías, en el
/// selector de categoría y en la ficha de la categoría.
enum CategoryDeletion {
    static func message(for category: String, in expenses: [Expense]) -> String {
        let count = CategoryEditor.expenseCount(of: category, in: expenses)
        switch count {
        case 0: return "No tiene gastos. Se borrará también su límite."
        case 1: return "Su gasto pasa a Sin Clasificar y vuelve a Pendientes."
        default: return "Sus \(count) gastos pasan a Sin Clasificar y vuelven a Pendientes."
        }
    }
}
