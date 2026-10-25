import XCTest
@testable import AVPPlayCore

final class CoreModBundleTests: XCTestCase {
    func testUpdatedBundleWithSameGitBaseInstallsNewContentAndKeepsRollback() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("avp-core-update-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let base = root.appendingPathComponent("data")
        func bundle(_ marker: String) throws -> Bundle {
            let dir = root.appendingPathComponent(marker + ".bundle")
            let resources = dir.appendingPathComponent("Contents/Resources/core-mods")
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "test.avp.\(marker)", "CFBundlePackageType": "BNDL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: dir.appendingPathComponent("Contents/Info.plist"))
            let source = root.appendingPathComponent(marker + "-source")
            for folder in ["visionos", "ports/scotland2/tools"] {
                try fm.createDirectory(at: source.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            for file in ["visionos/run.sh", "ports/scotland2/tools/avp_play.py", "ports/scotland2/selected-mods.json"] {
                try marker.write(to: source.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
            var manifest = ToolchainManifest(format: 1, version: 346, commit: "9f5f2c7",
                ancestors: ["9f5f2c7"], created: Date(timeIntervalSince1970: 1_800_000_000))
            manifest.modified = true
            try ToolchainPackager.encoder.encode(manifest).write(to: source.appendingPathComponent("toolchain.json"))
            let archive = resources.appendingPathComponent("profile.tar.gz")
            _ = try ToolchainPackager.run(["/usr/bin/tar", "-czf", archive.path, "-C", source.path, "."])
            manifest.sha256 = try Hashing.sha256(of: archive)
            manifest.size = ContentStore.fileSize(archive)
            try ToolchainPackager.encoder.encode(manifest).write(to: ToolchainPackager.sidecar(for: archive))
            return try XCTUnwrap(Bundle(url: dir))
        }
        let old = try XCTUnwrap(CoreModToolchainSelection.installBundled(from: bundle("old"), at: base))
        let updatedBundle = try bundle("new")
        let new = try XCTUnwrap(CoreModToolchainSelection.installBundled(from: updatedBundle, at: base))
        XCTAssertEqual(old.commit(), new.commit())
        XCTAssertNotEqual(old.root, new.root)
        let marker = "ports/scotland2/selected-mods.json"
        XCTAssertEqual(try String(contentsOf: old.root.appendingPathComponent(marker)), "old")
        XCTAssertEqual(try String(contentsOf: new.root.appendingPathComponent(marker)), "new")
        let again = try XCTUnwrap(CoreModToolchainSelection.installBundled(from: updatedBundle, at: base))
        XCTAssertEqual(new.root, again.root)
        let saved = try XCTUnwrap(CoreModToolchainSelection.load(from: base.appendingPathComponent("core-mods-toolchain.json")))
        XCTAssertEqual(saved.toolchain()?.root, new.root)
    }
}
