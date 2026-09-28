import SwiftUI

/// Icono y color de cada categoría, en un solo sitio.
///
/// Antes cada pantalla tenía su propia copia de este `switch` —Resumen,
/// Categorías, el detalle— y ya habían empezado a divergir: Supermercado era
/// teal en la dona y verde en las filas.
///
/// Desde `6b` el usuario puede elegir color e icono: `CategoryCatalog` manda
/// sobre este `switch`, que queda como el valor por defecto de las categorías
/// que nadie ha tocado.
enum CategoryStyle {

    static func icon(for category: String) -> String {
        if let custom = CategoryCatalog.shared.icon(for: category) { return custom }
        return defaultIcon(for: category)
    }

    static func defaultIcon(for category: String) -> String {
        switch category {
        case "Comida": return "fork.knife"
        case "Transporte": return "car.fill"
        case "Entretenimiento": return "play.tv.fill"
        case "Supermercado": return "cart.fill"
        case "Servicios": return "bolt.fill"
        case "Salud": return "cross.case.fill"
        case "Compras": return "bag.fill"
        case "Casa": return "house.fill"
        case "Educación": return "graduationcap.fill"
        case "Suscripciones": return "repeat.circle.fill"
        case "Viajes": return "airplane"
        case "Otros": return "ellipsis.circle.fill"
        case Accounting.unclassified: return "tray.full.fill"
        default: 
            let key = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Antes el catálogo de palabras; si no, ¿es una persona? ("María",
            // "Regalos papá", "Mi hijo"). Ver `PersonCategoryIcon`.
            return hiddenIcons[key] ?? PersonCategoryIcon.icon(for: category) ?? "bag.fill"
        }
    }

    static func color(for category: String, accent: Color) -> Color {
        if let custom = CategoryCatalog.shared.color(for: category) { return custom }
        if AppThemeColor.usesThemedCategoryColors, let themed = themedColor(for: category) {
            return themed
        }
        return defaultColor(for: category, accent: accent)
    }

    /// Orden fijo en la rampa del tema para las categorías por defecto, así
    /// las más comunes nunca comparten tono entre sí.
    private static let rampOrder = ["Comida", "Supermercado", "Transporte", "Entretenimiento",
                                    "Servicios", "Otros", "Salud", "Compras",
                                    "Casa", "Suscripciones", "Viajes", "Educación"]

    /// Color de la rampa del tema (Ajustes › Apariencia). "Sin Clasificar" se
    /// queda gris: es un estado, no una categoría.
    static func themedColor(for category: String) -> Color? {
        guard category != Accounting.unclassified else { return nil }
        let ramp = AppThemeColor.current.categoryRamp(.light)
        let index = rampOrder.firstIndex(of: category)
            ?? category.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return ramp[index % ramp.count]
    }

    static func defaultColor(for category: String, accent: Color) -> Color {
        switch category {
        case "Comida": return .orange
        case "Transporte": return .blue
        case "Entretenimiento": return accent
        case "Supermercado": return .teal
        case "Otros": return .green
        case "Servicios": return .yellow
        case "Salud": return .pink
        case "Compras": return .indigo
        case "Casa": return .brown
        case "Educación": return .mint
        case "Suscripciones": return .purple
        case "Viajes": return .cyan
        case Accounting.unclassified: return .gray
        default:
            let key = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let color = hiddenColors[key] {
                return color
            }
            // Color estable derivado del nombre, para categorías creadas por el
            // usuario. `hashValue` cambia entre ejecuciones, así que no sirve.
            let sum = category.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            return Color(hue: Double(sum % 360) / 360.0, saturation: 0.6, brightness: 0.8)
        }
    }

    /// Nombre corto para cuando el largo no cabe en una línea:
    /// «Entretenimiento» → «Entr.», «Supermercado» → «Super.».
    ///
    /// Se corta como se abrevia en castellano: al menos cuatro letras y
    /// terminando en consonante, con el punto. Las palabras cortas se dejan
    /// igual —«Comida» se entiende mejor entera que «Com.»—.
    static func shortName(for category: String) -> String {
        if let fixed = shortNames[category] { return fixed }
        return category
            .split(separator: " ")
            .map { abbreviate(String($0)) }
            .joined(separator: " ")
    }

    private static let shortNames = [
        "Entretenimiento": "Entr.",
        "Supermercado": "Super.",
        "Transporte": "Transp.",
        "Servicios": "Serv.",
        "Suscripciones": "Suscr.",
        "Educación": "Educ.",
        Accounting.unclassified: "Sin clas."
    ]

    private static func abbreviate(_ word: String) -> String {
        let letters = Array(word)
        guard letters.count > 8 else { return word }
        let vowels = Set("aeiouáéíóúAEIOUÁÉÍÓÚ")
        var end = 4
        while end < letters.count - 2, vowels.contains(letters[end - 1]) { end += 1 }
        return String(letters[..<end]) + "."
    }

    /// Las básicas que el usuario no quitó, sin "Sin Clasificar": ése es el
    /// estado de lo que llega del banco sin regla, no algo que se elija a
    /// mano. Puede quedar vacía. Ver `BuiltInCategories`.
    static var defaults: [String] { CategoryCatalog.shared.builtIns.visible }

    /// Adónde va lo que antes caía en «Otros» por defecto (un gasto a mano,
    /// una recurrencia nueva). Si se eliminó, a Pendientes.
    static var fallback: String {
        CategoryCatalog.shared.builtIns.resolve("Otros") ?? Accounting.unclassified
    }

    /// Todas las categorías elegibles, con las más usadas por delante.
    ///
    /// Incluye las del catálogo aunque no tengan ni un gasto: una categoría
    /// recién creada en `6a` tiene que sobrevivir a cerrar la pantalla.
    static func selectable(history: [Expense]) -> [String] {
        selectable(counts: usageCounts(history))
    }

    /// Cuántos gastos hay por categoría, sin contar «Sin Clasificar». Se
    /// puede calcular fuera del hilo principal; `selectable(counts:)` no,
    /// porque lee `CategoryCatalog`.
    static func usageCounts(_ history: [Expense]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for expense in history where expense.category != Accounting.unclassified {
            counts[expense.category, default: 0] += 1
        }
        return counts
    }

    static func selectable(counts: [String: Int]) -> [String] {
        let known = Set(counts.keys)
            .union(defaults)
            .union(CategoryCatalog.shared.names)
        return known.sorted { lhs, rhs in
            let l = counts[lhs] ?? 0
            let r = counts[rhs] ?? 0
            return l == r ? lhs < rhs : l > r
        }
    }

    /// Alfabéticas, para las listas donde la posición debe ser estable.
    static func alphabetical(history: [Expense]) -> [String] {
        selectable(history: history).sorted()
    }
    
    // MARK: - Autocompletado Oculto
    
    /// Gran catálogo oculto de iconos separado por temáticas.
    /// Si el usuario escribe una de estas palabras, automáticamente se le asignará el icono correspondiente.
    private static let hiddenIcons: [String: String] = [
        // Comida
        "restaurante": "fork.knife", "restaurantes": "fork.knife", "almuerzo": "fork.knife", "cena": "fork.knife", "desayuno": "fork.knife", "comida": "fork.knife", "chifa": "fork.knife", "pollería": "fork.knife", "cevichería": "fork.knife", "menu": "fork.knife", "menú": "fork.knife",
        "fast food": "takeoutbag.and.cup.and.straw.fill", "comida rápida": "takeoutbag.and.cup.and.straw.fill", "hamburguesa": "takeoutbag.and.cup.and.straw.fill", "pizza": "takeoutbag.and.cup.and.straw.fill", "kfc": "takeoutbag.and.cup.and.straw.fill", "mcdonalds": "takeoutbag.and.cup.and.straw.fill", "bembos": "takeoutbag.and.cup.and.straw.fill", "burger king": "takeoutbag.and.cup.and.straw.fill",
        "postres": "birthday.cake.fill", "dulces": "birthday.cake.fill", "panadería": "birthday.cake.fill", "pastelería": "birthday.cake.fill", "torta": "birthday.cake.fill", "empanadas": "birthday.cake.fill",
        "helado": "icecream.fill", "heladería": "icecream.fill",
        
        // Bebidas
        "cafe": "cup.and.saucer.fill", "café": "cup.and.saucer.fill", "cafeteria": "cup.and.saucer.fill", "cafetería": "cup.and.saucer.fill", "starbucks": "cup.and.saucer.fill", "té": "cup.and.saucer.fill", "infusión": "cup.and.saucer.fill",
        "bar": "wineglass.fill", "cerveza": "wineglass.fill", "tragos": "wineglass.fill", "alcohol": "wineglass.fill", "fiesta": "wineglass.fill", "discoteca": "wineglass.fill", "pub": "wineglass.fill", "licor": "wineglass.fill", "licorería": "wineglass.fill", "vino": "wineglass.fill", "pisquera": "wineglass.fill",
        
        // Supermercado
        "supermercado": "cart.fill", "mercado": "cart.fill", "despensa": "cart.fill", "abarrotes": "cart.fill", "bodega": "cart.fill", "wong": "cart.fill", "plaza vea": "cart.fill", "tottus": "cart.fill", "vivanda": "cart.fill", "metro": "cart.fill", "makro": "cart.fill", "tambo": "cart.fill", "oxxo": "cart.fill", "mass": "cart.fill", "minimarket": "cart.fill",
        "verdulería": "basket.fill", "frutería": "basket.fill", "carnicería": "basket.fill",
        
        // Transporte Privado
        "uber": "car.fill", "taxi": "car.fill", "cabify": "car.fill", "indriver": "car.fill", "didi": "car.fill", "yango": "car.fill",
        "gasolina": "fuelpump.fill", "combustible": "fuelpump.fill", "grifo": "fuelpump.fill", "repsol": "fuelpump.fill", "primax": "fuelpump.fill", "pecsa": "fuelpump.fill",
        "peaje": "car.fill",
        "estacionamiento": "parkingsign", "parking": "parkingsign", "cochera": "parkingsign", "los portales": "parkingsign",
        "mantenimiento auto": "wrench.and.screwdriver.fill", "taller": "wrench.and.screwdriver.fill", "mecánico": "wrench.and.screwdriver.fill",
        
        // Transporte Público
        "bus": "bus.fill", "autobús": "bus.fill", "pasajes de bus": "bus.fill", "transporte público": "bus.fill", "corredor": "bus.fill", "metropolitano": "bus.fill",
        "tren": "tram.fill", "metro de lima": "tram.fill", "línea 1": "tram.fill",
        
        // Viajes y Turismo
        "vuelos": "airplane", "avión": "airplane", "pasajes": "airplane", "viajes": "airplane", "turismo": "airplane", "aerolínea": "airplane", "latam": "airplane", "sky": "airplane", "jetsmart": "airplane",
        "hotel": "bed.double.fill", "hospedaje": "bed.double.fill", "alojamiento": "bed.double.fill", "airbnb": "bed.double.fill", "resort": "bed.double.fill", "hostal": "bed.double.fill",
        "maletas": "suitcase.fill", "equipaje": "suitcase.fill",
        
        // Entretenimiento en Casa
        "streaming": "play.tv.fill", "netflix": "play.tv.fill", "spotify": "play.tv.fill", "hbo": "play.tv.fill", "disney": "play.tv.fill", "prime video": "play.tv.fill", "suscripciones": "play.tv.fill", "suscripción": "play.tv.fill", "apple tv": "play.tv.fill", "youtube premium": "play.tv.fill",
        
        // Entretenimiento Fuera
        "cine": "ticket.fill", "películas": "ticket.fill", "teatro": "ticket.fill", "concierto": "ticket.fill", "entradas": "ticket.fill", "cineplanet": "ticket.fill", "cinemark": "ticket.fill", "tkts": "ticket.fill", "teleticket": "ticket.fill", "joinnus": "ticket.fill",
        "museo": "building.columns.fill", "exposición": "building.columns.fill", "arte": "building.columns.fill",
        "parque de diversiones": "figure.play", "juegos mecánicos": "figure.play",
        
        // Gaming
        "juegos": "gamecontroller.fill", "videojuegos": "gamecontroller.fill", "gaming": "gamecontroller.fill", "playstation": "gamecontroller.fill", "xbox": "gamecontroller.fill", "nintendo": "gamecontroller.fill", "steam": "gamecontroller.fill", "epic games": "gamecontroller.fill", "riot": "gamecontroller.fill",
        
        // Salud
        "salud": "cross.case.fill", "clínica": "cross.case.fill", "hospital": "cross.case.fill", "doctor": "cross.case.fill", "médico": "cross.case.fill", "dentista": "cross.case.fill", "odontólogo": "cross.case.fill", "terapia": "cross.case.fill", "psicólogo": "cross.case.fill", "oftalmólogo": "cross.case.fill", "pediatra": "cross.case.fill", "exámenes médicos": "cross.case.fill",
        "medicina": "pills.fill", "pastillas": "pills.fill", "farmacia": "pills.fill", "inkafarma": "pills.fill", "mifarma": "pills.fill", "botica": "pills.fill", "receta": "pills.fill",
        
        // Cuidado Personal y Belleza
        "belleza": "scissors", "peluquería": "scissors", "barbería": "scissors", "corte de pelo": "scissors",
        "maquillaje": "comb.fill", "skincare": "comb.fill", "cuidado de la piel": "comb.fill",
        "spa": "sparkles", "masajes": "sparkles", "cosméticos": "sparkles", "perfume": "sparkles", "aruma": "sparkles",
        
        // Mascotas
        "mascotas": "pawprint.fill", "mascota": "pawprint.fill", "perro": "pawprint.fill", "gato": "pawprint.fill", "veterinaria": "pawprint.fill", "comida para perro": "pawprint.fill", "comida para gato": "pawprint.fill", "grooming": "pawprint.fill", "pet shop": "pawprint.fill", "superpet": "pawprint.fill",
        
        // Ropa y Accesorios
        "ropa": "tshirt.fill", "moda": "tshirt.fill", "vestuario": "tshirt.fill", "prendas": "tshirt.fill", "zara": "tshirt.fill", "h&m": "tshirt.fill", "falabella": "tshirt.fill", "ripley": "tshirt.fill", "oechsle": "tshirt.fill",
        "zapatos": "shoe.fill", "zapatillas": "shoe.fill", "calzado": "shoe.fill", "nike": "shoe.fill", "adidas": "shoe.fill", "puma": "shoe.fill",
        "joyería": "diamond.fill", "relojes": "diamond.fill", "accesorios": "diamond.fill",
        
        // Tecnología y Electrónica
        "tecnología": "desktopcomputer", "electrónica": "desktopcomputer", "gadgets": "desktopcomputer", "computadora": "desktopcomputer", "pc": "desktopcomputer", "monitor": "desktopcomputer",
        "laptop": "laptopcomputer", "notebook": "laptopcomputer",
        "celular": "iphone", "smartphone": "iphone", "iphone": "iphone", "apple": "iphone", "samsung": "iphone", "xiaomi": "iphone", "cargador": "iphone", "audífonos": "iphone",
        
        // Educación
        "educación": "graduationcap.fill", "universidad": "graduationcap.fill", "colegio": "graduationcap.fill", "cursos": "graduationcap.fill", "diplomado": "graduationcap.fill", "maestría": "graduationcap.fill", "pensiones": "graduationcap.fill", "matrícula": "graduationcap.fill",
        "libros": "book.fill", "librería": "book.fill", "lectura": "book.fill", "crisol": "book.fill", "sbs": "book.fill",
        "útiles": "pencil", "papelería": "pencil", "tayloy": "pencil",
        
        // Deportes y Fitness
        "gimnasio": "dumbbell.fill", "gym": "dumbbell.fill", "smart fit": "dumbbell.fill", "bodytech": "dumbbell.fill", "pesas": "dumbbell.fill",
        "deportes": "figure.run", "fitness": "figure.run", "fútbol": "figure.run", "tenis": "figure.run", "natación": "figure.run", "ciclismo": "figure.run",
        "suplementos": "leaf.fill", "proteína": "leaf.fill", "vitaminas": "leaf.fill",
        
        // Hogar
        "hogar": "house.fill", "casa": "house.fill", "decoración": "house.fill", "muebles": "house.fill", "sofa": "house.fill", "cama": "house.fill", "colchón": "house.fill",
        "ferretería": "hammer.fill", "sodimac": "hammer.fill", "promart": "hammer.fill", "maestro": "hammer.fill", "herramientas": "hammer.fill",
        "alquiler": "key.fill", "renta": "key.fill", "departamento": "key.fill", "arriendo": "key.fill", "mensualidad casa": "key.fill",
        
        // Servicios Básicos
        "servicios": "bolt.fill", "luz": "bolt.fill", "enel": "bolt.fill", "luz del sur": "bolt.fill",
        "agua": "drop.fill", "sedapal": "drop.fill",
        "internet": "wifi", "movistar": "wifi", "claro": "wifi", "entel": "wifi", "win": "wifi", "wow": "wifi",
        "teléfono": "phone.fill", "celular (plan)": "phone.fill", "plan móvil": "phone.fill", "recarga": "phone.fill",
        "cable": "tv.fill", "directv": "tv.fill",
        
        // Mantenimiento y Limpieza
        "limpieza": "sparkles", "aseo": "sparkles", "detergente": "sparkles", "artículos de limpieza": "sparkles",
        "mantenimiento": "wrench.and.screwdriver.fill", "reparación": "wrench.and.screwdriver.fill", "gasfitero": "wrench.and.screwdriver.fill", "electricista": "wrench.and.screwdriver.fill",
        
        // Finanzas y Seguros
        "impuestos": "building.columns.fill", "sunat": "building.columns.fill", "tributos": "building.columns.fill", "arbitrios": "building.columns.fill", "predial": "building.columns.fill", "multas": "building.columns.fill", "sat": "building.columns.fill",
        "seguros": "shield.fill", "seguro": "shield.fill", "póliza": "shield.fill", "rimac": "shield.fill", "pacifico": "shield.fill", "mapfre": "shield.fill", "lapositiva": "shield.fill", "eps": "shield.fill",
        "banco": "building.columns.fill", "comisiones": "building.columns.fill", "mantenimiento cuenta": "building.columns.fill", "membresía": "building.columns.fill",
        "intereses": "percent", "tasas": "percent",
        "préstamo": "dollarsign.circle.fill", "cuota": "dollarsign.circle.fill", "hipoteca": "dollarsign.circle.fill", "crédito": "dollarsign.circle.fill",
        "tarjeta de crédito": "creditcard.fill", "tc": "creditcard.fill", "pago tarjeta": "creditcard.fill",
        "ahorros": "chart.line.uptrend.xyaxis", "inversiones": "chart.line.uptrend.xyaxis", "depósito plazo": "chart.line.uptrend.xyaxis", "fondos mutuos": "chart.line.uptrend.xyaxis",
        
        // Regalos y Donaciones
        "regalos": "gift.fill", "obsequios": "gift.fill", "sorpresas": "gift.fill", "navidad": "gift.fill", "cumpleaños": "gift.fill",
        "donaciones": "heart.fill", "caridad": "heart.fill", "ong": "heart.fill", "apoyo": "heart.fill",
        
        // Otros y Envíos
        "otros": "ellipsis.circle.fill", "miscelánea": "ellipsis.circle.fill", "varios": "ellipsis.circle.fill",
        "delivery": "motorcycle.fill", "rappi": "motorcycle.fill", "pedidosya": "motorcycle.fill", "didi food": "motorcycle.fill", "envío": "motorcycle.fill", "courier": "motorcycle.fill", "olva": "motorcycle.fill", "shalom": "motorcycle.fill"
    ]
    
    /// Gran catálogo oculto de colores asociados a las categorías.
    private static let hiddenColors: [String: Color] = [
        // Comida
        "restaurante": .orange, "restaurantes": .orange, "almuerzo": .orange, "cena": .orange, "desayuno": .orange, "comida": .orange, "chifa": .orange, "pollería": .orange, "cevichería": .orange, "menu": .orange, "menú": .orange,
        "fast food": .orange, "comida rápida": .orange, "hamburguesa": .orange, "pizza": .orange, "kfc": .orange, "mcdonalds": .orange, "bembos": .orange, "burger king": .orange,
        "postres": .pink, "dulces": .pink, "panadería": .pink, "pastelería": .pink, "torta": .pink, "empanadas": .pink,
        "helado": .pink, "heladería": .pink,
        
        // Bebidas
        "cafe": .brown, "café": .brown, "cafeteria": .brown, "cafetería": .brown, "starbucks": .brown, "té": .brown, "infusión": .brown,
        "bar": .purple, "cerveza": .purple, "tragos": .purple, "alcohol": .purple, "fiesta": .purple, "discoteca": .purple, "pub": .purple, "licor": .purple, "licorería": .purple, "vino": .purple, "pisquera": .purple,
        
        // Supermercado
        "supermercado": .teal, "mercado": .teal, "despensa": .teal, "abarrotes": .teal, "bodega": .teal, "wong": .teal, "plaza vea": .teal, "tottus": .teal, "vivanda": .teal, "metro": .teal, "makro": .teal, "tambo": .teal, "oxxo": .teal, "mass": .teal, "minimarket": .teal,
        "verdulería": .green, "frutería": .green, "carnicería": .red,
        
        // Transporte Privado
        "uber": .blue, "taxi": .blue, "cabify": .blue, "indriver": .blue, "didi": .blue, "yango": .blue,
        "gasolina": .orange, "combustible": .orange, "grifo": .orange, "repsol": .orange, "primax": .orange, "pecsa": .orange,
        "peaje": .blue,
        "estacionamiento": .gray, "parking": .gray, "cochera": .gray, "los portales": .gray,
        "mantenimiento auto": .gray, "taller": .gray, "mecánico": .gray,
        
        // Transporte Público
        "bus": .blue, "autobús": .blue, "pasajes de bus": .blue, "transporte público": .blue, "corredor": .blue, "metropolitano": .blue,
        "tren": .blue, "metro de lima": .blue, "línea 1": .blue,
        
        // Viajes y Turismo
        "vuelos": .cyan, "avión": .cyan, "pasajes": .cyan, "viajes": .cyan, "turismo": .cyan, "aerolínea": .cyan, "latam": .cyan, "sky": .cyan, "jetsmart": .cyan,
        "hotel": .indigo, "hospedaje": .indigo, "alojamiento": .indigo, "airbnb": .indigo, "resort": .indigo, "hostal": .indigo,
        "maletas": .cyan, "equipaje": .cyan,
        
        // Entretenimiento en Casa
        "streaming": .red, "netflix": .red, "spotify": .green, "hbo": .purple, "disney": .blue, "prime video": .cyan, "suscripciones": .red, "suscripción": .red, "apple tv": .gray, "youtube premium": .red,
        
        // Entretenimiento Fuera
        "cine": .red, "películas": .red, "teatro": .red, "concierto": .red, "entradas": .red, "cineplanet": .blue, "cinemark": .red, "tkts": .orange, "teleticket": .yellow, "joinnus": .green,
        "museo": .orange, "exposición": .orange, "arte": .orange,
        "parque de diversiones": .purple, "juegos mecánicos": .purple,
        
        // Gaming
        "juegos": .purple, "videojuegos": .purple, "gaming": .purple, "playstation": .blue, "xbox": .green, "nintendo": .red, "steam": .black, "epic games": .gray, "riot": .red,
        
        // Salud
        "salud": .pink, "clínica": .pink, "hospital": .pink, "doctor": .pink, "médico": .pink, "dentista": .pink, "odontólogo": .pink, "terapia": .pink, "psicólogo": .pink, "oftalmólogo": .pink, "pediatra": .pink, "exámenes médicos": .pink,
        "medicina": .pink, "pastillas": .pink, "farmacia": .pink, "inkafarma": .pink, "mifarma": .pink, "botica": .pink, "receta": .pink,
        
        // Cuidado Personal y Belleza
        "belleza": .pink, "peluquería": .pink, "barbería": .blue, "corte de pelo": .pink,
        "maquillaje": .pink, "skincare": .pink, "cuidado de la piel": .pink,
        "spa": .teal, "masajes": .teal, "cosméticos": .pink, "perfume": .purple, "aruma": .pink,
        
        // Mascotas
        "mascotas": .brown, "mascota": .brown, "perro": .brown, "gato": .brown, "veterinaria": .brown, "comida para perro": .brown, "comida para gato": .brown, "grooming": .brown, "pet shop": .brown, "superpet": .brown,
        
        // Ropa y Accesorios
        "ropa": .pink, "moda": .pink, "vestuario": .pink, "prendas": .pink, "zara": .gray, "h&m": .red, "falabella": .green, "ripley": .purple, "oechsle": .red,
        "zapatos": .brown, "zapatillas": .blue, "calzado": .brown, "nike": .black, "adidas": .black, "puma": .black,
        "joyería": .indigo, "relojes": .gray, "accesorios": .indigo,
        
        // Tecnología y Electrónica
        "tecnología": .gray, "electrónica": .gray, "gadgets": .gray, "computadora": .gray, "pc": .gray, "monitor": .gray,
        "laptop": .gray, "notebook": .gray,
        "celular": .gray, "smartphone": .gray, "iphone": .gray, "apple": .gray, "samsung": .blue, "xiaomi": .orange, "cargador": .gray, "audífonos": .gray,
        
        // Educación
        "educación": .blue, "universidad": .blue, "colegio": .blue, "cursos": .blue, "diplomado": .blue, "maestría": .blue, "pensiones": .blue, "matrícula": .blue,
        "libros": .orange, "librería": .orange, "lectura": .orange, "crisol": .orange, "sbs": .blue,
        "útiles": .yellow, "papelería": .yellow, "tayloy": .yellow,
        
        // Deportes y Fitness
        "gimnasio": .green, "gym": .green, "smart fit": .yellow, "bodytech": .red, "pesas": .gray,
        "deportes": .green, "fitness": .green, "fútbol": .green, "tenis": .green, "natación": .blue, "ciclismo": .orange,
        "suplementos": .green, "proteína": .green, "vitaminas": .orange,
        
        // Hogar
        "hogar": .orange, "casa": .orange, "decoración": .yellow, "muebles": .brown, "sofa": .brown, "cama": .indigo, "colchón": .indigo,
        "ferretería": .gray, "sodimac": .red, "promart": .orange, "maestro": .yellow, "herramientas": .gray,
        "alquiler": .brown, "renta": .brown, "departamento": .brown, "arriendo": .brown, "mensualidad casa": .brown,
        
        // Servicios Básicos
        "servicios": .yellow, "luz": .yellow, "enel": .orange, "luz del sur": .yellow,
        "agua": .blue, "sedapal": .blue,
        "internet": .blue, "movistar": .green, "claro": .red, "entel": .blue, "win": .orange, "wow": .pink,
        "teléfono": .green, "celular (plan)": .green, "plan móvil": .green, "recarga": .green,
        "cable": .purple, "directv": .blue,
        
        // Mantenimiento y Limpieza
        "limpieza": .cyan, "aseo": .cyan, "detergente": .cyan, "artículos de limpieza": .cyan,
        "mantenimiento": .gray, "reparación": .gray, "gasfitero": .gray, "electricista": .yellow,
        
        // Finanzas y Seguros
        "impuestos": .gray, "sunat": .gray, "tributos": .gray, "arbitrios": .gray, "predial": .gray, "multas": .red, "sat": .gray,
        "seguros": .blue, "seguro": .blue, "póliza": .blue, "rimac": .red, "pacifico": .blue, "mapfre": .red, "lapositiva": .green, "eps": .blue,
        "banco": .red, "comisiones": .red, "mantenimiento cuenta": .red, "membresía": .red,
        "intereses": .green, "tasas": .green,
        "préstamo": .orange, "cuota": .orange, "hipoteca": .orange, "crédito": .orange,
        "tarjeta de crédito": .gray, "tc": .gray, "pago tarjeta": .gray,
        "ahorros": .green, "inversiones": .green, "depósito plazo": .green, "fondos mutuos": .green,
        
        // Regalos y Donaciones
        "regalos": .pink, "obsequios": .pink, "sorpresas": .pink, "navidad": .red, "cumpleaños": .pink,
        "donaciones": .pink, "caridad": .pink, "ong": .pink, "apoyo": .pink,
        
        // Otros y Envíos
        "otros": .gray, "miscelánea": .gray, "varios": .gray,
        "delivery": .orange, "rappi": .orange, "pedidosya": .red, "didi food": .orange, "envío": .orange, "courier": .blue, "olva": .yellow, "shalom": .red
    ]
}
