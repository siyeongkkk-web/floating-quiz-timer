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
        loadSavedCharacterImage()
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
            .fullScreenAuxiliary,
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
        customizeImageButton.action = #selector(chooseCharacterImage)
        customizeImageButton.bezelStyle = .inline
        customizeImageButton.controlSize = .mini
        customizeImageButton.image = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: "选择自定义形象")
        customizeImageButton.imagePosition = .imageOnly
        customizeImageButton.contentTintColor = .secondaryLabelColor
        customizeImageButton.toolTip = "选择或更换自定义形象"
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
        removeCharacterButton.action = #selector(removeCharacterImage)
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

    @objc func chooseCharacterImage() {
        let picker = NSOpenPanel()
        picker.title = "选择计时器形象"
        picker.prompt = "使用这张图片"
        picker.message = "支持常见图片格式；图片只保存在这台 Mac 上。"
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.image]

        guard picker.runModal() == .OK,
              let sourceURL = picker.url,
              let image = NSImage(contentsOf: sourceURL),
              saveCharacterImage(image) else { return }

        showCharacterImage(image)
    }

    @objc func removeCharacterImage() {
        try? FileManager.default.removeItem(at: characterImageURL)
        characterImageView.image = nil
        setCharacterVisible(false)
    }

    private var characterImageURL: URL {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportDirectory
            .appendingPathComponent("FloatingQuizTimer", isDirectory: true)
            .appendingPathComponent("custom-character.png")
    }

    private func saveCharacterImage(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            NSSound.beep()
            return false
        }

        do {
            try FileManager.default.createDirectory(
                at: characterImageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try png.write(to: characterImageURL, options: .atomic)
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    private func loadSavedCharacterImage() {
        guard let image = NSImage(contentsOf: characterImageURL) else { return }
        showCharacterImage(image)
    }

    private func showCharacterImage(_ image: NSImage) {
        characterImageView.image = image
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

        if remaining <= 10 {
            characterCaption.stringValue = "快到时间，先做选择"
            characterCaption.textColor = .systemRed
            characterImageView.layer?.borderColor = NSColor.systemRed.cgColor
        } else if ratio <= 0.5 {
            characterCaption.stringValue = "已经过半，注意节奏"
            characterCaption.textColor = .systemOrange
            characterImageView.layer?.borderColor = NSColor.systemOrange.cgColor
        } else {
            characterCaption.stringValue = "从容一点，先看清题"
            characterCaption.textColor = .secondaryLabelColor
            characterImageView.layer?.borderColor = NSColor.systemGreen.cgColor
        }
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
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
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

        let chooseImageItem = NSMenuItem(title: "选择自定义形象…", action: #selector(chooseCharacterImage), keyEquivalent: "")
        chooseImageItem.target = self
        menu.addItem(chooseImageItem)

        let removeImageItem = NSMenuItem(title: "恢复简洁模式", action: #selector(removeCharacterImage), keyEquivalent: "")
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

    @objc private func chooseCharacterImage() {
        timerController.chooseCharacterImage()
        timerController.show()
    }

    @objc private func removeCharacterImage() {
        timerController.removeCharacterImage()
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
