import Foundation

struct ActiveBindingRepository {
    private let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TodoDesktop", isDirectory: true)
            .appendingPathComponent("active-bindings", isDirectory: true)
    }

    func load(for identity: FeishuIdentity) throws -> String? {
        let url = stateURL(for: identity)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let state = try JSONDecoder().decode(ActiveBindingState.self, from: data)
        guard state.schemaVersion == 1, state.accountKey == identity.storageKey else {
            throw ActiveBindingRepositoryError.invalidState
        }
        return state.activeBindingID
    }

    func save(_ bindingID: String?, for identity: FeishuIdentity) throws {
        let url = stateURL(for: identity)
        guard let bindingID else {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            return
        }
        try fileManager.createDirectory(at: rootDirectory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let state = ActiveBindingState(schemaVersion: 1,
                                       accountKey: identity.storageKey,
                                       activeBindingID: bindingID)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func stateURL(for identity: FeishuIdentity) -> URL {
        rootDirectory.appendingPathComponent("\(identity.storageKey).json", isDirectory: false)
    }
}

private struct ActiveBindingState: Codable {
    let schemaVersion: Int
    let accountKey: String
    let activeBindingID: String
}

enum ActiveBindingRepositoryError: LocalizedError {
    case invalidState

    var errorDescription: String? {
        "本机当前便签状态无效或与当前飞书账号不匹配。"
    }
}
