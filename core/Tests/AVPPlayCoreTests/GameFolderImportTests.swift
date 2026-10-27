import Foundation
import XCTest
@testable import AVPPlayCore

final class GameFolderImportTests: XCTestCase {
    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("avp-folder-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.resolvingSymlinksInPath()
    }

    func fixture(_ root: URL) throws -> (Recipe, URL, RecipeFile) {
        let nested = root.appendingPathComponent("com.example.saber")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("fixture apk".utf8).write(to: nested.appendingPathComponent("different-name.apk"))
        let data = Data("complete matching game data".utf8), source = nested.appendingPathComponent("main.3237.obb")
        try data.write(to: source)
        var recipe = try JSONDecoder().decode(Recipe.self, from: Data("""
        {"schema":1,"id":"saber","title":"Saber","package":"com.example.saber",
         "versionName":"1.45.3","versionCode":3237,"store":{"appId":"123"},
         "toolchain":{"target":"saber","minCommit":"abcdef0"},
         "files":[{"name":"imported.apk","role":"apk","id":"456","required":true}],
         "status":{"playability":"untested","download":"special"}}
        """.utf8))
        let file = RecipeFile(name: source.lastPathComponent, role: "main-obb", id: "789", size: Int64(data.count),
                              sha256: Hashing.sha256(of: data), required: true, dest: "android-files/klepton-assets", localName: nil, locale: nil, source: nil)
        recipe.files.append(file)
        return (recipe, source, file)
    }

    func testNestedFolderKeepsExactRecipeDestinationsAndIgnoresFinderMetadata() throws {
        let root = try temporary(), (recipe, source, file) = try fixture(root)
        try Data("finder".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        let inputs = try GameFolderInputs(folder: root)
        XCTAssertEqual(inputs.files.count, 2)
        XCTAssertEqual(inputs.apk.lastPathComponent, "different-name.apk")
        let selected = try inputs.dataFiles(for: recipe)
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(try Data(contentsOf: selected[0].1), try Data(contentsOf: source))
        XCTAssertEqual(selected[0].0.dest, file.dest)
        XCTAssertEqual(selected[0].0.sha256, file.sha256)
        XCTAssertEqual(selected[0].0.size, file.size)
        XCTAssertEqual(selected[0].0.source?.kind, .user)
    }

    func testMissingOrCorruptRequiredDataIsRejectedBeforePublishingAnything() throws {
        let root = try temporary(), (recipe, source, _) = try fixture(root)
        try Data("incorrect".utf8).write(to: source)
        XCTAssertThrowsError(try GameFolderInputs(folder: root).dataFiles(for: recipe))
        try FileManager.default.removeItem(at: source)
        XCTAssertThrowsError(try GameFolderInputs(folder: root).dataFiles(for: recipe))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count, 1)
    }

    func testMultipleAPKsAndSymlinksAreRejected() throws {
        let root = try temporary(); _ = try fixture(root)
        let other = root.appendingPathComponent("other.apk")
        try Data("other".utf8).write(to: other)
        XCTAssertThrowsError(try GameFolderInputs(folder: root))
        try FileManager.default.removeItem(at: other)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: try temporary())
        XCTAssertThrowsError(try GameFolderInputs(folder: root))
    }

    func testDuplicateFileNamesUseThePinnedHashAndUnpinnedDuplicatesAreAmbiguous() throws {
        let root = try temporary(), (recipe, source, _) = try fixture(root)
        try Data("wrong duplicate".utf8).write(to: root.appendingPathComponent(source.lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(GameFolderInputs(folder: root).dataFiles(for: recipe).first?.1)), try Data(contentsOf: source))
        var unpinned = recipe; unpinned.files[1].size = nil; unpinned.files[1].sha256 = nil
        XCTAssertThrowsError(try GameFolderInputs(folder: root).dataFiles(for: unpinned))
    }

    func testVerifiedCopyIsIdempotentAndNeverOverwritesExistingOrSymlinkedData() throws {
        let root = try temporary(), (_, source, file) = try fixture(root)
        let target = root.appendingPathComponent("store/main.3237.obb")
        try ImportedAPKStore.copyFolderFile(source, to: target, file: file)
        try ImportedAPKStore.copyFolderFile(source, to: target, file: file)
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: source))
        try Data("keep existing".utf8).write(to: target)
        XCTAssertThrowsError(try ImportedAPKStore.copyFolderFile(source, to: target, file: file))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep existing".utf8))
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try ImportedAPKStore.copyFolderFile(source, to: target, file: file))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), root.appendingPathComponent("missing").path)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil).contains { $0.lastPathComponent.hasPrefix(".folder-import-") })
    }

    func testOnlyMissingPinnedFilesMayUseTheExistingLocalCache() throws {
        let root = try temporary(), (recipe, source, _) = try fixture(root)
        let cache = try temporary().appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: cache)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try GameFolderInputs(folder: root).dataFiles(for: recipe, cachedFiles: [cache]).first?.1, cache)
        try Data("wrong supplied file".utf8).write(to: source)
        XCTAssertThrowsError(try GameFolderInputs(folder: root).dataFiles(for: recipe, cachedFiles: [cache]))
        try FileManager.default.removeItem(at: source)
        try Data("wrong cache".utf8).write(to: cache)
        XCTAssertThrowsError(try GameFolderInputs(folder: root).dataFiles(for: recipe, cachedFiles: [cache]))
    }

    func testChangedSourceCannotLeaveAnUnverifiedTargetOrTemporaryFile() throws {
        let root = try temporary(), (_, source, file) = try fixture(root)
        let target = root.appendingPathComponent("store/main.3237.obb")
        try Data("source changed after preflight".utf8).write(to: source)
        XCTAssertThrowsError(try ImportedAPKStore.copyFolderFile(source, to: target, file: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil).isEmpty)
    }
}
