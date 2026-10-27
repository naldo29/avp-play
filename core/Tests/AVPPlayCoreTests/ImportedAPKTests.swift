import Foundation
import XCTest
@testable import AVPPlayCore

final class ImportedAPKTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("avp-profile-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testBuildModeRoutesToFixedAdapterAndCannotFallBackWhenMissing() throws {
        let root = try temporary()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("visionos/run.sh"))
        let chain = try Toolchain(root: root)
        XCTAssertEqual(try chain.buildCommand(coreMods: false).executable.lastPathComponent, "run.sh")
        XCTAssertThrowsError(try chain.buildCommand(coreMods: true))
        let script = root.appendingPathComponent("ports/scotland2/tools/avp_play.py")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: script)
        try Data().write(to: root.appendingPathComponent("ports/scotland2/selected-mods.json"))
        XCTAssertEqual(try chain.buildCommand(coreMods: true).executable.path, "/usr/bin/python3")
        XCTAssertEqual(try chain.buildCommand(coreMods: true).arguments, [script.path])
    }

    func testImportedSigningKeepsExistingIdentityAndHonorsExplicitOverride() throws {
        let root = try temporary(), store = ContentStore(root: root)
        let imported = try recipe(String(repeating: "a", count: 64))
        var record = SigningRecord(team: "AAAAAAAAAA", free: true, installed: Date(), expires: nil,
                                   bundleId: "dev.example.saber.test")
        record.coreMods = true
        record.save(store: store, recipe: imported, live: true)
        var request = InstallRequest(toolchain: root.path); request.team = record.team
        XCTAssertEqual(Installer(recipe: imported, request: request, store: store, report: { _ in }).resolvedBundleId, record.bundleId)
        request.bundleId = "dev.example.explicit"
        XCTAssertEqual(Installer(recipe: imported, request: request, store: store, report: { _ in }).resolvedBundleId, request.bundleId)
        XCTAssertEqual(SigningRecord.load(store: store, recipe: imported)?.coreMods, true)
        XCTAssertNil(SigningRecord.load(store: store, recipe: try recipe()))
        request.coreMods = true
        let restored = try JSONDecoder().decode(InstallRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(restored.coreMods, true)
        let legacy = try JSONDecoder().decode(InstallRequest.self, from: Data("{\"toolchain\":\"/tmp\",\"account\":\"default\",\"locales\":[],\"optionalNames\":[],\"addons\":true,\"storeArt\":true,\"interval\":0}".utf8))
        XCTAssertNil(legacy.coreMods)
    }

    func testImportedStatusRecognizesRecordedAppIdentity() throws {
        let store = ContentStore(root: try temporary()), imported = try recipe(String(repeating: "a", count: 64))
        let bundle = "dev.example.saber.test", stamp = "1716.346.1"
        SigningRecord(team: "AAAAAAAAAA", free: true, installed: Date(), expires: nil, bundleId: bundle)
            .save(store: store, recipe: imported, live: true)
        let app = InstalledApp(bundleIdentifier: bundle, name: "Saber", version: AppStamp.short(versionName: imported.versionName), bundleVersion: stamp)
        let status = GameStatus.of(recipe: imported, store: store, apps: [app], toolchainVersion: 346, bundlePrefix: "dev.example.ordinary")
        XCTAssertEqual(status.onDevice, .current(stamp: "1.40 (\(stamp))"))
    }

    func testAnotherCustomAPKUsesImportedFamilyIdentityWithoutBorrowingOrdinaryApp() throws {
        let root = try temporary(), store = ContentStore(root: root.appendingPathComponent("store")), imports = ImportedAPKStore(directory: root.appendingPathComponent("imports"))
        try FileManager.default.createDirectory(at: imports.directory, withIntermediateDirectories: true)
        let base = try recipe(), first = try recipe(String(repeating: "a", count: 64)), second = try recipe(String(repeating: "b", count: 64))
        try JSONEncoder().encode(first).write(to: imports.url(recipeId: first.id, sha256: first.importedAPK!.sha256))
        SigningRecord(team: "AAAAAAAAAA", free: true, installed: Date(), expires: nil, bundleId: "dev.example.ordinary")
            .save(store: store, recipe: base, live: true)
        XCTAssertNil(SigningRecord.importedIdentity(store: store, recipe: second, imports: imports))
        var record = SigningRecord(team: "AAAAAAAAAA", free: true, installed: Date(), expires: nil, bundleId: "dev.example.existing.test")
        record.coreMods = true; record.save(store: store, recipe: first, live: true)
        XCTAssertEqual(SigningRecord.importedIdentity(store: store, recipe: second, imports: imports)?.bundleId, record.bundleId)
        XCTAssertNil(SigningRecord.load(store: store, recipe: second))
        XCTAssertEqual(SigningRecord.load(store: store, recipe: base)?.bundleId, "dev.example.ordinary")
    }

    func testCustomUpdateRetainsValidProfileButRenewalAndExpiredProfilesRefresh() throws {
        let root = try temporary(), now = Date(), team = "AAAAAAAAAA", bundle = "dev.example.existing.test"
        for (name,expiry) in [("valid", now.addingTimeInterval(3600)), ("expired", now.addingTimeInterval(-1))] {
            let plist: [String: Any] = ["Entitlements": ["application-identifier": "\(team).\(bundle)"], "ExpirationDate": expiry, "IsXcodeManaged": true]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: root.appendingPathComponent(name + ".mobileprovision"))
        }
        let threshold = SigningProfiles.refreshThreshold(free: true, renewal: false, imported: true)
        XCTAssertEqual(threshold, 0)
        XCTAssertEqual(SigningProfiles.removeStale(team: team, bundleId: bundle, fresherThan: threshold, now: now,
                                                  directories: [root], decode: { try? Data(contentsOf: $0) }), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("valid.mobileprovision").path))
        XCTAssertEqual(SigningProfiles.refreshThreshold(free: true, renewal: true, imported: true), 6 * 86_400)
        XCTAssertEqual(SigningProfiles.refreshThreshold(free: true, renewal: false, imported: false), 6 * 86_400)
    }

    func testFailedRefreshRestoresOnlyValidExactAppProfileWithoutOverwritingNewProfile() throws {
        let root = try temporary(), now = Date(), team = "AAAAAAAAAA", bundle = "dev.example.existing.test"
        for (name,app,expiry) in [("valid",bundle,now.addingTimeInterval(3600)),("expired",bundle,now.addingTimeInterval(-1)),("other","dev.example.other",now.addingTimeInterval(3600))] {
            let plist: [String: Any] = ["Entitlements": ["application-identifier": "\(team).\(app)"], "ExpirationDate": expiry, "IsXcodeManaged": true]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: root.appendingPathComponent(name + ".mobileprovision"))
        }
        let kept = SigningProfiles.backupValid(team: team, bundleId: bundle, now: now, directories: [root], decode: { try? Data(contentsOf: $0) })
        XCTAssertEqual(kept.keys.map(\.lastPathComponent), ["valid.mobileprovision"])
        let valid = try XCTUnwrap(kept.keys.first)
        try FileManager.default.removeItem(at: valid)
        XCTAssertEqual(SigningProfiles.restoreMissing(kept), 1)
        XCTAssertEqual(try Data(contentsOf: valid), kept[valid])
        let fresh = Data("newly issued profile fixture".utf8); try fresh.write(to: valid)
        XCTAssertEqual(SigningProfiles.restoreMissing(kept), 0)
        XCTAssertEqual(try Data(contentsOf: valid), fresh)
    }

    func testRenewalIncludesInstalledImportsEvenAfterChoosingNormalVersion() throws {
        let root = try temporary(), bundled = root.appendingPathComponent("recipes"), imports = ImportedAPKStore(directory: root.appendingPathComponent("imports"))
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imports.directory, withIntermediateDirectories: true)
        let base = try recipe(), imported = try recipe(String(repeating: "a", count: 64))
        try JSONEncoder().encode(base).write(to: bundled.appendingPathComponent("saber.json"))
        try JSONEncoder().encode(imported).write(to: imports.url(recipeId: "saber", sha256: imported.importedAPK!.sha256))
        let renewable = Renewal.recipes(bundled: bundled, drafts: root.appendingPathComponent("drafts"), imports: imports)
        XCTAssertEqual(renewable.count, 2)
        XCTAssertEqual(renewable.filter { $0.importedAPK != nil }.count, 1)
    }

    func testOnlyHashMatchingRequiredCachedDataIsReused() throws {
        let root = try temporary(), store = ContentStore(root: root), imports = ImportedAPKStore(directory: root.appendingPathComponent("registry"))
        let cached = root.appendingPathComponent("old-1716")
        try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: true)
        let data = Data("correct game data".utf8), name = "main.obb"
        try data.write(to: cached.appendingPathComponent(name))
        var imported = try recipe(String(repeating: "a", count: 64))
        var file = imported.files[0]; file.name = name; file.role = "obb"; file.source = nil
        file.size = Int64(data.count); file.sha256 = try Hashing.sha256(of: cached.appendingPathComponent(name))
        imported.files.append(file)
        try FileManager.default.createDirectory(at: store.directory(for: imported), withIntermediateDirectories: true)
        try imports.reuseRequiredFiles(for: imported, store: store)
        XCTAssertEqual(try Data(contentsOf: store.url(for: file, in: imported)), data)
        try FileManager.default.removeItem(at: store.url(for: file, in: imported))
        try Data(repeating: 0, count: data.count).write(to: cached.appendingPathComponent(name))
        try imports.reuseRequiredFiles(for: imported, store: store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: file, in: imported).path))
    }

    func recipe(_ digest: String? = nil) throws -> Recipe {
        var r = try JSONDecoder().decode(Recipe.self, from: Data("""
        {"schema":1,"id":"saber","title":"Saber","package":"com.example.saber",
         "versionName":"1.40","versionCode":1716,"store":{"appId":"123","pinned":true},
         "toolchain":{"target":"saber","minCommit":"abcdef0"},
         "files":[{"name":"game.apk","role":"apk","id":"456","required":true}],
         "status":{"playability":"verified","download":"proven"}}
        """.utf8))
        if let digest {
            r.importedAPK = ImportedAPK(sha256: digest, fileName: "custom.apk", coreModsEligible: false)
            r.files[0].sha256 = digest
            r.files[0].source = FileSource(kind: .user, url: nil, hint: nil)
        }
        return r
    }

    func testSameVersionImportsHaveDifferentContentDirectoriesAndKeepOriginalSeparate() throws {
        let store = ContentStore(root: URL(fileURLWithPath: "/tmp/avp-import-fixture"))
        let original = try recipe(), a = try recipe(String(repeating: "a", count: 64)), b = try recipe(String(repeating: "b", count: 64))
        try original.validate(); try a.validate(); try b.validate()
        XCTAssertEqual(original.versionCode, a.versionCode)
        XCTAssertNotEqual(store.directory(for: original), store.directory(for: a))
        XCTAssertNotEqual(store.directory(for: a), store.directory(for: b))
        XCTAssertEqual(store.directory(for: original).lastPathComponent, "saber-1716")
    }

    func testMalformedOrMismatchedImportedIdentityIsRejected() throws {
        var r = try recipe("../escape")
        XCTAssertThrowsError(try r.validate())
        r = try recipe(String(repeating: "a", count: 64))
        r.files[0].sha256 = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try r.validate())
        r.files[0].sha256 = r.importedAPK?.sha256
        r.files[0].source = nil
        XCTAssertThrowsError(try r.validate())
    }

    func testCoreModsRequireEveryExactFingerprintAndCorrectGameBuild() {
        var hashes = Dictionary(uniqueKeysWithValues: CoreModCompatibility.members.map { ($0.name, $0.sha256) })
        XCTAssertTrue(CoreModCompatibility.matches(package: "com.beatgames.beatsaber", versionCode: 1716, hashes: hashes))
        XCTAssertFalse(CoreModCompatibility.matches(package: "com.other.game", versionCode: 1716, hashes: hashes))
        XCTAssertFalse(CoreModCompatibility.matches(package: "com.beatgames.beatsaber", versionCode: 3148, hashes: hashes))
        hashes.removeValue(forKey: CoreModCompatibility.members[0].name)
        XCTAssertFalse(CoreModCompatibility.matches(package: "com.beatgames.beatsaber", versionCode: 1716, hashes: hashes))
    }

    func testLegacyChoicesDecodeAndNormalSelectionClearsImportedSelection() throws {
        var choices = try JSONDecoder().decode(StoreUpdate.Choices.self, from: Data("{\"latest\":[],\"versions\":{}}".utf8))
        XCTAssertTrue(choices.importedAPKs.isEmpty)
        choices.chooseImported(String(repeating: "a", count: 64), for: "saber")
        let restored = try JSONDecoder().decode(StoreUpdate.Choices.self, from: JSONEncoder().encode(choices))
        XCTAssertEqual(restored.importedAPKs, choices.importedAPKs)
        choices.choose(1716, for: "saber")
        XCTAssertNil(choices.importedAPKs["saber"])
    }

    func testUnity63CoreModsRequireMatchingVersionAndEveryActualGameFingerprint() {
        var hashes = Dictionary(uniqueKeysWithValues: CoreModCompatibility.unity63Members.map { ($0.name, $0.sha256) })
        XCTAssertTrue(CoreModCompatibility.matches(package: "com.beatgames.beatsaber", versionCode: 3237, hashes: hashes))
        XCTAssertFalse(CoreModCompatibility.matches(package: "com.beatgames.beatsaber", versionCode: 1716, hashes: hashes))
        XCTAssertFalse(CoreModCompatibility.matches(package: "com.other.game", versionCode: 3237, hashes: hashes))
        hashes[CoreModCompatibility.unity63Members[1].name] = String(repeating: "0", count: 64)
        XCTAssertFalse(CoreModCompatibility.matches(package: "com.beatgames.beatsaber", versionCode: 3237, hashes: hashes))
        hashes.removeValue(forKey: CoreModCompatibility.unity63Members[0].name)
        XCTAssertFalse(CoreModCompatibility.matches(package: "com.beatgames.beatsaber", versionCode: 3237, hashes: hashes))
    }

    func testImportedSelectionResolvesPinnedRecipeWithoutChangingItsOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("avp-import-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imports = ImportedAPKStore(directory: folder), digest = String(repeating: "a", count: 64)
        let base = try recipe(), imported = try recipe(digest)
        try JSONEncoder().encode(imported).write(to: imports.url(recipeId: "saber", sha256: digest))
        var choice = StoreUpdate.Choices(); choice.chooseImported(digest, for: "saber")
        let resolved = StoreUpdate.resolve([base], drafts: folder, choices: choice, imports: imports)
        XCTAssertEqual(resolved.first?.importedAPK?.sha256, digest)
        XCTAssertNil(base.importedAPK)
        choice.choose(1716, for: "saber")
        XCTAssertNil(StoreUpdate.resolve([base], drafts: folder, choices: choice, imports: imports).first?.importedAPK)
    }
}
