import Foundation
import XCTest
@testable import TodoDesktop

@MainActor
final class BindingConcurrencyTests: XCTestCase {
    func testConcurrentBindingCreationPreservesDistinctViewsAndRejectsDuplicates() async throws {
        for sameView in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let repository = WorkspaceRepository(rootDirectory: root.appendingPathComponent("workspace"))
            let identity = FeishuIdentity(userID: "user", tenantID: "tenant")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BindingBarrierProtocol.self]
            let service = BitableBindingService(client: FeishuBitableClient(session: URLSession(configuration: configuration)),
                                                workspaceRepository: repository,
                                                snapshotRepository: SnapshotRepository(rootDirectory: root.appendingPathComponent("snapshots")))
            let mapping = FieldMapping(taskFieldID: "task", dateFieldID: "date", priorityFieldID: "priority",
                                       doneFieldID: "done", doneOptionID: "yes", doneOptionName: "已完成",
                                       undoneOptionID: "no", undoneOptionName: "未完成")
            let fields = [BitableField(id: "task", name: "任务内容", type: 1, property: nil),
                          BitableField(id: "date", name: "日期", type: 5, property: nil),
                          BitableField(id: "priority", name: "优先级", type: 3, property: nil),
                          BitableField(id: "done", name: "状态", type: 3, property: BitableFieldProperty(options: [BitableOption(id: "yes", name: "已完成"), BitableOption(id: "no", name: "未完成")]))]
            func inspection(_ view: String) -> BindingInspection {
                let link = ParsedViewLink(kind: .base, resourceToken: "app", tableID: "table", viewID: view,
                                          sourceURL: URL(string: "https://example.feishu.cn/base/app?table=table&view=\(view)")!)
                return BindingInspection(link: link, view: BitableView(id: view, name: view), fields: fields)
            }
            let firstInspection = inspection("one")
            let secondInspection = inspection(sameView ? "one" : "two")
            async let first = Result<(ViewBinding, ViewSnapshot), Error>(catching: { try await service.createBinding(inspection: firstInspection, fieldMapping: mapping, identity: identity, accessToken: "token") })
            async let second = Result<(ViewBinding, ViewSnapshot), Error>(catching: { try await service.createBinding(inspection: secondInspection, fieldMapping: mapping, identity: identity, accessToken: "token") })
            let results = await [first, second]
            XCTAssertEqual(results.filter { if case .success = $0 { return true }; return false }.count, sameView ? 1 : 2)
            let bindings = try repository.load(for: identity).bindings
            XCTAssertEqual(bindings.count, sameView ? 1 : 2)
            XCTAssertEqual(Set(bindings.map(\.viewID)).count, bindings.count)
        }
    }
}

private extension Result where Failure == Error {
    init(catching operation: () async throws -> Success) async {
        do { self = .success(try await operation()) } catch { self = .failure(error) }
    }
}

private final class BindingBarrierProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var waiting: [BindingBarrierProtocol] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.waiting.append(self)
        let ready = Self.waiting.count == 2 ? Self.waiting : []
        if !ready.isEmpty { Self.waiting.removeAll() }
        Self.lock.unlock()
        for item in ready {
            let response = HTTPURLResponse(url: item.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            item.client?.urlProtocol(item, didReceive: response, cacheStoragePolicy: .notAllowed)
            item.client?.urlProtocol(item, didLoad: Data(#"{"code":0,"data":{"items":[],"has_more":false},"msg":"success"}"#.utf8))
            item.client?.urlProtocolDidFinishLoading(item)
        }
    }
    override func stopLoading() {}
}
