import XCTest
import CryptoKit
@testable import LiveContainerSwiftUI

final class AppSourcesTests: XCTestCase {
    private let base = URL(string: "https://example.com/source.json")!
    private func parse(_ json: String) throws -> AppSourceParser.Parsed { try AppSourceParser.parse(Data(json.utf8), sourceURL: base) }

    func testLegacyAppFieldsBecomeOneVersion() throws {
        let parsed = try parse("""
        {"name":"Legacy","apps":[{"name":"Old","bundleIdentifier":"com.example.old","developerName":"Dev","version":"1.2","versionDate":"2024-01-02",
          "versionDescription":"notes","downloadURL":"http://cdn.example.com/old.ipa","size":"2048","iconURL":"icons/old.png",
          "screenshotURLs":["https://example.com/1.png"]}]}
        """)
        XCTAssertEqual(parsed.name, "Legacy")
        let app = try XCTUnwrap(parsed.apps.first)
        XCTAssertEqual(app.versions.count, 1)
        XCTAssertEqual(app.latest?.version, "1.2")
        XCTAssertEqual(app.latest?.notes, "notes")
        XCTAssertEqual(app.latest?.size, 2048)
        // http 升级为 https；相对图标地址按源地址解析。
        XCTAssertEqual(app.latest?.downloadURL.absoluteString, "https://cdn.example.com/old.ipa")
        XCTAssertEqual(app.iconURL?.absoluteString, "https://example.com/icons/old.png")
        XCTAssertEqual(app.screenshots.count, 1)
    }

    func testVersionsArrayWinsAndKeepsOrderAndChecksums() throws {
        let parsed = try parse("""
        {"apps":[{"name":"New","bundleIdentifier":"com.example.new","version":"0.1","downloadURL":"https://example.com/stale.ipa",
          "screenshots":{"iphone":[{"imageURL":"https://example.com/p.png","width":1}],"ipad":["https://example.com/i.png"]},
          "versions":[{"version":"2.0","buildVersion":"20","date":"2025-05-01T10:00:00Z","downloadURL":"https://example.com/2.ipa","size":10,"sha256":"ABCDEF","minOSVersion":"16.0"},
                      {"version":"1.0","date":"2024-01-01","downloadURL":"https://example.com/1.ipa"},
                      {"version":"broken"}]}]}
        """)
        let app = try XCTUnwrap(parsed.apps.first)
        XCTAssertEqual(parsed.name, "example.com")
        XCTAssertEqual(app.versions.map(\.version), ["2.0", "1.0"])
        XCTAssertEqual(app.latest?.build, "20")
        XCTAssertEqual(app.latest?.sha256, "abcdef")
        XCTAssertEqual(app.latest?.minimumOS, "16.0")
        XCTAssertEqual(app.screenshots.map(\.absoluteString), ["https://example.com/p.png"])
    }

    func testAppsWithoutDownloadsOrIdentityAreSkippedAndDuplicatesMerged() throws {
        let parsed = try parse("""
        {"apps":[{"name":"No URL","bundleIdentifier":"a","version":"1"},{"bundleIdentifier":"b","version":"1","downloadURL":"https://x.com/b.ipa"},
                 {"name":"Ok","bundleIdentifier":"c","version":"1","downloadURL":"https://x.com/c.ipa"},
                 {"name":"Ok","bundleIdentifier":"c","version":"2","downloadURL":"https://x.com/c2.ipa"},
                 {"name":"Unsafe","bundleIdentifier":"d","version":"1","downloadURL":"ftp://x.com/d.ipa"}, 5]}
        """)
        XCTAssertEqual(parsed.apps.map(\.bundleID), ["c"])
    }

    func testWebPagesAndOtherShapesAreRejectedWithReasons() {
        XCTAssertThrowsError(try parse("\n <!DOCTYPE html><html></html>")) { XCTAssertTrue($0.localizedDescription.contains("网页")) }
        XCTAssertThrowsError(try parse("[1,2]")) { XCTAssertTrue($0.localizedDescription.contains("源信息")) }
        XCTAssertThrowsError(try parse("{\"name\":\"x\"}")) { XCTAssertTrue($0.localizedDescription.contains("apps")) }
        XCTAssertThrowsError(try parse("{oops")) { XCTAssertTrue($0.localizedDescription.contains("JSON")) }
    }

    func testAddressNormalization() throws {
        XCTAssertEqual(try AppSourceAddress.normalize(" alt.getutm.app ").absoluteString, "https://alt.getutm.app")
        XCTAssertEqual(try AppSourceAddress.normalize("http://bit.ly/Altstore-complete").absoluteString, "https://bit.ly/Altstore-complete")
        XCTAssertEqual(try AppSourceAddress.normalize("altstore://source?url=https://example.com/a.json").absoluteString, "https://example.com/a.json")
        XCTAssertEqual(try AppSourceAddress.normalize("sidestore://source?url=example.com/b.json").absoluteString, "https://example.com/b.json")
        XCTAssertEqual(try AppSourceAddress.normalize("https://altdirect.app/?url=https://raw.githubusercontent.com/a/b/refs/heads/master/all-apps.json").absoluteString,
                       "https://raw.githubusercontent.com/a/b/refs/heads/master/all-apps.json")
        XCTAssertThrowsError(try AppSourceAddress.normalize("ftp://example.com/a.json"))
        XCTAssertThrowsError(try AppSourceAddress.normalize("https://user:pass@example.com/a.json"))
        XCTAssertThrowsError(try AppSourceAddress.normalize("   "))
        XCTAssertEqual(AppSourceAddress.candidates(in: "源一：https://a.com/x.json，源二（https://b.com/y.json）\n重复 https://a.com/x.json。"), ["https://a.com/x.json", "https://b.com/y.json"])
        XCTAssertEqual(AppSourceAddress.candidates(in: "alt.getutm.app\n  c.com/x.json 说明"), ["alt.getutm.app", "c.com/x.json"])
        // 连在一起的地址拆开；添加源链接里 url= 后面的地址不拆。
        XCTAssertEqual(AppSourceAddress.candidates(in: "https://alt.getutm.apphttps://a.com/x.jsonaltstore://source?url=https://b.com/y.json"),
                       ["https://alt.getutm.app", "https://a.com/x.json", "altstore://source?url=https://b.com/y.json"])
    }

    func testDownloadVerificationRequiresZipAndMatchingChecksum() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = folder.appendingPathComponent("a.ipa"), html = folder.appendingPathComponent("b.ipa")
        let bytes = Data([0x50, 0x4b, 0x03, 0x04, 0x01, 0x02])
        try bytes.write(to: zip); try Data("<html>".utf8).write(to: html)
        let digest = "e7c1ae0ecc0e46e5cb4e33c1a0c7d1f05f4bd5a9b4eb9a2f0c7b4bce7a7d3b44"
        XCTAssertNoThrow(try AppSourceStore.verify(zip, sha256: nil))
        XCTAssertThrowsError(try AppSourceStore.verify(html, sha256: nil))
        XCTAssertThrowsError(try AppSourceStore.verify(zip, sha256: digest)) { XCTAssertTrue($0.localizedDescription.contains("SHA-256")) }
        let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try AppSourceStore.verify(zip, sha256: actual))
    }

    func testVersionOrderComparesNumericSegments() {
        XCTAssertTrue(VersionOrder.isNewer("5.0.10", than: "5.0.9"))
        XCTAssertTrue(VersionOrder.isNewer("2.1", than: "2.0.9"))
        XCTAssertTrue(VersionOrder.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(VersionOrder.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(VersionOrder.isNewer("5.0.8", than: "5.0.8"))
        XCTAssertFalse(VersionOrder.isNewer("5.0.7", than: "5.0.8"))
        XCTAssertTrue(VersionOrder.isNewer("v3.2-beta", than: "3.1"))
        XCTAssertFalse(VersionOrder.isNewer("beta", than: "1.0"))
    }

    @MainActor
    func testUpdatesPickNewestVersionAcrossSourcesForLibraryApps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        func version(_ value: String) -> SourceVersion { SourceVersion(version: value, downloadURL: URL(string: "https://example.com/\(value).ipa")!) }
        func app(_ bundle: String, _ versions: [String]) -> SourceApp {
            SourceApp(name: bundle, bundleID: bundle, beta: false, screenshots: [], versions: versions.map(version))
        }
        let sources = [AppSource(url: URL(string: "https://a.test/s.json")!, name: "A", apps: [app("com.utm", ["5.0.9"]), app("com.same", ["1.0"])]),
                       AppSource(url: URL(string: "https://b.test/s.json")!, name: "B", apps: [app("com.utm", ["5.1.0", "5.0.9"]), app("com.old", ["0.9"])])]
        let file = paths.support.appendingPathComponent("Sources/sources.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(sources).write(to: file)
        let store = AppSourceStore(paths: paths)
        func package(_ bundle: String, _ version: String) -> AppPackage {
            AppPackage(id: UUID(), name: bundle, bundleID: bundle, version: version, build: "1", minimumOS: "15.0", fileName: "x.ipa", iconFile: nil,
                       byteCount: 1, isEncrypted: false, importedAt: Date())
        }
        let library = [package("com.utm", "5.0.8"), package("com.same", "1.0"), package("com.old", "1.0"), package("com.missing", "1.0")]
        let updates = store.updates(for: library)
        // 只有 UTM 有更新，且取两个源中最高的 5.1.0；同版本、源里更旧、源里没有的都不算。
        XCTAssertEqual(updates.map(\.package.bundleID), ["com.utm"])
        XCTAssertEqual(updates.first?.version.version, "5.1.0")
        XCTAssertEqual(updates.first?.sourceName, "B")
    }

    @MainActor
    func testAddingManySourcesRunsTogetherAndExplainsEachFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SourceStubProtocol.self]
        let paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        let store = AppSourceStore(paths: paths, session: URLSession(configuration: configuration))
        let inputs = ["https://stub.test/slow.json", "https://stub.test/missing.json", "https://stub.test/down.json",
                      "https://stub.test/page", "http://stub.test/ok.json", "stub.test/slow.json"]
        let started = Date()
        let results = await store.add(inputs)
        // 两个 0.6 秒的慢请求同时进行，总耗时不应是串行之和。
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(results.map(\.input), inputs)
        func reason(_ index: Int) -> String { if case .failure(let error) = results[index].result { return error.localizedDescription }; return "" }
        XCTAssertTrue(reason(1).contains("404"))
        XCTAssertTrue(reason(2).contains("522"))
        XCTAssertTrue(reason(3).contains("网页"))
        if case .success(let detail) = results[4].result { XCTAssertTrue(detail.contains("Stub")) } else { XCTFail("ok.json failed") }
        XCTAssertEqual(store.sources.map(\.url.absoluteString).sorted(), ["https://stub.test/ok.json", "https://stub.test/slow.json"])
        XCTAssertEqual(AppSourceStore(paths: paths).sources.count, 2)
    }
}

private final class SourceStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let json = #"{"name":"Stub","apps":[{"name":"A","bundleIdentifier":"a","version":"1","downloadURL":"https://stub.test/a.ipa"}]}"#
        let (status, body, delay): (Int, String, Double) = switch url.path {
        case "/slow.json": (200, json, 0.6)
        case "/ok.json": (200, json, 0)
        case "/missing.json": (404, "404: Not Found", 0)
        case "/down.json": (522, "error code: 522", 0)
        default: (200, "<!doctype html><html></html>", 0)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
