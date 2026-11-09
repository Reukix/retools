import Foundation

struct StoreCatalogApp: Codable, Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let bundleID: String
    let version: String
    let price: Double
    let artwork: URL?
    enum CodingKeys: String, CodingKey { case id = "trackId", name = "trackName", bundleID = "bundleId", version, price, artwork = "artworkUrl100" }
    init(id: Int64, name: String, bundleID: String, version: String, price: Double = 0, artwork: URL? = nil) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.version = version; self.price = price; self.artwork = artwork
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int64.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        bundleID = try values.decode(String.self, forKey: .bundleID)
        version = try values.decodeIfPresent(String.self, forKey: .version) ?? ""
        price = try values.decodeIfPresent(Double.self, forKey: .price) ?? 0
        artwork = try values.decodeIfPresent(URL.self, forKey: .artwork)
    }
}

enum AppStoreCatalog {
    static func country(storeFront: String?) -> String {
        let id = storeFront?.split(separator: "-").first.map(String.init)
        let countries = ["143441":"us", "143462":"jp", "143465":"cn", "143464":"sg", "143463":"hk", "143470":"tw", "143444":"gb", "143455":"ca", "143460":"au"]
        return id.flatMap { countries[$0] } ?? Locale.current.region?.identifier.lowercased() ?? "us"
    }
    static func url(term: String, country: String, lookup: Bool = false) throws -> URL {
        let text = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 300, country.count == 2 else { throw FairPlayFailure("请输入应用名称、Bundle ID 或商店链接。") }
        var components = URLComponents(string: "https://itunes.apple.com/"+(lookup ? "lookup" : "search"))!
        var items = [URLQueryItem(name: "country", value: country), URLQueryItem(name: "entity", value: "software"), URLQueryItem(name: "limit", value: "30")]
        if let input = URL(string: text), input.host == "apps.apple.com",
           let id = input.pathComponents.last(where: { $0.hasPrefix("id") && $0.dropFirst(2).allSatisfy(\.isNumber) }) {
            components.path = "/lookup"; items.append(URLQueryItem(name: "id", value: String(id.dropFirst(2))))
        } else { items.append(URLQueryItem(name: lookup ? "bundleId" : "term", value: text)) }
        components.queryItems = items
        guard let url = components.url else { throw FairPlayFailure("商店搜索条件无效。") }; return url
    }
    static func parse(_ data: Data) throws -> [StoreCatalogApp] {
        struct Result: Decodable { let results: [StoreCatalogApp] }
        return try JSONDecoder().decode(Result.self, from: data).results.filter { $0.id > 0 && !$0.bundleID.isEmpty }
    }
    static func search(_ term: String, country: String, lookup: Bool = false) async throws -> [StoreCatalogApp] {
        var request = URLRequest(url: try url(term: term, country: country, lookup: lookup))
        request.timeoutInterval = 30
        let (data,response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count < 8*1024*1024 else { throw FairPlayFailure("暂时无法读取 App Store，请稍后重试。") }
        return try parse(data)
    }
}
