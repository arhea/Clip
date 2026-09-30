import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Encodes, resizes, copies, and saves images using only ImageIO and AppKit.
enum ImageExporter {
    static func utType(for format: ImageFormat) -> UTType {
        switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }

    /// Encodes an image. `quality` (0...1) applies to lossy formats only.
    static func encode(_ image: CGImage, format: ImageFormat, quality: Double = 0.85, pointsPerPixel: CGFloat? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, utType(for: format).identifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if format == .jpeg, image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst {
            // JPEG has no alpha; flatten onto white so transparent window shadows don't turn black.
            guard let flattened = flatten(image) else { return nil }
            CGImageDestinationAddImage(destination, flattened, properties as CFDictionary)
        } else {
            if let pointsPerPixel, pointsPerPixel > 0 {
                // Record the DPI so Retina captures display at their point size.
                properties[kCGImagePropertyDPIWidth] = 72 / pointsPerPixel
                properties[kCGImagePropertyDPIHeight] = 72 / pointsPerPixel
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func flatten(_ image: CGImage, onto color: CGColor = .white) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(color)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// Resamples an image to an exact pixel size.
    static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = max(1, Int(size.width.rounded())), height = max(1, Int(size.height.rounded()))
        if width == image.width, height == image.height { return image }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func nsImage(_ image: CGImage, scale: CGFloat) -> NSImage {
        NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    static func copyToPasteboard(_ image: CGImage, scale: CGFloat) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if let png = encode(image, format: .png, pointsPerPixel: scale) {
            item.setData(png, forType: .png)
        }
        if let tiff = nsImage(image, scale: scale).tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.writeObjects([item])
    }

    static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double, scale: CGFloat) throws {
        guard let data = encode(image, format: format, quality: quality, pointsPerPixel: scale) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Returns `url`, or a numbered variant if a file already exists there.
    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let directory = url.deletingLastPathComponent()
        var index = 2
        while true {
            let candidate = directory.appending(path: "\(base) \(index).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// Writes a temporary file for drag and drop into other apps.
    static func temporaryFile(_ image: CGImage, name: String, format: ImageFormat, quality: Double, scale: CGFloat) -> URL? {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Clip-Drag-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        do {
            try write(image, to: url, format: format, quality: quality, scale: scale)
            return url
        } catch {
            return nil
        }
    }

    static func formattedByteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
