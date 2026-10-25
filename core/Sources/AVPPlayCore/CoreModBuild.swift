import Foundation

/// The explicitly configured, modified toolchain for the validated mod profile.
/// Keeping it separate leaves the user's ordinary game/toolchain choices intact.
public struct CoreModToolchainSelection: Codable, Sendable {
    public var pin: ToolchainChoices.Pin
    public var bundledCommit: String?
    public init(pin: ToolchainChoices.Pin) { self.pin = pin }
    public static var url: URL { DataLocation.base.appendingPathComponent("core-mods-toolchain.json") }

    public static func load(from url: URL = CoreModToolchainSelection.url) -> CoreModToolchainSelection? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public func save(to url: URL = Self.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public func toolchain() -> Toolchain? {
        guard let chain = ToolchainPackager(root: ToolchainPackager.defaultRoot).toolchain(for: pin), chain.supportsCoreMods else { return nil }
        return chain
    }

    /// This optional resource is part of the custom Mac app, contains only
    /// source/redistributable graphics, and uses the normal verified installer.
    @discardableResult
    public static func installBundled(from bundle: Bundle = .main, at base: URL = DataLocation.base) throws -> Toolchain? {
        let selectionURL = base.appendingPathComponent("core-mods-toolchain.json")
        let current = load(from: selectionURL)
        if let current, current.bundledCommit == nil { return current.toolchain() }
        guard let resources = bundle.resourceURL?.appendingPathComponent("core-mods", isDirectory: true),
              let archive = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil))?
                .first(where: { $0.lastPathComponent.hasSuffix(".tar.gz") }) else { return current?.toolchain() }
        // Modified profiles can legitimately have the same Git base. Isolate
        // each verified archive by its content, so an older profile is never
        // silently reused merely because the base commit number is unchanged.
        let digest = try Hashing.sha256(of: archive)
        let root = base.appendingPathComponent("core-mod-toolchains", isDirectory: true)
            .appendingPathComponent(String(digest.prefix(16)), isDirectory: true)
        let packager = ToolchainPackager(root: root)
        let chain = try packager.install(archive: archive)
        guard chain.supportsCoreMods else {
            throw APKImportError.invalid(L("the bundled core-mod toolchain is incomplete", "die mitgelieferte Core-Mod-Toolchain ist unvollständig"))
        }
        var selection = Self(pin: .init(version: chain.version(), commit: chain.commit(), modified: true, path: chain.root.path))
        selection.bundledCommit = chain.commit()
        try selection.save(to: selectionURL)
        return chain
    }
}

extension Toolchain {
    public var supportsCoreMods: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("ports/scotland2/tools/avp_play.py").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("ports/scotland2/selected-mods.json").path)
    }

    func buildCommand(coreMods: Bool) throws -> (executable: URL, arguments: [String]) {
        if coreMods {
            guard supportsCoreMods else {
                throw APKImportError.invalid(L("the core-mod toolchain is not set up for this build", "die Core-Mod-Toolchain ist für diese Fassung nicht eingerichtet"))
            }
            return (URL(fileURLWithPath: "/usr/bin/python3"), [root.appendingPathComponent("ports/scotland2/tools/avp_play.py").path])
        }
        return (root.appendingPathComponent("visionos/run.sh"), ["device"])
    }
}
