import AppKit

/// Settings for the reply assist: which brain answers a double-tap.
/// Changes apply immediately and persist to config.json.
final class SettingsWindow: NSObject {

    private var window: NSWindow?
    private var config: Config
    private let onChange: (Config) -> Void

    private let backendPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")

    /// `onChange` receives the updated config after every edit.
    init(config: Config, onChange: @escaping (Config) -> Void) {
        self.config = config
        self.onChange = onChange
        super.init()
    }

    func show(config current: Config) {
        config = current
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = "Smriti Settings"
        win.isReleasedWhenClosed = false
        win.center()
        let content = NSView(frame: win.contentLayoutRect)

        func label(_ text: String, y: CGFloat) {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 13, weight: .medium)
            l.frame = NSRect(x: 24, y: y, width: 150, height: 20)
            content.addSubview(l)
        }

        label("Reply drafts by:", y: 156)
        backendPopup.frame = NSRect(x: 180, y: 152, width: 216, height: 26)
        backendPopup.addItems(withTitles: [
            "Auto — local when available", "Ollama (local only)", "Claude (subscription)",
        ])
        backendPopup.target = self
        backendPopup.action = #selector(changed)
        content.addSubview(backendPopup)

        label("Local model:", y: 120)
        modelPopup.frame = NSRect(x: 180, y: 116, width: 216, height: 26)
        modelPopup.target = self
        modelPopup.action = #selector(changed)
        content.addSubview(modelPopup)

        statusLabel.frame = NSRect(x: 24, y: 74, width: 372, height: 34)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        content.addSubview(statusLabel)

        let note = NSTextField(labelWithString:
            "Chronicles, tone learning, and meeting summaries always use Claude.\nMemory Q&A lives in Claude Desktop via MCP.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.frame = NSRect(x: 24, y: 20, width: 372, height: 34)
        note.maximumNumberOfLines = 2
        content.addSubview(note)

        win.contentView = content
        window = win
    }

    private func refresh() {
        switch config.assistBackend {
        case "ollama": backendPopup.selectItem(at: 1)
        case "claude": backendPopup.selectItem(at: 2)
        default: backendPopup.selectItem(at: 0)
        }

        let models = OllamaClient.listModels()
        modelPopup.removeAllItems()
        if models.isEmpty {
            modelPopup.addItem(withTitle: config.ollamaModel)
            modelPopup.isEnabled = false
            statusLabel.stringValue = "Ollama isn't running — start the Ollama app to use local models. Falling back to Claude."
        } else {
            modelPopup.addItems(withTitles: models)
            if !models.contains(config.ollamaModel) {
                modelPopup.addItem(withTitle: config.ollamaModel)
            }
            modelPopup.selectItem(withTitle: config.ollamaModel)
            modelPopup.isEnabled = config.assistBackend != "claude"
            statusLabel.stringValue = "Ollama running with \(models.count) model(s). Drafts stay on this Mac when a local model is used."
        }
    }

    @objc private func changed() {
        config.assistBackend = ["auto", "ollama", "claude"][max(0, backendPopup.indexOfSelectedItem)]
        if let title = modelPopup.titleOfSelectedItem {
            config.ollamaModel = title
        }
        try? config.save()
        refresh()
        onChange(config)
    }
}
