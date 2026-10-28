import Foundation

struct BitableBindingService {
    private let parser: ViewLinkParser
    private let client: FeishuBitableClient
    private let workspaceRepository: WorkspaceRepository
    private let snapshotRepository: SnapshotRepository

    init(parser: ViewLinkParser = ViewLinkParser(),
         client: FeishuBitableClient = FeishuBitableClient(),
         workspaceRepository: WorkspaceRepository = WorkspaceRepository(),
         snapshotRepository: SnapshotRepository = SnapshotRepository()) {
        self.parser = parser
        self.client = client
        self.workspaceRepository = workspaceRepository
        self.snapshotRepository = snapshotRepository
    }

    func inspect(viewURL: String, accessToken: String) async throws -> BindingInspection {
        let link = try parser.parse(viewURL)
        async let view = client.getView(appToken: link.resourceToken,
                                        tableID: link.tableID,
                                        viewID: link.viewID,
                                        accessToken: accessToken)
        async let fields = client.listFields(appToken: link.resourceToken,
                                             tableID: link.tableID,
                                             accessToken: accessToken)
        let resolvedView = try await view
        let resolvedFields = try await fields
        return BindingInspection(link: link, view: resolvedView, fields: resolvedFields)
    }

    @MainActor
    func createBinding(inspection: BindingInspection,
                       fieldMapping: FieldMapping,
                       identity: FeishuIdentity,
                       accessToken: String) async throws -> (ViewBinding, ViewSnapshot) {
        let mapping = try validate(fieldMapping, fields: inspection.fields)
        let records = try await client.listRecords(appToken: inspection.link.resourceToken,
                                                   tableID: inspection.link.tableID,
                                                   viewID: inspection.link.viewID,
                                                   accessToken: accessToken)
        let snapshot = try project(records: records, mapping: mapping)
        var workspace = try workspaceRepository.load(for: identity)
        guard !workspace.bindings.contains(where: {
            !$0.isDeleted && $0.resourceToken == inspection.link.resourceToken
                && $0.tableID == inspection.link.tableID && $0.viewID == inspection.link.viewID
        }) else {
            throw FeishuBitableError.duplicateBinding
        }

        let binding = ViewBinding(link: inspection.link,
                                  identity: identity,
                                  fieldMapping: mapping,
                                  viewName: inspection.view.name)
        try snapshotRepository.save(snapshot, identity: identity, bindingID: binding.id)
        workspace.bindings.append(binding)
        do {
            try workspaceRepository.save(workspace)
        } catch {
            try? snapshotRepository.delete(identity: identity, bindingID: binding.id)
            throw error
        }
        return (binding, snapshot)
    }

    func refresh(binding: ViewBinding,
                 identity: FeishuIdentity,
                 accessToken: String) async throws -> ViewSnapshot {
        guard let mapping = binding.fieldMapping else {
            throw FeishuBitableError.invalidResponse("该便签尚未完成字段绑定，请重新绑定视图。")
        }
        let resolvedMapping = try await mappingWithFieldNames(mapping,
                                                              binding: binding,
                                                              identity: identity,
                                                              accessToken: accessToken)
        let records = try await client.listRecords(appToken: binding.resourceToken,
                                                   tableID: binding.tableID,
                                                   viewID: binding.viewID,
                                                   accessToken: accessToken)
        let snapshot = try project(records: records, mapping: resolvedMapping)
        // 所有记录分页成功后才替换旧快照。
        try snapshotRepository.save(snapshot, identity: identity, bindingID: binding.id)
        return snapshot
    }

    func taskCreationOptions(binding: ViewBinding,
                             accessToken: String) async throws -> (options: [BitableOption], plannedDurationAvailable: Bool) {
        guard let mapping = binding.fieldMapping,
              let priorityFieldID = mapping.priorityFieldID else {
            throw FeishuBitableError.missingField("优先级")
        }
        let fields = try await client.listFields(appToken: binding.resourceToken,
                                                 tableID: binding.tableID,
                                                 accessToken: accessToken)
        guard let priorityField = fields.first(where: { $0.id == priorityFieldID }),
              let options = priorityField.property?.options,
              !options.isEmpty else {
            throw FeishuBitableError.incompatibleField("优先级字段没有可选择的选项。")
        }
        let validMapping = try validate(mapping, fields: fields)
        return (options, validMapping.plannedDurationFieldID != nil)
    }

    func createTask(binding: ViewBinding,
                    identity: FeishuIdentity,
                    title: String,
                    priorityOptionID: String,
                    dateMilliseconds: Int64,
                    plannedDurationHours: Double?,
                    clientToken: String,
                    accessToken: String) async throws -> TaskCreationResult {
        let taskTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskTitle.isEmpty else {
            throw FeishuBitableError.invalidResponse("请输入待办内容。")
        }
        guard let mapping = binding.fieldMapping,
              let priorityFieldID = mapping.priorityFieldID else {
            throw FeishuBitableError.missingField("优先级")
        }
        let fields = try await client.listFields(appToken: binding.resourceToken,
                                                 tableID: binding.tableID,
                                                 accessToken: accessToken)
        let resolvedMapping = try validate(mapping, fields: fields)
        guard let priorityOption = fields.first(where: { $0.id == priorityFieldID })?
            .property?.options?.first(where: { $0.id == priorityOptionID }) else {
            throw FeishuBitableError.incompatibleField("所选优先级已不存在，请重新选择。")
        }
        guard let taskFieldName = resolvedMapping.taskFieldName,
              let dateFieldName = resolvedMapping.dateFieldName,
              let priorityFieldName = resolvedMapping.priorityFieldName,
              let doneFieldName = resolvedMapping.doneFieldName else {
            throw FeishuBitableError.incompatibleField("绑定字段信息不完整，请重新绑定视图。")
        }

        var recordFields: [String: BitableValue] = [
            taskFieldName: .string(taskTitle),
            dateFieldName: .integer(dateMilliseconds),
            priorityFieldName: .string(priorityOption.name),
            doneFieldName: .string(resolvedMapping.undoneOptionName)
        ]
        if let plannedDurationHours,
           let plannedFieldName = resolvedMapping.plannedDurationFieldName {
            recordFields[plannedFieldName] = .number(plannedDurationHours)
        }
        let record = try await client.createRecord(appToken: binding.resourceToken,
                                                   tableID: binding.tableID,
                                                   fields: recordFields,
                                                   clientToken: clientToken,
                                                   accessToken: accessToken)

        do {
            let snapshot = try await refresh(binding: binding,
                                             identity: identity,
                                             accessToken: accessToken)
            let visible = snapshot.items.contains(where: { $0.id == record.id })
            return TaskCreationResult(recordID: record.id,
                                      snapshot: snapshot,
                                      isStale: false,
                                      visibleInView: visible,
                                      warning: visible ? nil : "条目已添加，但当前视图没有显示它。请检查飞书视图筛选。")
        } catch {
            return TaskCreationResult(recordID: record.id,
                                      snapshot: snapshotRepository.load(identity: identity, bindingID: binding.id),
                                      isStale: true,
                                      visibleInView: false,
                                      warning: "条目已添加，但暂时无法刷新当前视图。请稍后刷新，并检查飞书视图筛选。\(error.localizedDescription)")
        }
    }

    func updateTask(binding: ViewBinding,
                    identity: FeishuIdentity,
                    recordID: String,
                    field: String,
                    value: BitableValue,
                    accessToken: String) async throws -> TaskMutationResult {
        guard let mapping = binding.fieldMapping,
              let existingItem = snapshotRepository.load(identity: identity, bindingID: binding.id)?.items.first(where: { $0.id == recordID }) else {
            throw FeishuBitableError.invalidResponse("该便签尚未完成字段绑定，请重新绑定视图。")
        }
        let fields = try await client.listFields(appToken: binding.resourceToken,
                                                 tableID: binding.tableID,
                                                 accessToken: accessToken)
        let resolvedMapping = try validate(mapping, fields: fields)
        let fieldName: String
        let fieldValue: BitableValue
        var title = existingItem.title
        var priority = existingItem.priority
        var duration = existingItem.plannedDurationHours
        switch (field, value) {
        case ("title", .string(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let name = resolvedMapping.taskFieldName else {
                throw FeishuBitableError.invalidResponse("请输入待办内容。")
            }
            title = trimmed
            fieldName = name
            fieldValue = .string(trimmed)
        case ("priority", .string(let optionID)):
            guard let id = resolvedMapping.priorityFieldID,
                  let name = resolvedMapping.priorityFieldName,
                  let option = fields.first(where: { $0.id == id })?.property?.options?.first(where: { $0.id == optionID }) else {
                throw FeishuBitableError.incompatibleField("所选优先级已不存在，请重新选择。")
            }
            priority = option.name
            fieldName = name
            fieldValue = .string(option.name)
        case ("duration", .number(let hours)) where hours.isFinite && hours >= 0.5 && (hours * 2).rounded() == hours * 2:
            guard let name = resolvedMapping.plannedDurationFieldName else {
                throw FeishuBitableError.missingField("计划时长")
            }
            duration = hours
            fieldName = name
            fieldValue = .number(hours)
        case ("duration", .null):
            guard let name = resolvedMapping.plannedDurationFieldName else {
                throw FeishuBitableError.missingField("计划时长")
            }
            duration = nil
            fieldName = name
            fieldValue = .null
        default:
            throw FeishuBitableError.invalidResponse("任务字段或输入值无效。")
        }

        do {
            _ = try await client.updateRecord(appToken: binding.resourceToken,
                                              tableID: binding.tableID,
                                              recordID: recordID,
                                              fields: [fieldName: fieldValue],
                                              accessToken: accessToken)
        } catch {
            let updateError = error
            let actual: BitableRecord
            do {
                actual = try await client.getRecord(appToken: binding.resourceToken,
                                                    tableID: binding.tableID,
                                                    recordID: recordID,
                                                    accessToken: accessToken)
            } catch {
                throw FeishuBitableError.mutationOutcomeUnknown(
                    "修改结果暂时无法确认。请刷新视图后检查该任务，不要重复提交。\n\(updateError.localizedDescription)\n核对失败：\(error.localizedDescription)"
                )
            }
            let matches: Bool
            switch fieldValue {
            case .string(let expected): matches = actual.fields[fieldName]?.text == expected
            case .number(let expected): matches = actual.fields[fieldName]?.numericValue == expected
            case .null:
                if let actualValue = actual.fields[fieldName] {
                    if case .null = actualValue { matches = true } else { matches = false }
                } else { matches = true }
            default: matches = false
            }
            guard matches else {
                throw FeishuBitableError.mutationRejected("飞书中的任务内容未确认更新。\(updateError.localizedDescription)")
            }
        }

        do {
            let snapshot = try await refresh(binding: binding, identity: identity, accessToken: accessToken)
            let visible = snapshot.items.contains(where: { $0.id == recordID })
            return TaskMutationResult(snapshot: snapshot, isStale: false, visibleInView: visible,
                                      warning: visible ? nil : "任务已修改，但当前视图没有显示它。请检查飞书视图筛选。")
        } catch {
            let local = try snapshotRepository.saveTask(identity: identity,
                                                        bindingID: binding.id,
                                                        recordID: recordID,
                                                        title: title,
                                                        priority: priority,
                                                        plannedDurationHours: duration)
            guard let local else {
                throw FeishuBitableError.mutationOutcomeUnknown("任务已写回飞书，但本机无法更新快照。请刷新视图。\(error.localizedDescription)")
            }
            return TaskMutationResult(snapshot: local, isStale: true, visibleInView: false,
                                      warning: "任务已写回飞书，但视图暂时无法刷新。\(error.localizedDescription)")
        }
    }

    func deleteTask(binding: ViewBinding,
                    identity: FeishuIdentity,
                    recordID: String,
                    accessToken: String) async throws -> TaskMutationResult {
        guard snapshotRepository.load(identity: identity, bindingID: binding.id)?.items.contains(where: { $0.id == recordID }) == true else {
            throw FeishuBitableError.invalidResponse("找不到这条任务的本机视图记录，请先刷新便签。")
        }
        do {
            try await client.deleteRecord(appToken: binding.resourceToken,
                                          tableID: binding.tableID,
                                          recordID: recordID,
                                          accessToken: accessToken)
        } catch {
            let deleteError = error
            do {
                _ = try await client.getRecord(appToken: binding.resourceToken,
                                                tableID: binding.tableID,
                                                recordID: recordID,
                                                accessToken: accessToken)
                throw FeishuBitableError.mutationRejected("删除失败，飞书记录仍然存在。\(deleteError.localizedDescription)")
            } catch let verificationError as FeishuBitableError {
                if isRecordNotFound(verificationError) {
                    // DELETE may have succeeded even if its response was lost.
                } else if case .mutationRejected = verificationError {
                    throw verificationError
                } else {
                    throw FeishuBitableError.mutationOutcomeUnknown(
                        "删除结果暂时无法确认。请刷新视图检查该任务，不要重复删除。\n\(deleteError.localizedDescription)\n核对失败：\(verificationError.localizedDescription)"
                    )
                }
            } catch {
                throw FeishuBitableError.mutationOutcomeUnknown(
                    "删除结果暂时无法确认。请刷新视图检查该任务，不要重复删除。\n\(deleteError.localizedDescription)\n核对失败：\(error.localizedDescription)"
                )
            }
        }
        do {
            let snapshot = try await refresh(binding: binding, identity: identity, accessToken: accessToken)
            return TaskMutationResult(snapshot: snapshot,
                                      isStale: false,
                                      visibleInView: !snapshot.items.contains(where: { $0.id == recordID }),
                                      warning: nil)
        } catch {
            guard let local = try snapshotRepository.deleteTask(identity: identity,
                                                                bindingID: binding.id,
                                                                recordID: recordID) else {
                throw FeishuBitableError.mutationOutcomeUnknown("任务已从飞书删除，但本机无法更新快照。请刷新视图。\(error.localizedDescription)")
            }
            return TaskMutationResult(snapshot: local,
                                      isStale: true,
                                      visibleInView: false,
                                      warning: "任务已从飞书删除，但视图暂时无法刷新。\(error.localizedDescription)")
        }
    }

    func createFixedTaskOccurrences(binding: ViewBinding,
                                    occurrences: [PendingFixedTaskOccurrence],
                                    dateMilliseconds: Int64,
                                    accessToken: String,
                                    onCreated: (String, String) throws -> Void) async throws -> [String] {
        guard !occurrences.isEmpty else { return [] }
        guard let mapping = binding.fieldMapping,
              let priorityFieldID = mapping.priorityFieldID else {
            throw FeishuBitableError.missingField("优先级")
        }
        let fields = try await client.listFields(appToken: binding.resourceToken,
                                                 tableID: binding.tableID,
                                                 accessToken: accessToken)
        let resolvedMapping = try validate(mapping, fields: fields)
        guard let taskFieldName = resolvedMapping.taskFieldName,
              let dateFieldName = resolvedMapping.dateFieldName,
              let priorityFieldName = resolvedMapping.priorityFieldName,
              let doneFieldName = resolvedMapping.doneFieldName,
              let priorityField = fields.first(where: { $0.id == priorityFieldID }),
              let priorityOptions = priorityField.property?.options else {
            throw FeishuBitableError.incompatibleField("固定待办所需的字段映射或优先级选项不可用。")
        }

        var createdRecordIDs: [String] = []
        for pending in occurrences {
            let template = pending.template
            let title = template.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  let option = priorityOptions.first(where: { $0.id == template.priorityOptionID }) else {
                throw FeishuBitableError.incompatibleField("固定待办“\(template.title)”的优先级选项已失效，请在个性化中重新设置。")
            }
            var recordFields: [String: BitableValue] = [
                taskFieldName: .string(title),
                dateFieldName: .integer(dateMilliseconds),
                priorityFieldName: .string(option.name),
                doneFieldName: .string(resolvedMapping.undoneOptionName)
            ]
            if let duration = template.plannedDurationHours,
               let plannedFieldName = resolvedMapping.plannedDurationFieldName {
                recordFields[plannedFieldName] = .number(duration)
            }
            let record = try await client.createRecord(appToken: binding.resourceToken,
                                                       tableID: binding.tableID,
                                                       fields: recordFields,
                                                       clientToken: pending.occurrence.clientToken,
                                                       accessToken: accessToken)
            try onCreated(pending.occurrence.id, record.id)
            createdRecordIDs.append(record.id)
        }
        return createdRecordIDs
    }

    func moveTaskToToday(binding: ViewBinding,
                         identity: FeishuIdentity,
                         recordID: String,
                         accessToken: String) async throws -> TaskMoveResult {
        guard let mapping = binding.fieldMapping,
              let snapshot = snapshotRepository.load(identity: identity, bindingID: binding.id),
              let item = snapshot.items.first(where: { $0.id == recordID }) else {
            throw FeishuBitableError.invalidResponse("找不到这条任务的本机视图记录，请先刷新便签。")
        }
        let resolvedMapping = try await mappingWithFieldNames(mapping,
                                                              binding: binding,
                                                              identity: identity,
                                                              accessToken: accessToken)
        guard let dateFieldName = resolvedMapping.dateFieldName else {
            throw FeishuBitableError.missingField("日期")
        }
        guard !item.isDone else {
            throw FeishuBitableError.invalidResponse("已完成任务不能迁移到今天。")
        }
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
        let itemDay = calendar.startOfDay(for: Date(timeIntervalSince1970: item.dateMilliseconds / 1000))
        guard itemDay == yesterday else {
            throw FeishuBitableError.invalidResponse("只能迁移昨天的未完成任务。")
        }
        let todayStart = calendar.startOfDay(for: Date())
        let todayMilliseconds = Int64((todayStart.timeIntervalSince1970 * 1000).rounded())

        var updateError: Error?
        do {
            let updated = try await client.updateRecord(appToken: binding.resourceToken,
                                                        tableID: binding.tableID,
                                                        recordID: recordID,
                                                        fields: [dateFieldName: .integer(todayMilliseconds)],
                                                        accessToken: accessToken)
            guard let actualDate = updated.fields[dateFieldName]?.timestampMilliseconds,
                  calendar.isDate(Date(timeIntervalSince1970: actualDate / 1000), inSameDayAs: todayStart) else {
                throw FeishuBitableError.invalidResponse("飞书更新响应未确认日期已变更。")
            }
        } catch {
            updateError = error
        }

        if let updateError {
            let actual: BitableRecord
            do {
                actual = try await client.getRecord(appToken: binding.resourceToken,
                                                    tableID: binding.tableID,
                                                    recordID: recordID,
                                                    accessToken: accessToken)
            } catch {
                throw FeishuBitableError.mutationOutcomeUnknown(
                    "迁移结果暂时无法确认。请刷新视图后检查该任务；不会自动重复修改。\n\(updateError.localizedDescription)\n核对失败：\(error.localizedDescription)"
                )
            }
            guard let actualDate = actual.fields[dateFieldName]?.timestampMilliseconds,
                  calendar.isDate(Date(timeIntervalSince1970: actualDate / 1000), inSameDayAs: todayStart) else {
                throw FeishuBitableError.mutationRejected("飞书中的日期仍未变更。\(updateError.localizedDescription)")
            }
        }

        do {
            let refreshed = try await refresh(binding: binding, identity: identity, accessToken: accessToken)
            return TaskMoveResult(snapshot: refreshed,
                                  isStale: false,
                                  visibleInView: refreshed.items.contains(where: { $0.id == recordID }),
                                  warning: refreshed.items.contains(where: { $0.id == recordID })
                                    ? nil
                                    : "任务日期已改为今天，但当前视图筛选后未显示它。请检查飞书视图筛选。")
        } catch {
            let local = try snapshotRepository.saveDate(identity: identity,
                                                        bindingID: binding.id,
                                                        recordID: recordID,
                                                        dateMilliseconds: Double(todayMilliseconds)) ?? snapshot
            return TaskMoveResult(snapshot: local,
                                  isStale: true,
                                  visibleInView: false,
                                  warning: "任务日期已写回飞书，但视图暂时无法刷新。请稍后刷新检查。\(error.localizedDescription)")
        }
    }

    func setCompletion(binding: ViewBinding,
                       identity: FeishuIdentity,
                       recordID: String,
                       isDone: Bool,
                       accessToken: String) async throws -> CompletionMutationResult {
        guard let mapping = binding.fieldMapping else {
            throw FeishuBitableError.invalidResponse("该便签尚未完成字段绑定，请重新绑定视图。")
        }
        guard let snapshot = snapshotRepository.load(identity: identity, bindingID: binding.id),
              let itemIndex = snapshot.items.firstIndex(where: { $0.id == recordID }) else {
            throw FeishuBitableError.invalidResponse("找不到这条任务的本机视图记录，请先刷新便签。")
        }

        let validatedMapping = try await mappingWithFieldNames(mapping,
                                                               binding: binding,
                                                               identity: identity,
                                                               accessToken: accessToken)
        guard let doneFieldName = validatedMapping.doneFieldName else {
            throw FeishuBitableError.missingField("完成情况")
        }
        let optionName = isDone ? validatedMapping.doneOptionName : validatedMapping.undoneOptionName
        guard snapshot.items[itemIndex].isDone != isDone else {
            return CompletionMutationResult(snapshot: snapshot, isStale: false, warning: nil)
        }

        var updateError: Error?
        do {
            let updated = try await client.updateRecord(appToken: binding.resourceToken,
                                                        tableID: binding.tableID,
                                                        recordID: recordID,
                                                        fields: [doneFieldName: .string(optionName)],
                                                        accessToken: accessToken)
            if updated.fields[doneFieldName]?.text != optionName {
                updateError = FeishuBitableError.invalidResponse("飞书更新响应未确认完成状态。")
            }
        } catch {
            updateError = error
        }

        if let updateError {
            let actual: BitableRecord
            do {
                actual = try await client.getRecord(appToken: binding.resourceToken,
                                                    tableID: binding.tableID,
                                                    recordID: recordID,
                                                    accessToken: accessToken)
            } catch {
                throw FeishuBitableError.mutationOutcomeUnknown(
                    "写回结果暂时无法确认。请刷新视图后再检查该任务；不会自动重复写入。\n\(updateError.localizedDescription)\n核对失败：\(error.localizedDescription)"
                )
            }
            guard actual.fields[doneFieldName]?.text == optionName else {
                let current = actual.fields[doneFieldName]?.text ?? "空值"
                throw FeishuBitableError.mutationRejected(
                    "飞书中的状态仍为“\(current)”，本次没有确认写入。\(updateError.localizedDescription)"
                )
            }
        }

        do {
            guard let mergedSnapshot = try snapshotRepository.saveCompletion(identity: identity,
                                                                              bindingID: binding.id,
                                                                              recordID: recordID,
                                                                              isDone: isDone) else {
                throw FeishuBitableError.invalidResponse("本机任务快照已不可用。")
            }
            return CompletionMutationResult(snapshot: mergedSnapshot, isStale: false, warning: nil)
        } catch {
            let item = snapshot.items[itemIndex]
            let confirmedSnapshot = ViewSnapshot(fetchedAt: Date(),
                                                 items: snapshot.items.enumerated().map { index, current in
                                                     guard index == itemIndex else { return current }
                                                     return ProjectedTodo(id: item.id,
                                                                          title: item.title,
                                                                          priority: item.priority,
                                                                          isDone: isDone,
                                                                          dateMilliseconds: item.dateMilliseconds,
                                                                          sourceOrder: item.sourceOrder,
                                                                          plannedDurationHours: item.plannedDurationHours)
                                                 },
                                                 projectionIssues: snapshot.projectionIssues)
            return CompletionMutationResult(snapshot: confirmedSnapshot,
                                            isStale: true,
                                            warning: "飞书已确认更新，但本机快照保存失败；当前显示本地更新状态。\(error.localizedDescription)")
        }
    }

    func bindings(for identity: FeishuIdentity, retryDeletedSnapshotCleanup: Bool = true) throws -> [ViewBinding] {
        var workspace = try workspaceRepository.load(for: identity)
        if retryDeletedSnapshotCleanup {
            let tombstones = workspace.bindings.filter(\.isDeleted)
            var removedTombstone = false
            for binding in tombstones {
                do {
                    try snapshotRepository.delete(identity: identity, bindingID: binding.id)
                    workspace.bindings.removeAll { $0.id == binding.id }
                    removedTombstone = true
                } catch {
                    // Keep the tombstone so a later notebook load can retry this cache cleanup.
                }
            }
            if removedTombstone { try workspaceRepository.save(workspace) }
        }
        return workspace.bindings.filter { !$0.isDeleted }
    }

    func deleteBinding(id bindingID: String, identity: FeishuIdentity) throws -> String? {
        var workspace = try workspaceRepository.load(for: identity)
        guard let index = workspace.bindings.firstIndex(where: { $0.id == bindingID && !$0.isDeleted }) else {
            throw NotebookLifecycleError.bindingNotFound
        }
        let cachedSnapshot = snapshotRepository.load(identity: identity, bindingID: bindingID)
        do {
            try snapshotRepository.delete(identity: identity, bindingID: bindingID)
        } catch {
            workspace.bindings[index].isDeleted = true
            try workspaceRepository.save(workspace)
            return "便签已从便签夹移除，但本机缓存清理失败；Todo 会在下次读取便签夹时重试。\(error.localizedDescription)"
        }

        workspace.bindings.remove(at: index)
        do {
            try workspaceRepository.save(workspace)
            return nil
        } catch {
            if let cachedSnapshot {
                try? snapshotRepository.save(cachedSnapshot, identity: identity, bindingID: bindingID)
            }
            throw error
        }
    }

    func snapshot(identity: FeishuIdentity, bindingID: String) -> ViewSnapshot? {
        snapshotRepository.load(identity: identity, bindingID: bindingID)
    }

    private func validate(_ mapping: FieldMapping, fields: [BitableField]) throws -> FieldMapping {
        guard let task = fields.first(where: { $0.id == mapping.taskFieldID }) else {
            throw FeishuBitableError.missingField("任务内容")
        }
        guard task.type == 1 else {
            throw FeishuBitableError.incompatibleField("任务内容字段“\(task.name)”必须是文本类型。")
        }
        guard let date = fields.first(where: { $0.id == mapping.dateFieldID }) else {
            throw FeishuBitableError.missingField("日期")
        }
        guard date.type == 5 else {
            throw FeishuBitableError.incompatibleField("日期字段“\(date.name)”必须是日期类型。")
        }
        guard let done = fields.first(where: { $0.id == mapping.doneFieldID }) else {
            throw FeishuBitableError.missingField("完成情况")
        }
        guard done.type == 3, let options = done.property?.options else {
            throw FeishuBitableError.incompatibleField("完成情况字段必须是单选字段。")
        }
        guard options.count == 2, Set(options.map(\.name)) == Set(["未完成", "已完成"]) else {
            throw FeishuBitableError.incompatibleField("完成情况字段只能包含“未完成”和“已完成”两个选项。")
        }
        guard let doneOption = options.first(where: { $0.id == mapping.doneOptionID }),
              let undoneOption = options.first(where: { $0.id == mapping.undoneOptionID }),
              doneOption.name == "已完成", undoneOption.name == "未完成" else {
            throw FeishuBitableError.incompatibleField("完成情况选项必须对应“未完成”和“已完成”。")
        }
        guard let priorityID = mapping.priorityFieldID,
              let priority = fields.first(where: { $0.id == priorityID }) else {
            throw FeishuBitableError.missingField("优先级")
        }
        guard priority.type == 3 else {
            throw FeishuBitableError.incompatibleField("优先级字段“\(priority.name)”必须是单选字段。")
        }
        guard Set([task.id, date.id, priority.id, done.id]).count == 4 else {
            throw FeishuBitableError.incompatibleField("任务内容、日期、优先级和完成情况需要分别使用不同字段。")
        }
        let matchingDurationFields = fields.filter { $0.name == "计划时长" && $0.type == 2 }
        let plannedDuration = matchingDurationFields.count == 1 ? matchingDurationFields.first : nil
        return FieldMapping(taskFieldID: task.id,
                           dateFieldID: date.id,
                           priorityFieldID: mapping.priorityFieldID,
                           doneFieldID: done.id,
                           doneOptionID: doneOption.id,
                           doneOptionName: doneOption.name,
                           undoneOptionID: undoneOption.id,
                           undoneOptionName: undoneOption.name,
                           taskFieldName: task.name,
                           dateFieldName: date.name,
                           priorityFieldName: priority.name,
                           doneFieldName: done.name,
                           plannedDurationFieldID: plannedDuration?.id,
                           plannedDurationFieldName: plannedDuration?.name,
                           plannedDurationFieldChecked: true)
    }

    private func mappingWithFieldNames(_ mapping: FieldMapping,
                                       binding: ViewBinding,
                                       identity: FeishuIdentity,
                                       accessToken: String) async throws -> FieldMapping {
        if mapping.taskFieldName != nil,
           mapping.dateFieldName != nil,
           mapping.doneFieldName != nil,
           mapping.priorityFieldName != nil,
           mapping.plannedDurationFieldChecked == true {
            return mapping
        }
        let fields = try await client.listFields(appToken: binding.resourceToken,
                                                 tableID: binding.tableID,
                                                 accessToken: accessToken)
        let resolved = try validate(mapping, fields: fields)
        var workspace = try workspaceRepository.load(for: identity)
        if let index = workspace.bindings.firstIndex(where: { $0.id == binding.id }) {
            workspace.bindings[index].fieldMapping = resolved
            try? workspaceRepository.save(workspace)
        }
        return resolved
    }

    private func project(records: [BitableRecord], mapping: FieldMapping) throws -> ViewSnapshot {
        guard let taskFieldName = mapping.taskFieldName,
              let dateFieldName = mapping.dateFieldName,
              let doneFieldName = mapping.doneFieldName else {
            throw FeishuBitableError.incompatibleField("绑定字段信息不完整，请重新绑定视图。")
        }
        var items: [ProjectedTodo] = []
        var projectionIssues: [ProjectionIssue] = []
        for (index, record) in records.enumerated() {
            let title = record.fields[taskFieldName]?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawTimestamp = record.fields[dateFieldName]?.timestampMilliseconds
            let timestamp = rawTimestamp.flatMap { $0.isFinite ? $0 : nil }
            let doneName = record.fields[doneFieldName]?.text
            let priority = mapping.priorityFieldName.flatMap { record.fields[$0]?.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            var reasons: [String] = []
            if title?.isEmpty != false { reasons.append("任务内容为空或无法读取") }
            if timestamp == nil { reasons.append("日期为空或格式无法识别") }
            if priority?.isEmpty != false { reasons.append("优先级为空或无法读取") }
            if doneName != mapping.doneOptionName && doneName != mapping.undoneOptionName {
                reasons.append("完成状态不是“未完成”或“已完成”")
            }
            guard reasons.isEmpty, let title, let timestamp else {
                projectionIssues.append(ProjectionIssue(recordID: record.id,
                                                        dateMilliseconds: timestamp,
                                                        reason: reasons.joined(separator: "；")))
                continue
            }
            let plannedDuration = mapping.plannedDurationFieldName.flatMap { record.fields[$0]?.numericValue }
            items.append(ProjectedTodo(id: record.id,
                                       title: title,
                                       priority: priority,
                                       isDone: doneName == mapping.doneOptionName,
                                       dateMilliseconds: timestamp,
                                       sourceOrder: index,
                                       plannedDurationHours: plannedDuration))
        }
        return ViewSnapshot(fetchedAt: Date(), items: items, projectionIssues: projectionIssues)
    }

    private func isRecordNotFound(_ error: FeishuBitableError) -> Bool {
        guard case let .requestFailed(_, code, _) = error else { return false }
        return code == 1254006 || code == 1254043
    }
}

private enum NotebookLifecycleError: LocalizedError {
    case bindingNotFound

    var errorDescription: String? {
        switch self {
        case .bindingNotFound:
            return "找不到这张便签的本机绑定。"
        }
    }
}
