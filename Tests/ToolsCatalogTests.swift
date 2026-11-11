import XCTest
@testable import LiveContainerSwiftUI

final class ToolsCatalogTests: XCTestCase {
    func testSearchFindsToolNamesFormatsAndCommonTerms() {
        XCTAssertTrue(WorkspaceTool.files.matches("worse_query"))
        XCTAssertTrue(WorkspaceTool.files.matches("目录 读写"))
        XCTAssertTrue(WorkspaceTool.decryption.matches("IPA 下载"))
        XCTAssertTrue(WorkspaceTool.storeDownload.matches("ipadn 历史版本"))
        XCTAssertTrue(WorkspaceTool.crashes.matches("闪退"))
        XCTAssertTrue(WorkspaceTool.logs.matches("syslog"))
        XCTAssertTrue(WorkspaceTool.runtime.matches("JIT 证书"))
        XCTAssertFalse(WorkspaceTool.files.matches("IPA 下载"))
        XCTAssertFalse(WorkspaceTool.connection.matches("没有这个工具"))
    }
    func testEveryToolHasUniqueIdentityAndCanBeFoundByItsTitle() {
        XCTAssertEqual(Set(WorkspaceTool.allCases.map(\.accessibilityID)).count, WorkspaceTool.allCases.count)
        for tool in WorkspaceTool.allCases {
            XCTAssertTrue(tool.matches(tool.title))
            XCTAssertFalse(tool.detail.isEmpty)
            XCTAssertTrue(ToolCategory.allCases.contains(tool.category))
        }
    }
    func testFavoritesKeepOrderRemoveUnknownAndDuplicateEntries() {
        XCTAssertEqual(ToolFavorites.decode("[\"location\",\"localFiles\",\"unknown\",\"location\",\"apps\"]"), [.location, .files, .apps])
        XCTAssertEqual(ToolFavorites.decode("[\"gestalt\",\"localFiles\",\"apps\"]"), [.files, .apps])
        XCTAssertEqual(ToolFavorites.decode(ToolFavorites.encode([.processes, .apps, .files, .apps])), [.processes, .apps, .files])
    }
    func testEmptyFavoritesArePreservedAndCorruptValuesUseDefaults() {
        XCTAssertEqual(ToolFavorites.decode("[]"), [])
        XCTAssertEqual(ToolFavorites.decode("not-json"), ToolFavorites.defaults)
        XCTAssertEqual(ToolFavorites.decode("[\"removed-tool\"]"), ToolFavorites.defaults)
    }
    func testFavoritesNeverExceedSixEntries() {
        let all = ToolFavorites.encode(WorkspaceTool.allCases)
        XCTAssertEqual(ToolFavorites.decode(all).count, ToolFavorites.maximumCount)
        XCTAssertEqual(ToolFavorites.decode(all), Array(WorkspaceTool.allCases.prefix(ToolFavorites.maximumCount)))
    }
}
