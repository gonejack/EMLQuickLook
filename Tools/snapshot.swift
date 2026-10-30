import AppKit
import WebKit

final class Snapshotter: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let output: URL
    private let width: CGFloat = 1000
    private var window: NSWindow!

    init(input: URL, output: URL) {
        self.output = output
        let configuration = WKWebViewConfiguration()
        self.webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: width, height: 1200),
            configuration: configuration
        )
        super.init()
        self.webView.navigationDelegate = self

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 1200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFront(nil)
        webView.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            webView.evaluateJavaScript(
                "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)"
            ) { result, _ in
                let reported = (result as? NSNumber)?.doubleValue ?? 1200
                let height = min(max(900, reported), 4000)
                let size = NSSize(width: self.width, height: height)
                webView.setFrameSize(size)
                self.window.setContentSize(size)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let configuration = WKSnapshotConfiguration()
                    configuration.rect = NSRect(origin: .zero, size: size)
                    webView.takeSnapshot(with: configuration) { image, error in
                        guard let image = image,
                              let tiff = image.tiffRepresentation,
                              let bitmap = NSBitmapImageRep(data: tiff),
                              let png = bitmap.representation(using: .png, properties: [:]) else {
                            FileHandle.standardError.write(
                                Data("snapshot failed: \(String(describing: error))\n".utf8)
                            )
                            NSApp.terminate(nil)
                            return
                        }
                        do {
                            try png.write(to: self.output)
                            print("wrote \(self.output.path) (\(Int(size.width))x\(Int(size.height)))")
                        } catch {
                            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
                        }
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
}

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write(
        Data("usage: emlsnapshot <input.html> <output.png>\n".utf8)
    )
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let snapshotter = Snapshotter(input: input, output: output)
withExtendedLifetime(snapshotter) {
    app.run()
}
