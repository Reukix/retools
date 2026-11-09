import XCTest
@testable import LiveContainerSwiftUI

final class StoreDownloadTests: XCTestCase {
    func testAnonymousDownloadRuntime() async throws {
        guard ProcessInfo.processInfo.environment["RETOOLS_TEST_DOWNLOAD_RUNTIME"] == "1" else { throw XCTSkip("Requires cached public Apple components and explicit runtime check") }
        try await StoreDownloadService().verifyDownloadRuntime()
    }
    func testHelperStartsOnlyForThePreparedTaskAuthorization() throws {
        var manifest = FairPlayManifest(schemaVersion: 1,id: UUID(),name: "Test",bundleID: "test.app",appFileName: "Test.app",binaries: [])
        let token = UUID(); manifest.startAuthorization = token
        let url = URL(string: "retoolsdecrypt://start?job=\(manifest.id.uuidString)&authorization=\(token.uuidString)")!
        XCTAssertTrue(manifest.authorizesStart(url))
        XCTAssertFalse(manifest.authorizesStart(URL(string: "retoolsdecrypt://start?job=\(UUID().uuidString)&authorization=\(token.uuidString)")!))
        XCTAssertFalse(manifest.authorizesStart(URL(string: "retoolsdecrypt://start?job=\(manifest.id.uuidString)")!))
        XCTAssertFalse(manifest.authorizesStart(URL(string: url.absoluteString+"&authorization=extra")!))
    }
    func testSearchEscapesUserInputWithoutChangingDestination() throws {
        let url = try AppStoreCatalog.url(term: "X & country=cn",country: "sg")
        let parts = try XCTUnwrap(URLComponents(url: url,resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host,"itunes.apple.com")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "term" })?.value,"X & country=cn")
        XCTAssertEqual(parts.queryItems?.filter { $0.name == "country" }.count,1)
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "country" })?.value,"sg")
    }
    func testInstalledSelectionAndStoreLinksResolveByIdentity() throws {
        let url = try AppStoreCatalog.url(term: "com.atebits.Tweetie2",country: "us",lookup: true)
        XCTAssertEqual(url.path,"/lookup")
        XCTAssertTrue(url.absoluteString.contains("bundleId=com.atebits.Tweetie2"))
        let link = try AppStoreCatalog.url(term: "https://apps.apple.com/us/app/x/id333903271",country: "sg")
        let query = URLComponents(url: link,resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(link.path,"/lookup")
        XCTAssertEqual(query?.first(where: { $0.name == "id" })?.value,"333903271")
    }
    func testCatalogKeepsAppIdentityAndHandlesOptionalMetadata() throws {
        let data = Data(#"{"results":[{"trackId":333903271,"trackName":"X","bundleId":"com.atebits.Tweetie2"}]}"#.utf8)
        let app = try XCTUnwrap(AppStoreCatalog.parse(data).first)
        XCTAssertEqual(app.id,333903271); XCTAssertEqual(app.bundleID,"com.atebits.Tweetie2")
        XCTAssertEqual(app.price,0); XCTAssertNil(app.artwork)
    }
    func testEmbeddedInterpreterAndCGoCallbacksRunWithoutAccountOrNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = StoreDownloadService(paths: WorkspacePaths(documents: root,support: root))
        try await service.probe()
    }
    func testCancellingGuestExecutionStopsTheInterpreter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = StoreDownloadService(paths: WorkspacePaths(documents: root,support: root))
        let task = Task { try await service.probeCancellation() }
        let deadline = Date().addingTimeInterval(3)
        while StoreDownloadService.progress() != "正在检查解释器取消…", Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let cancelledAt = Date(); StoreDownloadService.cancel()
        do { try await task.value; XCTFail("Cancelled guest must not report success") }
        catch { XCTAssertTrue(error.localizedDescription.contains("已取消")) }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt),3)
    }
}
