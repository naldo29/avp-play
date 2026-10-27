import Darwin
import Foundation

/// A folder import keeps the existing recipe's exact destinations. It never
/// guesses an OBB, interprets a folder name as a version, or imports saves.
struct GameFolderInputs {
    let files: [URL]
    let apk: URL

    init(folder: URL) throws {
        let fm = FileManager.default
        var pending: [(URL, Int)] = [(folder, 0)], found: [URL] = [], visited = 0
        while let (directory, depth) = pending.popLast() {
            let kind = try fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType
            guard kind == .typeDirectory, depth <= 16 else {
                throw APKImportError.invalid(L("choose a regular game folder, at most 16 folders deep", "einen regulären Spieleordner mit höchstens 16 Ebenen wählen"))
            }
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                visited += 1
                guard visited <= 50_000 else {
                    throw APKImportError.invalid(L("the selected folder is too large; choose only this game's folder", "der gewählte Ordner ist zu groß; nur den Spieleordner wählen"))
                }
                let kind = try fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
                switch kind {
                case .typeDirectory: pending.append((file, depth + 1))
                case .typeRegular: found.append(file)
                default:
                    throw APKImportError.invalid(L("game folders must not contain symbolic links or special files: \(file.lastPathComponent)", "Spieleordner dürfen keine symbolischen Links oder Spezialdateien enthalten: \(file.lastPathComponent)"))
                }
            }
        }
        let apks = found.filter { $0.pathExtension.lowercased() == "apk" }
        guard apks.count == 1 else {
            throw APKImportError.invalid(L("choose a folder containing exactly one APK and its matching game data (found \(apks.count) APKs)", "einen Ordner mit genau einem APK und den passenden Spieldaten wählen (\(apks.count) APKs gefunden)"))
        }
        self.files = found.sorted { $0.path < $1.path }
        self.apk = apks[0]
    }

    func dataFiles(for recipe: Recipe, cachedFiles: [URL] = []) throws -> [(RecipeFile, URL)] {
        try recipe.validate()
        let supplied = Set(files.map(\.lastPathComponent))
        let fallback = cachedFiles.filter { !supplied.contains($0.lastPathComponent) }
        let grouped = Dictionary(grouping: files + fallback, by: \.lastPathComponent)
        var result: [(RecipeFile, URL)] = []
        for file in recipe.files where file.role != "apk" {
            let candidates = grouped[file.name] ?? []
            if candidates.isEmpty && !file.required { continue }
            guard !candidates.isEmpty else {
                throw APKImportError.invalid(L("the folder is missing required file \(file.name); choose the complete game folder", "im Ordner fehlt die Pflichtdatei \(file.name); den vollständigen Spieleordner wählen"))
            }
            var matching: [URL] = []
            for candidate in candidates {
                guard let size = ContentStore.fileSize(candidate), file.size == nil || size == file.size else { continue }
                if let expected = file.sha256, try Hashing.sha256(of: candidate) != expected { continue }
                matching.append(candidate)
            }
            guard let source = matching.first, file.sha256 != nil || matching.count == 1 else {
                throw APKImportError.invalid(L("\(file.name) is ambiguous or does not match this version's size/checksum; existing imports were left intact", "\(file.name) ist mehrdeutig oder passt nicht zu Größe/Prüfsumme dieser Fassung; vorhandene Importe bleiben erhalten"))
            }
            var local = file
            local.size = ContentStore.fileSize(source)
            if local.sha256 == nil { local.sha256 = try Hashing.sha256(of: source) }
            // This exact file was explicitly supplied locally. This does not
            // change add-on purchase metadata or unlock any entitlement.
            local.id = ""
            local.source = FileSource(kind: .user, url: nil, hint: LocalizedText(
                en: "From your imported game folder; kept locally and never uploaded.",
                de: "Aus deinem importierten Spieleordner; bleibt lokal und wird nicht hochgeladen."))
            result.append((local, source))
        }
        return result
    }
}

extension ImportedAPKStore {
    /// Accept either a single APK or the complete folder containing it.
    public func register(input: URL, matching recipes: [Recipe], store: ContentStore) throws -> Recipe {
        let kind = try FileManager.default.attributesOfItem(atPath: input.path)[.type] as? FileAttributeType
        if kind == .typeRegular { return try register(apk: input, matching: recipes, store: store) }
        guard kind == .typeDirectory else { throw APKImportError.invalid(L("choose an APK or a regular game folder", "ein APK oder einen regulären Spieleordner wählen")) }
        let folder = try GameFolderInputs(folder: input)
        guard let size = ContentStore.fileSize(folder.apk), size > 0, size <= 4 << 30 else {
            throw APKImportError.invalid(L("the folder's APK must be a regular file no larger than 4 GB", "das APK im Ordner muss eine reguläre Datei bis 4 GB sein"))
        }
        let info = try ApkUnpacker.manifest(of: folder.apk)
        guard let code = info.versionCode.flatMap(Int.init),
              var base = recipes.first(where: { $0.package == info.package && $0.versionCode == code && $0.importedAPK == nil }) else {
            throw APKImportError.invalid(L("no matching game/version recipe was found for this folder's APK", "für das APK dieses Ordners wurde kein passendes Spiel-/Versionsrezept gefunden"))
        }
        // Validate the entire folder before publishing a new selectable import.
        // A previous local preparation may have generated a required index
        // outside the original download folder. Reuse only exact pinned files
        // already in this library, and never hide a mismatched supplied file.
        let supplied = Set(folder.files.map(\.lastPathComponent))
        let missing = base.files.filter { $0.role != "apk" && $0.required && $0.sha256 != nil && !supplied.contains($0.name) }
        let fm = FileManager.default
        let directories = ((try? fm.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil)) ?? [])
            .filter { (try? fm.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType) == .typeDirectory }
        let cached = directories.flatMap { directory in missing.compactMap { file -> URL? in
            let path = directory.appendingPathComponent(file.name)
            guard let size = ContentStore.fileSize(path), file.size == nil || file.size == size else { return nil }
            return path
        } }
        let files = try folder.dataFiles(for: base, cachedFiles: cached)
        for (file, _) in files {
            if let index = base.files.firstIndex(where: { $0.name == file.name }) { base.files[index] = file }
        }
        let imported = try prepareAPK(apk: folder.apk, matching: [base], store: store)
        for (file, source) in files {
            try Self.copyFolderFile(source, to: store.url(for: file, in: imported), file: file)
        }
        try saveRegistration(imported)
        return imported
    }

    /// Clone on APFS to avoid another multi-GB physical game copy; otherwise
    /// copy to a temporary file, verify it, then commit without replacing data.
    static func copyFolderFile(_ source: URL, to target: URL, file: RecipeFile) throws {
        let fm = FileManager.default
        guard let expected = file.sha256, let size = file.size else { throw APKImportError.invalid("missing folder file fingerprint") }
        if let kind = try? fm.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType {
            guard kind == .typeRegular, ContentStore.fileSize(target) == size, try Hashing.sha256(of: target) == expected else {
                throw APKImportError.invalid(L("an existing import is damaged and was left untouched: \(file.name)", "ein vorhandener Import ist beschädigt und bleibt unverändert: \(file.name)"))
            }
            return
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".folder-import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        if clonefile(source.path, temporary.path, UInt32(CLONE_NOFOLLOW)) != 0 {
            let failure = errno
            guard failure == EXDEV || failure == ENOTSUP || failure == EINVAL else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
            }
            try fm.copyItem(at: source, to: temporary)
        }
        guard ContentStore.fileSize(temporary) == size, try Hashing.sha256(of: temporary) == expected else {
            throw APKImportError.invalid(L("a game file changed while importing; the existing import was left intact: \(file.name)", "eine Spieldatei wurde beim Import geändert; der vorhandene Import bleibt erhalten: \(file.name)"))
        }
        // POSIX link refuses an existing destination, including a dangling
        // symlink. The temporary name is removed after this atomic commit.
        guard link(temporary.path, target.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
