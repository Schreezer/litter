import Foundation
import NativeBlockEditorCore
import NativeEditorMCP

@main
enum PageEditBridge {
    static func main() async {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let request = try JSONDecoder().decode([String: JSONValue].self, from: input)
            let command = request["command"]?.stringValue ?? ""
            let result: JSONValue
            if command == "catalog" {
                result = .array(NativeEditorMCPToolCatalog.tools.map {
                    .object(["name": .string($0.name), "description": .string($0.description),
                             "parameters": $0.inputSchema])
                })
            } else {
                let database = URL(fileURLWithPath: request["database"]!.stringValue!)
                let service = try await NativeEditorMCPService.open(databaseURL: database)
                if command == "seed" {
                    let root = try await service.rootPageSnapshot()
                    let created = try await service.createPages([
                        "parent": .object(["page_id": .string(root.id)]),
                        "pages": .array([.object([
                            "properties": .object(["title": request["title"] ?? .string("Lesson"),
                                                   "course_node_id": .string("benchmark-lesson"),
                                                   "course_role": .string("lesson"),
                                                   "generation_status": .string("generated")]),
                            "content": request["markdown"] ?? .string("")
                        ])])
                    ])
                    let pageID = created.objectValue!["results"]!.arrayValue![0].objectValue!["id"]!.stringValue!
                    if request["opaque"]?.boolValue == true {
                        let snapshot = try await service.pageSnapshot(id: pageID)
                        var document = snapshot.document
                        document.root.children.append(BlockNode(type: "nbe/plugin", data: [
                            "plugin_id": .string("benchmark-quiz"),
                            "payload": .object(["answer": .integer(42), "attempts": .integer(2)])
                        ]))
                        document.ensureStableBlockIDs()
                        _ = try await service.saveDocument(document, pageID: pageID, expectedRevision: snapshot.revision)
                    }
                    result = try await service.fetch(["id": .string(pageID)])
                } else if command == "inspect" {
                    let id = request["page_id"]!.stringValue!
                    let snapshot = try await service.pageSnapshot(id: id)
                    let document = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(snapshot.document))
                    result = .object(["page": try await service.fetch(["id": .string(id)]), "document": document])
                } else {
                    let response = await service.callTool(named: request["name"]!.stringValue!,
                                                          arguments: request["arguments"]!.objectValue!)
                    result = .object(["isError": .bool(response.isError), "value": response.value])
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(result))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }
}
