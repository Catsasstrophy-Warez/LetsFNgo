import Foundation
import Observation

/// User-built scan recipes, persisted alongside the 17 built-ins in
/// `RecipeLibrary`. Kept separate from that enum's static library since
/// these are mutable and need somewhere to actually live — UserDefaults,
/// the same place every other setting in this app is stored, is more than
/// enough for a personal list of a few dozen filter-chip recipes.
@MainActor
@Observable
final class CustomRecipeStore {
    static let shared = CustomRecipeStore()

    private(set) var recipes: [ScanRecipe] = []
    private let defaultsKey = "customRecipes"
    private let defaults = UserDefaults.standard

    init() {
        load()
    }

    func save(_ recipe: ScanRecipe) {
        if let index = recipes.firstIndex(where: { $0.name == recipe.name }) {
            recipes[index] = recipe
        } else {
            recipes.append(recipe)
        }
        persist()
    }

    func delete(named name: String) {
        recipes.removeAll { $0.name == name }
        persist()
    }

    func recipe(named name: String) -> ScanRecipe? {
        recipes.first { $0.name == name }
    }

    /// Whether a name belongs to a user recipe rather than a built-in —
    /// governs whether the picker offers an edit/delete affordance for it.
    func isCustom(named name: String) -> Bool {
        recipes.contains { $0.name == name }
    }

    // MARK: - Import / export

    /// A single recipe as pretty-printed JSON, for the Share sheet.
    func exportJSON(_ recipe: ScanRecipe) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(recipe)
    }

    /// Imports a single recipe or an array of recipes from JSON data,
    /// accepting whichever shape the file turns out to be rather than
    /// forcing the caller to know in advance. Returns the recipes actually
    /// added.
    @discardableResult
    func importJSON(_ data: Data) -> [ScanRecipe] {
        let decoder = JSONDecoder()
        let imported: [ScanRecipe]
        if let single = try? decoder.decode(ScanRecipe.self, from: data) {
            imported = [single]
        } else if let many = try? decoder.decode([ScanRecipe].self, from: data) {
            imported = many
        } else {
            return []
        }
        for recipe in imported { save(recipe) }
        return imported
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(recipes) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ScanRecipe].self, from: data) else { return }
        recipes = decoded
    }
}
