import AppKit
import Foundation

/// A signature saved on disk, ready to stamp.
struct SavedSignature: Identifiable {
    /// The file name, which is unique within the store's folder.
    let id: String
    let url: URL
    let image: NSImage
}

/// Keeps the user's reusable signatures as PNG files.
///
/// ## Why files in Application Support
///
/// A signature is personal and reused across documents, so it belongs to the
/// user rather than to any one PDF. Plain PNGs in a private folder keep it
/// inspectable and deletable from Finder, with no database to corrupt. The
/// folder is owner-only (0700) and each file 0600, because a signature image is
/// exactly the kind of thing another local account should not be able to copy.
@MainActor
final class SignatureStore: ObservableObject {

    /// Enough for a full name, initials and a few variants; the cap stops an
    /// accidental loop of "Save and Use" from filling the disk and the grid.
    static let maxSignatures = 20

    /// Transparent margin kept around the ink after trimming, in pixels, so
    /// antialiased stroke edges are never clipped.
    static let trimPadding = 8

    @Published private(set) var signatures: [SavedSignature] = []

    let directory: URL

    /// - Parameter directory: Override for tests; defaults to
    ///   `~/Library/Application Support/PDF Engineer/Signatures/`.
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        reload()
    }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return support.appending(path: "PDF Engineer/Signatures", directoryHint: .isDirectory)
    }

    /// Rereads the folder, newest first. A missing folder simply means no
    /// signatures yet; unreadable files are skipped rather than failing the list.
    func reload() {
        let manager = FileManager.default
        let urls = (try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        let dated: [(SavedSignature, Date)] = urls
            .filter { $0.pathExtension.lowercased() == "png" }
            .compactMap { url in
                guard let image = NSImage(contentsOf: url) else { return nil }
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return (SavedSignature(id: url.lastPathComponent, url: url, image: image), created)
            }
        signatures = dated.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Trims `image` to its ink, saves it, and returns the saved entry.
    ///
    /// - Throws: ``SignatureStoreError`` if the store is full, the image has no
    ///   visible content, or the file cannot be written.
    @discardableResult
    func add(_ image: NSImage) throws -> SavedSignature {
        guard signatures.count < Self.maxSignatures else {
            throw SignatureStoreError.limitReached(Self.maxSignatures)
        }
        guard let trimmed = image.trimmedToContent(padding: Self.trimPadding) else {
            throw SignatureStoreError.emptyImage
        }
        guard let png = trimmed.pngData() else { throw SignatureStoreError.unreadableImage }

        try ensureDirectory()
        let url = directory.appending(path: "\(UUID().uuidString).png")
        guard FileManager.default.createFile(
            atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600]
        ) else { throw SignatureStoreError.writeFailed(directory.path) }

        let saved = SavedSignature(id: url.lastPathComponent, url: url, image: trimmed)
        signatures = [saved] + signatures
        return saved
    }

    /// Removes a signature's file. Moved to the Trash rather than unlinked, so
    /// an accidental ⌫ is recoverable from Finder.
    func delete(_ signature: SavedSignature) {
        let manager = FileManager.default
        if (try? manager.trashItem(at: signature.url, resultingItemURL: nil)) == nil {
            try? manager.removeItem(at: signature.url)
        }
        signatures = signatures.filter { $0.id != signature.id }
    }

    private func ensureDirectory() throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // createDirectory leaves an existing folder's mode alone; tighten it
            // in case an older build or the user created it more permissively.
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw SignatureStoreError.writeFailed(directory.path)
        }
    }
}

/// Why a signature could not be saved.
enum SignatureStoreError: Error, Equatable, LocalizedError {
    case limitReached(Int)
    case emptyImage
    case unreadableImage
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .limitReached(limit):
            return "You already have \(limit) saved signatures. Delete one you no longer use, then save again."
        case .emptyImage:
            return "The signature is blank. Draw, type, or import a signature first."
        case .unreadableImage:
            return "The signature image could not be converted to PNG. Try a different image."
        case let .writeFailed(path):
            return "The signature could not be saved to \(path). Check that the folder is writable and the disk has free space."
        }
    }
}

// MARK: - Image helpers

extension NSImage {

    /// PNG encoding of the image's best bitmap, preserving transparency.
    ///
    /// This is the bridge to `StampImageCommand(imagePNG:)`.
    func pngData() -> Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// The image cropped to the bounding box of its non-transparent pixels plus
    /// `padding`, or `nil` if every pixel is transparent.
    ///
    /// Trimming matters because the stamp is aspect-fitted into the user's
    /// box: stray empty canvas around the ink would make the signature render
    /// small and off-centre.
    func trimmedToContent(padding: Int, alphaThreshold: UInt8 = 8) -> NSImage? {
        guard let source = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bitmap = RGBABitmap(source)
        else { return nil }
        guard let box = bitmap.opaqueBounds(threshold: alphaThreshold) else { return nil }
        let padded = box.insetBy(dx: -CGFloat(padding), dy: -CGFloat(padding))
            .intersection(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        guard let cropped = bitmap.makeImage()?.cropping(to: padded) else { return nil }
        // Keep the original points-per-pixel ratio so a 2x render stays 2x.
        let scale = size.width > 0 ? CGFloat(source.width) / size.width : 1
        return NSImage(
            cgImage: cropped,
            size: CGSize(width: CGFloat(cropped.width) / scale, height: CGFloat(cropped.height) / scale)
        )
    }

    /// A copy with near-white pixels made transparent, for scanned or
    /// photographed signatures on paper. `nil` if the image cannot be read.
    func removingWhiteBackground(threshold: UInt8 = 225) -> NSImage? {
        guard let source = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bitmap = RGBABitmap(source)
        else { return nil }
        let cleared = bitmap.clearingPixels { r, g, b in r >= threshold && g >= threshold && b >= threshold }
        guard let image = cleared.makeImage() else { return nil }
        return NSImage(cgImage: image, size: size)
    }
}

/// A premultiplied RGBA8 copy of an image's pixels, top row first.
struct RGBABitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = Self.context(raw.baseAddress, width: width, height: height) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }

    private init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Bounding box of pixels with alpha above `threshold`, in top-left-origin
    /// pixel coordinates (the space `CGImage.cropping(to:)` uses).
    func opaqueBounds(threshold: UInt8) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let rowStart = y * width * 4
            for x in 0..<width where pixels[rowStart + x * 4 + 3] > threshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// A new bitmap with every pixel matching `predicate` (on un-premultiplied
    /// RGB) made fully transparent.
    func clearingPixels(where predicate: (UInt8, UInt8, UInt8) -> Bool) -> RGBABitmap {
        var output = pixels
        for offset in stride(from: 0, to: output.count, by: 4) {
            let alpha = output[offset + 3]
            guard alpha > 0 else { continue }
            let unpremultiply = { (value: UInt8) in UInt8(min(255, Int(value) * 255 / Int(alpha))) }
            if predicate(unpremultiply(output[offset]), unpremultiply(output[offset + 1]), unpremultiply(output[offset + 2])) {
                output.replaceSubrange(offset..<offset + 4, with: [0, 0, 0, 0])
            }
        }
        return RGBABitmap(width: width, height: height, pixels: output)
    }

    func makeImage() -> CGImage? {
        var copy = pixels
        return copy.withUnsafeMutableBytes { raw in
            Self.context(raw.baseAddress, width: width, height: height)?.makeImage()
        }
    }

    private static func context(_ data: UnsafeMutableRawPointer?, width: Int, height: Int) -> CGContext? {
        CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}
