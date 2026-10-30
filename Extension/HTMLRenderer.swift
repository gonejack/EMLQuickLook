import Foundation

struct RenderedPreview {
    let title: String
    let html: String
    let summary: String
}

private struct InlineImage {
    let contentID: String
    let mimeType: String
    let data: Data
}

private struct AttachmentInfo {
    let name: String
    let byteCount: Int
}

enum HTMLRenderer {
    /// Base typography for HTML bodies.  These rules are inserted before the
    /// message's own styles so an email that sets its own font still wins.
    private static let htmlBaseCSSRules = """
    :root { color-scheme: light dark; }
    html { font-size: 12px; -webkit-text-size-adjust: 100%; }
    html, body { background-color: #ffffff; }
    body {
        margin: 0;
        padding: 15px 21px 24px 21px;
        font-family: Helvetica, Arial, sans-serif;
        font-size: 12px;
        line-height: normal;
    }
    a { color: #0e64d7; }
    img { max-width: 100%; height: auto; }
    a > img:not([style]) { display: block; margin-bottom: 8px; }
    /* Mail's share-page wrapper leaves one extra line of breathing room
       below the URL field. */
    .Apple-Mail-URLShareUserContentTopClass { margin-bottom: 12px; }

    /* Mail renders light message bodies on a dark page by inverting their
       lightness (its own style sheet uses
       `-apple-color-filter: apple-invert-lightness()` in dark mode).  WebKit
       does not expose that filter outside Mail, so reproduce it with a
       regular CSS inversion.  The hue rotation keeps blues blue; images get
       the same filter again so photos and screenshots keep their colors. */
    @media (prefers-color-scheme: dark) {
        html, body {
            background-color: #1e1e1f !important;
            color: #000000;
        }
        #emlql-content {
            -webkit-filter: invert(1) hue-rotate(180deg);
            filter: invert(1) hue-rotate(180deg);
        }
        #emlql-content img,
        #emlql-content video {
            -webkit-filter: invert(1) hue-rotate(180deg);
            filter: invert(1) hue-rotate(180deg);
        }
        a { color: #3483fa; }
    }
    """

    /// Header styling shared by HTML and plain-text previews.  The id keeps
    /// message rules such as `div { ... }` from changing the header.
    private static let headerCSSRules = """
    #emlql-header {
        margin: 0 -21px 5px 4px;
        padding: 1px 0 13px;
        border-bottom: 1px solid #e8e8e8;
        font: 12px/1.3 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
        color: #575757;
    }
    #emlql-header .emlql-top {
        display: flex;
        align-items: baseline;
        justify-content: space-between;
        gap: 12px;
    }
    #emlql-header .emlql-sender {
        font-size: 14px;
        font-weight: 600;
        line-height: 1.25;
        color: #575757;
        overflow-wrap: anywhere;
    }
    #emlql-header .emlql-date {
        flex: none;
        margin-right: 18px;
        font-size: 11px;
        line-height: 1.3;
        color: #808080;
        white-space: nowrap;
    }
    #emlql-header .emlql-subject {
        margin: 5px 0 0;
        font-size: 12px;
        line-height: 1.3;
        font-weight: 400;
        color: #575757;
    }
    #emlql-header .emlql-label {
        color: #575757;
    }
    #emlql-header .emlql-recipients {
        margin-top: 6px;
        font-size: 12px;
        line-height: 1.3;
        color: #808080;
    }
    #emlql-header .emlql-row { margin: 0; }
    @media (prefers-color-scheme: dark) {
        #emlql-header {
            color: #ebebeb;
            border-bottom-color: rgba(255, 255, 255, .115);
        }
        #emlql-header .emlql-sender,
        #emlql-header .emlql-subject,
        #emlql-header .emlql-label { color: #ebebeb; }
        #emlql-header .emlql-date,
        #emlql-header .emlql-recipients { color: #7c7c7c; }
    }
    /* A one-pixel separator keeps the message's own top margin from
       collapsing into the header margin. */
    #emlql-body-gap {
        height: 1px;
        margin: 0;
        padding: 0;
        border: 0;
        line-height: 0;
        font-size: 0;
    }
    """

    static func render(message: MIMEPart, fileName: String) -> RenderedPreview {
        let subject = decodedHeader(message, "Subject")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = subject.isEmpty ? fileName : subject
        let header = headerHTML(message)
        let attachments = attachmentListHTML(message)

        guard let body = findBody(in: message) else {
            let html = wrapPlainText(
                "This message does not contain a text body.",
                header: header,
                attachments: attachments
            )
            return RenderedPreview(title: title, html: html, summary: "no body")
        }

        if body.isHTML {
            let images = collectInlineImages(from: message)
            let embedded = embedInlineImages(in: body.text, images: images)
            var html = prepareHTMLDocument(embedded.html, header: header)
            if !attachments.isEmpty {
                html = insertBeforeBodyEnd(attachments, into: html)
            }
            return RenderedPreview(
                title: title,
                html: html,
                summary: "html body, \(countEmbeddedImages(in: html)) inline image(s)"
            )
        }

        let html = wrapPlainText(body.text, header: header, attachments: attachments)
        return RenderedPreview(title: title, html: html, summary: "plain text body")
    }

    // MARK: Body selection

    private static func findBody(in part: MIMEPart) -> (text: String, isHTML: Bool)? {
        if part.contentType.isMultipart {
            switch part.contentType.subtype {
            case "alternative":
                var plain: (text: String, isHTML: Bool)?
                var html: (text: String, isHTML: Bool)?
                for child in part.children {
                    guard let candidate = findBody(in: child) else { continue }
                    if candidate.isHTML {
                        html = candidate
                    } else if plain == nil {
                        plain = candidate
                    }
                }
                return html ?? plain

            case "related":
                var plain: (text: String, isHTML: Bool)?
                var html: (text: String, isHTML: Bool)?
                for child in part.children {
                    guard let candidate = findBody(in: child) else { continue }
                    if candidate.isHTML {
                        html = candidate
                    } else if plain == nil {
                        plain = candidate
                    }
                }
                return html ?? plain

            default:
                // Apple Mail's "share page" exporter can split an article
                // into a sequence of HTML fragments followed by the images
                // for each fragment.  Concatenating those fragments keeps
                // the whole body visible instead of returning only the
                // first chunk.
                if let sequence = mixedSequenceHTML(part) {
                    return (sequence, true)
                }

                var plain: (text: String, isHTML: Bool)?
                var html: (text: String, isHTML: Bool)?
                for child in part.children where !child.isAttachment {
                    guard let candidate = findBody(in: child) else { continue }
                    if candidate.isHTML {
                        html = candidate
                    } else if plain == nil {
                        plain = candidate
                    }
                }
                return html ?? plain
            }
        }

        if part.isAttachment { return nil }

        switch part.contentType.mimeType {
        case "text/html":
            let data = TransferDecoder.decode(part)
            return (
                TextDecoder.string(
                    from: data,
                    charset: part.contentType.charset,
                    sniffHTML: true
                ),
                true
            )
        case "text/plain":
            let data = TransferDecoder.decode(part)
            return (
                TextDecoder.string(
                    from: data,
                    charset: part.contentType.charset
                ),
                false
            )
        default:
            return nil
        }
    }

    /// Handles multipart/mixed bodies made of several text/html fragments,
    /// each optionally followed by the image part for the figure at the end
    /// of that fragment.
    private static func mixedSequenceHTML(_ part: MIMEPart) -> String? {
        let htmlChildren = part.children.filter {
            !$0.isAttachment && $0.contentType.mimeType == "text/html"
        }
        guard htmlChildren.count >= 2 else { return nil }

        struct Fragment {
            var body: String
            var styles: String
        }

        var fragments: [Fragment] = []
        var currentIndex: Int?

        for child in part.children {
            if !child.isAttachment, child.contentType.mimeType == "text/html" {
                let data = TransferDecoder.decode(child)
                let html = TextDecoder.string(
                    from: data,
                    charset: child.contentType.charset,
                    sniffHTML: true
                )
                fragments.append(
                    Fragment(
                        body: extractBodyContent(html),
                        styles: extractStyles(html)
                    )
                )
                currentIndex = fragments.count - 1
                continue
            }

            guard let index = currentIndex,
                  child.contentType.type == "image",
                  child.disposition != "attachment" else {
                continue
            }

            let data = TransferDecoder.decode(child)
            guard !data.isEmpty, data.count <= 12_000_000 else { continue }
            let dataURL = "data:\(child.contentType.mimeType);base64,\(data.base64EncodedString())"
            fragments[index].body = attachImage(dataURL, to: fragments[index].body)
        }

        guard !fragments.isEmpty else { return nil }
        let styles = fragments.map(\.styles).joined()
        let body = fragments.map(\.body).joined(separator: "\n")
        return "<!DOCTYPE html><html><head>\(styles)</head><body>\(body)</body></html>"
    }

    private static func extractBodyContent(_ html: String) -> String {
        guard let open = html.range(
            of: "<body[^>]*>",
            options: [.regularExpression, .caseInsensitive]
        ), let close = html.range(
            of: "</body>",
            options: [.caseInsensitive, .backwards]
        ), open.upperBound <= close.lowerBound else {
            return html
        }
        return String(html[open.upperBound..<close.lowerBound])
    }

    private static func extractStyles(_ html: String) -> String {
        var styles = ""
        let patterns = [
            "(?is)<style\\b[^>]*>.*?</style\\s*>",
            "(?is)<link\\b[^>]*rel\\s*=\\s*[\"']?stylesheet[\"']?[^>]*>",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(html.startIndex..., in: html)
            for match in regex.matches(in: html, range: range) {
                if let matchRange = Range(match.range, in: html) {
                    styles += String(html[matchRange])
                }
            }
        }
        return styles
    }

    private static func attachImage(_ dataURL: String, to html: String) -> String {
        let imageTag = """
        <img src="\(dataURL)" alt="" \
        style="display:block;max-width:100%;height:auto;margin:1em auto;">
        """
        let fallback = html + "<figure style=\"margin:1em 0;\">\(imageTag)</figure>"

        guard let regex = try? NSRegularExpression(
            pattern: "(?is)<a\\b[^>]*>\\s*</a>"
        ) else {
            return fallback
        }
        let matches = regex.matches(
            in: html,
            range: NSRange(html.startIndex..., in: html)
        )
        guard let last = matches.last, let range = Range(last.range, in: html) else {
            return fallback
        }

        var result = html
        result.replaceSubrange(range, with: imageTag)
        return result
    }

    // MARK: Inline images

    private static func collectInlineImages(from message: MIMEPart) -> [InlineImage] {
        var images: [InlineImage] = []
        var totalBytes = 0
        let maximumImageBytes = 12_000_000
        let maximumTotalBytes = 48_000_000

        func walk(_ part: MIMEPart) {
            if !part.contentType.isMultipart,
               let contentID = part.contentID,
               part.contentType.type == "image" {
                let data = TransferDecoder.decode(part)
                if !data.isEmpty,
                   data.count <= maximumImageBytes,
                   totalBytes + data.count <= maximumTotalBytes {
                    images.append(
                        InlineImage(
                            contentID: contentID,
                            mimeType: part.contentType.mimeType,
                            data: data
                        )
                    )
                    totalBytes += data.count
                }
            }
            for child in part.children {
                walk(child)
            }
        }

        walk(message)
        return images.sorted { $0.contentID.count > $1.contentID.count }
    }

    private static func embedInlineImages(
        in html: String,
        images: [InlineImage]
    ) -> (html: String, count: Int) {
        guard !html.isEmpty, !images.isEmpty else { return (html, 0) }

        var result = html
        var embeddedCount = 0
        for image in images {
            let dataURL = "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
            var candidates: Set<String> = [image.contentID]
            if let percentEncoded = image.contentID.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) {
                candidates.insert(percentEncoded)
            }

            var replaced = false
            for candidate in candidates.sorted(by: { $0.count > $1.count }) {
                let needle = "cid:" + candidate
                if result.contains(needle) {
                    result = result.replacingOccurrences(of: needle, with: dataURL)
                    replaced = true
                }
            }
            if replaced {
                embeddedCount += 1
            }
        }
        return (result, embeddedCount)
    }

    // MARK: HTML document handling

    private static func prepareHTMLDocument(_ html: String, header: String) -> String {
        var result = sanitizeHTML(html)
        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return wrapPlainText(
                "This message does not contain a readable HTML body.",
                header: "",
                attachments: ""
            )
        }

        let metadata = """
        <meta charset="utf-8">\
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; frame-src 'none';">\
        <meta name="viewport" content="width=device-width, initial-scale=1">\
        <style id="emlql-document-style">
        \(htmlBaseCSSRules)
        \(headerCSSRules)
        </style>
        """

        // Insert after the first available document anchor so the existing
        // doctype and document structure stay valid.  The message's own
        // styles come later and therefore override the base rules.
        var inserted = false
        for pattern in ["<head[^>]*>", "<html[^>]*>", "<!DOCTYPE[^>]*>"] {
            if let range = result.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) {
                result.insert(contentsOf: metadata, at: range.upperBound)
                inserted = true
                break
            }
        }
        if !inserted {
            result = metadata + result
        }

        result = insertHeader(header, into: result)
        return wrapMessageContent(in: result)
    }

    /// Wraps the message (everything after the Mail-style header) so dark mode
    /// can invert just the message colors and leave the header untouched.
    private static func wrapMessageContent(in html: String) -> String {
        let opening = "<div id=\"emlql-content\">"
        var result = html

        if let range = result.range(of: "<div id=\"emlql-body-gap\"></div>") {
            result.insert(contentsOf: opening, at: range.upperBound)
        } else if let range = result.range(
            of: "<body[^>]*>",
            options: [.regularExpression, .caseInsensitive]
        ) {
            result.insert(contentsOf: opening, at: range.upperBound)
        } else {
            result = opening + result
        }

        if let range = result.range(
            of: "</body>",
            options: [.caseInsensitive, .backwards]
        ) {
            result.insert(contentsOf: "</div>", at: range.lowerBound)
        } else {
            result += "</div>"
        }
        return result
    }

    private static func insertHeader(_ header: String, into html: String) -> String {
        guard !header.isEmpty else { return html }
        guard let range = html.range(
            of: "<body[^>]*>",
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return header + html
        }
        var result = html
        result.insert(contentsOf: header, at: range.upperBound)
        return result
    }

    private static func sanitizeHTML(_ html: String) -> String {
        var result = html
        let patterns: [(pattern: String, template: String)] = [
            ("(?is)<script\\b[^>]*>.*?</script\\s*>", ""),
            ("(?is)<script\\b[^>]*/?>", ""),
            ("(?is)<iframe\\b[^>]*>.*?</iframe\\s*>", ""),
            ("(?is)<object\\b[^>]*>.*?</object\\s*>", ""),
            ("(?is)<embed\\b[^>]*/?>", ""),
            ("(?is)<meta[^>]*http-equiv\\s*=\\s*[\"']?refresh[\"']?[^>]*>", ""),
            ("(?i)\\son[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", ""),
            ("(?i)(href|src)\\s*=\\s*([\"'])\\s*javascript:[^\"']*\\2", "$1=$2#$2"),
            ("(?i)(href|src)\\s*=\\s*javascript:[^\\s>]+", "$1=\"#\""),
        ]

        for item in patterns {
            guard let regex = try? NSRegularExpression(pattern: item.pattern) else {
                continue
            }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: item.template
            )
        }
        return result
    }

    private static func insertBeforeBodyEnd(_ snippet: String, into html: String) -> String {
        guard !snippet.isEmpty else { return html }
        // The message content is wrapped in `#emlql-content` for dark mode;
        // attachments belong inside that wrapper so they invert with the rest
        // of the body.
        if let range = html.range(
            of: "</div></body>",
            options: [.caseInsensitive, .backwards]
        ) {
            var result = html
            result.insert(contentsOf: snippet, at: range.lowerBound)
            return result
        }
        guard let range = html.range(
            of: "</body>",
            options: [.caseInsensitive, .backwards]
        ) else {
            return html + snippet
        }
        var result = html
        result.insert(contentsOf: snippet, at: range.lowerBound)
        return result
    }

    // MARK: Plain-text rendering

    private static func wrapPlainText(
        _ text: String,
        header: String,
        attachments: String
    ) -> String {
        let body = linkify(escapeHTML(text))
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; frame-src 'none';">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; }
        body {
            margin: 0;
            padding: 15px 21px 24px 21px;
            font: 12px/1.55 Helvetica, Arial, sans-serif;
            color: #000000;
            background: #ffffff;
            -webkit-text-size-adjust: 100%;
        }
        \(headerCSSRules)
        pre {
            margin: 0;
            white-space: pre-wrap;
            overflow-wrap: anywhere;
            font: 12px/1.6 ui-monospace, "SF Mono", Menlo, Consolas, monospace;
        }
        a { color: #0e64d7; }
        @media (prefers-color-scheme: dark) {
            body { color: #ffffff; background: #1c1c1d; }
            a { color: #3796f9; }
        }
        </style>
        </head>
        <body>
        \(header)
        <div id="emlql-content"><pre>\(body)</pre>
        \(attachments)</div>
        </body>
        </html>
        """
    }

    private static func headerHTML(_ message: MIMEPart) -> String {
        let subject = decodedHeader(message, "Subject")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let from = decodedHeader(message, "From")
        let to = decodedHeader(message, "To")
        let cc = decodedHeader(message, "Cc")
        let date = decodedHeader(message, "Date")

        guard !subject.isEmpty || !from.isEmpty || !to.isEmpty
            || !cc.isEmpty || !date.isEmpty else {
            return ""
        }

        var html = "<div id=\"emlql-header\">"

        // Mail puts the sender on the first line and the date at the far
        // right, then the subject, then the recipients.
        if !from.isEmpty || !date.isEmpty {
            html += "<div class=\"emlql-top\">"
            if from.isEmpty {
                html += "<span class=\"emlql-sender\"></span>"
            } else {
                html += "<span class=\"emlql-sender\">\(formatAddresses(from))</span>"
            }
            if !date.isEmpty {
                html += "<span class=\"emlql-date\">\(escapeHTML(displayDate(date)))</span>"
            }
            html += "</div>"
        }

        if !subject.isEmpty {
            html += "<div class=\"emlql-subject\">\(escapeHTML(subject))</div>"
        }

        if !to.isEmpty || !cc.isEmpty {
            html += "<div class=\"emlql-recipients\">"
            if !to.isEmpty {
                html += """
                <div class="emlql-row"><span class="emlql-label">\(escapeHTML(localizedLabel("To"))):</span> \
                \(formatAddresses(to))</div>
                """
            }
            if !cc.isEmpty {
                html += """
                <div class="emlql-row"><span class="emlql-label">\(escapeHTML(localizedLabel("Cc"))):</span> \
                \(formatAddresses(cc))</div>
                """
            }
            html += "</div>"
        }

        html += "</div>"
        html += "<div id=\"emlql-body-gap\"></div>"
        return html
    }

    /// Returns escaped text using Mail's `Name <address>` display form.
    private static func formatAddresses(_ raw: String) -> String {
        let addresses = splitAddressList(raw)
        guard !addresses.isEmpty else { return escapeHTML(raw) }

        return addresses.map { item in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let left = trimmed.firstIndex(of: "<"),
                  let right = trimmed.lastIndex(of: ">"),
                  left < right else {
                if trimmed.contains("@"), !trimmed.contains(" ") {
                    return "&lt;\(escapeHTML(trimmed))&gt;"
                }
                return escapeHTML(trimmed)
            }

            var name = String(trimmed[..<left])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let address = String(trimmed[trimmed.index(after: left)..<right])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Mail keeps the quotes from headers such as
            // `"youi" <zhongsiyuan@sunteng.com>`.
            name = name.replacingOccurrences(of: "\\\"", with: "\"")
            name = name.replacingOccurrences(of: "\\\\", with: "\\")

            if name.isEmpty || name.caseInsensitiveCompare(address) == .orderedSame {
                return "&lt;\(escapeHTML(address))&gt;"
            }
            return "\(escapeHTML(name)) &lt;\(escapeHTML(address))&gt;"
        }.joined(separator: ", ")
    }

    private static func splitAddressList(_ raw: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var angleDepth = 0
        var escaped = false

        for character in raw {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", inQuotes {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
                continue
            }
            if !inQuotes {
                if character == "<" { angleDepth += 1 }
                if character == ">" { angleDepth = max(0, angleDepth - 1) }
            }
            if character == ",", !inQuotes, angleDepth == 0 {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func displayDate(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm zzz",
        ]

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            parser.dateFormat = format
            guard let date = parser.date(from: value) else { continue }
            let output = DateFormatter()
            output.locale = Locale.current
            output.dateStyle = .medium
            output.timeStyle = .medium
            return output.string(from: date)
        }
        return value
    }

    private static func localizedLabel(_ key: String) -> String {
        let language = Locale.preferredLanguages.first ?? "en"
        guard language.hasPrefix("zh") else { return key }

        let traditional = language.contains("Hant")
            || language.hasPrefix("zh-TW")
            || language.hasPrefix("zh-HK")
            || language.hasPrefix("zh-MO")
        switch key {
        case "From":
            return traditional ? "寄件者" : "发件人"
        case "To":
            return traditional ? "收件者" : "收件人"
        case "Cc":
            return traditional ? "副本" : "抄送"
        case "Date":
            return "日期"
        default:
            return key
        }
    }

    private static func attachmentListHTML(_ message: MIMEPart) -> String {
        var items: [AttachmentInfo] = []

        func walk(_ part: MIMEPart) {
            if !part.contentType.isMultipart {
                let isSignature = part.contentType.mimeType == "application/pgp-signature"
                    || part.contentType.mimeType == "application/pkcs7-signature"
                if part.isAttachment, !isSignature {
                    items.append(
                        AttachmentInfo(
                            name: part.fileName ?? "Attachment",
                            byteCount: TransferDecoder.decode(part).count
                        )
                    )
                }
            }
            for child in part.children {
                walk(child)
            }
        }

        walk(message)
        guard !items.isEmpty else { return "" }

        let rows = items.map { item in
            """
            <li style="margin:4px 0;">\
            <span>\(escapeHTML(item.name))</span> \
            <span style="opacity:.55;white-space:nowrap;">(\(byteCount(item.byteCount)))</span>\
            </li>
            """
        }.joined()

        return """
        <div style="clear:both;margin:28px 0 8px;padding:16px 0 0;border-top:1px solid rgba(127,127,127,.35);font:13px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;color:inherit;">\
        <div style="font-weight:600;margin-bottom:8px;">Attachments</div>\
        <ul style="margin:0;padding-left:20px;">\(rows)</ul>\
        </div>
        """
    }

    // MARK: Small helpers

    private static func decodedHeader(_ message: MIMEPart, _ name: String) -> String {
        guard let value = message.header(name) else { return "" }
        return HeaderDecoder.decode(value)
    }

    private static func countEmbeddedImages(in html: String) -> Int {
        html.components(separatedBy: "data:image/").count - 1
    }

    private static func linkify(_ escapedText: String) -> String {
        let pattern = "https?://[^\\s<]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return escapedText
        }

        let nsText = escapedText as NSString
        let matches = regex.matches(
            in: escapedText,
            range: NSRange(location: 0, length: nsText.length)
        )
        guard !matches.isEmpty else { return escapedText }

        var output = ""
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                output += nsText.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
            }
            let url = nsText.substring(with: match.range)
            output += "<a href=\"\(url)\">\(url)</a>"
            cursor = match.range.location + match.range.length
        }
        if cursor < nsText.length {
            output += nsText.substring(
                with: NSRange(location: cursor, length: nsText.length - cursor)
            )
        }
        return output
    }

    private static func escapeHTML(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&#39;")
        return result
    }

    private static func byteCount(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(count))
    }
}
