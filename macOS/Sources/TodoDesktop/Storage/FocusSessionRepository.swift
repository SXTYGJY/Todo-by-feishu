import Foundation

struct FocusConfiguration: Codable {
    var workMinutes = 25
    var shortBreakMinutes = 5
    var longBreakMinutes = 15
    var longBreakEvery = 4
}

struct FocusTaskProgress: Codable {
    var totalFocusedSeconds = 0.0
    var currentRoundSeconds = 0.0
    var completedRounds = 0
}

struct FocusSessionData: Codable {
    var configuration = FocusConfiguration()
    var tasks: [String: FocusTaskProgress] = [:]
    var activeTaskID: String?
    var mode = "idle"
    var lastTickAt: Date?
    var breakEndsAt: Date?
}

struct FocusSessionState {
    let data: FocusSessionData
    let progress: FocusTaskProgress
    let roundCompleted: Bool
}

struct FocusSessionRepository {
    private let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TodoDesktop", isDirectory: true)
            .appendingPathComponent("focus-sessions", isDirectory: true)
    }

    func state(accountKey: String, bindingID: String, taskID: String) throws -> FocusSessionState {
        var data = try load(accountKey: accountKey, bindingID: bindingID)
        let completed = advance(&data, now: Date())
        let progress = data.tasks[taskID] ?? FocusTaskProgress()
        try save(data, accountKey: accountKey, bindingID: bindingID)
        return FocusSessionState(data: data, progress: progress, roundCompleted: completed)
    }

    func tick(accountKey: String, bindingID: String) throws -> (FocusSessionData, Bool, String?) {
        var data = try load(accountKey: accountKey, bindingID: bindingID)
        guard data.mode != "idle" || data.activeTaskID != nil || data.breakEndsAt != nil else {
            return (data, false, nil)
        }
        let previousTaskID = data.activeTaskID
        let completed = advance(&data, now: Date())
        if data.mode == "rest", let breakEndsAt = data.breakEndsAt, breakEndsAt <= Date() {
            data.activeTaskID = nil
            data.mode = "idle"
            data.breakEndsAt = nil
            data.lastTickAt = nil
        }
        try save(data, accountKey: accountKey, bindingID: bindingID)
        return (data, completed, previousTaskID)
    }

    func pauseCurrent(accountKey: String, bindingID: String) throws {
        let data = try load(accountKey: accountKey, bindingID: bindingID)
        guard let taskID = data.activeTaskID else { return }
        _ = try pause(accountKey: accountKey, bindingID: bindingID, taskID: taskID)
    }

    func start(accountKey: String, bindingID: String, taskID: String) throws -> FocusSessionState {
        var data = try load(accountKey: accountKey, bindingID: bindingID)
        _ = advance(&data, now: Date())
        if data.mode == "rest" { data.mode = "idle"; data.breakEndsAt = nil }
        data.activeTaskID = taskID
        data.mode = "work"
        data.lastTickAt = Date()
        if data.tasks[taskID] == nil { data.tasks[taskID] = FocusTaskProgress() }
        try save(data, accountKey: accountKey, bindingID: bindingID)
        return FocusSessionState(data: data, progress: data.tasks[taskID] ?? FocusTaskProgress(), roundCompleted: false)
    }

    func pause(accountKey: String, bindingID: String, taskID: String) throws -> (FocusSessionData, Bool) {
        var data = try load(accountKey: accountKey, bindingID: bindingID)
        let roundCompleted = advance(&data, now: Date())
        if roundCompleted {
            try save(data, accountKey: accountKey, bindingID: bindingID)
            return (data, true)
        }
        if data.activeTaskID == taskID {
            data.activeTaskID = nil
            data.mode = "idle"
            data.lastTickAt = nil
            data.breakEndsAt = nil
        }
        try save(data, accountKey: accountKey, bindingID: bindingID)
        return (data, false)
    }

    func completeTask(accountKey: String, bindingID: String, taskID: String) throws {
        var data = try load(accountKey: accountKey, bindingID: bindingID)
        _ = advance(&data, now: Date())
        if data.activeTaskID == taskID {
            data.activeTaskID = nil
            data.mode = "idle"
            data.lastTickAt = nil
            data.breakEndsAt = nil
        }
        try save(data, accountKey: accountKey, bindingID: bindingID)
    }

    func forgetTask(accountKey: String, bindingID: String, taskID: String) throws {
        var data = try load(accountKey: accountKey, bindingID: bindingID)
        _ = advance(&data, now: Date())
        data.tasks.removeValue(forKey: taskID)
        if data.activeTaskID == taskID {
            data.activeTaskID = nil
            data.mode = "idle"
            data.lastTickAt = nil
            data.breakEndsAt = nil
        }
        try save(data, accountKey: accountKey, bindingID: bindingID)
    }

    func configure(accountKey: String, bindingID: String, configuration: FocusConfiguration) throws -> FocusSessionData {
        guard (1...120).contains(configuration.workMinutes),
              (1...60).contains(configuration.shortBreakMinutes),
              (1...90).contains(configuration.longBreakMinutes),
              (2...8).contains(configuration.longBreakEvery) else {
            throw FocusSessionError.invalidConfiguration
        }
        var data = try load(accountKey: accountKey, bindingID: bindingID)
        data.configuration = configuration
        try save(data, accountKey: accountKey, bindingID: bindingID)
        return data
    }

    func delete(accountKey: String, bindingID: String) throws {
        let url = fileURL(accountKey: accountKey, bindingID: bindingID)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func advance(_ data: inout FocusSessionData, now: Date) -> Bool {
        if data.mode == "rest", let breakEndsAt = data.breakEndsAt, breakEndsAt <= now {
            data.activeTaskID = nil
            data.mode = "idle"
            data.breakEndsAt = nil
            data.lastTickAt = nil
            return false
        }
        guard data.mode == "work", let taskID = data.activeTaskID,
              let previous = data.lastTickAt else { return false }
        let rawDelta = now.timeIntervalSince(previous)
        // Treat long gaps as app suspension so sleep time is never counted as focus.
        let delta = rawDelta > 5 ? 0 : max(0, rawDelta)
        data.lastTickAt = now
        var progress = data.tasks[taskID] ?? FocusTaskProgress()
        progress.totalFocusedSeconds += delta
        progress.currentRoundSeconds += delta
        let roundLength = Double(data.configuration.workMinutes * 60)
        guard progress.currentRoundSeconds >= roundLength else {
            data.tasks[taskID] = progress
            return false
        }
        progress.currentRoundSeconds = 0
        progress.completedRounds += 1
        data.tasks[taskID] = progress
        let breakMinutes = progress.completedRounds.isMultiple(of: data.configuration.longBreakEvery)
            ? data.configuration.longBreakMinutes : data.configuration.shortBreakMinutes
        data.mode = "rest"
        data.breakEndsAt = now.addingTimeInterval(TimeInterval(breakMinutes * 60))
        return true
    }

    private func load(accountKey: String, bindingID: String) throws -> FocusSessionData {
        guard let data = try? Data(contentsOf: fileURL(accountKey: accountKey, bindingID: bindingID)) else {
            return FocusSessionData()
        }
        return try JSONDecoder().decode(FocusSessionData.self, from: data)
    }

    private func save(_ data: FocusSessionData, accountKey: String, bindingID: String) throws {
        let directory = rootDirectory.appendingPathComponent(accountKey, isDirectory: true)
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let url = fileURL(accountKey: accountKey, bindingID: bindingID)
        try JSONEncoder().encode(data).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func fileURL(accountKey: String, bindingID: String) -> URL {
        rootDirectory.appendingPathComponent(accountKey, isDirectory: true)
            .appendingPathComponent("\(bindingID).json", isDirectory: false)
    }
}

enum FocusSessionError: LocalizedError {
    case invalidConfiguration

    var errorDescription: String? {
        "工作、休息时长或长休息轮次超出可用范围。"
    }
}
