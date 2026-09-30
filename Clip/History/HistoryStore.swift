import AppKit
import ImageIO
import Observation

struct HistoryItem: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let kind: CaptureKind
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: CGFloat
    /// The last place this capture was saved to disk, if any.
    var savedURL: URL?
    /// Whether an editable project (annotations, crop, background) is stored.
    var hasProject = false
}

/// Persists the most recent captures under Application Support.
///
/// Layout: `History/index.json` plus one folder per capture holding the
/// original pixels, a thumbnail, and an optional editable project.
@Observable
final class HistoryStore {
    static let limit = 50

    private(set) var items: [HistoryItem] = []
    /// Bumped when a thumbnail changes so views re-read it.
    private(set) var thumbnailRevision = 0
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var thumbnails: [UUID: NSImage] = [:]

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Clip/History", directoryHint: .isDirectory)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    private var indexURL: URL { directory.appending(path: "index.json") }
    private func folder(for id: UUID) -> URL { directory.appending(path: id.uuidString, directoryHint: .isDirectory) }
    func originalURL(for id: UUID) -> URL { folder(for: id).appending(path: "original.png") }
    func thumbnailURL(for id: UUID) -> URL { folder(for: id).appending(path: "thumbnail.png") }
    private func projectURL(for id: UUID) -> URL { folder(for: id).appending(path: "project.json") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([HistoryItem].self, from: data)) ?? []
        items.removeAll { !FileManager.default.fileExists(atPath: originalURL(for: $0.id).path) }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    @discardableResult
    func add(_ capture: Capture) -> HistoryItem {
        let item = HistoryItem(id: UUID(), date: capture.date, kind: capture.kind,
                               pixelWidth: capture.image.width, pixelHeight: capture.image.height, scale: capture.scale)
        let folder = folder(for: item.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? ImageExporter.write(capture.image, to: originalURL(for: item.id), format: .png, quality: 1, scale: capture.scale)
        writeThumbnail(capture.image, for: item.id)
        items.insert(item, at: 0)
        prune()
        persist()
        return item
    }

    /// Stores the editable project and a refreshed thumbnail after editing.
    func updateProject(_ id: UUID, project: EditorProject, baseImage: CGImage, baseChanged: Bool, rendered: CGImage?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if baseChanged {
            try? ImageExporter.write(baseImage, to: originalURL(for: id), format: .png, quality: 1, scale: items[index].scale)
        }
        if let data = try? JSONEncoder().encode(project) {
            try? data.write(to: projectURL(for: id), options: .atomic)
            items[index].hasProject = true
        }
        if let rendered { writeThumbnail(rendered, for: id) }
        persist()
    }

    func markSaved(_ id: UUID, at url: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].savedURL = url
        persist()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        thumbnails[id] = nil
        try? FileManager.default.removeItem(at: folder(for: id))
        persist()
    }

    func clear() {
        for item in items { try? FileManager.default.removeItem(at: folder(for: item.id)) }
        items.removeAll()
        thumbnails.removeAll()
        persist()
    }

    private func prune() {
        while items.count > Self.limit, let last = items.popLast() {
            thumbnails[last.id] = nil
            try? FileManager.default.removeItem(at: folder(for: last.id))
        }
    }

    // MARK: Loading

    func capture(for item: HistoryItem) -> Capture? {
        guard let source = CGImageSourceCreateWithURL(originalURL(for: item.id) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Capture(image: image, scale: item.scale, kind: item.kind, date: item.date)
    }

    func project(for item: HistoryItem) -> EditorProject? {
        guard item.hasProject, let data = try? Data(contentsOf: projectURL(for: item.id)) else { return nil }
        return try? JSONDecoder().decode(EditorProject.self, from: data)
    }

    /// The finished image: the original with any saved edits applied.
    func renderedImage(for item: HistoryItem) -> CGImage? {
        guard let capture = capture(for: item) else { return nil }
        guard let project = project(for: item) else { return capture.image }
        var state = EditorState(baseImage: capture.image)
        state.annotations = project.annotations
        state.crop = project.crop
        state.background = project.background
        return Renderer.renderImage(state, scale: item.scale)
    }

    func thumbnail(for item: HistoryItem) -> NSImage? {
        _ = thumbnailRevision
        if let cached = thumbnails[item.id] { return cached }
        let image = NSImage(contentsOf: thumbnailURL(for: item.id))
        thumbnails[item.id] = image
        return image
    }

    private func writeThumbnail(_ image: CGImage, for id: UUID) {
        let maxSide: CGFloat = 480
        let factor = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let size = CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
        guard let small = ImageExporter.resize(image, to: size),
              let data = ImageExporter.encode(small, format: .png) else { return }
        try? data.write(to: thumbnailURL(for: id), options: .atomic)
        thumbnails[id] = NSImage(data: data)
        thumbnailRevision += 1
    }
}
