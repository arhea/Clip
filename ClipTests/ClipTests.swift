import CoreGraphics
import Foundation
import Testing
@testable import Clip

private func solidImage(width: Int, height: Int, color: CGColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

struct GeometryTests {
    @Test func rectFromPointsIsNormalized() {
        let rect = CGRect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 0, y: 5))
        #expect(rect == CGRect(x: 0, y: 5, width: 10, height: 15))
    }

    @Test func squaredKeepsDirection() {
        let point = CGPoint(x: -10, y: 4).squared(from: .zero)
        #expect(point == CGPoint(x: -10, y: 10))
    }

    @Test func snapTo45Degrees() {
        let point = CGPoint(x: 100, y: 5).snapped45(from: .zero)
        #expect(abs(point.y) < 0.001)
        #expect(abs(point.x - hypot(100, 5)) < 0.001)
    }

    @Test func distanceToSegment() {
        #expect(CGPoint(x: 5, y: 3).distance(toSegment: .zero, CGPoint(x: 10, y: 0)) == 3)
        #expect(CGPoint(x: -4, y: 3).distance(toSegment: .zero, CGPoint(x: 10, y: 0)) == 5)
    }
}

@MainActor
struct LayoutTests {
    @Test func noBackgroundUsesCropSize() {
        var state = EditorState(baseImage: solidImage(width: 200, height: 100))
        state.crop = CGRect(x: 50, y: 10, width: 100, height: 50)
        let layout = RenderLayout.make(for: state, scale: 2, includeBackground: true, applyCrop: true)
        #expect(layout.canvasSize == CGSize(width: 100, height: 50))
        #expect(CGPoint(x: 50, y: 10).applying(layout.transform) == .zero)
    }

    @Test func backgroundAddsScaledPadding() {
        var state = EditorState(baseImage: solidImage(width: 200, height: 100))
        state.background.isEnabled = true
        state.background.padding = 10
        state.background.inset = 0
        let layout = RenderLayout.make(for: state, scale: 2, includeBackground: true, applyCrop: true)
        #expect(layout.canvasSize == CGSize(width: 240, height: 140))
        #expect(layout.imageFrame == CGRect(x: 20, y: 20, width: 200, height: 100))
    }

    @Test func aspectRatioExpandsCanvas() {
        var state = EditorState(baseImage: solidImage(width: 200, height: 100))
        state.background.isEnabled = true
        state.background.padding = 0
        state.background.aspect = .square
        let layout = RenderLayout.make(for: state, scale: 1, includeBackground: true, applyCrop: true)
        #expect(layout.canvasSize == CGSize(width: 200, height: 200))
        #expect(layout.imageFrame.minY == 50)
    }

    @Test func renderProducesExpectedSize() throws {
        var state = EditorState(baseImage: solidImage(width: 120, height: 80))
        state.annotations.append(Annotation(kind: .arrow, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 100, y: 60), style: AnnotationStyle()))
        state.annotations.append(Annotation(kind: .redact, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 40, y: 40), style: AnnotationStyle()))
        state.background.isEnabled = true
        state.background.padding = 8
        let image = try #require(Renderer.renderImage(state, scale: 1))
        #expect(image.width == 136)
        #expect(image.height == 96)
    }
}

@MainActor
struct DocumentTests {
    @Test func undoRedo() {
        let document = EditorDocument(capture: Capture(image: solidImage(width: 50, height: 50), scale: 1, kind: .area), historyID: nil)
        let annotation = Annotation(kind: .rectangle, start: .zero, end: CGPoint(x: 10, y: 10), style: AnnotationStyle())
        document.mutate { $0.annotations.append(annotation) }
        #expect(document.state.annotations.count == 1)
        document.undo()
        #expect(document.state.annotations.isEmpty)
        document.redo()
        #expect(document.state.annotations.count == 1)
    }

    @Test func rotateRightSwapsDimensionsAndMovesAnnotations() {
        let document = EditorDocument(capture: Capture(image: solidImage(width: 40, height: 20), scale: 1, kind: .area), historyID: nil)
        document.mutate { $0.annotations.append(Annotation(kind: .line, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 40, y: 0), style: AnnotationStyle())) }
        document.apply(.rotateRight)
        #expect(document.state.baseImage.width == 20)
        #expect(document.state.baseImage.height == 40)
        let line = document.state.annotations[0]
        #expect(line.start == CGPoint(x: 20, y: 0))
        #expect(line.end == CGPoint(x: 20, y: 40))
    }

    @Test func counterNumbersIncrement() {
        let document = EditorDocument(capture: Capture(image: solidImage(width: 50, height: 50), scale: 1, kind: .area), historyID: nil)
        #expect(document.nextCounterNumber == 1)
        document.mutate { $0.annotations.append(Annotation(kind: .counter, start: .zero, end: .zero, number: 1, style: AnnotationStyle())) }
        #expect(document.nextCounterNumber == 2)
    }
}

@MainActor
struct HistoryTests {
    @Test func prunesToLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClipTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let image = solidImage(width: 4, height: 4)
        for _ in 0..<(HistoryStore.limit + 3) {
            store.add(Capture(image: image, scale: 1, kind: .area))
        }
        #expect(store.items.count == HistoryStore.limit)

        let reloaded = HistoryStore(directory: directory)
        #expect(reloaded.items.count == HistoryStore.limit)
        #expect(reloaded.capture(for: reloaded.items[0]) != nil)
    }

    @Test func projectRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClipTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let image = solidImage(width: 20, height: 20)
        let item = store.add(Capture(image: image, scale: 1, kind: .area))
        var background = BackgroundStyle()
        background.isEnabled = true
        let project = EditorProject(annotations: [Annotation(kind: .text, start: .zero, end: .zero, text: "Hi", style: AnnotationStyle())],
                                    crop: CGRect(x: 1, y: 1, width: 10, height: 10), background: background)
        store.updateProject(item.id, project: project, baseImage: image, baseChanged: false, rendered: nil)
        let loaded = try #require(store.project(for: store.items[0]))
        #expect(loaded.annotations.first?.text == "Hi")
        #expect(loaded.crop == CGRect(x: 1, y: 1, width: 10, height: 10))
        #expect(loaded.background.isEnabled)
    }
}

struct ExporterTests {
    @Test func encodesAllFormats() throws {
        let image = solidImage(width: 16, height: 16)
        for format in ImageFormat.allCases {
            let data = try #require(ImageExporter.encode(image, format: format, quality: 0.5))
            #expect(!data.isEmpty)
        }
    }

    @Test func resizes() throws {
        let resized = try #require(ImageExporter.resize(solidImage(width: 100, height: 50), to: CGSize(width: 50, height: 25)))
        #expect(resized.width == 50 && resized.height == 25)
    }
}

@MainActor
struct PreferencesTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "ClipTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func defaultsToCopyWithNotification() {
        let preferences = Preferences(defaults: freshDefaults())
        #expect(preferences.afterCapture == .copyToClipboard)
        #expect(preferences.captureFeedback == .notification)
    }

    @Test func defaultSaveDirectoryIsDocumentsClipScreenshots() {
        let preferences = Preferences(defaults: freshDefaults())
        #expect(preferences.saveDirectory.lastPathComponent == "ClipScreenshots")
        #expect(preferences.saveDirectory.deletingLastPathComponent().lastPathComponent == "Documents")
    }

    @Test func migratesLegacyMultiSelect() {
        let defaults = freshDefaults()
        defaults.set(["saveToDisk"], forKey: "afterCaptureActions")
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.afterCapture == .saveToDisk)

    }

    @Test func persistsChoice() {
        let defaults = freshDefaults()
        Preferences(defaults: defaults).afterCapture = .openEditor
        #expect(Preferences(defaults: defaults).afterCapture == .openEditor)
    }
}
