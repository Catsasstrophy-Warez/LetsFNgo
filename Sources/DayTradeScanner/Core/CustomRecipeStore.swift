import Foundation
import Observation

/// User-built scan recipes, persisted alongside the 17 built-ins in
/// `RecipeLibrary`. Kept separate from that enum's static library since
/// these are mutable and need somewhere to actually live — UserDefaults,
/// the same place every other setting in this app is stored, is more than
/// enough for a personal list of a few dozen filter-chip recipes.
///
/// Wraps `UserDefaultsPresetStore` for the actual save/delete/persist
/// mechanics rather than reimplementing them — see that type's doc comment
/// for why. This type's own job is the recipe-specific surface: the
/// `recipes` name callers already use, `isCustom`, and JSON import/export.
@MainActor
@Observable
final class CustomRecipeStore {
    static let shared = CustomRecipeStore()

    private let store = UserDefaultsPresetStore<ScanRecipe>(defaultsKey: "customRecipes")

    var recipes: [ScanRecipe] { store.items }

    func save(_ recipe: ScanRecipe) { store.save(recipe) }
    func delete(named name: String) { store.delete(named: name) }
    func recipe(named name: String) -> ScanRecipe? { store.item(named: name) }

    /// Whether a name belongs to a user recipe rather than a built-in —
    /// governs whether the picker offers an edit/delete affordance for it.
    func isCustom(named name: String) -> Bool {
        store.item(named: name) != nil
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
}
