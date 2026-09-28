import Foundation
import Testing
@testable import Notifable

/// Las básicas se pueden eliminar, renombrar y fusionar, y el motor de
/// sugerencias —que habla en nombres de fábrica— sigue esos cambios.
struct BuiltInCategoriesTests {

    private func freshCatalog() -> CategoryCatalog {
        let suite = "BuiltInCategoriesTests-" + UUID().uuidString
        return CategoryCatalog(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test("Doce básicas y sólo la bandeja es del sistema")
    func arranque() {
        let catalog = freshCatalog()
        #expect(catalog.builtIns.visible == BuiltInCategories.all)
        #expect(BuiltInCategories.all.count == 12)
        #expect(CategoryCatalog.isSystem(Accounting.unclassified))
        #expect(!CategoryCatalog.isSystem("Comida"))
    }

    @Test("Eliminar una básica la oculta y el motor deja de sugerirla")
    func eliminar() {
        let catalog = freshCatalog()
        catalog.delete("Comida")
        #expect(!catalog.builtIns.visible.contains("Comida"))
        #expect(catalog.builtIns.resolve("Comida") == nil)
        #expect(catalog.builtIns.resolve("Transporte") == "Transporte")
    }

    @Test("Se puede quedar sin ninguna categoría")
    func sinCategorias() {
        let catalog = freshCatalog()
        BuiltInCategories.all.forEach(catalog.delete)
        #expect(catalog.builtIns.visible.isEmpty)
    }

    @Test("Renombrar lleva las sugerencias al nombre nuevo, también encadenado")
    func renombrar() {
        let catalog = freshCatalog()
        catalog.rename("Comida", to: "Restaurantes")
        #expect(catalog.builtIns.resolve("Comida") == "Restaurantes")
        catalog.rename("Restaurantes", to: "Salidas")
        #expect(catalog.builtIns.resolve("Comida") == "Salidas")
        // Eliminar la renombrada corta la cadena: nada vuelve a «Comida».
        catalog.delete("Salidas")
        #expect(catalog.builtIns.resolve("Comida") == nil)
    }

    @Test("Fusionar manda las sugerencias al destino")
    func fusionar() {
        let catalog = freshCatalog()
        catalog.merge("Suscripciones", into: "Entretenimiento")
        #expect(catalog.builtIns.resolve("Suscripciones") == "Entretenimiento")
        #expect(!catalog.builtIns.visible.contains("Suscripciones"))
    }

    @Test("Crear una categoría con el nombre de una básica eliminada la trae de vuelta")
    func restaurar() {
        let catalog = freshCatalog()
        catalog.delete("Viajes")
        catalog.save(CustomCategory(name: "Viajes"))
        #expect(catalog.builtIns.visible.contains("Viajes"))
        #expect(catalog.builtIns.resolve("Viajes") == "Viajes")
    }

    @Test("Borrar datos devuelve las básicas")
    func borrarDatos() {
        let catalog = freshCatalog()
        catalog.delete("Casa")
        catalog.removeAll()
        #expect(catalog.builtIns.visible == BuiltInCategories.all)
    }

    @Test("Catálogo de fábrica: streaming a Suscripciones, vuelos a Viajes, ferretería a Casa")
    func catalogoDeFabrica() {
        let matchers = MerchantCatalog.matchers(for: MerchantCatalog.bundled)
        func category(_ keyword: String) -> String? {
            matchers.first { $0.keyword == MerchantCatalog.normalize(keyword) }?.category
        }
        #expect(category("netflix") == "Suscripciones")
        #expect(category("latam") == "Viajes")
        #expect(category("sodimac") == "Casa")
        #expect(category("platzi") == "Educación")
        #expect(category("cine") == "Entretenimiento")
    }
}
