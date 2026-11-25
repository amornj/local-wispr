import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var window: NSWindow!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Local Wispr"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 840, height: 620)
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.center()
        window.setFrameAutosaveName("LocalWisprWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        model.onStateChange = { [weak self] in self?.updateMenu() }
        updateMenu()
        buildAppMenu()
        model.bootstrap()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.willSleepNotification, object: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshPermissions() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
    @objc private func sessionResigned() { if model.phase == .recording { model.finishRecording() } }
    @objc func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func toggleEnabled() { model.toggleEnabled() }
    @objc private func showSettings() { showWindow(); model.showingSettings = true }
    @objc private func cancelTypingTest() { model.cancelTypingTest(); updateMenu() }

    private func updateMenu() {
        let state = model.menuBarState
        let symbol: String
        let color: NSColor?
        switch state {
        case .idle: symbol = "waveform"; color = nil
        case .listening: symbol = "mic.fill"; color = nil
        case .processing: symbol = "waveform"; color = .systemYellow
        case .inserted: symbol = "checkmark.circle.fill"; color = .systemGreen
        }
        let description = "Local Wispr · \(model.menuBarStatus)"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        if let color {
            // A template status image discards its colors. Use an original palette
            // symbol during processing and confirmation, then restore a template
            // image for the system's automatic light/dark idle appearance.
            let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
            statusItem.button?.image = image?.withSymbolConfiguration(configuration)
            statusItem.button?.image?.isTemplate = false
        } else {
            image?.isTemplate = true
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Local Wispr", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let status = NSMenuItem(title: model.menuBarStatus, action: nil, keyEquivalent: "")
        status.isEnabled = false; menu.addItem(status)
        menu.addItem(withTitle: model.enabled ? "Pause Wispr" : "Activate Wispr", action: #selector(toggleEnabled), keyEquivalent: "").target = self
        if let seconds = model.typingTestCountdown, seconds > 0 {
            menu.addItem(withTitle: "Cancel typing test (\(seconds)s)", action: #selector(cancelTypingTest), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Local Wispr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func buildAppMenu() {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "About Local Wispr", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Local Wispr", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Local Wispr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem(); item.submenu = app; main.addItem(item)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editItem.submenu = edit; main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

@main
struct LocalWisprMain {
    @MainActor
    static func main() async {
        if let index = CommandLine.arguments.firstIndex(of: "--format-text") {
            do {
                guard index + 1 < CommandLine.arguments.count else {
                    throw WisprError.message("Usage: LocalWispr --format-text 'start list cucumbers next item carrots end list'")
                }
                let draft = DictationFormatting.parse(CommandLine.arguments[index + 1])
                let cleaned = try await OllamaClient().clean(draft)
                let data = try JSONSerialization.data(withJSONObject: ["ok": true, "cleaned": cleaned], options: [.prettyPrinted])
                print(String(decoding: data, as: UTF8.self))
                exit(0)
            } catch {
                fputs("Formatting test failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--self-test") {
            do {
                guard let index = CommandLine.arguments.firstIndex(of: "--self-test"), index + 1 < CommandLine.arguments.count else {
                    throw WisprError.message("Usage: LocalWispr --self-test /path/to/audio.wav")
                }
                let audioURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                guard let modelURL = Bundle.main.url(forResource: "ggml-base", withExtension: "bin") else { throw WisprError.message("Speech model missing.") }
                let speech = SpeechEngine()
                let started = Date()
                try await speech.load(modelURL: modelURL)
                let samples = try AudioRecorder.readAudio(at: audioURL)
                let formatting = CommandLine.arguments.contains("--experimental-formatting")
                let recognition = try await speech.recognize(samples, language: "en", wordTimings: formatting)
                let transcript = recognition.text
                let draft = DictationFormatting.prepare(recognition, samples: samples, enabled: formatting)
                let recognized = Date()
                fputs("Speech recognized in \(String(format: "%.1f", recognized.timeIntervalSince(started)))s; cleaning \(transcript.count) characters locally.\n", stderr)
                let client = OllamaClient()
                try await client.checkModel()
                let cleaned = try await client.clean(draft)
                let result: [String: Any] = ["ok": true, "transcript": transcript, "cleaned": cleaned,
                                              "timedWords": recognition.words.count, "experimentalFormatting": formatting,
                                              "speechSeconds": recognized.timeIntervalSince(started),
                                              "totalSeconds": Date().timeIntervalSince(started)]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                exit(0)
            } catch {
                fputs("Self-test failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
