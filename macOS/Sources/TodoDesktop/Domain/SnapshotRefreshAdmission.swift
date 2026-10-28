enum SnapshotRefreshAdmission {
    static func begin(bindingID: String,
                      hasActiveMutation: Bool,
                      markStale: (String) -> Void) -> Bool {
        guard !hasActiveMutation else { return false }
        markStale(bindingID)
        return true
    }
}

@MainActor
final class SnapshotRefreshCoordinator<Value> {
    private var tasks: [String: Task<Value, Error>] = [:]

    func run(key: String, operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        if let task = tasks[key] { return try await task.value }
        let task = Task { try await operation() }
        tasks[key] = task
        defer { tasks.removeValue(forKey: key) }
        return try await task.value
    }
}
