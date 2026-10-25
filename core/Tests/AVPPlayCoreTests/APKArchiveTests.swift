import Foundation
import XCTest
@testable import AVPPlayCore

final class APKArchiveTests: XCTestCase {
    func zip(_ entries: [(String, UInt32)]) -> Data {
        var output = Data(), central = Data()
        func word(_ value: UInt32, bytes: Int, into data: inout Data) {
            for index in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
        }
        for (name, mode) in entries {
            let raw = Data(name.utf8), offset = UInt32(output.count)
            word(0x04034b50, bytes: 4, into: &output)
            for v: UInt32 in [20, 0x800, 0, 0, 0] { word(v, bytes: 2, into: &output) }
            for _ in 0..<3 { word(0, bytes: 4, into: &output) }
            word(UInt32(raw.count), bytes: 2, into: &output); word(0, bytes: 2, into: &output); output.append(raw)
            word(0x02014b50, bytes: 4, into: &central)
            for v: UInt32 in [0x314, 20, 0x800, 0, 0, 0] { word(v, bytes: 2, into: &central) }
            for _ in 0..<3 { word(0, bytes: 4, into: &central) }
            for v: UInt32 in [UInt32(raw.count), 0, 0, 0, 0] { word(v, bytes: 2, into: &central) }
            word(mode << 16, bytes: 4, into: &central); word(offset, bytes: 4, into: &central); central.append(raw)
        }
        let offset = UInt32(output.count); output.append(central)
        word(0x06054b50, bytes: 4, into: &output)
        for v: UInt32 in [0, 0, UInt32(entries.count), UInt32(entries.count)] { word(v, bytes: 2, into: &output) }
        word(UInt32(central.count), bytes: 4, into: &output); word(offset, bytes: 4, into: &output); word(0, bytes: 2, into: &output)
        return output
    }

    func validate(_ data: Data) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("avp-zip-\(UUID().uuidString).apk")
        try data.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        try APKArchive.validate(path)
    }

    func testRegularUnicodeFilesAndExplicitDirectoriesAreAccepted() throws {
        try validate(zip([("assets/", 0x4000), ("assets/漢.txt", 0x8000), ("AndroidManifest.xml", 0x8000)]))
    }

    func testPathsLinksSpecialFilesDuplicatesAndNamespaceCollisionsAreRejected() {
        let bad: [[(String, UInt32)]] = [
            [("../escape", 0x8000)], [("/absolute", 0x8000)], [("assets/../escape", 0x8000)],
            [("assets\\escape", 0x8000)], [("C:escape", 0x8000)], [("assets/./x", 0x8000)],
            [("assets//x", 0x8000)], [("assets/link", 0xa000)], [("assets/pipe", 0x1000)],
            [("assets/x", 0x8000), ("assets/x", 0x8000)],
            [("assets/X", 0x8000), ("assets/x", 0x8000)],
            [("assets", 0x8000), ("assets/x", 0x8000)]
        ]
        for entries in bad { XCTAssertThrowsError(try validate(zip(entries)), "\(entries)") }
    }

    func testTruncationAndDifferentLocalNameAreRejected() {
        var data = zip([("assets/x", 0x8000)])
        XCTAssertThrowsError(try validate(data.dropLast()))
        data[30] = UInt8(ascii: "z")
        XCTAssertThrowsError(try validate(data))
    }

    func testSameSizeAPKReplacementUsesBytesAndPreservesExternalLinkTarget() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("avp-stage-apk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.apk"), output = folder.appendingPathComponent("build.apk"), old = folder.appendingPathComponent("old.apk")
        try Data("AAAA".utf8).write(to: source); try Data("BBBB".utf8).write(to: old)
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: old)
        try Toolchain.stageAPK(from: source, to: output)
        XCTAssertEqual(try Data(contentsOf: output), Data("AAAA".utf8))
        XCTAssertEqual(try Data(contentsOf: old), Data("BBBB".utf8))
        try Data("CCCC".utf8).write(to: source)
        XCTAssertThrowsError(try Toolchain.stageAPK(from: source, to: output, expected: String(repeating: "0", count: 64)))
        XCTAssertEqual(try Data(contentsOf: output), Data("AAAA".utf8))
        try Toolchain.stageAPK(from: source, to: output)
        XCTAssertEqual(try Data(contentsOf: output), Data("CCCC".utf8))
    }
}
