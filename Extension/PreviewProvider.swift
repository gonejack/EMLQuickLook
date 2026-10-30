import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import os

/// Data-based Quick Look preview for RFC 5322 `.eml` and Mail `.emlx` files.
///
/// Apple's `MailQuickLookExtension` passes the raw file bytes to
/// `MCMessage +messageWithRFC822Data:sanitizeData:` with `sanitizeData:NO`.
/// On macOS 27 that parser produces no MIME subparts for a CRLF message, so
/// Mail's Quick Look preview shows an empty body even though the message is
/// valid.  This extension parses and renders the message itself.
///
/// A nested `QLPreviewReply(fileURL:)` was tried first and does not invoke
/// another preview extension: Quick Look renders the referenced file with a
/// built-in generator instead.  Producing the HTML here is therefore the
/// reliable route.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    private static let logger = Logger(
        subsystem: "com.youi.EMLQuickLook",
        category: "preview"
    )

    func providePreview(
        for request: QLFilePreviewRequest
    ) async throws -> QLPreviewReply {
        let source = request.fileURL
        Self.logger.notice("preview request: \(source.path, privacy: .public)")

        let raw = try Data(contentsOf: source, options: .mappedIfSafe)
        let messageData = EMLXMessage.messageData(from: raw)
        let message = MIMEParser.parse(messageData)
        let rendered = HTMLRenderer.render(
            message: message,
            fileName: source.lastPathComponent
        )
        let htmlData = Data(rendered.html.utf8)

        Self.logger.notice(
            "rendered \(htmlData.count, privacy: .public) bytes of HTML from \(messageData.count, privacy: .public) message bytes (\(rendered.summary, privacy: .public))"
        )

        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 800, height: 600)
        ) { _ in
            htmlData
        }
        reply.title = rendered.title
        return reply
    }
}
