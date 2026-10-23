import Foundation

struct FixedTaskPreference: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var priorityOptionID: String
    var priorityName: String
    var plannedDurationHours: Double?

    var bridgeValue: [String: Any] {
        [
            "id": id,
            "title": title,
            "priorityOptionID": priorityOptionID,
            "priorityName": priorityName,
            "plannedDurationHours": plannedDurationHours as Any? ?? NSNull()
        ]
    }
}

struct FixedTaskOccurrence: Codable, Identifiable {
    let id: String
    let templateID: String
    let dateKey: String
    let clientToken: String
    var recordID: String?
}

struct PendingFixedTaskOccurrence {
    let template: FixedTaskPreference
    let occurrence: FixedTaskOccurrence
}
