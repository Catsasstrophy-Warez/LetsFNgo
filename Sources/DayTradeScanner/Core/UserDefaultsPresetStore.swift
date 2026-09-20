import Foundation
import Observation

/// Anything with a name unique enough to key a preset list by — every
/// recipe/filter/screen type this store manages already has exactly this
/// shape (it's also how each one implements `Identifiable`).
protocol NamedPreset: Codable {
    var name: String { get }
}

/// The save/delete/persist-to-UserDefaults-as-JSON shape shared by
/// `CustomRecipeStore`, `UnusualActivityFilterStore`, and
/// `OptionScreenFilterStore` — three independent types that all
/// reimplemented the identical ~30 lines of boilerplate. Each of those now
/// wraps one of these rather than duplicating it, so a bug fixed here (an
/// encoding edge case, a persistence-key collision) can't be fixed in one
/// and silently missed in the other two, the way three copies invites.
///
/// Composition over inheritance deliberately: each wrapper type keeps its
/// own public API (different property names — `recipes` vs `presets` —
/// and store-specific extras like `CustomRecipeStore`'s JSON import/export)
/// without every call site across the app needing to change to a shared
/// generic type name.
@MainActor
@Observable
final class UserDefaultsPresetStore<Item: NamedPreset> {
    private(set) var items: [Item] = []
    private let defaultsKey: String
    private let defaults: UserDefaults

    init(defaultsKey: String, defaults: UserDefaults = .standard) {
        self.defaultsKey = defaultsKey
        self.defaults = defaults
        load()
    }

    func save(_ item: Item) {
        if let index = items.firstIndex(where: { $0.name == item.name }) {
            items[index] = item
        } else {
            items.append(item)
        }
        persist()
    }

    func delete(named name: String) {
        items.removeAll { $0.name == name }
        persist()
    }

    func item(named name: String) -> Item? {
        items.first { $0.name == name }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Item].self, from: data) else { return }
        items = decoded
    }
}
