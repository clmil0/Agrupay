import Foundation

/// Una palabra que delata la categoría de un comercio ("tottus" → Supermercado).
struct MerchantKeyword: Codable, Equatable, Sendable {
    let keyword: String
    let category: String
}

/// El catálogo de comercios con el que la Bandeja sugiere categorías.
///
/// Vive en Supabase (`merchant_catalog`, ver `agrupay_merchant_catalog.sql`)
/// para poder sumar comercios sin publicar una versión. La app lo baja **una
/// vez** y lo guarda en el teléfono (Application Support, no Caches: iOS no lo
/// borra por falta de espacio), igual que los movimientos. Después, al entrar,
/// sólo pregunta la versión — una línea de texto — y vuelve a bajar la lista
/// únicamente si cambió.
///
/// Sin red y sin nada guardado todavía, usa `bundled`: la lista con la que
/// salió la app, para que la primera apertura sin conexión también sugiera.
final class MerchantCatalog: @unchecked Sendable {

    static let shared = MerchantCatalog()

    struct Stored: Codable, Equatable {
        /// La de `merchant_catalog_version()`. `nil` = la lista de fábrica.
        var version: String?
        var downloadedAt: Date?
        var entries: [MerchantKeyword]
    }

    /// Entre dos consultas de versión: volver a la app tras contestar un
    /// mensaje no debería salir a la red cada vez.
    static let checkInterval: TimeInterval = 15 * 60

    private static let projectURL = "https://zjzzqaeusmxmtszgdncl.supabase.co"
    private static let apiKey = "sb_publishable_NVM2GcvxZFmf0VLNbaBr7A_y_8EMS97"
    private static let pageSize = 1_000

    private let lock = NSLock()
    private let fileURL: URL
    private var stored: Stored
    /// Ya normalizadas y de la más larga a la más corta (ver `category(for:)`).
    private var matchers: [MerchantKeyword]
    private var lastCheck: Date?
    private var isRefreshing = false

    init(fileURL: URL = MerchantCatalog.defaultFileURL) {
        self.fileURL = fileURL
        let saved = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        let initial = saved.flatMap { $0.entries.isEmpty ? nil : $0 } ?? Stored(version: nil, downloadedAt: nil, entries: Self.bundled)
        stored = initial
        matchers = Self.matchers(for: initial.entries)
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MerchantCatalog.json")
    }

    // MARK: - Lectura

    var version: String? { lock.withLock { stored.version } }
    var entries: [MerchantKeyword] { lock.withLock { stored.entries } }

    /// La categoría de una palabra **entera** del catálogo («cine», «plaza
    /// vea»), sin buscarla dentro de otras: en una frase dictada, «gastado»
    /// no puede delatar «gas». Acepta también el plural («pollos»).
    func exactCategory(for word: String) -> String? {
        let clean = Self.normalize(word)
        guard clean.count >= 3 else { return nil }
        let singular = clean.hasSuffix("s") ? String(clean.dropLast()) : clean
        return lock.withLock { matchers }
            .first { $0.keyword == clean || $0.keyword == singular }?
            .category
    }

    /// La categoría de la palabra que aparece primero en el nombre; si dos
    /// empiezan en el mismo sitio, la más larga ("uber eats" gana a "uber",
    /// y en "TOTTUS LA MARINA" gana "tottus" y no "la mar").
    func category(for merchantName: String) -> String? {
        let clean = Self.normalize(merchantName)
        guard !clean.isEmpty else { return nil }
        var best: (offset: Int, entry: MerchantKeyword)?
        for entry in lock.withLock({ matchers }) {
            guard let range = clean.range(of: entry.keyword) else { continue }
            let offset = clean.distance(from: clean.startIndex, to: range.lowerBound)
            // `matchers` va de la más larga a la más corta: con el mismo inicio
            // se queda la primera que se encontró.
            if best == nil || offset < best!.offset { best = (offset, entry) }
        }
        return best?.entry.category
    }

    // MARK: - Actualización

    /// Al entrar a la app. Pregunta la versión y sólo si cambió baja la lista.
    /// Cualquier fallo de red deja intacto lo guardado.
    func refreshIfNeeded(now: Date = Date()) async {
        let shouldCheck: Bool = lock.withLock {
            guard !isRefreshing else { return false }
            if let lastCheck, now.timeIntervalSince(lastCheck) < Self.checkInterval { return false }
            isRefreshing = true
            return true
        }
        guard shouldCheck else { return }
        defer { lock.withLock { isRefreshing = false } }

        guard let remote = await fetchVersion() else { return }
        lock.withLock { lastCheck = now }
        guard remote != version else { return }

        guard let downloaded = await fetchEntries(), !downloaded.isEmpty else { return }
        replace(with: Stored(version: remote, downloadedAt: now, entries: downloaded))
        Diagnostics.shared.log("Catálogo de comercios actualizado: \(downloaded.count) palabras")
    }

    func replace(with new: Stored) {
        if let data = try? JSONEncoder().encode(new) {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
        let newMatchers = Self.matchers(for: new.entries)
        lock.withLock {
            stored = new
            matchers = newMatchers
        }
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest? {
        guard let url = URL(string: Self.projectURL + path) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.addValue(Self.apiKey, forHTTPHeaderField: "apikey")
        request.addValue("Bearer \(Self.apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func fetchVersion() async -> String? {
        guard var request = request("/rest/v1/rpc/merchant_catalog_version", method: "POST") else { return nil }
        request.httpBody = Data("{}".utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let version = try? JSONDecoder().decode(String.self, from: data) else { return nil }
        return version
    }

    /// Por páginas: PostgREST corta en mil filas por respuesta.
    private func fetchEntries() async -> [MerchantKeyword]? {
        var all: [MerchantKeyword] = []
        var offset = 0
        while true {
            let path = "/rest/v1/merchant_catalog?select=keyword,category&active=eq.true&order=id"
                + "&limit=\(Self.pageSize)&offset=\(offset)"
            guard let request = request(path),
                  let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let page = try? JSONDecoder().decode([MerchantKeyword].self, from: data) else { return nil }
            all += page
            guard page.count == Self.pageSize else { return all }
            offset += Self.pageSize
        }
    }

    // MARK: - Normalización

    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_PE"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalizadas igual que el nombre del comercio — sin esto "pollería"
    /// nunca coincidía con un nombre ya sin tildes — y la más larga primero.
    static func matchers(for entries: [MerchantKeyword]) -> [MerchantKeyword] {
        var seen = Set<String>()
        return entries
            .map { MerchantKeyword(keyword: normalize($0.keyword), category: $0.category.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.keyword.count >= 2 && !$0.category.isEmpty && seen.insert($0.keyword).inserted }
            .sorted { $0.keyword.count == $1.keyword.count ? $0.keyword < $1.keyword : $0.keyword.count > $1.keyword.count }
    }

    // MARK: - Lista de fábrica

    /// La misma que siembra `agrupay_merchant_catalog.sql`. Sólo se usa hasta
    /// la primera descarga.
    ///
    /// Marcas con posesivo en español ("McDonald's", "Domino's", "Norky's")
    /// van sin el "'s": los parsers de banco no siempre conservan el
    /// apóstrofo, y la raíz sin él sigue apareciendo dentro del nombre completo.
    static let bundled: [MerchantKeyword] = bundledByCategory.flatMap { category, words in
        words.map { MerchantKeyword(keyword: $0, category: category) }
    }

    private static let bundledByCategory: KeyValuePairs<String, [String]> = [
        "Supermercado": [
            "metro", "tottus", "plaza vea", "plazavea", "vivanda", "wong", "makro", "mass", "mass xtra", "oxxo",
            "tambo", "tambo+", "economax", "holi", "listo", "viva", "repshop", "petro market", "bodega",
            "bodeguita", "minimarket", "mini market", "supermercado", "hipermercado", "autoservicio", "mercado",
            "mercadillo", "abarrotes", "abarrotería", "despensa", "provisiones", "canasta familiar",
            "delicatessen", "verdulería", "frutería", "carnicería", "pescadería", "granos y abarrotes",
            "plaza vea express", "grocery", "market", "superette", "tienda de conveniencia",
            "cooperativa de consumo", "canasta basica", "dia a dia", "el chinito", "provincial market", "el super"
        ],
        "Comida": [
            "rappi", "pedidosya", "didi food", "uber eats", "glovo", "kfc", "bembos", "starbucks", "papa john",
            "pizza", "pizza hut", "burger", "burger king", "mcdonald", "norky", "china wok", "chinawok", "popeye",
            "roky", "pardos chicken", "la lucha", "dunkin", "cinnabon", "subway", "domino", "telepizza", "tanta",
            "la mar", "chifa", "pollería", "cevichería", "anticuchos", "sanguchería", "menu", "menú",
            "restaurante", "almuerzo", "cena", "desayuno", "comida rápida", "hamburguesa", "sushi", "nikkei",
            "panadería", "pastelería", "heladería", "helados", "cafe", "café", "cafeteria", "cafetería", "bar",
            "cerveza", "discoteca", "licorería", "taco bell"
        ],
        "Transporte": [
            "uber", "cabify", "beat", "didi", "indriver", "yango", "taxi", "taxi directo", "taxi satelital",
            "metropolitano", "corredor", "tren", "línea 1", "tren eléctrico", "primax", "repsol", "petroperu",
            "petroperú", "pecsa", "grifo", "gasolina", "combustible", "peaje", "estacionamiento", "parking",
            "cochera", "los portales", "taller", "mecánico", "mantenimiento auto", "flores", "bus", "autobús",
            "pasajes", "soat", "revisión técnica", "llantas", "neumáticos"
        ],
        "Viajes": [
            "latam", "sky airline", "jetsmart", "avianca", "vuelos", "avión", "aerolínea", "aeropuerto",
            "cruz del sur", "oltursa", "movil tours", "movil bus", "tepsa", "civa", "cavassa",
            "terminal terrestre", "hotel", "hostal", "hospedaje", "airbnb", "booking", "despegar", "expedia",
            "casa andina", "costa del sol", "tierra viva", "peru rail", "perurail", "inca rail",
            "paquete turístico", "agencia de viajes"
        ],
        "Casa": [
            "sodimac", "promart", "maestro", "muebles", "decoración", "ferretería", "herramientas", "alquiler",
            "arriendo", "mantenimiento de edificio", "cuota de mantenimiento", "cassinelli", "la curacao hogar",
            "lavandería", "cerrajero", "gasfitero", "electricista", "jardinería", "limpieza del hogar", "ikea",
            "casaideas", "decor center"
        ],
        "Servicios": [
            "movistar", "claro", "entel", "bitel", "win", "wow", "luz del sur", "enel", "sedapal", "calidda",
            "hidrandina", "seal", "electro sur", "electrocentro", "electronoroeste", "agua", "luz", "gas",
            "internet", "teléfono", "cable", "directv", "recarga", "plan móvil", "rimac", "pacifico", "mapfre",
            "la positiva", "eps", "seguro", "seguros", "póliza", "banco", "comisión bancaria",
            "mantenimiento de cuenta", "membresía", "sunat", "tributos", "arbitrios", "predial", "multas",
            "municipalidad", "sedapar", "sedalib", "epsel", "seda chimbote", "telefonica", "fibra óptica", "wifi",
            "plan postpago", "plan prepago", "recibo de luz", "recibo de agua"
        ],
        "Salud": [
            "inkafarma", "mifarma", "boticas y salud", "botica", "farmacia", "arcángel", "albis", "clínica",
            "hospital", "clínica anglo americana", "clínica ricardo palma", "clínica internacional",
            "clínica san pablo", "clínica delgado", "auna", "essalud", "minsa", "doctor", "médico", "dentista",
            "odontólogo", "odontología", "terapia", "psicólogo", "psicología", "oftalmólogo", "pediatra",
            "laboratorio", "análisis clínicos", "examenes médicos", "medicina", "pastillas", "receta", "óptica",
            "lentes", "vacuna", "vacunación", "consulta médica", "emergencia médica", "ambulancia", "fisioterapia",
            "nutricionista", "dermatólogo", "ginecólogo", "cardiólogo", "traumatólogo", "farmacia universal",
            "mi farmacia", "boticas torres de limatambo", "fasa", "inca farma", "óptica gmo"
        ],
        "Educación": [
            "librería", "papelería", "universidad", "colegio", "pensión escolar", "matrícula", "instituto",
            "academia", "cursos", "curso", "idiomas", "icpna", "británico", "alianza francesa", "pucp", "upc",
            "ulima", "usil", "upch", "udemy", "platzi", "coursera", "crehana", "domestika", "tayloy", "crisol",
            "útiles escolares"
        ],
        "Entretenimiento": [
            "cineplanet", "cinemark", "cinestar", "teleticket", "joinnus", "tuentrada", "atrapalo", "cine",
            "película", "películas", "teatro", "concierto", "entradas", "museo", "exposición",
            "parque de diversiones", "playstation", "xbox", "nintendo", "steam", "epic games", "riot games",
            "gaming", "videojuegos", "juegos", "boliche", "karaoke", "feria", "circo", "zoológico", "acuario",
            "escape room"
        ],
        "Suscripciones": [
            "netflix", "spotify", "disney", "hbo", "max", "prime video", "amazon prime", "youtube premium",
            "apple tv", "crunchyroll", "twitch", "discord nitro", "paramount+", "star+", "vix", "claro video",
            "movistar play", "directv go", "deezer", "tidal", "icloud", "google one", "chatgpt", "openai",
            "microsoft 365", "adobe", "canva", "duolingo", "dropbox", "notion", "suscripción", "membresía digital"
        ],
        "Compras": [
            "falabella", "saga falabella", "ripley", "oechsle", "hiraoka", "la curacao", "curacao", "tiendas efe",
            "carsa", "elektra", "zara", "h&m", "adidas", "nike", "puma", "forever 21", "topitop", "platanitos",
            "payless", "ropa", "moda", "zapatos", "zapatillas", "calzado", "joyería", "relojes", "accesorios",
            "tecnología", "electrónica", "celular", "smartphone", "iphone", "samsung", "xiaomi", "laptop",
            "computadora", "regalos", "juguetería", "juguetes", "cosméticos", "perfumería",
            "tienda por departamento", "mall", "centro comercial"
        ]
    ]
}
