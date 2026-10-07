#if os(iOS)
import AVKit
import NativeBlockEditorEngine
import SwiftUI
import WebKit

struct DocumentImageBlockView: View {
    let node: BlockNode
    let identifier: String
    var showsResizeControls = true
    let onResize: (Double) -> Void

    private var source: String { node.data["url"]?.stringValue ?? "" }
    private var width: Double { min(680, max(96, node.data["width"]?.doubleValue ?? 360)) }

    var body: some View {
        VStack(alignment: alignment.horizontal, spacing: 6) {
            resolvedImage
                .frame(width: width)
                .frame(maxWidth: .infinity, alignment: alignment)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            if showsResizeControls { resizeControls }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(node.data["alt"]?.stringValue ?? "Image block")
        .accessibilityIdentifier("image-block-\(identifier)")
    }

    private var resizeControls: some View {
        HStack(spacing: 8) {
            Button { onResize(max(96, width - 48)) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .accessibilityLabel("Make image smaller")
            .accessibilityIdentifier("image-smaller-\(identifier)")

            Text("\(Int(width)) pt")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button { onResize(min(680, width + 48)) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .accessibilityLabel("Make image larger")
            .accessibilityIdentifier("image-larger-\(identifier)")
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    @ViewBuilder
    private var resolvedImage: some View {
        if let image = localImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else if let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image): image.resizable().scaledToFit()
                case .failure:
                    ContentUnavailableView("Image unavailable", systemImage: "photo")
                        .frame(minHeight: 120)
                default:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        } else {
            ContentUnavailableView("Image unavailable", systemImage: "photo")
                .frame(minHeight: 120)
        }
    }

    private var localImage: UIImage? {
        NativeBlockEditorImageSource.localData(source).flatMap(UIImage.init(data:))
    }

    private var alignment: Alignment {
        switch node.data["align"]?.stringValue {
        case "left": .leading
        case "right": .trailing
        default: .center
        }
    }
}

/// Reads the picture an image block's `url` names: a data URL, a file, or a
/// web address.
public enum NativeBlockEditorImageSource {
    /// The bytes of a data URL or local file, read without the network.
    public static func localData(_ source: String) -> Data? {
        if source.lowercased().hasPrefix("data:image/"),
           let comma = source.firstIndex(of: ",") {
            return Data(base64Encoded: String(source[source.index(after: comma)...]))
        }
        if let url = URL(string: source), url.isFileURL {
            return try? Data(contentsOf: url, options: [.mappedIfSafe])
        }
        if source.hasPrefix("/") {
            return try? Data(contentsOf: URL(fileURLWithPath: source), options: [.mappedIfSafe])
        }
        return nil
    }

    /// The image's bytes, downloading a web image. Returns nil when it
    /// cannot be read.
    public static func data(_ source: String) async -> Data? {
        if let data = localData(source) { return data }
        guard let url = URL(string: source),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let (data, response) = try? await URLSession.shared.data(
                for: URLRequest(url: url, timeoutInterval: 20)
              ),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        return data
    }
}

struct NativeMediaBlockView: View {
    let node: BlockNode
    let identifier: String
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    private var kind: String { node.data["kind"]?.stringValue ?? "file" }
    private var url: URL? { URL(string: node.data["url"]?.stringValue ?? "") }

    var body: some View {
        Group {
            if kind == "video", let player {
                VideoPlayer(player: player)
                    .frame(minHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.data["title"]?.stringValue?.isEmpty == false
                            ? node.data["title"]?.stringValue ?? "Media"
                            : kind.capitalized)
                            .font(.body.weight(.semibold))
                        Text(node.data["url"]?.stringValue ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if kind == "audio" {
                        Button {
                            guard let player else { return }
                            if isPlaying { player.pause() } else { player.play() }
                            isPlaying.toggle()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        }
                        .accessibilityLabel(isPlaying ? "Pause audio" : "Play audio")
                    } else if let url {
                        Link(destination: url) { Image(systemName: "arrow.up.right") }
                    }
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: node.data["url"]?.stringValue) {
            if let url { player = AVPlayer(url: url) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.capitalized) block")
        .accessibilityIdentifier("media-block-\(identifier)")
    }

    private var icon: String {
        switch kind {
        case "audio": "waveform"
        case "video": "play.rectangle"
        default: "doc"
        }
    }
}

struct LinkPreviewBlockView: View {
    let node: BlockNode

    var body: some View {
        if let string = node.data["url"]?.stringValue, let url = URL(string: string) {
            Link(destination: url) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                    VStack(alignment: .leading) {
                        Text(url.host ?? "Link preview").font(.body.weight(.semibold))
                        Text(string).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct PluginBlockView: View {
    let node: BlockNode
    let identifier: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.data["display_name"]?.stringValue ?? "Plugin")
                    .font(.body.weight(.semibold))
                Text(node.data["plugin_id"]?.stringValue ?? "Unknown plugin")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("Payload is preserved losslessly in document JSON.")
                    .font(.caption)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plugin block")
        .accessibilityIdentifier("plugin-block-\(identifier)")
    }
}

struct DatabaseBlockView: View {
    let node: BlockNode
    let identifier: String
    let onCellChange: (String, String, String) -> Void
    let onAddRow: () -> Void

    private var columns: [(id: String, name: String)] {
        guard case let .array(values)? = node.data["columns"] else { return [] }
        return values.compactMap { value in
            guard case let .object(column) = value,
                  let id = column["id"]?.stringValue,
                  let name = column["name"]?.stringValue else { return nil }
            return (id, name)
        }
    }

    private var rows: [(id: String, cells: [String: JSONValue])] {
        guard case let .array(values)? = node.data["rows"] else { return [] }
        return values.compactMap { value in
            guard case let .object(row) = value, let id = row["id"]?.stringValue else { return nil }
            if case let .object(cells)? = row["cells"] { return (id, cells) }
            return (id, [:])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(node.data["title"]?.stringValue ?? "Database", systemImage: "tablecells")
                    .font(.headline)
                Spacer()
                Button("Add row", systemImage: "plus", action: onAddRow)
                    .font(.caption)
                    .accessibilityIdentifier("database-add-row-\(identifier)")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(columns, id: \.id) { column in
                            Text(column.name)
                                .font(.caption.weight(.semibold))
                                .frame(width: 132, alignment: .leading)
                                .padding(8)
                                .background(Color(uiColor: .secondarySystemBackground))
                        }
                    }
                    ForEach(rows, id: \.id) { row in
                        GridRow {
                            ForEach(columns, id: \.id) { column in
                                DatabaseCellField(
                                    value: row.cells[column.id]?.stringValue ?? "",
                                    onCommit: { onCellChange(row.id, column.id, $0) }
                                )
                                .frame(width: 132)
                                .padding(8)
                            }
                        }
                    }
                }
                .overlay { Rectangle().stroke(Color(uiColor: .separator), lineWidth: 0.5) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Database block")
        .accessibilityIdentifier("database-block-\(identifier)")
    }
}

private struct DatabaseCellField: View {
    @State var value: String
    let onCommit: (String) -> Void

    var body: some View {
        TextField("Empty", text: $value)
            .textFieldStyle(.plain)
            .onSubmit { onCommit(value) }
    }
}

actor ImageAssetStore {
    enum StorageMode { case localFile, embeddedBase64 }

    func importImage(_ data: Data, mode: StorageMode) throws -> String {
        guard data.count <= 20 * 1_024 * 1_024, let image = UIImage(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let normalized = image.jpegData(compressionQuality: 0.86) ?? data
        switch mode {
        case .embeddedBase64:
            return "data:image/jpeg;base64,\(normalized.base64EncodedString())"
        case .localFile:
            let manager = FileManager.default
            let root = try manager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("NativeEditorMedia", isDirectory: true)
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent("\(UUID().uuidString).jpg")
            try normalized.write(to: destination, options: .atomic)
            return destination.absoluteString
        }
    }
}

#endif
