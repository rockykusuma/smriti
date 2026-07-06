import AppKit
import Security

// MARK: - Settings

final class SettingsSection: NSObject, MainSection {
    let title = "Settings"
    let symbol = "gearshape"
    private var config: Config
    private let onChange: (Config) -> Void
    private var view: NSView?

    private let backendPopup = NSPopUpButton()
    private let providerPopup = NSPopUpButton()
    private let providerLabel = NSTextField(labelWithString: "Cloud provider")
    private let modelLabel = NSTextField(labelWithString: "Model")
    private let modelPopup = NSPopUpButton()
    private let apiKeyLabel = NSTextField(labelWithString: "API key")
    private let apiKeyField = NSSecureTextField()
    private let apiKeySaveButton = NSButton()
    private let apiKeyStatusLabel = NSTextField(labelWithString: "")
    private var apiKeyRow: NSStackView?
    private let redactCheckbox = NSButton()
    private let autoRecordCheckbox = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let loginStatusLabel = NSTextField(labelWithString: "")
    private let loginButton = NSButton()
    private let appearanceControl = NSSegmentedControl(
        labels: ["System", "Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil)

    init(config: Config, onChange: @escaping (Config) -> Void) {
        self.config = config
        self.onChange = onChange
    }

    func makeView() -> NSView {
        if let view { return view }
        let heading = NSTextField(labelWithString: "Settings")
        heading.font = Theme.serif(26, .semibold)
        heading.textColor = Theme.ink

        // Section: Appearance
        let appearanceHeader = makeSectionHeader("APPEARANCE")
        let appearanceCard = makeAppearanceCard()

        // Section: AI Backend
        let backendHeader = makeSectionHeader("AI BACKEND")
        let backendCard = makeBackendCard()

        // Section: Privacy & Recording
        let privacyHeader = makeSectionHeader("PRIVACY & RECORDING")
        let privacyCard = makePrivacyCard()

        // Section: Account
        let accountHeader = makeSectionHeader("ACCOUNT")
        let accountCard = makeAccountCard()

        let stack = NSStackView(views: [
            heading,
            appearanceHeader, appearanceCard,
            backendHeader, backendCard,
            privacyHeader, privacyCard,
            accountHeader, accountCard,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(20, after: heading)
        stack.setCustomSpacing(24, after: appearanceCard)
        stack.setCustomSpacing(24, after: backendCard)
        stack.setCustomSpacing(24, after: privacyCard)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 739, height: 620))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -40),
        ])
        view = container
        return container
    }

    private func makeSectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = Theme.label(text)
        return label
    }

    private func makeAppearanceCard() -> NSView {
        let card = Theme.makeCard()
        card.translatesAutoresizingMaskIntoConstraints = false

        let appearanceLabel = NSTextField(labelWithString: "Appearance")
        appearanceLabel.font = .systemFont(ofSize: 13, weight: .medium)
        appearanceLabel.textColor = Theme.ink
        appearanceControl.selectedSegment = ["system", "light", "dark"].firstIndex(of: config.appearanceMode) ?? 0
        appearanceControl.target = self
        appearanceControl.action = #selector(changedAppearance)

        let stack = NSStackView(views: [appearanceLabel, appearanceControl])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    private func makeBackendCard() -> NSView {
        let card = Theme.makeCard()
        card.translatesAutoresizingMaskIntoConstraints = false

        let backendLabel = NSTextField(labelWithString: "Reply drafts by")
        backendLabel.font = .systemFont(ofSize: 13, weight: .medium)
        backendPopup.addItems(withTitles: [
            "Auto — best available",
            "Cloud (Groq, OpenRouter…)",
            "Ollama (local only)",
            "Claude (subscription)",
        ])
        backendPopup.target = self
        backendPopup.action = #selector(changed)

        providerLabel.font = .systemFont(ofSize: 13, weight: .medium)
        providerPopup.target = self
        providerPopup.action = #selector(changedProvider)

        modelLabel.font = .systemFont(ofSize: 13, weight: .medium)
        modelPopup.target = self
        modelPopup.action = #selector(changed)

        // API key entry — store the active provider's key in the login
        // Keychain without leaving the app.
        apiKeyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        apiKeyField.placeholderString = "Paste API key (e.g. gsk_… for Groq)"
        apiKeyField.target = self
        apiKeyField.action = #selector(saveKey) // Return in the field saves
        apiKeySaveButton.title = "Save key"
        apiKeySaveButton.bezelStyle = .rounded
        apiKeySaveButton.target = self
        apiKeySaveButton.action = #selector(saveKey)
        let apiKeyRemoveButton = NSButton(
            title: "Remove", target: self, action: #selector(removeKey))
        apiKeyRemoveButton.bezelStyle = .rounded
        let keyRow = NSStackView(views: [apiKeyField, apiKeySaveButton, apiKeyRemoveButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        apiKeyRow = keyRow
        apiKeyStatusLabel.font = .systemFont(ofSize: 11)
        apiKeyStatusLabel.textColor = .secondaryLabelColor
        apiKeyStatusLabel.maximumNumberOfLines = 2
        apiKeyStatusLabel.preferredMaxLayoutWidth = 520

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = 520

        let note = NSTextField(wrappingLabelWithString:
            "Chronicles, tone learning, and meeting summaries always use Claude. Memory Q&A lives in Claude Desktop via MCP.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.preferredMaxLayoutWidth = 520

        let stack = NSStackView(views: [
            backendLabel, backendPopup,
            providerLabel, providerPopup,
            apiKeyLabel, keyRow, apiKeyStatusLabel,
            modelLabel, modelPopup,
            statusLabel, note,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: backendPopup)
        stack.setCustomSpacing(12, after: apiKeyStatusLabel)
        stack.setCustomSpacing(20, after: modelPopup)

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            backendPopup.widthAnchor.constraint(equalToConstant: 300),
            providerPopup.widthAnchor.constraint(equalToConstant: 300),
            modelPopup.widthAnchor.constraint(equalToConstant: 300),
            apiKeyField.widthAnchor.constraint(equalToConstant: 220),
        ])
        return card
    }

    private func makePrivacyCard() -> NSView {
        let card = Theme.makeCard()
        card.translatesAutoresizingMaskIntoConstraints = false

        redactCheckbox.setButtonType(.switch)
        redactCheckbox.title = "Redact secrets & personal info before sending to any remote model"
        redactCheckbox.target = self
        redactCheckbox.action = #selector(toggledRedaction)
        redactCheckbox.state = config.redactRemoteEgress ? .on : .off
        let redactNote = NSTextField(wrappingLabelWithString:
            "Applies to cloud providers and Claude. API keys, tokens, private keys, "
            + "emails, card numbers and the like become [REDACTED_…] placeholders. "
            + "A local Ollama always receives the full text.")
        redactNote.font = .systemFont(ofSize: 11)
        redactNote.textColor = .tertiaryLabelColor
        redactNote.preferredMaxLayoutWidth = 520

        autoRecordCheckbox.setButtonType(.switch)
        autoRecordCheckbox.title = "Detect calls automatically and offer to record them"
        autoRecordCheckbox.target = self
        autoRecordCheckbox.action = #selector(toggledAutoRecord)
        autoRecordCheckbox.state = config.autoRecordMeetings ? .on : .off
        let autoRecordNote = NSTextField(wrappingLabelWithString:
            "When on, Smriti asks to record when a call app (Zoom, Teams, WhatsApp, "
            + "Meet…) is in use. Turn off if dictation tools keep triggering it — you "
            + "can still record manually from the Meetings tab.")
        autoRecordNote.font = .systemFont(ofSize: 11)
        autoRecordNote.textColor = .tertiaryLabelColor
        autoRecordNote.preferredMaxLayoutWidth = 520

        let stack = NSStackView(views: [
            redactCheckbox, redactNote,
            autoRecordCheckbox, autoRecordNote,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: redactNote)

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    private func makeAccountCard() -> NSView {
        let card = Theme.makeCard()
        card.translatesAutoresizingMaskIntoConstraints = false

        loginStatusLabel.font = .systemFont(ofSize: 11)
        loginStatusLabel.textColor = .secondaryLabelColor
        loginStatusLabel.maximumNumberOfLines = 2
        loginStatusLabel.preferredMaxLayoutWidth = 520
        loginButton.title = "Log in to Claude CLI…"
        loginButton.bezelStyle = .rounded
        loginButton.target = self
        loginButton.action = #selector(login)
        let checkButton = NSButton(title: "Check status", target: self, action: #selector(checkLogin))
        checkButton.bezelStyle = .rounded
        let loginRow = NSStackView(views: [loginButton, checkButton])
        loginRow.orientation = .horizontal
        loginRow.spacing = 8

        let stack = NSStackView(views: [
            loginStatusLabel, loginRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    func willAppear() {
        refresh()
        if ClaudeCLI.path() == nil {
            loginStatusLabel.stringValue = "⚠︎ Claude CLI not found. Install Claude Code, then log in."
            loginButton.isEnabled = false
        } else {
            loginButton.isEnabled = true
            checkLogin() // cheap (claude auth status), so run it on open
        }
    }

    @objc private func login() {
        loginStatusLabel.stringValue = "Opening Terminal — complete the login there, then click “Check status”."
        ClaudeCLI.openLoginInTerminal()
    }

    @objc private func changedAppearance() {
        config.appearanceMode = ["system", "light", "dark"][max(0, appearanceControl.selectedSegment)]
        try? config.save()
        Theme.applyAppearance(config.appearanceMode)
        onChange(config)
    }

    @objc private func checkLogin() {
        loginStatusLabel.stringValue = "Checking Claude login…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = ClaudeCLI.isLoggedIn()
            DispatchQueue.main.async {
                self?.loginStatusLabel.stringValue = ok
                    ? "✓ Claude CLI is logged in — drafting is ready."
                    : "⚠︎ Not logged in. Click “Log in to Claude CLI…”, finish in Terminal, then re-check."
            }
        }
    }

    private static let backendKeys = ["auto", "cloud", "ollama", "claude"]

    /// The cloud picker is shown for "auto" and "cloud"; the model popup
    /// switches between local (Ollama) and cloud models to match.
    private var showsCloudModels: Bool {
        config.assistBackend == "cloud"
            || (config.assistBackend == "auto"
                && CloudKeyStore.hasKey(provider: config.cloudProvider))
    }

    /// What the model popup currently lists — decided at refresh time, so a
    /// backend switch doesn't save an Ollama title into a cloud provider.
    private var modelPopupListsCloud = false

    private func refresh() {
        backendPopup.selectItem(
            at: SettingsSection.backendKeys.firstIndex(of: config.assistBackend) ?? 0)
        redactCheckbox.state = config.redactRemoteEgress ? .on : .off
        autoRecordCheckbox.state = config.autoRecordMeetings ? .on : .off

        let cloudVisible = config.assistBackend == "cloud" || config.assistBackend == "auto"
        providerLabel.isHidden = !cloudVisible
        providerPopup.isHidden = !cloudVisible
        providerPopup.removeAllItems()
        providerPopup.addItems(withTitles: config.cloudProviders.keys.sorted())
        providerPopup.selectItem(withTitle: config.cloudProvider)

        // API key entry follows the provider; hidden unless a cloud lane is in
        // play and the provider actually needs a key (localhost endpoints don't).
        let provider = config.cloudProviders[config.cloudProvider]
        let needsKey = cloudVisible && !(provider?.isLocal ?? false)
        apiKeyLabel.isHidden = !needsKey
        apiKeyRow?.isHidden = !needsKey
        apiKeyStatusLabel.isHidden = !needsKey
        if needsKey {
            apiKeyLabel.stringValue = "API key for \(config.cloudProvider)"
            if let source = CloudKeyStore.source(provider: config.cloudProvider) {
                apiKeyStatusLabel.stringValue = "✓ Key in place (from \(source)). Paste a new one and Save to replace it."
            } else {
                apiKeyStatusLabel.stringValue = "No key yet — free Groq keys at console.groq.com. Paste above and Save."
            }
        }

        if showsCloudModels {
            refreshCloudModels()
        } else {
            refreshOllamaModels()
        }
    }

    private func refreshOllamaModels() {
        modelPopupListsCloud = false
        modelLabel.stringValue = "Local model"
        let models = OllamaClient.listModels()
        modelPopup.removeAllItems()
        if models.isEmpty {
            modelPopup.addItem(withTitle: config.ollamaModel)
            modelPopup.isEnabled = false
            statusLabel.stringValue = "Ollama isn't running — start the Ollama app to use local models. Falling back to Claude."
        } else {
            modelPopup.addItems(withTitles: models)
            if !models.contains(config.ollamaModel) { modelPopup.addItem(withTitle: config.ollamaModel) }
            modelPopup.selectItem(withTitle: config.ollamaModel)
            modelPopup.isEnabled = config.assistBackend != "claude"
            statusLabel.stringValue = "Ollama running with \(models.count) model(s). Drafts stay on this Mac when a local model is used."
        }
    }

    private func refreshCloudModels() {
        let providerName = config.cloudProvider
        guard let provider = config.cloudProviders[providerName] else { return }
        modelPopupListsCloud = true
        modelLabel.stringValue = "Cloud model"
        modelPopup.removeAllItems()
        modelPopup.addItem(withTitle: provider.model)
        modelPopup.isEnabled = true

        guard CloudKeyStore.hasKey(provider: providerName) || provider.isLocal else {
            statusLabel.stringValue = "No API key for \(providerName) yet. Paste one in the “API key” field above and click Save."
            return
        }
        statusLabel.stringValue = "\(providerName) key found. Drafts use \(provider.model); only the window text of the moment is sent, exclusions always apply."
        // Model list comes from the provider's /models endpoint — network, so
        // fetch off the main thread and fill in when it lands.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let key = CloudKeyStore.get(provider: providerName)
            let models = CloudLLMClient.listModels(config: provider, apiKey: key)
            DispatchQueue.main.async {
                guard let self, self.showsCloudModels,
                      self.config.cloudProvider == providerName, !models.isEmpty
                else { return }
                let current = self.config.cloudProviders[providerName]?.model ?? provider.model
                self.modelPopup.removeAllItems()
                self.modelPopup.addItems(withTitles: models)
                if !models.contains(current) { self.modelPopup.addItem(withTitle: current) }
                self.modelPopup.selectItem(withTitle: current)
            }
        }
    }

    @objc private func changedProvider() {
        if let title = providerPopup.titleOfSelectedItem { config.cloudProvider = title }
        try? config.save()
        refresh()
        onChange(config)
    }

    @objc private func changed() {
        config.assistBackend =
            SettingsSection.backendKeys[max(0, backendPopup.indexOfSelectedItem)]
        if let title = modelPopup.titleOfSelectedItem {
            if modelPopupListsCloud {
                config.cloudProviders[config.cloudProvider]?.model = title
            } else {
                config.ollamaModel = title
            }
        }
        try? config.save()
        refresh()
        onChange(config)
    }

    @objc private func saveKey() {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            apiKeyStatusLabel.stringValue = "Paste a key first, then Save."
            return
        }
        let providerName = config.cloudProvider
        if CloudKeyStore.set(key, provider: providerName) {
            apiKeyField.stringValue = "" // never keep the secret on screen
            apiKeyStatusLabel.stringValue = "✓ Saved \(providerName) key to the login Keychain."
            refresh()      // re-list models now that the key exists
            onChange(config) // re-wire backends so the cloud lane goes live
        } else {
            apiKeyStatusLabel.stringValue = "⚠︎ Couldn't save to the Keychain — try again."
        }
    }

    @objc private func removeKey() {
        let providerName = config.cloudProvider
        CloudKeyStore.remove(provider: providerName)
        apiKeyField.stringValue = ""
        // A key can also live in an env var or .env; the Keychain copy is gone
        // but note if another source still supplies one.
        if let source = CloudKeyStore.source(provider: providerName) {
            apiKeyStatusLabel.stringValue = "Removed the Keychain key. A key is still provided by \(source)."
        } else {
            apiKeyStatusLabel.stringValue = "Removed the \(providerName) key."
        }
        refresh()
        onChange(config)
    }

    @objc private func toggledRedaction() {
        config.redactRemoteEgress = (redactCheckbox.state == .on)
        try? config.save()
        onChange(config)
    }

    @objc private func toggledAutoRecord() {
        config.autoRecordMeetings = (autoRecordCheckbox.state == .on)
        try? config.save()
        onChange(config)
    }
}
