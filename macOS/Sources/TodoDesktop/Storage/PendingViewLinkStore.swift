import Foundation

struct PendingViewLinkStore {
    private let defaults: UserDefaults
    private let key = "TodoDesktop.pendingViewURL"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> String? {
        defaults.string(forKey: key)
    }

    func save(_ url: String) {
        defaults.set(url, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
