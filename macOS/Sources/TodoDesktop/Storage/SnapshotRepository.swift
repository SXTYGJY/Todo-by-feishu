import Foundation

struct SnapshotRepository {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let accessLock = NSRecursiveLock()

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TodoDesktop", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
    }

    func load(identity: FeishuIdentity, bindingID: String) -> ViewSnapshot? {
        accessLock.lock()
        defer { accessLock.unlock() }
        let url = snapshotURL(identity: identity, bindingID: bindingID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ViewSnapshot.self, from: data)
    }

    func save(_ snapshot: ViewSnapshot, identity: FeishuIdentity, bindingID: String) throws {
        accessLock.lock()
        defer { accessLock.unlock() }
        let directory = rootDirectory.appendingPathComponent(identity.storageKey, isDirectory: true)
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: snapshotURL(identity: identity, bindingID: bindingID), options: .atomic)
    }

    func delete(identity: FeishuIdentity, bindingID: String) throws {
        accessLock.lock()
        defer { accessLock.unlock() }
        let url = snapshotURL(identity: identity, bindingID: bindingID)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    func saveCompletion(identity: FeishuIdentity,
                        bindingID: String,
                        recordID: String,
                        isDone: Bool) throws -> ViewSnapshot? {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let current = load(identity: identity, bindingID: bindingID) else { return nil }
        var didFindRecord = false
        let items = current.items.map { item -> ProjectedTodo in
            guard item.id == recordID else { return item }
            didFindRecord = true
            return ProjectedTodo(id: item.id,
                                 title: item.title,
                                 priority: item.priority,
                                 isDone: isDone,
                                 dateMilliseconds: item.dateMilliseconds,
                                 sourceOrder: item.sourceOrder,
                                 plannedDurationHours: item.plannedDurationHours)
        }
        guard didFindRecord else { return current }
        let updated = ViewSnapshot(fetchedAt: Date(), items: items, projectionIssues: current.projectionIssues)
        try save(updated, identity: identity, bindingID: bindingID)
        return updated
    }

    func saveDate(identity: FeishuIdentity,
                  bindingID: String,
                  recordID: String,
                  dateMilliseconds: Double) throws -> ViewSnapshot? {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let current = load(identity: identity, bindingID: bindingID) else { return nil }
        var didFindRecord = false
        let items = current.items.map { item -> ProjectedTodo in
            guard item.id == recordID else { return item }
            didFindRecord = true
            return ProjectedTodo(id: item.id,
                                 title: item.title,
                                 priority: item.priority,
                                 isDone: item.isDone,
                                 dateMilliseconds: dateMilliseconds,
                                 sourceOrder: item.sourceOrder,
                                 plannedDurationHours: item.plannedDurationHours)
        }
        guard didFindRecord else { return current }
        let updated = ViewSnapshot(fetchedAt: Date(), items: items, projectionIssues: current.projectionIssues)
        try save(updated, identity: identity, bindingID: bindingID)
        return updated
    }

    func saveTask(identity: FeishuIdentity,
                  bindingID: String,
                  recordID: String,
                  title: String,
                  priority: String?,
                  plannedDurationHours: Double?) throws -> ViewSnapshot? {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let current = load(identity: identity, bindingID: bindingID) else { return nil }
        var didFindRecord = false
        let items = current.items.map { item -> ProjectedTodo in
            guard item.id == recordID else { return item }
            didFindRecord = true
            return ProjectedTodo(id: item.id,
                                 title: title,
                                 priority: priority,
                                 isDone: item.isDone,
                                 dateMilliseconds: item.dateMilliseconds,
                                 sourceOrder: item.sourceOrder,
                                 plannedDurationHours: plannedDurationHours)
        }
        guard didFindRecord else { return current }
        let updated = ViewSnapshot(fetchedAt: Date(), items: items, projectionIssues: current.projectionIssues)
        try save(updated, identity: identity, bindingID: bindingID)
        return updated
    }

    func deleteTask(identity: FeishuIdentity, bindingID: String, recordID: String) throws -> ViewSnapshot? {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let current = load(identity: identity, bindingID: bindingID) else { return nil }
        let updated = ViewSnapshot(fetchedAt: Date(),
                                   items: current.items.filter { $0.id != recordID },
                                   projectionIssues: current.projectionIssues?.filter { $0.recordID != recordID })
        try save(updated, identity: identity, bindingID: bindingID)
        return updated
    }

    private func snapshotURL(identity: FeishuIdentity, bindingID: String) -> URL {
        rootDirectory.appendingPathComponent(identity.storageKey, isDirectory: true)
            .appendingPathComponent("\(bindingID).json", isDirectory: false)
    }
}
