import Compression
import Foundation

/// Reads the raw content-stream text out of a PDF.
///
/// This exists so tests can assert on the **emitted operators**, not just on
/// observed behaviour. There is a residual risk that a
/// third-party extractor might choose to skip text render mode 3; the defence
/// is to guarantee we actually emit the conventional `3 Tr` that Acrobat and
/// Tesseract also emit, and that guarantee needs a test that can see the bytes.
///
/// Deliberately minimal: enough to find an operator in a context *we* generated,
/// not a general PDF parser. The real object layer is `PDFCore`'s job.
public enum ContentStreamProbe {

    /// Returns every content stream in the file, inflated where possible,
    /// concatenated into one string.
    ///
    /// Streams that are not Flate-compressed (or fail to inflate) are included
    /// raw, since a `3 Tr` in an uncompressed stream should still be found.
    public static func decompressedStreams(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var result = ""

        for stream in rawStreams(in: data) {
            if let inflated = inflate(stream) {
                result += String(decoding: inflated, as: UTF8.self)
            } else {
                result += String(decoding: stream, as: UTF8.self)
            }
            result += "\n"
        }
        return result
    }

    // MARK: - Private

    /// Extracts the bytes between each `stream` / `endstream` keyword pair.
    private static func rawStreams(in data: Data) -> [Data] {
        let open = Data("stream".utf8)
        let close = Data("endstream".utf8)
        var streams: [Data] = []
        var index = data.startIndex

        while index < data.endIndex,
              let start = data.range(of: open, in: index..<data.endIndex) {
            // `endstream` also contains "stream", so searching from the end of
            // the opening keyword is what keeps the two from being confused.
            guard let end = data.range(of: close, in: start.upperBound..<data.endIndex) else {
                break
            }
            var payloadStart = start.upperBound
            // Skip the EOL that must follow the `stream` keyword (CR, LF, CRLF).
            if payloadStart < data.endIndex, data[payloadStart] == 0x0D { payloadStart += 1 }
            if payloadStart < data.endIndex, data[payloadStart] == 0x0A { payloadStart += 1 }

            if payloadStart < end.lowerBound {
                streams.append(data[payloadStart..<end.lowerBound])
            }
            index = end.upperBound
        }
        return streams
    }

    /// Inflates a raw-deflate or zlib stream, or returns nil.
    private static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        // PDF FlateDecode is zlib-wrapped; Compression's ZLIB algorithm expects
        // the raw deflate payload, so the 2-byte zlib header is skipped when
        // present (0x78 is the near-universal CMF byte).
        let payload = data.first == 0x78 ? data.dropFirst(2) : data[...]
        guard !payload.isEmpty else { return nil }

        let capacity = max(payload.count * 8, 64 * 1024)
        var output = Data(count: capacity)

        let written: Int = output.withUnsafeMutableBytes { outBuffer -> Int in
            guard let outBase = outBuffer.baseAddress else { return 0 }
            return payload.withUnsafeBytes { inBuffer -> Int in
                guard let inBase = inBuffer.baseAddress else { return 0 }
                return compression_decode_buffer(
                    outBase.assumingMemoryBound(to: UInt8.self), capacity,
                    inBase.assumingMemoryBound(to: UInt8.self), payload.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0 else { return nil }
        return output.prefix(written)
    }
}
