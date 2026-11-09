import XCTest
import RetoolsNative

final class FairPlayNativeTests: XCTestCase {
    private func files() throws -> (URL, URL, URL, Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("original"), output = root.appendingPathComponent("copy")
        let bytes = Data(repeating: 0x7b, count: 32768)
        try bytes.write(to: input); try bytes.write(to: output)
        return (root,input,output,bytes)
    }
    func testRejectsWritingIntoOriginalFile() throws {
        let (root,input,_,bytes) = try files(); defer { try? FileManager.default.removeItem(at: root) }
        let region = RTFairPlayRegion(slice_offset: 0,slice_size: 32768,encrypted_offset: 16384,encrypted_size: 16384,signature_offset: 0,signature_size: 0,cpu_type: 0x0100000c,cpu_subtype: 0)
        var result = RTFairPlayResult()
        let status = input.path.withCString { path in rt_fairplay_decrypt_region(path,path,region,&result,nil,nil) }
        XCTAssertNotEqual(status,0); XCTAssertEqual(result.bytes_written,0)
        XCTAssertEqual(try Data(contentsOf: input),bytes)
    }
    func testRejectsOverflowingSliceWithoutChangingEitherFile() throws {
        let (root,input,output,bytes) = try files(); defer { try? FileManager.default.removeItem(at: root) }
        let region = RTFairPlayRegion(slice_offset: UInt64.max,slice_size: 32768,encrypted_offset: 16384,encrypted_size: 16384,signature_offset: 0,signature_size: 0,cpu_type: 0x0100000c,cpu_subtype: 0)
        var result = RTFairPlayResult()
        let status = input.path.withCString { a in output.path.withCString { b in rt_fairplay_decrypt_region(a,b,region,&result,nil,nil) } }
        XCTAssertNotEqual(status,0); XCTAssertEqual(result.bytes_written,0)
        XCTAssertEqual(try Data(contentsOf: input),bytes); XCTAssertEqual(try Data(contentsOf: output),bytes)
    }
    func testRejectsSymlinkInput() throws {
        let (root,input,output,bytes) = try files(); defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input)
        let region = RTFairPlayRegion(slice_offset: 0,slice_size: 32768,encrypted_offset: 16384,encrypted_size: 16384,signature_offset: 0,signature_size: 0,cpu_type: 0x0100000c,cpu_subtype: 0)
        var result = RTFairPlayResult()
        let status = alias.path.withCString { a in output.path.withCString { b in rt_fairplay_decrypt_region(a,b,region,&result,nil,nil) } }
        XCTAssertNotEqual(status,0); XCTAssertEqual(result.bytes_written,0)
        XCTAssertEqual(try Data(contentsOf: output),bytes)
    }
}
