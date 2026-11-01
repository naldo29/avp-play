import Foundation

/// Imports local game files into the versioned ContentStore without contacting Meta or Steam.
/// The normal installation pipeline and its ownership checks are unchanged.
public struct LocalGameImporter: Sendable {
    public struct Result: Sendable {
        public var imported: [String] = []
        public var alreadyPresent: [String] = []
        public var missingRequired: [String] = []
        public var unverifiedCompanions: [String] = []
    }

    public enum ImportError: Error, CustomStringConvertible {
        case notReady, unknownPackage, noAPK, wrongVersion(String), ambiguous(String)
        case sizeMismatch(String), checksumMismatch(String), unsafeName(String)

        public var description: String {
            switch self {
            case .notReady: return "Choose a game version with a known APK file list first."
            case .unknownPackage: return "The selected game has no known Android package ID."
            case .noAPK: return "No matching APK found. Select the APK or a folder containing it."
            case .wrongVersion(let name): return "Wrong game or version: \(name)."
            case .ambiguous(let name): return "More than one candidate matches \(name). Select a smaller folder."
            case .sizeMismatch(let name): return "File size does not match: \(name)."
            case .checksumMismatch(let name): return "Checksum does not match: \(name)."
            case .unsafeName(let name): return "Unsafe recipe filename: \(name)."
            }
        }
    }

    private let store: ContentStore
    public init(store: ContentStore) { self.store = store }

    public static func validateAPK(_ info: ApkUnpacker.Info, recipe: Recipe) throws {
        guard recipe.versionCode > 0, recipe.files.contains(where: { $0.role == "apk" }) else {
            throw ImportError.notReady
        }
        guard !recipe.package.isEmpty else { throw ImportError.unknownPackage }
        guard Toolchain.apkMatches(info, recipe: recipe) else {
            throw ImportError.wrongVersion("\(info.package ?? "?"), version code \(info.versionCode ?? "?"); expected \(recipe.package), code \(recipe.versionCode)")
        }
    }

    public func run(recipe: Recipe, sources: [URL]) throws -> Result {
        guard recipe.versionCode > 0, let apk = recipe.files.first(where: { $0.role == "apk" }) else {
            throw ImportError.notReady
        }
        guard !recipe.package.isEmpty else { throw ImportError.unknownPackage }
        let index = Adopter.index(sources, maxDepth: 5)
        let candidates = Array(Set(index.values.flatMap { $0 }))
        let apks = candidates.filter { $0.pathExtension.lowercased() == "apk" }
        var matching: [URL] = []
        var firstFailure: Error?
        for url in apks {
            guard let info = try? ApkUnpacker.manifest(of: url) else { continue }
            do {
                try Self.validateAPK(info, recipe: recipe)
                try Self.verify(url, file: apk)
                matching.append(url)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        let cached = store.url(for: apk, in: recipe)
        if matching.isEmpty, apks.isEmpty, ContentStore.fileSize(cached) != nil {
            try Self.validateAPK(ApkUnpacker.manifest(of: cached), recipe: recipe)
            try Self.verify(cached, file: apk)
            matching.append(cached)
        }
        guard !matching.isEmpty else { throw firstFailure ?? ImportError.noAPK }
        guard matching.count == 1 else { throw ImportError.ambiguous(apk.name) }

        var work: [(RecipeFile, URL)] = [(apk, matching[0])]
        var result = Result()
        for file in recipe.files where file.role != "apk" {
            guard Recipe.isSafeName(file.name) else { throw ImportError.unsafeName(file.name) }
            let named = (index[file.name] ?? []) + (file.localName.flatMap { index[$0] } ?? [])
            let found = Array(Set(named))
            if found.isEmpty {
                if file.required, ContentStore.fileSize(store.url(for: file, in: recipe)) == nil {
                    result.missingRequired.append(file.name)
                }
                continue
            }
            let valid = found.filter { (try? Self.verify($0, file: file)) != nil }
            guard !valid.isEmpty else { try Self.verify(found[0], file: file); throw ImportError.sizeMismatch(file.name) }
            guard valid.count == 1 else { throw ImportError.ambiguous(file.name) }
            work.append((file, valid[0]))
            if file.sha256 == nil { result.unverifiedCompanions.append(file.name) }
        }
        for (file, _) in work where !Recipe.isSafeName(file.name) {
            throw ImportError.unsafeName(file.name)
        }

        let fm = FileManager.default
        let directory = store.directory(for: recipe)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var staged: [(RecipeFile, URL, URL)] = []
        defer { for (_, temporary, _) in staged { try? fm.removeItem(at: temporary) } }
        for (file, source) in work {
            let target = store.url(for: file, in: recipe)
            let same = source.standardizedFileURL == target.standardizedFileURL ||
                (ContentStore.fileSize(target) == ContentStore.fileSize(source) &&
                 (try? Hashing.sha256(of: target)) == (try? Hashing.sha256(of: source)))
            if same {
                result.alreadyPresent.append(file.name)
                continue
            }
            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).import-part")
            try fm.copyItem(at: source, to: temporary)
            staged.append((file, temporary, target))
            try Self.verify(temporary, file: file)
        }
        for (file, temporary, target) in staged {
            try? fm.removeItem(at: target)
            try fm.moveItem(at: temporary, to: target)
            Adopter.stripDownloadMetadata(target)
            result.imported.append(file.name)
        }
        return result
    }

    private static func verify(_ url: URL, file: RecipeFile) throws {
        guard let size = ContentStore.fileSize(url) else { throw ImportError.sizeMismatch(file.name) }
        if let expected = file.size, expected != size { throw ImportError.sizeMismatch(file.name) }
        if let expected = file.sha256, try Hashing.sha256(of: url) != expected.lowercased() {
            throw ImportError.checksumMismatch(file.name)
        }
    }
}
