import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: emlrender <input.eml|input.emlx> [output.html]\n".utf8)
    )
    exit(2)
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = CommandLine.arguments.count >= 3
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : URL(fileURLWithPath: "/tmp/emlquicklook-preview.html")

do {
    let raw = try Data(contentsOf: input)
    let messageData = EMLXMessage.messageData(from: raw)
    let message = MIMEParser.parse(messageData)
    let rendered = HTMLRenderer.render(
        message: message,
        fileName: input.lastPathComponent
    )
    let html = Data(rendered.html.utf8)
    try html.write(to: output, options: .atomic)

    print("input bytes:   \(raw.count)")
    print("message bytes: \(messageData.count)")
    print("title:         \(rendered.title)")
    print("summary:       \(rendered.summary)")
    print("html bytes:    \(html.count)")
    print("output:        \(output.path)")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
