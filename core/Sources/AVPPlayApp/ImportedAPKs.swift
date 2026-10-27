import AppKit
import AVPPlayCore
import UniformTypeIdentifiers

extension AppModel {
    func importAPK() {
        guard !importingAPK, let recipesURL = paths.recipes else { return }
        let panel = NSOpenPanel()
        panel.title = L("Import APK", "APK importieren")
        panel.message = L("Choose an APK from your own game. AVP Play will match its package and version to a recipe and add it to that game's Version menu.",
                          "Wähle ein APK deines eigenen Spiels. AVP Play ordnet Paket und Fassung einem Rezept zu und ergänzt das Menü „Fassung“ des Spiels.")
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        guard StoreLocation.isAvailable(paths.store.root) else {
            notice = L("The downloads disk is not available.", "Das Laufwerk für Downloads ist nicht erreichbar.")
            return
        }
        importingAPK = true
        let store = paths.store, drafts = draftsDirectory
        Task {
            do {
                let recipe = try await Task.detached(priority: .userInitiated) {
                    let known = RecipeStore(directory: recipesURL)
                    let family = try known.importCandidates(drafts: drafts)
                    return try ImportedAPKStore().register(apk: file, matching: family, store: store)
                }.value
                if isBusy(recipe.id) {
                    refresh()
                    notice = L("APK imported. Select it from Version after this game's current job finishes.",
                               "APK importiert. Wähle es unter „Fassung“, wenn der aktuelle Auftrag dieses Spiels beendet ist.")
                    importingAPK = false
                    return
                }
                var choice = StoreUpdate.Choices.load()
                choice.chooseImported(recipe.importedAPK!.sha256, for: recipe.id)
                try choice.save()
                latestChoices = choice
                section = .games
                refresh()
                gamePath = [recipe.id]
                notice = L("\(recipe.title) \(recipe.versionName) recognized. Your APK is selected in the game's Version menu.",
                           "\(recipe.title) \(recipe.versionName) erkannt. Dein APK ist im Menü „Fassung“ des Spiels gewählt.")
            } catch { notice = "\(error)" }
            importingAPK = false
        }
    }

    func includesCoreMods(for game: Game) -> Bool {
        guard let imported = game.recipe.importedAPK, imported.coreModsEligible else { return false }
        return options(for: game).coreModsByAPK?[imported.sha256]
            ?? SigningRecord.importedIdentity(store: paths.store, recipe: game.recipe)?.coreMods ?? false
    }

    func setCoreMods(_ enabled: Bool, for game: Game) {
        guard let imported = game.recipe.importedAPK, imported.coreModsEligible else { return }
        if enabled, CoreModToolchainSelection.load()?.toolchain()?.supportsCoreMods(versionCode: game.recipe.versionCode) != true {
            notice = L("The core-mod toolchain is not installed in this copy of AVP Play.",
                       "Die Core-Mod-Toolchain ist in dieser Kopie von AVP Play nicht installiert.")
            return
        }
        var value = options(for: game)
        if value.coreModsByAPK == nil { value.coreModsByAPK = [:] }
        value.coreModsByAPK?[imported.sha256] = enabled
        setOptions(value, for: game)
    }
}
