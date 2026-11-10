import CoreFoundation
import CZstd
import Foundation
import zlib

// MARK: - MIME model

struct MIMEHeader {
    let name: String
    let value: String
}

extension Array where Element == MIMEHeader {
    func firstValue(for name: String) -> String? {
        for header in self where header.name.caseInsensitiveCompare(name) == .orderedSame {
            return header.value
        }
        return nil
    }
}

struct MIMEContentType {
    var type = "text"
    var subtype = "plain"
    var parameters: [String: String] = [:]

    var mimeType: String { "\(type)/\(subtype)" }
    var isMultipart: Bool { type == "multipart" }
    var charset: String? { parameters["charset"] }
    var boundary: String? { parameters["boundary"] }
    var name: String? { parameters["name"] }

    static func parse(_ raw: String) -> MIMEContentType {
        let segments = MIMEParameters.split(raw)
        guard let first = segments.first else { return MIMEContentType() }

        let mime = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pieces = mime.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        var result = MIMEContentType()
        if pieces.count == 2 {
            result.type = String(pieces[0])
            result.subtype = String(pieces[1])
        } else if !mime.isEmpty {
            result.type = mime
            result.subtype = ""
        }
        result.parameters = MIMEParameters.parse(segments.dropFirst())
        return result
    }
}

enum MIMEParameters {
    /// Splits a structured header on semicolons while respecting quoted values.
    static func split(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false

        for character in raw {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", inQuotes {
                escaped = true
                current.append(character)
                continue
            }
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
                continue
            }
            if character == ";", !inQuotes {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        parts.append(current)
        return parts
    }

    static func parse(_ segments: ArraySlice<String>) -> [String: String] {
        var result: [String: String] = [:]
        for segment in segments {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            var key = String(segment[..<equals])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            var value = String(segment[segment.index(after: equals)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
                value = value.replacingOccurrences(of: "\\\"", with: "\"")
                value = value.replacingOccurrences(of: "\\\\", with: "\\")
            }
            if key.hasSuffix("*") {
                key = String(key.dropLast())
                value = decodeExtendedValue(value)
            }
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    /// Decodes the common `charset'language'percent-encoded` form from RFC 2231.
    private static func decodeExtendedValue(_ value: String) -> String {
        let components = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        let encoded = components.count == 3 ? String(components[2]) : value
        return encoded.removingPercentEncoding ?? encoded
    }
}

struct MIMEPart {
    let headers: [MIMEHeader]
    let body: Data
    let contentType: MIMEContentType
    let children: [MIMEPart]

    func header(_ name: String) -> String? {
        headers.firstValue(for: name)
    }

    var transferEncoding: String {
        (header("Content-Transfer-Encoding") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var contentID: String? {
        guard var value = header("Content-ID")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("<") { value.removeFirst() }
        if value.hasSuffix(">") { value.removeLast() }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var disposition: String {
        guard let raw = header("Content-Disposition") else { return "" }
        return MIMEParameters.split(raw)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    var fileName: String? {
        if let name = contentType.parameters["name"], !name.isEmpty {
            return HeaderDecoder.decode(name)
        }
        guard let raw = header("Content-Disposition") else { return nil }
        let segments = MIMEParameters.split(raw)
        let parameters = MIMEParameters.parse(segments.dropFirst())
        guard let name = parameters["filename"], !name.isEmpty else { return nil }
        return HeaderDecoder.decode(name)
    }

    var isAttachment: Bool {
        if disposition == "attachment" { return true }
        guard let name = fileName, !name.isEmpty, contentID == nil else {
            return false
        }
        // Inline images without a Content-ID are body content in messages
        // exported as a sequence of HTML fragments and images.
        if contentType.type == "image" { return false }
        return contentType.type != "text"
    }
}

// MARK: - MIME parsing

enum MIMEParser {
    /// A cheap check used for gzip containers, where arbitrary `.gz` files are
    /// also routed to this extension by Quick Look.  True when the bytes start
    /// with a plausible RFC 5322 header block.
    static func hasMessageHeaders(_ data: Data) -> Bool {
        let split = splitHeaderBody(normalizeNewlines(data))
        guard !split.header.isEmpty else { return false }
        return !parseHeaders(split.header).isEmpty
    }

    static func parse(_ data: Data, depth: Int = 0) -> MIMEPart {
        let normalized = normalizeNewlines(data)
        let split = splitHeaderBody(normalized)
        let headers = parseHeaders(split.header)
        let contentType = MIMEContentType.parse(
            headers.firstValue(for: "Content-Type") ?? "text/plain"
        )

        var children: [MIMEPart] = []
        if depth < 32,
           contentType.isMultipart,
           let boundary = contentType.boundary,
           !boundary.isEmpty {
            for child in MultipartSplitter.split(split.body, boundary: boundary) {
                children.append(parse(child, depth: depth + 1))
            }
        }

        return MIMEPart(
            headers: headers,
            body: split.body,
            contentType: contentType,
            children: children
        )
    }

    private static func normalizeNewlines(_ data: Data) -> Data {
        guard data.contains(0x0d) else { return data }

        var result: [UInt8] = []
        result.reserveCapacity(data.count)
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            if byte == 0x0d {
                result.append(0x0a)
                let next = data.index(after: index)
                if next < data.endIndex, data[next] == 0x0a {
                    index = next
                }
            } else {
                result.append(byte)
            }
            index = data.index(after: index)
        }
        return Data(result)
    }

    /// Splits a message into header and body blocks.  A blank first line or a
    /// first line that does not look like a header means the whole input is
    /// treated as a body, which keeps plain-text fallbacks readable.
    private static func splitHeaderBody(_ data: Data) -> (header: Data, body: Data) {
        guard let separator = data.range(of: Data([0x0a, 0x0a])) else {
            return (Data(), data)
        }

        let candidate = data[data.startIndex..<separator.lowerBound]
        let firstLineEnd = candidate.firstIndex(of: 0x0a) ?? candidate.endIndex
        let firstLine = String(decoding: candidate[..<firstLineEnd], as: UTF8.self)
        guard let colon = firstLine.firstIndex(of: ":"), colon != firstLine.startIndex else {
            return (Data(), data)
        }
        let name = firstLine[..<colon]
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return (Data(), data)
        }
        return (Data(candidate), Data(data[separator.upperBound...]))
    }

    private static func parseHeaders(_ data: Data) -> [MIMEHeader] {
        guard !data.isEmpty else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        var result: [MIMEHeader] = []
        var currentName: String?
        var currentValue = ""

        func flush() {
            if let name = currentName {
                result.append(MIMEHeader(name: name, value: currentValue))
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.first == " " || line.first == "\t" {
                let continuation = line.trimmingCharacters(in: .whitespaces)
                if !continuation.isEmpty {
                    currentValue += (currentValue.isEmpty ? "" : " ") + continuation
                }
                continue
            }

            flush()
            guard let colon = line.firstIndex(of: ":") else {
                currentName = nil
                currentValue = ""
                continue
            }
            currentName = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            currentValue = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        flush()
        return result
    }
}

enum MultipartSplitter {
    static func split(_ body: Data, boundary: String) -> [Data] {
        let marker = "--" + boundary
        var parts: [Data] = []
        var partStart: Data.Index?
        var lineStart = body.startIndex

        while lineStart < body.endIndex {
            var lineEnd = lineStart
            while lineEnd < body.endIndex, body[lineEnd] != 0x0a {
                lineEnd = body.index(after: lineEnd)
            }

            var contentEnd = lineEnd
            if contentEnd > lineStart, body[body.index(before: contentEnd)] == 0x0d {
                contentEnd = body.index(before: contentEnd)
            }
            let line = String(decoding: body[lineStart..<contentEnd], as: UTF8.self)

            if line.hasPrefix(marker) {
                let rest = line.dropFirst(marker.count)
                let isClose = rest.hasPrefix("--")
                let padding = isClose ? rest.dropFirst(2) : rest
                let isDelimiter = padding.allSatisfy { $0 == " " || $0 == "\t" }

                if isDelimiter {
                    if let start = partStart {
                        var end = lineStart
                        if end > start, body[body.index(before: end)] == 0x0a {
                            end = body.index(before: end)
                        }
                        if end > start, body[body.index(before: end)] == 0x0d {
                            end = body.index(before: end)
                        }
                        parts.append(Data(body[start..<end]))
                    }

                    if isClose {
                        partStart = nil
                        break
                    }
                    partStart = lineEnd < body.endIndex
                        ? body.index(after: lineEnd)
                        : body.endIndex
                }
            }

            lineStart = lineEnd < body.endIndex
                ? body.index(after: lineEnd)
                : body.endIndex
        }

        if let start = partStart, start < body.endIndex {
            parts.append(Data(body[start..<body.endIndex]))
        }
        return parts
    }
}

// MARK: - Transfer and text decoding

enum TransferDecoder {
    static func decode(_ part: MIMEPart) -> Data {
        switch part.transferEncoding {
        case "base64":
            return decodeBase64(part.body)
        case "quoted-printable":
            return decodeQuotedPrintable(part.body)
        default:
            return part.body
        }
    }

    private static func decodeBase64(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        guard let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters),
              !decoded.isEmpty else {
            return data
        }
        return decoded
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3d { // "="
                if index + 1 < bytes.count, bytes[index + 1] == 0x0a {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count,
                   let high = hexValue(bytes[index + 1]),
                   let low = hexValue(bytes[index + 2]) {
                    output.append((high << 4) | low)
                    index += 3
                    continue
                }
            }
            output.append(byte)
            index += 1
        }
        return Data(output)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}

enum TextDecoder {
    static func string(from data: Data, charset: String?, sniffHTML: Bool = false) -> String {
        var names: [String] = []
        if let charset = charset?.trimmingCharacters(in: .whitespacesAndNewlines),
           !charset.isEmpty {
            names.append(charset)
        } else if sniffHTML, let sniffed = sniffHTMLCharset(data) {
            names.append(sniffed)
        }

        for name in names {
            if let encoding = encoding(forIANA: name),
               let string = String(data: data, encoding: encoding) {
                return string
            }
        }

        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let encoding = encoding(forIANA: "gb18030"),
           let string = String(data: data, encoding: encoding) {
            return string
        }
        if let string = String(data: data, encoding: .windowsCP1252) {
            return string
        }
        if let string = String(data: data, encoding: .isoLatin1) {
            return string
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func encoding(forIANA name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        guard nsEncoding != 0 else { return nil }
        return String.Encoding(rawValue: nsEncoding)
    }

    private static func sniffHTMLCharset(_ data: Data) -> String? {
        let prefixData = data.prefix(4096)
        let prefix = String(decoding: prefixData, as: UTF8.self)
        let pattern = "(?i)charset\\s*=\\s*[\"']?([a-z0-9._-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: prefix,
                range: NSRange(prefix.startIndex..., in: prefix)
              ),
              let range = Range(match.range(at: 1), in: prefix) else {
            return nil
        }
        return String(prefix[range])
    }
}

enum HeaderDecoder {
    private static let encodedWordPattern = "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?="

    static func decode(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        guard let regex = try? NSRegularExpression(pattern: encodedWordPattern) else {
            return value
        }

        let nsValue = value as NSString
        let matches = regex.matches(
            in: value,
            range: NSRange(location: 0, length: nsValue.length)
        )
        guard !matches.isEmpty else { return value }

        var output = ""
        var cursor = 0
        var previousWasEncodedWord = false
        for match in matches {
            if match.range.location > cursor {
                let between = nsValue.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
                // RFC 2047: whitespace between two adjacent encoded words is
                // not part of the decoded text.  Mail renders the split
                // subject "...初" + "之音" as "...初之音", without a space.
                if !(previousWasEncodedWord
                    && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    output += between
                }
            }

            let charset = nsValue.substring(with: match.range(at: 1))
            let encoding = nsValue.substring(with: match.range(at: 2)).lowercased()
            let text = nsValue.substring(with: match.range(at: 3))
            if let decoded = decodeWord(text, encoding: encoding, charset: charset) {
                output += decoded
                previousWasEncodedWord = true
            } else {
                output += nsValue.substring(with: match.range)
                previousWasEncodedWord = false
            }
            cursor = match.range.location + match.range.length
        }

        if cursor < nsValue.length {
            output += nsValue.substring(
                with: NSRange(location: cursor, length: nsValue.length - cursor)
            )
        }
        return output
    }

    private static func decodeWord(
        _ text: String,
        encoding: String,
        charset: String
    ) -> String? {
        let data: Data
        switch encoding {
        case "b":
            guard let decoded = Data(
                base64Encoded: text,
                options: .ignoreUnknownCharacters
            ) else {
                return nil
            }
            data = decoded
        case "q":
            let replaced = text.replacingOccurrences(of: "_", with: " ")
            data = TransferDecoder.decodeQuotedPrintable(Data(replaced.utf8))
        default:
            return nil
        }
        return TextDecoder.string(from: data, charset: charset)
    }
}

// MARK: - Message data

enum MessageCompression: String {
    case gzip
    case zstd
}

struct UnpackedMessage {
    /// Inflated bytes, before any `.emlx` envelope is removed.
    let expandedData: Data
    /// RFC 5322 bytes ready for the MIME parser.
    let messageData: Data
    let compression: MessageCompression?

    var isCompressed: Bool { compression != nil }
}

enum MessageData {
    /// Unwraps a gzip or zstd container (`.eml.gz` / `.eml.zst`) and then an
    /// optional `.emlx` envelope.
    static func unpack(
        _ data: Data,
        fileName: String? = nil
    ) throws -> UnpackedMessage {
        let compression: MessageCompression?
        let expanded: Data

        if GzipDecoder.isGzip(data) {
            compression = .gzip
            expanded = try GzipDecoder.decompress(data)
        } else if ZstdDecoder.isZstd(data) {
            compression = .zstd
            expanded = try ZstdDecoder.decompress(data)
        } else if fileName?.lowercased().hasSuffix(".gz") == true {
            compression = .gzip
            expanded = try GzipDecoder.decompress(data)
        } else if let name = fileName?.lowercased(),
                  name.hasSuffix(".zst") || name.hasSuffix(".zstd") {
            compression = .zstd
            expanded = try ZstdDecoder.decompress(data)
        } else {
            compression = nil
            expanded = data
        }

        return UnpackedMessage(
            expandedData: expanded,
            messageData: EMLXMessage.messageData(from: expanded),
            compression: compression
        )
    }
}

// MARK: - Compression limits

enum DecompressionLimits {
    /// A compressed message can expand enormously.  Keep a preview from
    /// consuming unbounded memory while still allowing large mail archives.
    static let maximumBytes = 512 * 1024 * 1024
}

enum CompressionError: LocalizedError {
    case invalidArchive(MessageCompression)
    case truncated(MessageCompression)
    case decompressionFailed(MessageCompression, String)
    case tooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let format):
            return "The \(format.rawValue) archive is invalid."
        case .truncated(let format):
            return "The \(format.rawValue) archive is truncated."
        case .decompressionFailed(let format, let detail):
            return "The \(format.rawValue) archive could not be decompressed (\(detail))."
        case .tooLarge(let maximumBytes):
            let limit = ByteCountFormatter.string(
                fromByteCount: Int64(maximumBytes),
                countStyle: .file
            )
            return "The decompressed message is larger than \(limit)."
        }
    }
}

// MARK: - Gzip

enum GzipDecoder {
    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2
            && data[data.startIndex] == 0x1f
            && data[data.index(after: data.startIndex)] == 0x8b
    }

    /// Inflates a gzip stream with zlib's automatic gzip-header handling.
    /// zlib also verifies the CRC and uncompressed length stored in the
    /// gzip trailer.
    static func decompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            15 + 16,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw CompressionError.decompressionFailed(
                .gzip,
                "zlib error \(initStatus)"
            )
        }
        defer { inflateEnd(&stream) }

        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var output = Data()
        var inputOffset = 0
        var reachedEnd = false

        try data.withUnsafeBytes { rawBuffer in
            guard let input = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                throw CompressionError.invalidArchive(.gzip)
            }

            while !reachedEnd {
                if stream.avail_in == 0, inputOffset < data.count {
                    let remaining = data.count - inputOffset
                    let chunk = min(remaining, Int(UInt32.max))
                    stream.next_in = UnsafeMutablePointer(mutating: input.advanced(by: inputOffset))
                    stream.avail_in = uInt(chunk)
                    inputOffset += chunk
                }

                let availableBefore = stream.avail_in
                let status = buffer.withUnsafeMutableBytes { outputBuffer in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    guard output.count <= DecompressionLimits.maximumBytes - produced else {
                        throw CompressionError.tooLarge(
                            maximumBytes: DecompressionLimits.maximumBytes
                        )
                    }
                    output.append(contentsOf: buffer[0..<produced])
                }

                switch status {
                case Z_OK:
                    let consumed = Int(availableBefore) - Int(stream.avail_in)
                    if produced == 0, consumed == 0 {
                        if inputOffset >= data.count {
                            throw CompressionError.truncated(.gzip)
                        }
                        throw CompressionError.decompressionFailed(
                            .gzip,
                            "zlib error \(status)"
                        )
                    }
                case Z_STREAM_END:
                    reachedEnd = true
                case Z_BUF_ERROR:
                    throw inputOffset >= data.count
                        ? CompressionError.truncated(.gzip)
                        : CompressionError.decompressionFailed(.gzip, "zlib error \(status)")
                default:
                    throw CompressionError.decompressionFailed(
                        .gzip,
                        "zlib error \(status)"
                    )
                }
            }
        }

        return output
    }
}

// MARK: - Zstandard

enum ZstdDecoder {
    private static let frameMagic: UInt32 = 0xFD2FB528
    private static let skippableMagic: UInt32 = 0x184D2A50
    private static let skippableMask: UInt32 = 0xFFFFFFF0

    static func isZstd(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }

        var magic: UInt32 = 0
        for offset in 0..<4 {
            magic |= UInt32(data[data.startIndex + offset]) << (8 * UInt32(offset))
        }
        return magic == frameMagic
            || (magic & skippableMask) == skippableMagic
    }

    static func decompress(_ data: Data) throws -> Data {
        guard let stream = ZSTD_createDStream() else {
            throw CompressionError.invalidArchive(.zstd)
        }
        defer { _ = ZSTD_freeDStream(stream) }
        let initStatus = ZSTD_initDStream(stream)
        if ZSTD_isError(initStatus) != 0 {
            throw CompressionError.decompressionFailed(
                .zstd,
                "zstd error \(initStatus)"
            )
        }

        let chunkSize = 128 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var output = Data()
        var finished = false

        try data.withUnsafeBytes { rawBuffer in
            var input = ZSTD_inBuffer(
                src: rawBuffer.baseAddress,
                size: data.count,
                pos: 0
            )

            while !finished {
                var outputBuffer = ZSTD_outBuffer()
                let beforeInput = input.pos
                var produced = 0
                let status = buffer.withUnsafeMutableBytes { rawOutput in
                    outputBuffer.dst = rawOutput.baseAddress
                    outputBuffer.size = chunkSize
                    outputBuffer.pos = 0
                    let status = ZSTD_decompressStream(stream, &outputBuffer, &input)
                    produced = Int(outputBuffer.pos)
                    return status
                }

                if ZSTD_isError(status) != 0 {
                    throw CompressionError.decompressionFailed(
                        .zstd,
                        "zstd error \(status)"
                    )
                }

                if produced > 0 {
                    guard output.count <= DecompressionLimits.maximumBytes - produced else {
                        throw CompressionError.tooLarge(
                            maximumBytes: DecompressionLimits.maximumBytes
                        )
                    }
                    output.append(contentsOf: buffer[0..<produced])
                }

                if status == 0 {
                    if input.pos == input.size {
                        finished = true
                    }
                    continue
                }

                // A positive status means the frame needs more input or the
                // decoder's internal output buffer flushed.  A full output
                // buffer is normal progress and is drained on the next pass.
                if produced == chunkSize {
                    continue
                }
                if input.pos == input.size {
                    throw CompressionError.truncated(.zstd)
                }
                if produced == 0, input.pos == beforeInput {
                    throw CompressionError.decompressionFailed(
                        .zstd,
                        "decoder made no progress"
                    )
                }
            }
        }

        return output
    }
}

// MARK: - EMLX

enum EMLXMessage {
    /// An `.emlx` file starts with the decimal byte length of the RFC 5322
    /// message followed by a newline, then the message, then a property list.
    static func messageData(from data: Data) -> Data {
        guard let newline = data.firstIndex(of: 0x0a) else { return data }
        let firstLine = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let length = Int(firstLine), length > 0 else { return data }

        let start = data.index(after: newline)
        guard let end = data.index(start, offsetBy: length, limitedBy: data.endIndex) else {
            return data
        }
        return Data(data[start..<end])
    }
}
