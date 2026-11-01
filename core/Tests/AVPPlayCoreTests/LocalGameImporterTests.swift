import XCTest
@testable import AVPPlayCore

final class LocalGameImporterTests: XCTestCase {
    private func recipe(package: String = "com.example.game", version: Int = 42) -> Recipe {
        Recipe(schema: 1, id: "local-test", title: "Local Test", package: package,
               versionName: "1.2.3", versionCode: version,
               store: .init(appId: "12345"),
               toolchain: .init(target: "local-test", minCommit: ""),
               files: [RecipeFile(name: "game.apk", role: "apk", id: "1", size: nil,
                                  sha256: nil, required: true, dest: "", localName: nil,
                                  locale: nil, source: nil)],
               addons: nil, status: .init(playability: "untested", download: "listed", notes: nil), icon: nil)
    }

    func testAcceptsSelectedVersion() throws {
        let info = ApkUnpacker.Info(package: "com.example.game", versionCode: "42", versionName: "1.2.3", files: 0)
        XCTAssertNoThrow(try LocalGameImporter.validateAPK(info, recipe: recipe()))
    }
    func testRejectsWrongPackage() {
        let info = ApkUnpacker.Info(package: "com.other.game", versionCode: "42", versionName: "1.2.3", files: 0)
        XCTAssertThrowsError(try LocalGameImporter.validateAPK(info, recipe: recipe()))
    }
    func testRejectsWrongBuild() {
        let info = ApkUnpacker.Info(package: "com.example.game", versionCode: "41", versionName: "1.2.2", files: 0)
        XCTAssertThrowsError(try LocalGameImporter.validateAPK(info, recipe: recipe()))
    }
    func testRejectsUnknownPackage() {
        let info = ApkUnpacker.Info(package: "com.example.game", versionCode: "42", versionName: "1.2.3", files: 0)
        XCTAssertThrowsError(try LocalGameImporter.validateAPK(info, recipe: recipe(package: "")))
    }
}
