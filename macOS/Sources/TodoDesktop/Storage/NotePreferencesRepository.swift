import Foundation

struct NotePreferencesRepository {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let accessLock = NSRecursiveLock()
    private let maximumImageBytes = 5 * 1024 * 1024
    private let defaultValues: [String: Any] = [
        "opacity": 100,
        "fontCN": "PingFang SC",
        "fontEN": "-apple-system",
        "textColor": "#454239",
        "textColorScope": "task",
        "textBold": false,
        "textItalic": false
    ]
    private let allowedFontsCN = ["PingFang SC", "Songti SC", "Kaiti SC", "system-ui"]
    private let allowedFontsEN = ["-apple-system", "Georgia", "Helvetica Neue", "Menlo"]

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TodoDesktop", isDirectory: true)
            .appendingPathComponent("note-preferences", isDirectory: true)
    }

    func load(accountKey: String, bindingID: String) -> [String: Any] {
        accessLock.lock()
        defer { accessLock.unlock() }
        var values = defaultValues
        guard let stored = loadStored(accountKey: accountKey, bindingID: bindingID) else {
            return values
        }
        values["opacity"] = (35...100).contains(stored.opacity) ? stored.opacity : 100
        values["fontCN"] = allowedFontsCN.contains(stored.fontCN) ? stored.fontCN : defaultValues["fontCN"]
        values["fontEN"] = allowedFontsEN.contains(stored.fontEN) ? stored.fontEN : defaultValues["fontEN"]
        values["textColor"] = Self.isValidHexColor(stored.textColor) ? stored.textColor : defaultValues["textColor"]
        values["textColorScope"] = ["task", "major"].contains(stored.textColorScope) ? stored.textColorScope : defaultValues["textColorScope"]
        values["textBold"] = stored.textBold
        values["textItalic"] = stored.textItalic
        values["fixedTasks"] = stored.fixedTasks.map(\.bridgeValue)
        if let selectedDate = stored.selectedDate, Self.isValidDateKey(selectedDate) {
            values["selectedDate"] = selectedDate
        }
        if let filename = stored.backgroundFilename,
           filename == "\(bindingID).jpg" || filename == "\(bindingID).png" || filename == "\(bindingID).webp",
           let imageData = try? Data(contentsOf: assetURL(accountKey: accountKey, filename: filename)) {
            let mimeType = URL(fileURLWithPath: filename).pathExtension == "jpg" ? "image/jpeg" : "image/\(URL(fileURLWithPath: filename).pathExtension)"
            values["backgroundImageData"] = "data:\(mimeType);base64,\(imageData.base64EncodedString())"
        }
        return values
    }

    func save(accountKey: String, bindingID: String, patch: [String: Any]) throws -> [String: Any] {
        accessLock.lock()
        defer { accessLock.unlock() }
        var current = load(accountKey: accountKey, bindingID: bindingID)
        let opacity = patch["opacity"] as? Int ?? current["opacity"] as? Int ?? 100
        guard (35...100).contains(opacity) else { throw NotePreferencesError.invalidOpacity }

        let fontCN = patch["fontCN"] as? String ?? current["fontCN"] as? String ?? "PingFang SC"
        let fontEN = patch["fontEN"] as? String ?? current["fontEN"] as? String ?? "-apple-system"
        guard allowedFontsCN.contains(fontCN), allowedFontsEN.contains(fontEN) else {
            throw NotePreferencesError.invalidFont
        }
        let textColor = patch["textColor"] as? String ?? current["textColor"] as? String ?? "#454239"
        let textColorScope = patch["textColorScope"] as? String ?? current["textColorScope"] as? String ?? "task"
        guard Self.isValidHexColor(textColor), ["task", "major"].contains(textColorScope) else {
            throw NotePreferencesError.invalidTextStyle
        }
        let textBold = patch["textBold"] as? Bool ?? current["textBold"] as? Bool ?? false
        let textItalic = patch["textItalic"] as? Bool ?? current["textItalic"] as? Bool ?? false
        let selectedDate = patch["selectedDate"] as? String ?? current["selectedDate"] as? String
        if patch["selectedDate"] != nil, selectedDate.map(Self.isValidDateKey) != true {
            throw NotePreferencesError.invalidSelectedDate
        }

        let existing = loadStored(accountKey: accountKey, bindingID: bindingID)
        let fixedTasks: [FixedTaskPreference]
        if let values = patch["fixedTasks"] as? [[String: Any]] {
            fixedTasks = try Self.decodeFixedTasks(values)
        } else {
            fixedTasks = existing?.fixedTasks ?? []
        }
        let retainedIDs = Set(fixedTasks.map(\.id))
        var occurrences = existing?.fixedTaskOccurrences ?? [:]
        occurrences = occurrences.filter { retainedIDs.contains($0.value.templateID) }

        let directory = accountDirectory(accountKey: accountKey)
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        var backgroundFilename = loadStored(accountKey: accountKey, bindingID: bindingID)?.backgroundFilename
        if let imageDataValue = patch["backgroundImageData"] as? String {
            let (mimeType, encodedData) = try parseImageData(imageDataValue)
            guard encodedData.count <= maximumImageBytes else { throw NotePreferencesError.imageTooLarge }
            let filename = "\(bindingID).\(mimeType == "image/jpeg" ? "jpg" : mimeType == "image/png" ? "png" : "webp")"
            try encodedData.write(to: assetURL(accountKey: accountKey, filename: filename), options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600],
                                          ofItemAtPath: assetURL(accountKey: accountKey, filename: filename).path)
            if let previousFilename = backgroundFilename, previousFilename != filename {
                try? fileManager.removeItem(at: assetURL(accountKey: accountKey, filename: previousFilename))
            }
            backgroundFilename = filename
        } else if patch["removeBackground"] as? Bool == true {
            if let backgroundFilename { try? fileManager.removeItem(at: assetURL(accountKey: accountKey, filename: backgroundFilename)) }
            backgroundFilename = nil
        }

        let stored = StoredNotePreferences(opacity: opacity,
                                           fontCN: fontCN,
                                           fontEN: fontEN,
                                           textColor: textColor,
                                           textColorScope: textColorScope,
                                           textBold: textBold,
                                           textItalic: textItalic,
                                           backgroundFilename: backgroundFilename,
                                           selectedDate: selectedDate,
                                           fixedTasks: fixedTasks,
                                           fixedTaskOccurrences: occurrences)
        let data = try JSONEncoder().encode(stored)
        try data.write(to: preferencesURL(accountKey: accountKey, bindingID: bindingID), options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600],
                                      ofItemAtPath: preferencesURL(accountKey: accountKey, bindingID: bindingID).path)
        current = load(accountKey: accountKey, bindingID: bindingID)
        return current
    }

    func pendingFixedTaskOccurrences(accountKey: String,
                                     bindingID: String,
                                     dateKey: String) throws -> [PendingFixedTaskOccurrence] {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard Self.isValidDateKey(dateKey) else { throw NotePreferencesError.invalidSelectedDate }
        guard var stored = loadStored(accountKey: accountKey, bindingID: bindingID) else { return [] }
        let calendar = Calendar.current
        let today = Self.date(from: dateKey, calendar: calendar) ?? calendar.startOfDay(for: Date())
        let cutoff = calendar.date(byAdding: .day, value: -60, to: today) ?? today
        stored.fixedTaskOccurrences = stored.fixedTaskOccurrences.filter { _, occurrence in
            guard let occurrenceDate = Self.date(from: occurrence.dateKey, calendar: calendar) else { return false }
            return occurrenceDate >= cutoff
        }

        var pending: [PendingFixedTaskOccurrence] = []
        for template in stored.fixedTasks {
            let occurrenceID = "\(template.id)|\(dateKey)"
            var occurrence = stored.fixedTaskOccurrences[occurrenceID]
            if occurrence == nil {
                occurrence = FixedTaskOccurrence(id: occurrenceID,
                                                 templateID: template.id,
                                                 dateKey: dateKey,
                                                 clientToken: UUID().uuidString,
                                                 recordID: nil)
                stored.fixedTaskOccurrences[occurrenceID] = occurrence
            }
            if let occurrence, occurrence.recordID == nil {
                pending.append(PendingFixedTaskOccurrence(template: template, occurrence: occurrence))
            }
        }
        try persist(stored, accountKey: accountKey, bindingID: bindingID)
        return pending
    }

    func fixedTaskOccurrenceRecordID(accountKey: String,
                                     bindingID: String,
                                     templateID: String,
                                     dateKey: String) -> String? {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard Self.isValidDateKey(dateKey),
              let stored = loadStored(accountKey: accountKey, bindingID: bindingID) else { return nil }
        return stored.fixedTaskOccurrences["\(templateID)|\(dateKey)"]?.recordID
    }

    func markFixedTaskOccurrenceCreated(accountKey: String,
                                        bindingID: String,
                                        occurrenceID: String,
                                        recordID: String) throws {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard var stored = loadStored(accountKey: accountKey, bindingID: bindingID),
              var occurrence = stored.fixedTaskOccurrences[occurrenceID] else { return }
        occurrence.recordID = recordID
        stored.fixedTaskOccurrences[occurrenceID] = occurrence
        try persist(stored, accountKey: accountKey, bindingID: bindingID)
    }

    func delete(accountKey: String, bindingID: String) throws {
        accessLock.lock()
        defer { accessLock.unlock() }
        let jsonURL = preferencesURL(accountKey: accountKey, bindingID: bindingID)
        if fileManager.fileExists(atPath: jsonURL.path) {
            try fileManager.removeItem(at: jsonURL)
        }
        for ext in ["jpg", "png", "webp"] {
            let imageURL = assetURL(accountKey: accountKey, filename: "\(bindingID).\(ext)")
            if fileManager.fileExists(atPath: imageURL.path) { try fileManager.removeItem(at: imageURL) }
        }
    }

    private func parseImageData(_ value: String) throws -> (String, Data) {
        let parts = value.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let header = parts.first,
              let mimeType = ["image/png", "image/jpeg", "image/webp"].first(where: { header.hasPrefix("data:\($0);base64") }),
              let data = Data(base64Encoded: parts[1]) else {
            throw NotePreferencesError.invalidImage
        }
        return (mimeType, data)
    }

    private func loadStored(accountKey: String, bindingID: String) -> StoredNotePreferences? {
        guard let data = try? Data(contentsOf: preferencesURL(accountKey: accountKey, bindingID: bindingID)) else { return nil }
        return try? JSONDecoder().decode(StoredNotePreferences.self, from: data)
    }

    private func persist(_ stored: StoredNotePreferences, accountKey: String, bindingID: String) throws {
        let directory = accountDirectory(accountKey: accountKey)
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(stored)
        try data.write(to: preferencesURL(accountKey: accountKey, bindingID: bindingID), options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600],
                                      ofItemAtPath: preferencesURL(accountKey: accountKey, bindingID: bindingID).path)
    }

    private static func decodeFixedTasks(_ values: [[String: Any]]) throws -> [FixedTaskPreference] {
        var seen = Set<String>()
        return try values.map { value in
            guard let id = value["id"] as? String, !id.isEmpty, seen.insert(id).inserted,
                  let title = value["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.count <= 500,
                  let priorityOptionID = value["priorityOptionID"] as? String, !priorityOptionID.isEmpty,
                  let priorityName = value["priorityName"] as? String, !priorityName.isEmpty else {
                throw NotePreferencesError.invalidFixedTask
            }
            let planned = (value["plannedDurationHours"] as? NSNumber)?.doubleValue
            if let planned,
               (!planned.isFinite || planned < 0.5 || (planned * 2).rounded() != planned * 2) {
                throw NotePreferencesError.invalidFixedTask
            }
            return FixedTaskPreference(id: id,
                                       title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                       priorityOptionID: priorityOptionID,
                                       priorityName: priorityName,
                                       plannedDurationHours: planned)
        }
    }

    private static func date(from key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func isValidDateKey(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    private static func isValidHexColor(_ value: String) -> Bool {
        value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
    }

    private func accountDirectory(accountKey: String) -> URL {
        rootDirectory.appendingPathComponent(accountKey, isDirectory: true)
    }

    private func preferencesURL(accountKey: String, bindingID: String) -> URL {
        accountDirectory(accountKey: accountKey).appendingPathComponent("\(bindingID).json", isDirectory: false)
    }

    private func assetURL(accountKey: String, filename: String) -> URL {
        accountDirectory(accountKey: accountKey).appendingPathComponent(filename, isDirectory: false)
    }
}

private struct StoredNotePreferences: Codable {
    let opacity: Int
    let fontCN: String
    let fontEN: String
    let textColor: String
    let textColorScope: String
    let textBold: Bool
    let textItalic: Bool
    let backgroundFilename: String?
    let selectedDate: String?
    var fixedTasks: [FixedTaskPreference]
    var fixedTaskOccurrences: [String: FixedTaskOccurrence]

    private enum CodingKeys: String, CodingKey {
        case opacity, fontCN, fontEN, textColor, textColorScope, textBold, textItalic, backgroundFilename, selectedDate, fixedTasks, fixedTaskOccurrences
    }

    init(opacity: Int,
         fontCN: String,
         fontEN: String,
         textColor: String = "#454239",
         textColorScope: String = "task",
         textBold: Bool = false,
         textItalic: Bool = false,
         backgroundFilename: String?,
         selectedDate: String?,
         fixedTasks: [FixedTaskPreference] = [],
         fixedTaskOccurrences: [String: FixedTaskOccurrence] = [:]) {
        self.opacity = opacity
        self.fontCN = fontCN
        self.fontEN = fontEN
        self.textColor = textColor
        self.textColorScope = textColorScope
        self.textBold = textBold
        self.textItalic = textItalic
        self.backgroundFilename = backgroundFilename
        self.selectedDate = selectedDate
        self.fixedTasks = fixedTasks
        self.fixedTaskOccurrences = fixedTaskOccurrences
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        opacity = try values.decode(Int.self, forKey: .opacity)
        fontCN = try values.decode(String.self, forKey: .fontCN)
        fontEN = try values.decode(String.self, forKey: .fontEN)
        textColor = try values.decodeIfPresent(String.self, forKey: .textColor) ?? "#454239"
        textColorScope = try values.decodeIfPresent(String.self, forKey: .textColorScope) ?? "task"
        textBold = try values.decodeIfPresent(Bool.self, forKey: .textBold) ?? false
        textItalic = try values.decodeIfPresent(Bool.self, forKey: .textItalic) ?? false
        backgroundFilename = try values.decodeIfPresent(String.self, forKey: .backgroundFilename)
        selectedDate = try values.decodeIfPresent(String.self, forKey: .selectedDate)
        fixedTasks = try values.decodeIfPresent([FixedTaskPreference].self, forKey: .fixedTasks) ?? []
        fixedTaskOccurrences = try values.decodeIfPresent([String: FixedTaskOccurrence].self, forKey: .fixedTaskOccurrences) ?? [:]
    }
}

enum NotePreferencesError: LocalizedError {
    case invalidOpacity
    case invalidFont
    case invalidTextStyle
    case imageTooLarge
    case invalidImage
    case invalidSelectedDate
    case invalidFixedTask

    var errorDescription: String? {
        switch self {
        case .invalidOpacity: "透明度需要在 35% 到 100% 之间。"
        case .invalidFont: "请选择 Todo 支持的字体。"
        case .invalidTextStyle: "文字颜色或样式设置无效。"
        case .imageTooLarge: "背景图片不能超过 5 MB。"
        case .invalidImage: "背景图片格式无效，请选择 PNG、JPEG 或 WebP 图片。"
        case .invalidSelectedDate: "待办日期格式无效。"
        case .invalidFixedTask: "固定待办内容、优先级或计划时长无效。"
        }
    }
}
