import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Where WhatsApp keeps downloaded media (`Message/` beside the chat database), and the
/// only place any tool here opens a file from.
///
/// A path is accepted only if, after `..` and symbolic links are resolved, it still sits
/// under this directory. WhatsApp's own rows are not trusted for that: a stored path with
/// `../` in it, or a link planted inside `Message/`, would otherwise let a media tool read
/// any file the user can. Files are only ever opened for reading.
public struct MediaFiles: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `Message/` for a container directory.
    public init(containerDirectory: URL) {
        self.root = containerDirectory.appendingPathComponent("Message")
    }

    /// The resolved URL when `candidate` exists and lies inside the root, nil otherwise.
    public func contained(_ candidate: String) -> URL? {
        Self.contained(candidate, in: root)
    }

    static func contained(_ candidate: String, in root: URL) -> URL? {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(resolvedRoot.path + "/"),
            FileManager.default.fileExists(atPath: resolved.path)
        else { return nil }
        return resolved
    }

    // MARK: Facts about a file

    public struct FileFacts: Sendable, Equatable {
        public var mimeType: String
        public var byteCount: Int64
        public var sha256: String
    }

    /// Size and SHA-256, hashed in chunks so a large video is never held in memory.
    public static func facts(of url: URL) throws -> FileFacts {
        try requireReadable(url)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            throw ViewError.unreadable("not a regular file")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FileFacts(mimeType: mimeType(of: url), byteCount: total, sha256: digest)
    }

    /// From the extension, because that is what WhatsApp names the file with; the bytes are
    /// not sniffed. Unknown extensions are reported as such, not guessed.
    public static func mimeType(of url: URL) -> String {
        UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType
            ?? "application/octet-stream"
    }

    // MARK: Viewing

    public enum ViewError: Error, Equatable {
        case unreadable(String)
        /// macOS refused to open the file; carries the path.
        case accessDenied(String)
        case tooLarge(Int64, limit: Int64)
        case tooManyPixels(Int, limit: Int)
        case locked
    }

    /// Larger than any photo or document WhatsApp lets through, small enough that a
    /// mislabelled file cannot make this process read gigabytes into memory.
    static let maximumDecodedFileBytes: Int64 = 100 * 1024 * 1024

    /// A regular file no larger than the limit. Fails closed: a file whose size cannot be
    /// read, or that is not a regular file (a FIFO would block a read forever), is refused.
    /// Every parser below would report a file macOS refused to open as "not an image" or
    /// "not a PDF", which sends the reader looking at the file instead of at the permission.
    static func requireReadable(_ url: URL) throws {
        if FileAccess.probe(url.path) == .denied { throw ViewError.accessDenied(url.path) }
    }

    private static func requireSize(_ url: URL) throws {
        try requireReadable(url)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true, let size = values.fileSize
        else { throw ViewError.unreadable("not a regular file") }
        if Int64(size) > maximumDecodedFileBytes {
            throw ViewError.tooLarge(Int64(size), limit: maximumDecodedFileBytes)
        }
    }

    /// An interlaced PNG has to be decoded whole to be reduced, so a small file can still
    /// need gigabytes. The pixel count comes from the header, before any decoding.
    public static let maximumPixels = 100_000_000

    /// The longest side an image is reduced to. A model reading a photo gains nothing from
    /// more, and the encoded size is what the client has to carry.
    public static let maximumImageSide = 1568
    static let maximumImageBytes = 1_500_000

    /// A JPEG of the image, reduced to `maximumImageSide` and flattened onto white so a
    /// sticker's transparency does not turn black. First frame only for a GIF.
    public static func jpegData(of url: URL, maxPixels: Int = maximumPixels) throws -> Data {
        try requireSize(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ViewError.unreadable("not an image this Mac can decode")
        }
        // No dimensions means no way to know what decoding would cost, so refuse.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ViewError.unreadable("the image's dimensions cannot be read") }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        if overflow || pixels > maxPixels {
            throw ViewError.tooManyPixels(overflow ? Int.max : pixels, limit: maxPixels)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumImageSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw ViewError.unreadable("the image could not be decoded") }
        return try encodeJPEG(flattened(image))
    }

    static func encodeJPEG(_ image: CGImage) throws -> Data {
        for quality in [0.8, 0.6, 0.4, 0.25] {
            let output = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    output, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw ViewError.unreadable("no JPEG encoder") }
            CGImageDestinationAddImage(
                destination, image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ViewError.unreadable("the image could not be encoded")
            }
            if output.length <= maximumImageBytes || quality == 0.25 { return output as Data }
        }
        throw ViewError.unreadable("the image could not be encoded")
    }

    private static func flattened(_ image: CGImage) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ViewError.unreadable("no drawing context") }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else {
            throw ViewError.unreadable("the image could not be flattened")
        }
        return result
    }

    public struct PDFText: Sendable, Equatable {
        public var text: String
        public var pageCount: Int
        public var truncated: Bool
    }

    /// The text layer of a PDF. A scan has none, and that is reported, not hidden: an
    /// empty string with `pageCount > 0` means "no text layer", not "no content".
    public static func pdfText(of url: URL, maxCharacters: Int = 60_000) throws -> PDFText {
        try requireSize(url)
        guard let document = PDFDocument(url: url) else {
            throw ViewError.unreadable("not a PDF this Mac can open")
        }
        if document.isLocked { throw ViewError.locked }
        // Page by page and stopping at the limit: `document.string` extracts every page
        // first, which for a few thousand pages is gigabytes and many seconds to return
        // sixty thousand characters.
        var collected = ""
        var stoppedEarly = false
        for index in 0..<document.pageCount {
            collected += document.page(at: index)?.string ?? ""
            if collected.count >= maxCharacters {
                stoppedEarly = index < document.pageCount - 1
                break
            }
        }
        let truncated = collected.count > maxCharacters || stoppedEarly
        return PDFText(
            text: collected.count > maxCharacters ? String(collected.prefix(maxCharacters)) : collected,
            pageCount: document.pageCount, truncated: truncated)
    }

    /// Plain text from a text document, decoded as UTF-8 only.
    public static func plainText(of url: URL, maxCharacters: Int = 60_000) throws -> PDFText {
        try requireSize(url)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ViewError.unreadable("not UTF-8 text")
        }
        let truncated = text.count > maxCharacters
        return PDFText(
            text: truncated ? String(text.prefix(maxCharacters)) : text, pageCount: 1,
            truncated: truncated)
    }

    /// Evenly spaced still frames from a video, as JPEGs.
    public static func keyFrames(of url: URL, count: Int) async throws -> (
        frames: [Data], durationSeconds: Double
    ) {
        try requireSize(url)
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do { duration = try await asset.load(.duration) } catch {
            throw ViewError.unreadable("not a video this Mac can open")
        }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else {
            throw ViewError.unreadable("the video has no duration")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumImageSide, height: maximumImageSide)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        var frames: [Data] = []
        for index in 0..<count {
            // Centre of each of `count` equal slices, so the first and last frames are
            // not the black lead-in and the fade-out.
            let time = CMTime(seconds: seconds * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
            do {
                let (image, _) = try await generator.image(at: time)
                frames.append(try encodeJPEG(flattened(image)))
            } catch let failure as ViewError {
                throw failure
            } catch {
                throw ViewError.unreadable("a frame could not be decoded (\(error.localizedDescription))")
            }
        }
        return (frames, seconds)
    }
}
