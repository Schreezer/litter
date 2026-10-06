import Foundation
import NativeBlockEditorCore
import NativeEditorMCP
import Network

enum CourseMCPServerError: LocalizedError {
    case startupTimedOut
    case startupFailed(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .startupTimedOut:
            "The local Learnfold course-tool server did not start in time."
        case .startupFailed(let message):
            "The local Learnfold course-tool server could not start: \(message)"
        case .unavailable:
            "The local Learnfold course-tool server is unavailable."
        }
    }
}

struct CourseMCPHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data?
}

enum CourseMCPHTTPRequestTestResult: Equatable {
    case incomplete
    case malformed
    case complete
}

private final class CourseMCPStartupResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<UInt16, Error>?

    func storeIfEmpty(_ value: Result<UInt16, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = value
    }

    func load() -> Result<UInt16, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

/// A small stateless Streamable HTTP MCP server hosted inside the iOS app.
///
/// Codex connects over loopback only for course-agent threads. Tool calls are
/// routed into the same revision-safe native editor repository used by the
/// existing dynamic-tool bridge.
final class CourseMCPServer: @unchecked Sendable {
    static let shared = CourseMCPServer()

    private static let maximumRequestBytes = 1_048_576
    private let queue = DispatchQueue(label: "com.chirag.learnfold.course-mcp", qos: .userInitiated)
    private let startLock = NSLock()
    private var listener: NWListener?
    private var listenerPort: UInt16?
    private var capabilityPathByWorkspace: [String: String] = [:]
    private var workspaceByCapabilityPath: [String: String] = [:]
    private(set) var endpointURL: URL?

    private init() {}

    @discardableResult
    func start(workspaceID: String) throws -> URL {
        guard CourseBashTool.isValidWorkspaceID(workspaceID) else {
            throw CourseMCPServerError.unavailable
        }
        startLock.lock()
        defer { startLock.unlock() }
        if listener != nil {
            return try endpoint(for: workspaceID)
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: .any
        )
        let listener = try NWListener(using: parameters)
        let startup = CourseMCPStartupResult()
        let ready = DispatchSemaphore(value: 0)

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    startup.storeIfEmpty(.success(port))
                } else {
                    startup.storeIfEmpty(.failure(CourseMCPServerError.unavailable))
                }
                ready.signal()
            case .failed(let error):
                startup.storeIfEmpty(.failure(error))
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success else {
            listener.cancel()
            throw CourseMCPServerError.startupTimedOut
        }
        guard let result = startup.load() else {
            listener.cancel()
            throw CourseMCPServerError.unavailable
        }

        let port: UInt16
        do {
            port = try result.get()
        } catch {
            listener.cancel()
            throw CourseMCPServerError.startupFailed(error.localizedDescription)
        }

        self.listener = listener
        listenerPort = port
        let endpoint = try endpoint(for: workspaceID)
        endpointURL = endpoint
        LLog.info(
            "course-mcp",
            "local course MCP server ready",
            fields: ["port": port, "workspaceId": workspaceID]
        )
        return endpoint
    }

    private func endpoint(for workspaceID: String) throws -> URL {
        guard let listenerPort else { throw CourseMCPServerError.unavailable }
        let path: String
        if let existing = capabilityPathByWorkspace[workspaceID] {
            path = existing
        } else {
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            path = "/mcp/\(token)"
            capabilityPathByWorkspace[workspaceID] = path
            workspaceByCapabilityPath[path] = workspaceID
        }
        guard let endpoint = URL(string: "http://127.0.0.1:\(listenerPort)\(path)") else {
            throw CourseMCPServerError.unavailable
        }
        return endpoint
    }

    private func authorizedWorkspaceID(for path: String) -> String? {
        startLock.lock()
        defer { startLock.unlock() }
        return workspaceByCapabilityPath[path]
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: queue)
        receiveRequest(connection, accumulated: Data())
    }

    private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maximumRequestBytes
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = accumulated
            if let data { accumulated.append(data) }
            if accumulated.count > Self.maximumRequestBytes {
                send(CourseMCPHTTPResponse(statusCode: 413, body: nil), over: connection)
                return
            }
            switch parseHTTPRequest(accumulated) {
            case .complete(let request):
                Task {
                    let response: CourseMCPHTTPResponse
                    if request.method == "POST",
                       let workspaceID = self.authorizedWorkspaceID(for: request.path) {
                        response = await CourseMCPProtocol.handleJSONRPC(
                            body: request.body,
                            authorizedWorkspaceID: workspaceID
                        )
                    } else if request.method == "GET",
                              self.authorizedWorkspaceID(for: request.path) != nil {
                        // Stateless JSON responses are used; SSE GET is not.
                        response = CourseMCPHTTPResponse(statusCode: 405, body: nil)
                    } else {
                        response = CourseMCPHTTPResponse(statusCode: 404, body: nil)
                    }
                    self.send(response, over: connection)
                }
                return
            case .malformed:
                send(CourseMCPHTTPResponse(statusCode: 400, body: nil), over: connection)
                return
            case .incomplete:
                if error != nil || isComplete {
                    send(CourseMCPHTTPResponse(statusCode: 400, body: nil), over: connection)
                    return
                }
            }
            receiveRequest(connection, accumulated: accumulated)
        }
    }

    private struct ParsedHTTPRequest {
        let method: String
        let path: String
        let body: Data
    }

    private enum HTTPRequestParseResult {
        case incomplete
        case malformed
        case complete(ParsedHTTPRequest)
    }

    private func parseHTTPRequest(_ data: Data) -> HTTPRequestParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return .incomplete }
        let headerData = data[..<headerRange.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else { return .malformed }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .malformed }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0" else {
            return .malformed
        }

        var contentLengthValues: [String] = []
        var hasTransferEncoding = false
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return .malformed }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .malformed }
            if name.caseInsensitiveCompare("Content-Length") == .orderedSame {
                contentLengthValues.append(value)
            } else if name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame {
                hasTransferEncoding = true
            }
        }
        guard !hasTransferEncoding, contentLengthValues.count <= 1 else { return .malformed }
        let contentLength: Int
        if let value = contentLengthValues.first {
            guard !value.isEmpty,
                  value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let parsed = Int(value),
                  parsed <= Self.maximumRequestBytes else { return .malformed }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        let bodyStart = headerRange.upperBound
        let (bodyEnd, overflow) = bodyStart.addingReportingOverflow(contentLength)
        guard !overflow, bodyEnd <= Self.maximumRequestBytes else { return .malformed }
        guard data.count >= bodyEnd else { return .incomplete }
        let body = data.subdata(in: bodyStart..<bodyEnd)
        return .complete(ParsedHTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            body: body
        ))
    }

    static func parseHTTPRequestForTesting(_ data: Data) -> CourseMCPHTTPRequestTestResult {
        switch shared.parseHTTPRequest(data) {
        case .incomplete: .incomplete
        case .malformed: .malformed
        case .complete: .complete
        }
    }

    private func send(_ response: CourseMCPHTTPResponse, over connection: NWConnection) {
        let body = response.body ?? Data()
        let reason = switch response.statusCode {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        default: "Internal Server Error"
        }
        var headers = [
            "HTTP/1.1 \(response.statusCode) \(reason)",
            "Content-Length: \(body.count)",
            "Connection: close",
        ]
        if !body.isEmpty {
            headers.append("Content-Type: application/json")
        }
        let head = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        connection.send(content: head + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum CourseMCPProtocol {
    static func handleJSONRPC(
        body: Data,
        authorizedWorkspaceID: String
    ) async -> CourseMCPHTTPResponse {
        do {
            let request = try JSONDecoder().decode(JSONValue.self, from: body)
            guard case .object(let object) = request,
                  object["jsonrpc"]?.stringValue == "2.0",
                  let method = object["method"]?.stringValue else {
                return errorResponse(id: .null, code: -32600, message: "Invalid Request")
            }

            let id = object["id"]
            if id == nil {
                return CourseMCPHTTPResponse(statusCode: 202, body: nil)
            }

            switch method {
            case "initialize":
                return resultResponse(
                    id: id ?? .null,
                    result: [
                        "protocolVersion": object["params"]?.objectValue?["protocolVersion"]
                            ?? .string("2025-06-18"),
                        "capabilities": ["tools": ["listChanged": false]],
                        "serverInfo": [
                            "name": .string(CourseAgentTools.mcpServerName),
                            "version": "1.0.0",
                        ],
                    ]
                )
            case "ping":
                return resultResponse(id: id ?? .null, result: .object([:]))
            case "tools/list":
                // Codex proposes plans as `learnfold-plan` reply blocks.
                let definitions = try CourseAgentTools.mcpToolDefinitions(
                    includePresentPlan: false,
                    includeCourseBash: CourseRuntimePaths.currentFileSystem != .nativeMac
                )
                let toolsData = try JSONSerialization.data(
                    withJSONObject: definitions.map(\.jsonObject),
                    options: [.sortedKeys]
                )
                let tools = try JSONDecoder().decode(JSONValue.self, from: toolsData)
                return resultResponse(id: id ?? .null, result: ["tools": tools])
            case "tools/call":
                return await callTool(
                    id: id ?? .null,
                    params: object["params"],
                    authorizedWorkspaceID: authorizedWorkspaceID
                )
            default:
                return errorResponse(id: id ?? .null, code: -32601, message: "Method not found")
            }
        } catch {
            return errorResponse(id: .null, code: -32700, message: "Parse error")
        }
    }

    private static func callTool(
        id: JSONValue,
        params: JSONValue?,
        authorizedWorkspaceID: String
    ) async -> CourseMCPHTTPResponse {
        guard let params = params?.objectValue,
              let name = params["name"]?.stringValue,
              var arguments = params["arguments"]?.objectValue,
              let requestedWorkspaceID = arguments.removeValue(
                  forKey: CourseAgentTools.workspaceIDArgument
              )?.stringValue,
              requestedWorkspaceID == authorizedWorkspaceID,
              let workspaceURL = workspaceURL(for: authorizedWorkspaceID) else {
            return toolResult(
                id: id,
                value: ["error": "The workspace_id does not match this course-tool capability."],
                isError: true
            )
        }
        let workspaceID = authorizedWorkspaceID

        guard FileManager.default.fileExists(atPath: workspaceURL.path) else {
            return toolResult(
                id: id,
                value: ["error": "The requested course workspace is not available."],
                isError: true
            )
        }

        if name == CourseAgentTools.presentPlan {
            do {
                let argumentsData = try JSONEncoder().encode(JSONValue.object(arguments))
                let plan = try JSONDecoder().decode(CourseBrief.self, from: argumentsData)
                if let problem = coursePlanSemanticProblem(for: plan) {
                    return invalidCoursePlanResult(id: id, problem: problem)
                }
                guard try await CourseDocumentRegistry.shared.presentPlan(
                    workspaceID: workspaceID,
                    plan: plan
                ) else {
                    return toolResult(
                        id: id,
                        value: [
                            "error": "The course editor is not connected to this workspace. The plan was not presented."
                        ],
                        isError: true
                    )
                }
                return toolResult(id: id, value: .object(arguments), isError: false)
            } catch {
                return invalidCoursePlanResult(
                    id: id,
                    problem: coursePlanValidationProblem(for: error)
                )
            }
        }

        if name == CourseAgentTools.courseBash {
            guard CourseRuntimePaths.currentFileSystem != .nativeMac else {
                return toolResult(
                    id: id,
                    value: ["error": "course_bash is unavailable on Mac. Use Codex's built-in shell in this course's working directory."],
                    isError: true
                )
            }
            guard let script = arguments["script"]?.stringValue else {
                return toolResult(
                    id: id,
                    value: ["error": "course_bash requires a non-empty script."],
                    isError: true
                )
            }
            do {
                let execution = try await CourseBashTool.execute(
                    workspaceID: workspaceID,
                    workspaceURL: workspaceURL,
                    script: script,
                    timeoutSeconds: arguments["timeout_seconds"]?.intValue
                )
                var value: [String: JSONValue] = [
                    "exit_code": .integer(Int(execution.exitCode)),
                    "output": .string(execution.output),
                    "output_truncated": .bool(execution.outputWasTruncated),
                    "changed_paths": .array(execution.changedPaths.map(JSONValue.string)),
                    "changed_paths_truncated": .bool(execution.changedPathsWereTruncated),
                    "workspace_root": "/workspace",
                    "workspace_access": .string(
                        execution.workspaceWasReadOnly ? "read_only" : "read_write"
                    ),
                ]
                if execution.exitCode != 0 {
                    value["warning"] = "The command exited nonzero but may have partially modified the course. Inspect the workspace before retrying."
                }
                return toolResult(
                    id: id,
                    value: .object(value),
                    isError: execution.exitCode != 0
                )
            } catch {
                return toolResult(
                    id: id,
                    value: ["error": .string(error.localizedDescription)],
                    isError: true
                )
            }
        }

        guard CourseAgentTools.isEditorTool(name) else {
            return toolResult(
                id: id,
                value: ["error": .string("Unknown course tool: \(name)")],
                isError: true
            )
        }

        if CourseAgentTools.isMutatingEditorTool(name) {
            guard AppleCourseApprovalPolicy.isLatestPlanApproved(
                courseDirectory: workspaceURL
            ) else {
                return toolResult(
                    id: id,
                    value: [
                        "error": "This course plan has not been approved. Present the plan and wait for explicit learner approval before changing native pages."
                    ],
                    isError: true
                )
            }
        }

        do {
            let argumentsData = try JSONEncoder().encode(JSONValue.object(arguments))
            guard let argumentsJSON = String(data: argumentsData, encoding: .utf8),
                  let result = await CourseDocumentRegistry.shared.handle(
                      workspaceID: workspaceID,
                      tool: name,
                      argumentsJSON: argumentsJSON
                  ) else {
                return toolResult(
                    id: id,
                    value: ["error": "The course editor is not connected to this workspace."],
                    isError: true
                )
            }
            return toolResult(id: id, value: result.value, isError: result.isError)
        } catch {
            return toolResult(
                id: id,
                value: ["error": .string(error.localizedDescription)],
                isError: true
            )
        }
    }

    private static func coursePlanSemanticProblem(for plan: CourseBrief) -> String? {
        let requiredStrings = [
            ("plan_id", plan.planID),
            ("title", plan.title),
            ("summary", plan.summary),
            ("outcome", plan.outcome),
            ("starting_point", plan.startingPoint),
            ("focus_gap", plan.focusGap),
            ("estimated_duration", plan.estimatedDuration),
        ]
        for (field, value) in requiredStrings
        where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The field '\(field)' must be a non-empty string."
        }
        guard plan.revision > 0 else {
            return "The field 'revision' must be a positive integer."
        }
        guard !plan.chapters.isEmpty else {
            return "The field 'chapters' must contain at least one chapter."
        }
        for (chapterIndex, chapter) in plan.chapters.enumerated() {
            let requiredChapterStrings = [
                ("id", chapter.id),
                ("title", chapter.title),
                ("objective", chapter.objective),
            ]
            for (field, value) in requiredChapterStrings
            where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "The field 'chapters[\(chapterIndex)].\(field)' must be a non-empty string."
            }
            for (deliverableIndex, deliverable) in chapter.deliverables.enumerated()
            where deliverable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "The field 'chapters[\(chapterIndex)].deliverables[\(deliverableIndex)]' must be a non-empty string."
            }
        }
        return AppleCoursePlanValidator.issue(
            in: plan,
            requiresTypedHierarchy: true
        )
    }

    private static func invalidCoursePlanResult(
        id: JSONValue,
        problem: String
    ) -> CourseMCPHTTPResponse {
        toolResult(
            id: id,
            value: [
                "error": .string(
                    """
                    Invalid course plan: \(problem) Correct the arguments and call \
                    \(CourseAgentTools.presentPlan) again with every required typed field. \
                    Do not ask the learner to approve the plan until this tool succeeds.
                    """
                )
            ],
            isError: true
        )
    }

    private static func coursePlanValidationProblem(for error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return "The arguments are not valid typed JSON."
        }

        switch decodingError {
        case .keyNotFound(let key, let context):
            let path = codingPath(context.codingPath, appending: key)
            return "The required field '\(path)' is missing."
        case .typeMismatch(let type, let context):
            let path = codingPath(context.codingPath)
            return "The field '\(path)' has the wrong type; expected \(type)."
        case .valueNotFound(let type, let context):
            let path = codingPath(context.codingPath)
            return "The field '\(path)' cannot be null; expected \(type)."
        case .dataCorrupted(let context):
            let path = codingPath(context.codingPath)
            if path.isEmpty {
                return "The arguments contain invalid data."
            }
            return "The field '\(path)' contains invalid data."
        @unknown default:
            return "The arguments do not match the required course-plan schema."
        }
    }

    private static func codingPath(
        _ codingPath: [CodingKey],
        appending finalKey: CodingKey? = nil
    ) -> String {
        var keys = codingPath
        if let finalKey {
            keys.append(finalKey)
        }
        var result = ""
        for key in keys {
            if let index = key.intValue {
                result += "[\(index)]"
            } else if result.isEmpty {
                result = key.stringValue
            } else {
                result += ".\(key.stringValue)"
            }
        }
        return result
    }

    private static func workspaceURL(for workspaceID: String) -> URL? {
        guard CourseBashTool.isValidWorkspaceID(workspaceID) else { return nil }
        return CourseRuntimePaths.defaultCoursesRootURL
            .appendingPathComponent(workspaceID, isDirectory: true)
    }

    private static func toolResult(
        id: JSONValue,
        value: JSONValue,
        isError: Bool
    ) -> CourseMCPHTTPResponse {
        let encoded = (try? JSONEncoder().encode(value))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{}"
        let structured: JSONValue = switch value {
        case .object:
            value
        default:
            ["result": value]
        }
        return resultResponse(
            id: id,
            result: [
                "content": .array([
                    ["type": "text", "text": .string(encoded)]
                ]),
                "structuredContent": structured,
                "isError": .bool(isError),
            ]
        )
    }

    private static func resultResponse(
        id: JSONValue,
        result: JSONValue
    ) -> CourseMCPHTTPResponse {
        jsonResponse([
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ])
    }

    private static func errorResponse(
        id: JSONValue,
        code: Int,
        message: String
    ) -> CourseMCPHTTPResponse {
        jsonResponse([
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": .integer(code),
                "message": .string(message),
            ],
        ])
    }

    private static func jsonResponse(_ value: JSONValue) -> CourseMCPHTTPResponse {
        CourseMCPHTTPResponse(
            statusCode: 200,
            body: try? JSONEncoder().encode(value)
        )
    }
}
