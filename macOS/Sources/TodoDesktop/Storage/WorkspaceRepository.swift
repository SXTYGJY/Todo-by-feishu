import Foundation

struct WorkspaceRepository {
    private let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TodoDesktop", isDirectory: true)
            .appendingPathComponent("workspaces", isDirectory: true)
    }

    func load(for identity: FeishuIdentity) throws -> AccountWorkspace {
        let fileURL = workspaceURL(for: identity)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return AccountWorkspace(identity: identity)
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let workspace = try decoder.decode(AccountWorkspace.self, from: data)
        guard workspace.identity == identity,
              workspace.schemaVersion == 1,
              workspace.bindings.allSatisfy({ $0.accountKey == identity.storageKey }) else {
            throw WorkspaceRepositoryError.invalidWorkspace
        }
        return workspace
    }

    func save(_ workspace: AccountWorkspace) throws {
        guard workspace.schemaVersion == 1,
              workspace.bindings.allSatisfy({ $0.accountKey == workspace.identity.storageKey }) else {
            throw WorkspaceRepositoryError.invalidWorkspace
        }
        try fileManager.createDirectory(at: rootDirectory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(workspace)
        let fileURL = workspaceURL(for: workspace.identity)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func workspaceURL(for identity: FeishuIdentity) -> URL {
        rootDirectory.appendingPathComponent("\(identity.storageKey).json", isDirectory: false)
    }
}

enum WorkspaceRepositoryError: LocalizedError {
    case invalidWorkspace

    var errorDescription: String? {
        "本机便签配置格式无效或版本不受支持。"
    }
}
