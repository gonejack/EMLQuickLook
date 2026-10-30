import AppKit
import QuickLookUI

final class PreviewWindow: NSWindow, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var previewURL: URL?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: PreviewWindow!
    private var panel: QLPreviewPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = PreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "EML Quick Look"
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        let label = NSTextField(labelWithString: "Quick Look extension host")
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
        ])

        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--preview"), index + 1 < arguments.count {
            window.previewURL = URL(fileURLWithPath: arguments[index + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showPreviewPanel()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                self.panel?.orderOut(nil)
                NSApp.terminate(nil)
            }
        }
    }

    private func showPreviewPanel() {
        guard let panel = QLPreviewPanel.shared() else { return }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
