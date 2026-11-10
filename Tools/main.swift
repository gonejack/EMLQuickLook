import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: emlrender <input.eml|input.emlx|input.eml.gz|input.eml.zst> [output.html]\n".utf8)
    )
    exit(2)
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = CommandLine.arguments.count >= 3
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : URL(fileURLWithPath: "/tmp/emlquicklook-preview.html")

do {
    let raw = try Data(contentsOf: input)
    let unpacked = try MessageData.unpack(raw, fileName: input.lastPathComponent)
    let rendered: RenderedPreview
    if unpacked.isCompressed,
       !MIMEParser.hasMessageHeaders(unpacked.messageData) {
        rendered = HTMLRenderer.renderArchiveNotice(
            fileName: input.lastPathComponent,
            format: unpacked.compression?.rawValue ?? "compressed",
            compressedBytes: raw.count,
            decompressedBytes: unpacked.expandedData.count
        )
    } else {
        let message = MIMEParser.parse(unpacked.messageData)
        rendered = HTMLRenderer.render(
            message: message,
            fileName: input.lastPathComponent
        )
    }
    let html = Data(rendered.html.utf8)
    try html.write(to: output, options: .atomic)

    print("input bytes:   \(raw.count)")
    print("compression:   \(unpacked.compression?.rawValue ?? "none")")
    print("message bytes: \(unpacked.messageData.count)")
    print("title:         \(rendered.title)")
    print("summary:       \(rendered.summary)")
    print("html bytes:    \(html.count)")
    print("output:        \(output.path)")
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
