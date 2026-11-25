import AppKit
import AVFoundation
import Combine

enum DictationPhase: String { case idle, recording, transcribing, polishing }
enum MenuBarState { case idle, listening, processing, inserted }

@MainActor
final class AppModel: ObservableObject {
    @Published var enabled = false
    @Published var phase: DictationPhase = .idle
    @Published var cleanedText = ""
    @Published var error: String?
    @Published var speechReady = false
    @Published var qwenReady = false
    @Published var qwenIssue: String?
    @Published var fnReady = false
    @Published var microphoneReady = false
    @Published var accessibilityReady = false
    @Published var fnDown = false
    @Published var meter: Float = 0
    @Published var elapsed: TimeInterval = 0
    @Published var copied = false
    @Published var showingSettings = false
    @Published var canRetry = false
    @Published var lastProcessingTime: TimeInterval?
    @Published var insertionStatus: String?
    @Published private(set) var typingTestCountdown: Int?
    @Published var autoInsert = UserDefaults.standard.object(forKey: "autoInsert") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoInsert, forKey: "autoInsert") }
    }
    @Published var qwenModel = UserDefaults.standard.string(forKey: "qwenModel") ?? OllamaClient.recommendedModel {
        didSet {
            UserDefaults.standard.set(qwenModel, forKey: "qwenModel")
            qwenReady = false
            Task { await checkOllama() }
        }
    }
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "en" {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    @Published var autoCopy = UserDefaults.standard.bool(forKey: "autoCopy") {
        didSet { UserDefaults.standard.set(autoCopy, forKey: "autoCopy") }
    }
    @Published var experimentalFormatting = UserDefaults.standard.bool(forKey: "experimentalFormatting") {
        didSet { UserDefaults.standard.set(experimentalFormatting, forKey: "experimentalFormatting") }
    }
    var onStateChange: (() -> Void)?
    private let speech = SpeechEngine()
    private var ollama: OllamaClient { OllamaClient(model: qwenModel) }
    private let recorder = AudioRecorder()
    private let hotkey = FnKeyMonitor()
    private let textInsertion = TextInsertion()
    private var recordingTimer: Timer?
    private var healthTimer: Timer?
    private var recordingStart: Date?
    private var startedWithFn = false
    private var pendingDraft: DictationDraft?
    private var healthCheckRunning = false
    private var activationRunning = false
    private var insertionDestination: TextInsertion.Destination?
    private var typingTestTask: Task<Void, Never>?
    private var insertionIndicatorTask: Task<Void, Never>?
    private var insertionIndicatorVisible = false

    var busy: Bool { phase == .transcribing || phase == .polishing }
    var ready: Bool { speechReady && qwenReady }
    var wordCount: Int { cleanedText.split(whereSeparator: { $0.isWhitespace }).count }
    var menuBarState: MenuBarState {
        switch phase {
        case .recording: return .listening
        case .transcribing, .polishing: return .processing
        case .idle: return insertionIndicatorVisible ? .inserted : .idle
        }
    }
    var menuBarStatus: String {
        menuBarState == .inserted ? (insertionStatus ?? "Text inserted") : status
    }
    var status: String {
        switch phase {
        case .recording: return "Listening"
        case .transcribing: return "Recognizing speech…"
        case .polishing: return "Cleaning up with Qwen…"
        case .idle:
            if !speechReady { return "Loading speech model…" }
            if !qwenReady { return "Waiting for local Qwen" }
            if !enabled { return "Ready to activate" }
            return fnReady ? "Ready when you are" : "Microphone ready · enable Fn in Settings"
        }
    }

    init() {
        recorder.onMeter = { [weak self] value in
            DispatchQueue.main.async { self?.meter = value }
        }
        hotkey.onAvailabilityChange = { [weak self] ready in self?.fnReady = ready }
        hotkey.onChange = { [weak self] down in
            guard let self else { return }
            self.fnDown = down
            if down, self.enabled, self.phase == .idle { self.startRecording(fromFn: true) }
            else if !down, self.phase == .recording, self.startedWithFn { self.finishRecording() }
        }
        microphoneReady = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityReady = textInsertion.hasPermission
    }

    func bootstrap() {
        Task {
            do {
                guard let model = Bundle.main.url(forResource: "ggml-base", withExtension: "bin") else {
                    throw WisprError.message("The speech model is missing from the app. Run scripts/build.sh to rebuild it.")
                }
                try await speech.load(modelURL: model)
                speechReady = true
            } catch { self.error = error.localizedDescription }
            await checkOllama()
            onStateChange?()
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.qwenReady, !self.busy, self.phase != .recording else { return }
                await self.checkOllama()
            }
        }
    }

    func checkOllama() async {
        guard !healthCheckRunning else { return }
        healthCheckRunning = true
        let selectedModel = qwenModel
        defer {
            healthCheckRunning = false
            if selectedModel != qwenModel { Task { await checkOllama() } }
        }
        do {
            try await OllamaClient(model: selectedModel).checkModel()
            guard selectedModel == qwenModel else { return }
            qwenReady = true; qwenIssue = nil
        }
        catch {
            guard selectedModel == qwenModel else { return }
            qwenReady = false
            qwenIssue = (error as? URLError) != nil ? "Open Ollama, then click Check again." : error.localizedDescription
        }
    }

    func refreshPermissions() {
        microphoneReady = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityReady = textInsertion.hasPermission
        if enabled { fnReady = hotkey.start(requestPermission: false) }
    }

    func toggleEnabled() {
        if enabled {
            cancelTypingTest()
            clearInsertionIndicator()
            if phase == .recording { finishRecording() }
            enabled = false; fnDown = false; hotkey.stop(); onStateChange?()
        } else { Task { await activate() } }
    }

    func activate() async {
        guard !activationRunning else { return }
        activationRunning = true
        defer { activationRunning = false }
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        if permission == .notDetermined {
            microphoneReady = await AVCaptureDevice.requestAccess(for: .audio)
        } else { microphoneReady = permission == .authorized }
        guard microphoneReady else {
            error = "Allow Local Wispr to use the microphone in System Settings → Privacy & Security → Microphone."
            showingSettings = true
            return
        }
        enabled = true
        fnReady = hotkey.start(requestPermission: true)
        if autoInsert { accessibilityReady = textInsertion.requestPermission() }
        error = nil
        if !fnReady || (autoInsert && !accessibilityReady) { showingSettings = true }
        onStateChange?()
    }

    func toggleRecording() {
        if phase == .recording { finishRecording(); return }
        guard !busy else { return }
        Task {
            if !enabled { await activate() }
            guard enabled else { return }
            startRecording(fromFn: false)
        }
    }

    private func startRecording(fromFn: Bool) {
        guard phase == .idle else { return }
        guard typingTestCountdown != 0 else { return }
        cancelTypingTest()
        clearInsertionIndicator()
        guard ready else { error = qwenIssue ?? "The speech model is still loading. Try again in a moment."; return }
        guard microphoneReady else { error = "Microphone access is needed. Open Settings to allow it."; return }
        do {
            let shouldInsert = fromFn && autoInsert && NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier
            insertionDestination = shouldInsert ? try textInsertion.capture() : nil
            try recorder.start()
            // Preserve the previous completed text until the next result succeeds.
            error = nil; canRetry = false; pendingDraft = nil; copied = false
            insertionStatus = nil
            elapsed = 0; meter = 0; recordingStart = Date(); startedWithFn = fromFn
            phase = .recording
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let start = self.recordingStart else { return }
                    self.elapsed = Date().timeIntervalSince(start)
                    if self.elapsed >= 120 { self.finishRecording() }
                }
            }
            onStateChange?()
        } catch { self.error = error.localizedDescription; NSSound.beep() }
    }

    func finishRecording() {
        guard phase == .recording else { return }
        recordingTimer?.invalidate(); recordingTimer = nil; meter = 0
        let samples: [Float]
        do { samples = try recorder.stop() }
        catch { self.error = error.localizedDescription; phase = .idle; onStateChange?(); return }
        phase = .transcribing; onStateChange?()
        let chosenLanguage = language
        let useFormatting = experimentalFormatting
        let start = Date()
        Task {
            do {
                let draft = try await speech.prepare(samples, language: chosenLanguage, experimentalFormatting: useFormatting)
                pendingDraft = draft
                phase = .polishing; onStateChange?()
                try await finishCleanup(draft)
                lastProcessingTime = Date().timeIntervalSince(start)
            } catch {
                self.error = error.localizedDescription
                canRetry = pendingDraft?.lines.isEmpty == false
            }
            phase = .idle; onStateChange?()
        }
    }

    private func finishCleanup(_ draft: DictationDraft) async throws {
        let result = try await ollama.clean(draft)
        cleanedText = result
        pendingDraft = nil; canRetry = false; error = nil; qwenReady = true
        if let destination = insertionDestination {
            insertionDestination = nil
            do {
                let outcome = try await textInsertion.insert(result, into: destination)
                switch outcome {
                case .confirmed:
                    insertionStatus = "Inserted into \(destination.appName)"
                    showInsertionIndicator()
                case .unverified: insertionStatus = "Sent to \(destination.appName) · check the field"
                }
            } catch {
                self.error = error.localizedDescription
                insertionStatus = "Text ready in Local Wispr"
                NSSound.beep()
            }
        }
        if autoCopy { copyText() }
    }

    func retryCleanup() {
        guard let draft = pendingDraft, !busy else { return }
        clearInsertionIndicator()
        phase = .polishing; error = nil; onStateChange?()
        Task {
            do { try await finishCleanup(draft) }
            catch { self.error = error.localizedDescription }
            phase = .idle; onStateChange?()
        }
    }

    func copyText() {
        guard !cleanedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cleanedText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.copied = false }
    }

    func clearText() {
        cancelTypingTest(); clearInsertionIndicator()
        cleanedText = ""; pendingDraft = nil; insertionDestination = nil; insertionStatus = nil
        canRetry = false; error = nil; lastProcessingTime = nil
    }

    private func showInsertionIndicator() {
        insertionIndicatorTask?.cancel()
        insertionIndicatorVisible = true
        onStateChange?()
        insertionIndicatorTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 4_000_000_000) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.insertionIndicatorVisible = false
            self.insertionIndicatorTask = nil
            self.onStateChange?()
        }
    }

    private func clearInsertionIndicator() {
        insertionIndicatorTask?.cancel(); insertionIndicatorTask = nil
        guard insertionIndicatorVisible else { return }
        insertionIndicatorVisible = false
        onStateChange?()
    }

    func testTyping() {
        guard phase == .idle, typingTestTask == nil else { return }
        guard textInsertion.hasPermission else { requestInsertionPermission(); return }
        clearInsertionIndicator()
        showingSettings = false
        error = nil
        let sample = experimentalFormatting ? "- **Cucumbers**\n- *Carrots*\n- APPLES" : "Local Wispr typing works."
        typingTestTask = Task {
            defer { typingTestCountdown = nil; typingTestTask = nil; onStateChange?() }
            do {
                for seconds in stride(from: 10, through: 1, by: -1) {
                    typingTestCountdown = seconds
                    insertionStatus = "Typing test in \(seconds)s · click a text field"
                    onStateChange?()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try Task.checkCancellation()
                typingTestCountdown = 0
                let destination = try textInsertion.capture()
                let outcome = try await textInsertion.insert(sample, into: destination)
                switch outcome {
                case .confirmed:
                    insertionStatus = "Typing test confirmed in \(destination.appName)"
                    showInsertionIndicator()
                case .unverified: insertionStatus = "Test sent to \(destination.appName) · check the field"
                }
            } catch is CancellationError {
                // Cancelling a pending countdown does not type anything.
            } catch {
                self.error = error.localizedDescription
                insertionStatus = "Typing test could not be confirmed"
                NSSound.beep()
            }
        }
    }

    func cancelTypingTest() {
        guard typingTestCountdown != 0 else { return }
        guard typingTestTask != nil else { return }
        typingTestTask?.cancel(); typingTestCountdown = nil; insertionStatus = nil
        onStateChange?()
    }

    func requestFnPermission() { fnReady = hotkey.start(requestPermission: true) }
    func requestInsertionPermission() {
        accessibilityReady = textInsertion.requestPermission()
        if !accessibilityReady { openPrivacy("Privacy_Accessibility") }
    }
    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    func openOllama() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Ollama.app"), configuration: .init()) { _, _ in }
    }
    func shutdown() {
        typingTestTask?.cancel()
        insertionIndicatorTask?.cancel()
        hotkey.stop(); healthTimer?.invalidate(); recordingTimer?.invalidate()
        if phase == .recording { _ = try? recorder.stop() }
    }
}
