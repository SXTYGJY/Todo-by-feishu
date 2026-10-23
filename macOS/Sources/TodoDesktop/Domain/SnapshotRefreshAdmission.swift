enum SnapshotRefreshAdmission {
    static func begin(bindingID: String,
                      hasActiveMutation: Bool,
                      markStale: (String) -> Void) -> Bool {
        guard !hasActiveMutation else { return false }
        markStale(bindingID)
        return true
    }
}
