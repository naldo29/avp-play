import CryptoKit
import Foundation

/// Identity of an explicitly imported APK. The digest distinguishes two APKs
/// with the same Android version code; it is never an assertion of compatibility.
public struct ImportedAPK: Codable, Sendable, Equatable {
    public var sha256: String
    public var fileName: String
    public var coreModsEligible: Bool

    public init(sha256: String, fileName: String, coreModsEligible: Bool) {
        self.sha256 = sha256
        self.fileName = fileName
        self.coreModsEligible = coreModsEligible
    }
}

public enum APKImportError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self {
        case .invalid(let detail):
            return L("APK import: \(detail)", "APK-Import: \(detail)")
        }
    }
}

/// Read only bounded output from the system unzip tool. APK data never becomes
/// shell code, and neither a forged manifest nor a ZIP bomb is read without a cap.
enum APKEntryReader {
    @discardableResult
    static func stream(_ arguments: [String], limit: Int, consume: (Data) -> Void) throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        var count = 0
        do {
            while let data = try output.fileHandleForReading.read(upToCount: min(1 << 20, limit - count + 1)), !data.isEmpty {
                guard data.count <= limit - count else {
                    throw APKImportError.invalid(L("an archive entry exceeds its size limit", "ein Archiveintrag überschreitet seine Größenbegrenzung"))
                }
                count += data.count
                consume(data)
            }
        } catch {
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
            process.waitUntilExit()
            throw error
        }
        try? output.fileHandleForReading.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw APKImportError.invalid(L("the selected archive cannot be read", "das gewählte Archiv ist nicht lesbar"))
        }
        return count
    }

    static func data(_ arguments: [String], limit: Int) throws -> Data {
        var result = Data()
        try stream(arguments, limit: limit) { result.append($0) }
        return result
    }

    static func names(in apk: URL) throws -> [String] {
        let data = try self.data(["-Z1", apk.path], limit: 8 << 20)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    static func hash(_ member: String, in apk: URL, maximumBytes: Int) throws -> (sha256: String, bytes: Int) {
        var hash = SHA256()
        let bytes = try stream(["-p", apk.path, member], limit: maximumBytes) { hash.update(data: $0) }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }
}

/// Exact game boundaries already validated by the ten-mod port. A name or
/// version label alone must never enable the core-mod switch.
public enum CoreModCompatibility {
    public static let minimumToolchainCommit = "1c5229a38ccf25aff6734afe271714b7d0d7aa41"
    public static let existingTestBundleId = "dev.klepton.beatsaber140.scotland2.test"
    static let members: [(name: String, bytes: Int, sha256: String)] = [
        ("lib/arm64-v8a/libil2cpp.so", 85_827_064, "edae5059bd5a85ba354eb679e1cdcc3816116d2e2b29b3a16a70c05b56dd07cb"),
        ("lib/arm64-v8a/libunity.so", 20_382_560, "8203664e3b9203e9731251ea958ca2b1d9f0fc1e3b10032c34a61e5ee8068891"),
        ("assets/bin/Data/Managed/Metadata/global-metadata.dat", 16_841_972, "1814358a82213ff8ab48b088eae65c4039801f2ca0e9ec48157e74d84f329c17")
    ]

    static let unity63Members: [(name: String, bytes: Int, sha256: String)] = [
        ("lib/arm64-v8a/libil2cpp.so", 130_464_944, "bb560407d856fdd8f00ac3026967b5b10c3af4dbcfa3650ac3fa41d58a3744eb"),
        ("lib/arm64-v8a/libunity.so", 24_495_168, "4bd2583ea13fa77b13a5ff22ddc4508347f54a087c62995efe19ff8d944cef43"),
        ("assets/bin/Data/Managed/Metadata/global-metadata.dat", 21_238_284, "34859f9dbfeb2dcd5f6ebe3ce64d682c836bcf40c97b2055f414a151dba9c5b8")
    ]

    static func members(for versionCode: Int) -> [(name: String, bytes: Int, sha256: String)]? {
        switch versionCode {
        case 1716: return members
        case 3237: return unity63Members
        default: return nil
        }
    }

    public static func matches(package: String?, versionCode: Int, hashes: [String: String]) -> Bool {
        guard package == "com.beatgames.beatsaber", let selected = members(for: versionCode) else { return false }
        return selected.allSatisfy { hashes[$0.name] == $0.sha256 }
    }

    public static func supports(apk: URL, package: String?, versionCode: Int) -> Bool {
        guard package == "com.beatgames.beatsaber", let selected = members(for: versionCode),
              let names = try? APKEntryReader.names(in: apk) else { return false }
        var hashes: [String: String] = [:]
        for member in selected {
            guard names.filter({ $0 == member.name }).count == 1,
                  let actual = try? APKEntryReader.hash(member.name, in: apk, maximumBytes: member.bytes),
                  actual.bytes == member.bytes else { return false }
            hashes[member.name] = actual.sha256
        }
        return matches(package: package, versionCode: versionCode, hashes: hashes)
    }
}

/// Local, owned imports. Metadata is separate from the shipped recipes; the APK
/// and its matching data use an isolated content directory keyed by its digest.
public struct ImportedAPKStore: Sendable {
    public let directory: URL
    public init(directory: URL = DataLocation.base.appendingPathComponent("imported-apks", isDirectory: true)) {
        self.directory = directory
    }

    func url(recipeId: String, sha256: String) -> URL {
        directory.appendingPathComponent("\(recipeId)-\(sha256).json")
    }

    public func recipes(for recipeId: String) -> [Recipe] {
        guard Recipe.isSafeName(recipeId) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix(recipeId + "-") }
            .compactMap { file -> Recipe? in
                guard let recipe = try? JSONDecoder().decode(Recipe.self, from: Data(contentsOf: file)),
                      recipe.id == recipeId, recipe.importedAPK != nil, (try? recipe.validate()) != nil else { return nil }
                return recipe
            }
            .sorted { ($0.versionCode, $0.importedAPK!.sha256) > ($1.versionCode, $1.importedAPK!.sha256) }
    }

    public func recipe(for recipeId: String, sha256: String) -> Recipe? {
        recipes(for: recipeId).first { $0.importedAPK?.sha256 == sha256 }
    }

    public func register(apk: URL, matching recipes: [Recipe], store: ContentStore) throws -> Recipe {
        let fm = FileManager.default
        guard apk.pathExtension.lowercased() == "apk", let size = ContentStore.fileSize(apk), size > 0, size <= 4 << 30 else {
            throw APKImportError.invalid(L("choose a regular APK file no larger than 4 GB", "wähle eine normale APK-Datei mit höchstens 4 GB"))
        }
        try fm.createDirectory(at: store.root, withIntermediateDirectories: true)
        let temporary = store.root.appendingPathComponent(".import-\(UUID().uuidString).apk")
        try fm.copyItem(at: apk, to: temporary)
        defer { try? fm.removeItem(at: temporary) }
        guard ContentStore.fileSize(temporary) == size else {
            throw APKImportError.invalid(L("the APK changed while it was being copied", "das APK wurde während des Kopierens verändert"))
        }
        try APKArchive.validate(temporary)
        let info = try ApkUnpacker.manifest(of: temporary)
        guard let codeText = info.versionCode, let code = Int(codeText), code > 0,
              let base = recipes.first(where: { $0.package == info.package && $0.versionCode == code && $0.importedAPK == nil }) else {
            throw APKImportError.invalid(L("no matching game/version recipe was found; a version name is not enough to guess the required files", "kein passendes Rezept für Spiel und Fassung gefunden; ein Versionsname genügt nicht, um die nötigen Dateien zu erraten"))
        }
        try base.validate()
        let digest = try Hashing.sha256(of: temporary)
        var recipe = base
        recipe.importedAPK = ImportedAPK(sha256: digest, fileName: String(apk.lastPathComponent.prefix(256)),
                                        coreModsEligible: CoreModCompatibility.supports(apk: temporary, package: info.package, versionCode: code))
        guard let index = recipe.files.firstIndex(where: { $0.role == "apk" }) else {
            throw APKImportError.invalid(L("the matching recipe has no APK", "das passende Rezept enthält kein APK"))
        }
        recipe.files[index].id = ""
        recipe.files[index].size = size
        recipe.files[index].sha256 = digest
        recipe.files[index].source = FileSource(kind: .user, url: nil,
            hint: LocalizedText(en: "The APK you imported; kept locally and never uploaded.", de: "Dein importiertes APK; bleibt lokal und wird nicht hochgeladen."))
        recipe.status.playability = "untested"
        recipe.status.download = "special"
        recipe.status.notes = (base.status.notes ?? []) + [LocalizedText(en: "Imported APK using the matching game/version recipe. Recognition does not establish compatibility of arbitrary APK modifications.", de: "Importiertes APK mit passendem Rezept für Spiel und Fassung. Erkennung bestätigt nicht die Kompatibilität beliebiger APK-Änderungen.")]
        try recipe.validate()
        let destination = store.url(for: recipe.files[index], in: recipe)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            guard try Hashing.sha256(of: destination) == digest else {
                throw APKImportError.invalid(L("an existing import is damaged; it was left untouched", "ein vorhandener Import ist beschädigt; er wurde nicht verändert"))
            }
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
        try reuseRequiredFiles(for: recipe, store: store)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recipe).write(to: url(recipeId: recipe.id, sha256: digest), options: .atomic)
        return recipe
    }

    /// Reuse only complete, hash-matching game data already in this local
    /// library. Purchased add-ons still follow the recipe's normal purchase flow.
    func reuseRequiredFiles(for recipe: Recipe, store: ContentStore) throws {
        let fm = FileManager.default
        let own = store.directory(for: recipe)
        let candidates = (try? fm.contentsOfDirectory(at: store.root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for file in recipe.files where file.role != "apk" && file.required {
            let target = store.url(for: file, in: recipe)
            guard !fm.fileExists(atPath: target.path), let expected = file.sha256, let size = file.size else { continue }
            for directory in candidates where directory != own {
                guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let source = directory.appendingPathComponent(file.name)
                guard ContentStore.fileSize(source) == size, (try? Hashing.sha256(of: source)) == expected else { continue }
                try fm.copyItem(at: source, to: target)
                guard try Hashing.sha256(of: target) == expected else {
                    try? fm.removeItem(at: target)
                    throw APKImportError.invalid(L("cached game data changed while it was copied", "zwischengespeicherte Spieldaten wurden beim Kopieren verändert"))
                }
                break
            }
        }
    }
}
