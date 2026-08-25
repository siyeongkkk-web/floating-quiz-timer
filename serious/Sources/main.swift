import AppKit
import UniformTypeIdentifiers

final class ActivatingFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SelectAllComboBox: NSComboBox {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        DispatchQueue.main.async { [weak self] in
            self?.currentEditor()?.selectAll(nil)
        }
    }
}

final class PanelTextField: NSTextField {
    override var needsPanelToBecomeKey: Bool { true }
}

private enum CharacterStage: Int, CaseIterable {
    case calm
    case halfway
    case urgent

    var key: String {
        switch self {
        case .calm: return "calm"
        case .halfway: return "halfway"
        case .urgent: return "urgent"
        }
    }

    var title: String {
        switch self {
        case .calm: return "从容阶段"
        case .halfway: return "过半阶段"
        case .urgent: return "冲刺阶段"
        }
    }

    var timing: String {
        switch self {
        case .calm: return "剩余时间 > 50%"
        case .halfway: return "剩余时间 ≤ 50%"
        case .urgent: return "最后 10 秒"
        }
    }

    var defaultCaption: String {
        switch self {
        case .calm: return "从容一点，先看清题"
        case .halfway: return "已经过半，注意节奏"
        case .urgent: return "快到时间，先做选择"
        }
    }

    var color: NSColor {
        switch self {
        case .calm: return .systemGreen
        case .halfway: return .systemOrange
        case .urgent: return .systemRed
        }
    }

    var imageFileName: String { "\(key).png" }
}

private struct CharacterPackConfig: Codable {
    var captions: [String: String]
}

private final class CharacterPackEditorController: NSObject, NSTextFieldDelegate {
    private weak var hostPanel: ActivatingFloatingPanel?
    private let overlay = NSVisualEffectView()
    private var originalFrame: NSRect?
    private var originalPanelLevel: NSWindow.Level?
    private var isVisible = false
    private var previousApplication: NSRunningApplication?
    private var spaceChangeObserver: NSObjectProtocol?
    private weak var activeCaptionField: NSTextField?
    private var images: [CharacterStage: NSImage]
    private var imageViews: [CharacterStage: NSImageView] = [:]
    private var chooseButtons: [CharacterStage: NSButton] = [:]
    private var captionFields: [CharacterStage: NSTextField] = [:]
    private let saveButton = NSButton(title: "保存并使用", target: nil, action: nil)
    private let onSave: ([CharacterStage: NSImage], [CharacterStage: String]) -> Bool
    private let onClose: () -> Void

    init(
        hostPanel: ActivatingFloatingPanel,
        images: [CharacterStage: NSImage],
        captions: [CharacterStage: String],
        onSave: @escaping ([CharacterStage: NSImage], [CharacterStage: String]) -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.hostPanel = hostPanel
        self.images = images
        self.onSave = onSave
        self.onClose = onClose
        super.init()
        configureOverlay(captions: captions)
    }

    private func configureOverlay(captions: [CharacterStage: String]) {
        overlay.material = .popover
        overlay.blendingMode = .withinWindow
        overlay.state = .active
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 18
        overlay.layer?.cornerCurve = .continuous
        overlay.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "让形象和文案随答题时间一起变化")
        title.font = .systemFont(ofSize: 18, weight: .bold)

        let explanation = NSTextField(labelWithString: "分别选择三张图片并填写提示语。图片只保存在这台 Mac 上。")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor

        let stageList = NSStackView()
        stageList.orientation = .vertical
        stageList.spacing = 8
        for stage in CharacterStage.allCases {
            stageList.addArrangedSubview(makeStageRow(stage, caption: captions[stage] ?? stage.defaultCaption))
        }

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [NSView(), cancelButton, saveButton])
        footer.orientation = .horizontal
        footer.spacing = 8

        let root = NSStackView(views: [title, explanation, stageList, footer])
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            root.topAnchor.constraint(equalTo: overlay.topAnchor),
            root.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 32)
        ])
        updateSaveButton()
    }

    private func makeStageRow(_ stage: CharacterStage, caption: String) -> NSView {
        let stageTitle = NSTextField(labelWithString: stage.title)
        stageTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        let timing = NSTextField(labelWithString: stage.timing)
        timing.font = .systemFont(ofSize: 10)
        timing.textColor = .secondaryLabelColor

        let stageText = NSStackView(views: [stageTitle, timing])
        stageText.orientation = .vertical
        stageText.spacing = 3
        stageText.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.image = images[stage]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 9
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 2
        imageView.layer?.borderColor = stage.color.cgColor
        imageView.setAccessibilityLabel("\(stage.title)图片预览")
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageViews[stage] = imageView

        let chooseButton = NSButton(title: images[stage] == nil ? "选择图片" : "更换图片", target: self, action: #selector(chooseImage(_:)))
        chooseButton.tag = stage.rawValue
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small
        chooseButton.translatesAutoresizingMaskIntoConstraints = false
        chooseButtons[stage] = chooseButton

        let captionLabel = NSTextField(labelWithString: "阶段文案")
        captionLabel.font = .systemFont(ofSize: 10, weight: .medium)
        captionLabel.textColor = .secondaryLabelColor

        let captionField = PanelTextField(string: caption)
        captionField.placeholderString = stage.defaultCaption
        captionField.font = .systemFont(ofSize: 12)
        captionField.delegate = self
        captionField.translatesAutoresizingMaskIntoConstraints = false
        captionFields[stage] = captionField

        let captionColumn = NSStackView(views: [captionLabel, captionField])
        captionColumn.orientation = .vertical
        captionColumn.spacing = 4

        let row = NSStackView(views: [stageText, imageView, chooseButton, captionColumn])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.cornerCurve = .continuous
        row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 88),
            stageText.widthAnchor.constraint(equalToConstant: 100),
            imageView.widthAnchor.constraint(equalToConstant: 66),
            imageView.heightAnchor.constraint(equalToConstant: 66),
            chooseButton.widthAnchor.constraint(equalToConstant: 82),
            captionField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
        return row
    }

    @objc private func chooseImage(_ sender: NSButton) {
        guard let stage = CharacterStage(rawValue: sender.tag) else { return }
        let picker = NSOpenPanel()
        picker.title = "选择\(stage.title)图片"
        picker.prompt = "使用这张图片"
        picker.message = "支持常见图片格式；原图不会上传网络。"
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.image]
        picker.level = .floating
        picker.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .transient]

        guard let hostPanel else { return }
        picker.beginSheetModal(for: hostPanel) { [weak self] response in
            guard response == .OK,
                  let self,
                  let sourceURL = picker.url,
                  let image = NSImage(contentsOf: sourceURL) else { return }
            self.images[stage] = image
            self.imageViews[stage]?.image = image
            self.chooseButtons[stage]?.title = "更换图片"
            self.updateSaveButton()
        }
    }

    private func updateSaveButton() {
        saveButton.isEnabled = CharacterStage.allCases.allSatisfy { images[$0] != nil }
        saveButton.toolTip = saveButton.isEnabled ? "保存三阶段形象与文案" : "请先为三个阶段分别选择图片"
    }

    @objc private func save() {
        var captions: [CharacterStage: String] = [:]
        for stage in CharacterStage.allCases {
            let value = captionFields[stage]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            captions[stage] = value.isEmpty ? stage.defaultCaption : value
        }
        guard onSave(images, captions) else { return }
        close()
    }

    @objc private func cancel() {
        close()
    }

    func show() {
        guard let hostPanel else { return }
        if isVisible {
            NSApp.activate(ignoringOtherApps: true)
            hostPanel.makeKeyAndOrderFront(nil)
            return
        }

        previousApplication = NSWorkspace.shared.frontmostApplication
        originalFrame = hostPanel.frame
        originalPanelLevel = hostPanel.level
        var expandedFrame = hostPanel.frame
        expandedFrame.origin.x = expandedFrame.maxX - 650
        expandedFrame.origin.y = expandedFrame.maxY - 430
        expandedFrame.size = NSSize(width: 650, height: 430)
        hostPanel.setFrame(expandedFrame, display: true, animate: true)

        guard let contentView = hostPanel.contentView else { return }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            overlay.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
        ])
        isVisible = true
        startObservingSpaceChanges()
        hostPanel.level = .normal
        hostPanel.becomesKeyOnlyIfNeeded = false
        NSApp.activate(ignoringOtherApps: true)
        hostPanel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        stopObservingSpaceChanges()
        hostPanel?.endEditing(for: nil)
        overlay.removeFromSuperview()
        if let hostPanel, let originalFrame {
            hostPanel.becomesKeyOnlyIfNeeded = true
            hostPanel.level = originalPanelLevel ?? .statusBar
            hostPanel.setFrame(originalFrame, display: true, animate: true)
        }
        let applicationToRestore = previousApplication
        originalFrame = nil
        originalPanelLevel = nil
        previousApplication = nil
        activeCaptionField = nil
        isVisible = false
        onClose()
        DispatchQueue.main.async {
            applicationToRestore?.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        activeCaptionField = notification.object as? NSTextField
    }

    private func startObservingSpaceChanges() {
        guard spaceChangeObserver == nil else { return }
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.restoreEditingFocusAfterSpaceChange()
            }
        }
    }

    private func stopObservingSpaceChanges() {
        guard let spaceChangeObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
        self.spaceChangeObserver = nil
    }

    private func restoreEditingFocusAfterSpaceChange() {
        guard isVisible, let hostPanel, hostPanel.attachedSheet == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        hostPanel.makeKeyAndOrderFront(nil)
        if let activeCaptionField {
            hostPanel.makeFirstResponder(activeCaptionField)
        }
    }

    deinit {
        stopObservingSpaceChanges()
    }
}

final class FloatingTimerController: NSObject, NSComboBoxDelegate {
    private var duration: TimeInterval = 60
    private var remaining: TimeInterval = 60
    private var remainingAtStart: TimeInterval = 60
    private var startedAt: Date?
    private var timer: Timer?
    private var isRunning = false
    private var warningPlayed = false
    private var questionNumber = 1
    private var correctCount = 0
    private var wrongCount = 0
    private var skippedCount = 0
    private var correctQuestions: [Int] = []
    private var wrongQuestions: [Int] = []
    private var skippedQuestions: [Int] = []
    private var isManuallyHidden = false
    private var historyOverlay: NSVisualEffectView?
    private var historyFrame: NSRect?

    let panel: ActivatingFloatingPanel
    private let questionLabel = NSTextField(labelWithString: "第 1 题")
    private let scoreButton = NSButton(title: "✓0  ✗0  —0", target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "01:00")
    private let durationSelector = SelectAllComboBox()
    private let customDurationButton = NSButton(title: "✎", target: nil, action: nil)
    private let customizeImageButton = NSButton(title: "", target: nil, action: nil)
    private let minimizeButton = NSButton(title: "—", target: nil, action: nil)
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private let startButton = NSButton(title: "开始", target: nil, action: nil)
    private let correctButton = NSButton(title: "✓ 对", target: nil, action: nil)
    private let wrongButton = NSButton(title: "✗ 错", target: nil, action: nil)
    private let nextButton = NSButton(title: "跳过", target: nil, action: nil)
    private let resetButton = NSButton(title: "重置", target: nil, action: nil)
    private let statusDot = NSView()
    private let characterColumn = NSStackView()
    private let characterImageView = NSImageView()
    private let characterCaption = NSTextField(labelWithString: "从容一点，先看清题")
    private let removeCharacterButton = NSButton(title: "×", target: nil, action: nil)
    private var characterImages: [CharacterStage: NSImage] = [:]
    private var characterCaptions: [CharacterStage: String] = [:]
    private var characterEditor: CharacterPackEditorController?

    private let compactPanelWidth: CGFloat = 402
    private let customizedPanelWidth: CGFloat = 522

    override init() {
        panel = ActivatingFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 402, height: 142),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        buildInterface()
        loadSavedCharacterPack()
        updateView()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .transient,
            .stationary,
            .ignoresCycle
        ]

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panel.frame.width - 18,
                y: visible.maxY - panel.frame.height - 18
            ))
        }
    }

    private func buildInterface() {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        panel.contentView = background

        questionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        questionLabel.textColor = .secondaryLabelColor

        scoreButton.target = self
        scoreButton.action = #selector(showQuestionHistory)
        scoreButton.bezelStyle = .inline
        scoreButton.controlSize = .mini
        scoreButton.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        scoreButton.contentTintColor = .secondaryLabelColor
        scoreButton.toolTip = "查看本轮正误题号"

        durationSelector.addItems(withObjectValues: [30, 45, 60, 75, 90, 120].map { "\($0)秒" })
        durationSelector.stringValue = "60秒"
        durationSelector.isEditable = false
        durationSelector.completes = false
        durationSelector.numberOfVisibleItems = 6
        durationSelector.delegate = self
        durationSelector.target = self
        durationSelector.action = #selector(changeDuration)
        durationSelector.controlSize = .mini
        durationSelector.font = .systemFont(ofSize: 10, weight: .medium)
        durationSelector.toolTip = "选择预设时长"
        durationSelector.translatesAutoresizingMaskIntoConstraints = false

        customDurationButton.target = self
        customDurationButton.action = #selector(beginCustomDurationEdit)
        customDurationButton.bezelStyle = .rounded
        customDurationButton.controlSize = .mini
        customDurationButton.font = .systemFont(ofSize: 12, weight: .semibold)
        customDurationButton.toolTip = "输入自定义秒数"
        customDurationButton.translatesAutoresizingMaskIntoConstraints = false

        customizeImageButton.target = self
        customizeImageButton.action = #selector(showCharacterEditor)
        customizeImageButton.bezelStyle = .inline
        customizeImageButton.controlSize = .mini
        customizeImageButton.image = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: "选择自定义形象")
        customizeImageButton.imagePosition = .imageOnly
        customizeImageButton.contentTintColor = .secondaryLabelColor
        customizeImageButton.toolTip = "定制三阶段形象与文案"
        customizeImageButton.translatesAutoresizingMaskIntoConstraints = false

        minimizeButton.target = self
        minimizeButton.action = #selector(minimizeApp)
        minimizeButton.bezelStyle = .inline
        minimizeButton.controlSize = .mini
        minimizeButton.font = .systemFont(ofSize: 14, weight: .semibold)
        minimizeButton.contentTintColor = .secondaryLabelColor
        minimizeButton.toolTip = "最小化到程序坞"
        minimizeButton.translatesAutoresizingMaskIntoConstraints = false

        closeButton.target = self
        closeButton.action = #selector(quitApp)
        closeButton.bezelStyle = .inline
        closeButton.controlSize = .mini
        closeButton.font = .systemFont(ofSize: 16, weight: .semibold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "退出计时器"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        let headingRow = NSStackView(views: [statusDot, questionLabel, scoreButton, NSView(), durationSelector, customDurationButton, customizeImageButton, minimizeButton, closeButton])
        headingRow.orientation = .horizontal
        headingRow.alignment = .centerY
        headingRow.spacing = 7

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 46, weight: .bold)
        timeLabel.textColor = .labelColor
        timeLabel.alignment = .center
        timeLabel.toolTip = "本题剩余时间"

        configureButton(startButton, action: #selector(toggleTimer), emphasized: true)
        configureButton(correctButton, action: #selector(markCorrect), emphasized: false)
        configureButton(wrongButton, action: #selector(markWrong), emphasized: false)
        configureButton(nextButton, action: #selector(nextQuestion), emphasized: false)
        configureButton(resetButton, action: #selector(resetCurrent), emphasized: false)

        let buttonRow = NSStackView(views: [startButton, correctButton, wrongButton, nextButton, resetButton])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 7

        let timerColumn = NSStackView(views: [headingRow, timeLabel, buttonRow])
        timerColumn.orientation = .vertical
        timerColumn.spacing = 6

        characterImageView.imageScaling = .scaleProportionallyUpOrDown
        characterImageView.wantsLayer = true
        characterImageView.layer?.cornerRadius = 12
        characterImageView.layer?.cornerCurve = .continuous
        characterImageView.layer?.masksToBounds = true
        characterImageView.layer?.borderWidth = 2
        characterImageView.layer?.borderColor = NSColor.systemGreen.cgColor
        characterImageView.setAccessibilityLabel("自定义计时形象")
        characterImageView.translatesAutoresizingMaskIntoConstraints = false

        characterCaption.font = .systemFont(ofSize: 10, weight: .semibold)
        characterCaption.textColor = .secondaryLabelColor
        characterCaption.alignment = .center
        characterCaption.lineBreakMode = .byWordWrapping
        characterCaption.maximumNumberOfLines = 2

        removeCharacterButton.target = self
        removeCharacterButton.action = #selector(removeCharacterPack)
        removeCharacterButton.bezelStyle = .inline
        removeCharacterButton.controlSize = .mini
        removeCharacterButton.font = .systemFont(ofSize: 12, weight: .semibold)
        removeCharacterButton.contentTintColor = .secondaryLabelColor
        removeCharacterButton.toolTip = "移除自定义形象并恢复简洁模式"
        removeCharacterButton.translatesAutoresizingMaskIntoConstraints = false

        let captionRow = NSStackView(views: [characterCaption, removeCharacterButton])
        captionRow.orientation = .horizontal
        captionRow.alignment = .centerY
        captionRow.spacing = 2

        characterColumn.orientation = .vertical
        characterColumn.alignment = .centerX
        characterColumn.spacing = 4
        characterColumn.addArrangedSubview(characterImageView)
        characterColumn.addArrangedSubview(captionRow)
        characterColumn.isHidden = true

        let root = NSStackView(views: [characterColumn, timerColumn])
        root.orientation = .horizontal
        root.alignment = .centerY
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 10, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(root)

        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
            durationSelector.widthAnchor.constraint(equalToConstant: 57),
            customDurationButton.widthAnchor.constraint(equalToConstant: 27),
            customizeImageButton.widthAnchor.constraint(equalToConstant: 24),
            minimizeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            headingRow.heightAnchor.constraint(equalToConstant: 24),
            timeLabel.heightAnchor.constraint(equalToConstant: 49),
            timerColumn.widthAnchor.constraint(equalToConstant: 374),
            characterColumn.widthAnchor.constraint(equalToConstant: 104),
            characterImageView.widthAnchor.constraint(equalToConstant: 76),
            characterImageView.heightAnchor.constraint(equalToConstant: 76),
            captionRow.widthAnchor.constraint(equalToConstant: 104),
            captionRow.heightAnchor.constraint(equalToConstant: 34),
            removeCharacterButton.widthAnchor.constraint(equalToConstant: 16),
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            buttonRow.heightAnchor.constraint(equalToConstant: 31)
        ])
    }

    private func configureButton(_ button: NSButton, action: Selector, emphasized: Bool) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.bezelColor = emphasized ? .systemGreen : NSColor.controlColor
        button.contentTintColor = emphasized ? .white : .labelColor
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: emphasized ? .semibold : .medium)
        button.keyEquivalent = ""
    }

    func show() {
        isManuallyHidden = false
        panel.orderFront(nil)
    }

    func toggleVisibility() {
        if panel.isVisible {
            isManuallyHidden = true
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    @objc func toggleTimer() {
        if isRunning {
            pause()
        } else {
            applyDurationInput(resetIfChanged: true)
            start()
        }
    }

    private func start() {
        if remaining <= 0 {
            resetState()
        }

        isRunning = true
        startedAt = Date()
        remainingAtStart = remaining
        startButton.title = "暂停"
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func pause() {
        refreshRemaining()
        isRunning = false
        timer?.invalidate()
        timer = nil
        startButton.title = "继续"
        statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        updateView()
    }

    private func tick() {
        refreshRemaining()

        if remaining <= 10, remaining > 0, !warningPlayed {
            warningPlayed = true
            NSSound(named: "Tink")?.play()
        }

        if remaining <= 0 {
            remaining = 0
            isRunning = false
            timer?.invalidate()
            timer = nil
            startButton.title = "重来"
            NSSound.beep()
        }

        updateView()
    }

    private func refreshRemaining() {
        guard isRunning, let startedAt else { return }
        remaining = max(0, remainingAtStart - Date().timeIntervalSince(startedAt))
    }

    @objc func nextQuestion() {
        skippedCount += 1
        skippedQuestions.append(questionNumber)
        advanceToNextQuestion()
    }

    @objc private func markCorrect() {
        correctCount += 1
        correctQuestions.append(questionNumber)
        advanceToNextQuestion()
    }

    @objc private func markWrong() {
        wrongCount += 1
        wrongQuestions.append(questionNumber)
        advanceToNextQuestion()
    }

    @objc private func showQuestionHistory() {
        if historyOverlay != nil {
            hideQuestionHistory()
            return
        }

        historyFrame = panel.frame
        let expandedHeight: CGFloat = 258
        var expandedFrame = panel.frame
        expandedFrame.origin.y -= expandedHeight - expandedFrame.height
        expandedFrame.size.height = expandedHeight
        panel.setFrame(expandedFrame, display: true, animate: true)

        let overlay = NSVisualEffectView()
        overlay.material = .popover
        overlay.blendingMode = .withinWindow
        overlay.state = .active
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 16
        overlay.layer?.masksToBounds = true
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "本轮答题记录")
        title.font = .systemFont(ofSize: 14, weight: .bold)

        let close = NSButton(title: "收起", target: self, action: #selector(hideQuestionHistory))
        close.bezelStyle = .inline
        close.font = .systemFont(ofSize: 12, weight: .semibold)

        let textView = NSTextView()
        textView.string = "✓ 正确：\(formatQuestions(correctQuestions))\n\n✗ 错误：\(formatQuestions(wrongQuestions))\n\n— 跳过：\(formatQuestions(skippedQuestions))"
        textView.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.frame = NSRect(x: 0, y: 0, width: panel.frame.width - 48, height: 1_000)
        textView.minSize = NSSize(width: panel.frame.width - 48, height: 0)
        textView.maxSize = NSSize(width: panel.frame.width - 48, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        guard let contentView = panel.contentView else { return }
        contentView.addSubview(overlay)
        overlay.addSubview(title)
        overlay.addSubview(close)
        overlay.addSubview(scrollView)
        title.translatesAutoresizingMaskIntoConstraints = false
        close.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            overlay.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            title.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 14),
            close.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -12),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            scrollView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -12)
        ])
        historyOverlay = overlay
    }

    @objc private func hideQuestionHistory() {
        historyOverlay?.removeFromSuperview()
        historyOverlay = nil
        if let historyFrame {
            panel.setFrame(historyFrame, display: true, animate: true)
        }
        historyFrame = nil
    }

    private func formatQuestions(_ questions: [Int]) -> String {
        questions.isEmpty ? "暂无" : questions.map(String.init).joined(separator: "、")
    }

    private func advanceToNextQuestion() {
        applyDurationInput(resetIfChanged: false)
        questionNumber += 1
        resetState()
        updateView()
        start()
    }

    @objc func resetCurrent() {
        applyDurationInput(resetIfChanged: false)
        resetState()
        updateView()
    }

    @objc private func changeDuration() {
        applyDurationInput(resetIfChanged: true)
        durationSelector.isEditable = false
        customDurationButton.title = "✎"
        customDurationButton.toolTip = "输入自定义秒数"
    }

    @objc private func beginCustomDurationEdit() {
        if durationSelector.isEditable {
            changeDuration()
            return
        }
        durationSelector.isEditable = true
        durationSelector.stringValue = "\(Int(duration))"
        customDurationButton.title = "✓"
        customDurationButton.toolTip = "确认自定义秒数"
        panel.makeFirstResponder(durationSelector)
        DispatchQueue.main.async { [weak self] in
            self?.durationSelector.currentEditor()?.selectAll(nil)
        }
    }

    @objc func showCharacterEditor() {
        if let characterEditor {
            characterEditor.show()
            return
        }

        if historyOverlay != nil {
            hideQuestionHistory()
        }

        let editor = CharacterPackEditorController(
            hostPanel: panel,
            images: characterImages,
            captions: characterCaptions
        ) { [weak self] images, captions in
            self?.saveCharacterPack(images: images, captions: captions) ?? false
        } onClose: { [weak self] in
            self?.characterEditor = nil
        }
        characterEditor = editor
        editor.show()
    }

    @objc func removeCharacterPack() {
        for url in characterPackFileURLs.values {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: characterConfigURL)
        try? FileManager.default.removeItem(at: legacyCharacterImageURL)
        characterImages.removeAll()
        characterCaptions.removeAll()
        characterImageView.image = nil
        setCharacterVisible(false)
    }

    private var characterDirectory: URL {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportDirectory.appendingPathComponent("FloatingQuizTimer", isDirectory: true)
    }

    private var characterConfigURL: URL {
        characterDirectory.appendingPathComponent("character-pack.json")
    }

    private var legacyCharacterImageURL: URL {
        characterDirectory.appendingPathComponent("custom-character.png")
    }

    private var characterPackFileURLs: [CharacterStage: URL] {
        Dictionary(uniqueKeysWithValues: CharacterStage.allCases.map {
            ($0, characterDirectory.appendingPathComponent($0.imageFileName))
        })
    }

    private func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return png
    }

    private func saveCharacterPack(
        images: [CharacterStage: NSImage],
        captions: [CharacterStage: String]
    ) -> Bool {
        guard CharacterStage.allCases.allSatisfy({ images[$0] != nil }) else {
            NSSound.beep()
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: characterDirectory,
                withIntermediateDirectories: true
            )
            for stage in CharacterStage.allCases {
                guard let image = images[stage], let data = pngData(for: image), let url = characterPackFileURLs[stage] else {
                    NSSound.beep()
                    return false
                }
                try data.write(to: url, options: .atomic)
            }
            let config = CharacterPackConfig(captions: Dictionary(uniqueKeysWithValues: captions.map { ($0.key.key, $0.value) }))
            let configData = try JSONEncoder().encode(config)
            try configData.write(to: characterConfigURL, options: .atomic)
            try? FileManager.default.removeItem(at: legacyCharacterImageURL)
        } catch {
            NSSound.beep()
            return false
        }

        characterImages = images
        characterCaptions = captions
        setCharacterVisible(true)
        updateCharacterStage()
        return true
    }

    private func loadSavedCharacterPack() {
        var loadedImages: [CharacterStage: NSImage] = [:]
        for stage in CharacterStage.allCases {
            guard let url = characterPackFileURLs[stage], let image = NSImage(contentsOf: url) else {
                loadLegacyCharacterImage()
                return
            }
            loadedImages[stage] = image
        }

        var loadedCaptions = Dictionary(uniqueKeysWithValues: CharacterStage.allCases.map { ($0, $0.defaultCaption) })
        if let data = try? Data(contentsOf: characterConfigURL),
           let config = try? JSONDecoder().decode(CharacterPackConfig.self, from: data) {
            for stage in CharacterStage.allCases {
                if let value = config.captions[stage.key], !value.isEmpty {
                    loadedCaptions[stage] = value
                }
            }
        }

        characterImages = loadedImages
        characterCaptions = loadedCaptions
        setCharacterVisible(true)
        updateCharacterStage()
    }

    private func loadLegacyCharacterImage() {
        guard let image = NSImage(contentsOf: legacyCharacterImageURL) else { return }
        characterImages = Dictionary(uniqueKeysWithValues: CharacterStage.allCases.map { ($0, image) })
        characterCaptions = Dictionary(uniqueKeysWithValues: CharacterStage.allCases.map { ($0, $0.defaultCaption) })
        setCharacterVisible(true)
        updateCharacterStage()
    }

    private func setCharacterVisible(_ visible: Bool) {
        characterColumn.isHidden = !visible
        let targetWidth = visible ? customizedPanelWidth : compactPanelWidth
        guard panel.frame.width != targetWidth else { return }
        var frame = panel.frame
        let rightEdge = frame.maxX
        frame.size.width = targetWidth
        frame.origin.x = rightEdge - targetWidth
        panel.setFrame(frame, display: true, animate: true)
    }

    private func updateCharacterStage() {
        guard !characterColumn.isHidden else { return }
        let ratio = duration > 0 ? remaining / duration : 0
        let stage: CharacterStage
        if remaining <= 10 {
            stage = .urgent
        } else if ratio <= 0.5 {
            stage = .halfway
        } else {
            stage = .calm
        }

        characterImageView.image = characterImages[stage]
        characterCaption.stringValue = characterCaptions[stage] ?? stage.defaultCaption
        characterCaption.textColor = stage == .calm ? .secondaryLabelColor : stage.color
        characterImageView.layer?.borderColor = stage.color.cgColor
    }

    @discardableResult
    private func applyDurationInput(resetIfChanged: Bool) -> Bool {
        let digits = durationSelector.stringValue.filter(\.isNumber)
        guard let entered = Int(digits), entered >= 5, entered <= 600 else {
            durationSelector.stringValue = "\(Int(duration))秒"
            NSSound.beep()
            return false
        }
        let newDuration = TimeInterval(entered)
        let changed = newDuration != duration
        duration = newDuration
        durationSelector.stringValue = "\(entered)秒"
        if changed && resetIfChanged {
            resetState()
            updateView()
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        changeDuration()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func minimizeApp() {
        isManuallyHidden = true
        panel.orderOut(nil)
    }

    private func resetState() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        remaining = duration
        remainingAtStart = duration
        startedAt = nil
        warningPlayed = false
        startButton.title = "开始"
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
    }

    private func updateView() {
        let totalSeconds = max(0, Int(ceil(remaining)))
        timeLabel.stringValue = String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
        questionLabel.stringValue = "第 \(questionNumber) 题"
        scoreButton.title = "✓\(correctCount)  ✗\(wrongCount)  —\(skippedCount)"
        updateCharacterStage()

        if remaining <= 0 {
            timeLabel.textColor = .systemRed
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        } else if remaining <= 10 {
            timeLabel.textColor = .systemOrange
        } else {
            timeLabel.textColor = .labelColor
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timerController: FloatingTimerController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockIcon()
        timerController = FloatingTimerController()
        configureApplicationMenu()
        configureStatusItem()
        timerController.show()
    }

    private func applyDockIcon() {
        guard let iconURL = Bundle.main.url(forResource: "FloatingQuizTimer", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApp.applicationIconImage = icon
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        timerController.show()
        return true
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "退出限时答题", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "限时答题")
        }

        let menu = NSMenu()
        let visibilityItem = NSMenuItem(title: "显示/隐藏悬浮窗", action: #selector(toggleVisibility), keyEquivalent: "")
        visibilityItem.target = self
        menu.addItem(visibilityItem)

        let resetItem = NSMenuItem(title: "重置本题", action: #selector(resetTimer), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        let chooseImageItem = NSMenuItem(title: "定制三阶段形象…", action: #selector(showCharacterEditor), keyEquivalent: "")
        chooseImageItem.target = self
        menu.addItem(chooseImageItem)

        let removeImageItem = NSMenuItem(title: "恢复简洁模式", action: #selector(removeCharacterPack), keyEquivalent: "")
        removeImageItem.target = self
        menu.addItem(removeImageItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func toggleVisibility() {
        timerController.toggleVisibility()
    }

    @objc private func resetTimer() {
        timerController.resetCurrent()
        timerController.show()
    }

    @objc private func showCharacterEditor() {
        timerController.showCharacterEditor()
        timerController.show()
    }

    @objc private func removeCharacterPack() {
        timerController.removeCharacterPack()
        timerController.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
