import SwiftUI

private enum Theme {
    static let paper = Color(red: 0.965, green: 0.961, blue: 0.946)
    static let ink = Color(red: 0.17, green: 0.19, blue: 0.18)
    static let muted = Color(red: 0.48, green: 0.49, blue: 0.46)
    static let accent = Color(red: 0.78, green: 0.34, blue: 0.16)
    static let line = Color(red: 0.87, green: 0.87, blue: 0.83)
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            recordingControl.padding(.top, 40).padding(.bottom, 34)
            Rectangle().fill(Theme.line).frame(height: 1)
            output.padding(.top, 25)
            footer.padding(.top, 22)
        }
        .padding(.horizontal, 44).padding(.top, 52).padding(.bottom, 26)
        .frame(minWidth: 840, minHeight: 620)
        .background(Theme.paper)
        .foregroundStyle(Theme.ink)
        .preferredColorScheme(.light)
        .sheet(isPresented: $model.showingSettings) { SettingsView(model: model) }
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 23, weight: .bold)).foregroundStyle(Theme.accent)
                Text("Local Wispr").font(.system(size: 26, weight: .semibold, design: .rounded)).tracking(-0.7)
            }
            Spacer()
            Label("On this Mac", systemImage: "lock.shield")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                .padding(.trailing, 15)
            Button { model.showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 15)).frame(width: 32, height: 32)
            }
            .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
            Button { model.toggleEnabled() } label: {
                HStack(spacing: 7) {
                    Circle().fill(model.enabled ? Theme.accent : Theme.muted).frame(width: 6, height: 6)
                    Text(model.enabled ? "Wispr is on" : "Activate Wispr").font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(model.enabled ? Theme.accent.opacity(0.08) : Color.white.opacity(0.7))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain).padding(.leading, 7)
            .accessibilityLabel(model.enabled ? "Pause Wispr" : "Activate Wispr")
        }
    }

    private var recordingControl: some View {
        HStack(spacing: 26) {
            Button { model.toggleRecording() } label: {
                ZStack {
                    Circle().stroke(Theme.accent.opacity(model.phase == .recording ? 0.17 : 0), lineWidth: 9)
                        .frame(width: 102, height: 102)
                        .scaleEffect(model.phase == .recording ? 1 + CGFloat(model.meter) * 0.13 : 1)
                    Circle().fill(model.phase == .recording ? Theme.accent : Theme.ink).frame(width: 88, height: 88)
                    if model.busy {
                        ProgressView().controlSize(.regular).tint(.white).preferredColorScheme(.dark)
                    } else {
                        Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: model.phase == .recording ? 23 : 28, weight: .medium)).foregroundStyle(.white)
                    }
                }
                .frame(width: 110, height: 110).contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(model.busy || !model.ready)
            .accessibilityLabel(model.phase == .recording ? "Stop recording" : "Start recording")
            .help(model.phase == .recording ? "Finish and clean up" : "Click to record, then click again to finish")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if model.phase == .idle {
                        Text("Hold").font(.system(size: 29, weight: .medium)).tracking(-0.8)
                        Text("fn").font(.system(size: 24, weight: .medium, design: .rounded))
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
                        Text("to speak").font(.system(size: 29, weight: .medium)).tracking(-0.8)
                    } else {
                        Text(model.phase == .recording ? "Listening to you" : "Finding your words")
                            .font(.system(size: 29, weight: .medium)).tracking(-0.8)
                    }
                }
                Text(controlHint).font(.system(size: 13)).foregroundStyle(Theme.muted)
                HStack(spacing: 8) {
                    Circle().fill(model.enabled && model.ready ? Theme.accent : Theme.muted.opacity(0.6)).frame(width: 5, height: 5)
                    Text(model.status).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                }.padding(.top, 2)
            }
            Spacer(minLength: 15)
            if model.phase == .recording {
                VStack(alignment: .trailing, spacing: 11) {
                    AudioMeter(level: model.meter)
                    Text(String(format: "%02d:%02d", Int(model.elapsed) / 60, Int(model.elapsed) % 60))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                }.transition(.opacity)
            }
        }
    }

    private var controlHint: String {
        switch model.phase {
        case .idle:
            if !model.enabled { return "Activate Wispr to use Fn, or click the microphone." }
            return model.autoInsert ? "Click a text field in any app. Release Fn to insert your words." : "Release to finish. Your cleaned text appears below."
        case .recording: return "Release Fn, or click stop, when you’re finished."
        case .transcribing: return "Turning your recording into text on this Mac."
        case .polishing: return "Fixing punctuation and grammar. Keeping your meaning."
        }
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("CLEANED TEXT").font(.system(size: 10, weight: .semibold)).tracking(1.9).foregroundStyle(Theme.muted)
                if let status = model.insertionStatus {
                    Text(status).font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.leading, 10)
                }
                Spacer()
                if !model.cleanedText.isEmpty {
                    Button("Clear") { model.clearText() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted).disabled(model.phase != .idle)
                    Button { model.copyText() } label: {
                        Label(model.copied ? "Copied" : "Copy text", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                    }.buttonStyle(.plain).keyboardShortcut("c", modifiers: [.command, .shift]).padding(.leading, 17)
                }
            }.frame(height: 22)
            if model.cleanedText.isEmpty {
                VStack(alignment: .leading, spacing: 13) {
                    Text(model.busy ? "Cleaning your dictation…" : "Your cleaned text appears here.")
                        .font(.system(size: 28, weight: .regular, design: .serif)).foregroundStyle(Theme.ink.opacity(0.32))
                    Text("Speak naturally. Qwen handles the punctuation and grammar.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted.opacity(0.8))
                    Spacer(minLength: 20)
                }.padding(.top, 24).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    Text(model.cleanedText)
                        .font(.system(size: 23, weight: .regular, design: .serif))
                        .lineSpacing(9).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle").padding(.top, 1)
                    Text(error).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if model.canRetry { Button("Retry cleanup") { model.retryCleanup() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).disabled(model.busy) }
                    Button { model.error = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }
                .foregroundStyle(Theme.accent).padding(13).background(Theme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            }
        }.frame(maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 16) {
            if !model.qwenReady, let issue = model.qwenIssue {
                HStack {
                    Text(issue).font(.system(size: 11)).foregroundStyle(Theme.accent)
                    Spacer()
                    Button("Open Ollama") { model.openOllama() }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    Button("Check again") { Task { await model.checkOllama() } }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).padding(.leading, 10)
                }
            }
            HStack(spacing: 7) {
                Image(systemName: "cpu").font(.system(size: 11))
                Text("Whisper base  →  Qwen 3.5 · 2B").font(.system(size: 11))
                Spacer()
                if !model.cleanedText.isEmpty {
                    Text("\(model.wordCount) words").font(.system(size: 11))
                    if let duration = model.lastProcessingTime { Text("·  \(String(format: "%.1f", duration))s").font(.system(size: 11)) }
                } else {
                    Text("Local models. No subscription.").font(.system(size: 11))
                }
            }.foregroundStyle(Theme.muted)
        }
    }
}

private struct AudioMeter: View {
    let level: Float
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<13) { index in
                Capsule().fill(Theme.accent.opacity(0.6 + Double(index % 3) * 0.15))
                    .frame(width: 3, height: 5 + CGFloat(level) * CGFloat([13, 27, 17, 36, 24, 40, 29, 34, 18, 27, 13, 21, 9][index]))
            }
        }.frame(width: 90, height: 45).animation(.easeOut(duration: 0.12), value: level)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 23, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(30).padding(.bottom, -6)
            ScrollView {
            VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                Text("DICTATION").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Theme.muted)
                Picker("Spoken language", selection: $model.language) {
                    Text("English").tag("en"); Text("Thai").tag("th"); Text("Auto-detect").tag("auto")
                    Text("Chinese").tag("zh"); Text("Japanese").tag("ja"); Text("Korean").tag("ko")
                    Text("Spanish").tag("es"); Text("French").tag("fr"); Text("German").tag("de")
                    Text("Vietnamese").tag("vi")
                }.disabled(model.phase != .idle)
                Picker("Cleanup model", selection: $model.qwenModel) {
                    Text("Qwen 3.5 2B · Q4 (lighter)").tag(OllamaClient.recommendedModel)
                    Text("Qwen 3.5 2B · Q8 (original)").tag(OllamaClient.originalModel)
                }.disabled(model.phase != .idle)
                Toggle("Insert cleaned text into the active text field", isOn: $model.autoInsert).toggleStyle(.checkbox)
                    .disabled(model.phase != .idle)
                Toggle("Copy cleaned text to clipboard automatically", isOn: $model.autoCopy).toggleStyle(.checkbox)
                Text("Fn dictation inserts at your cursor without a paste command. Keep the same field focused while processing. The microphone button shows text here.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("EXPERIMENTAL").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Theme.muted)
                Toggle("Experimental voice formatting", isOn: $model.experimentalFormatting)
                    .toggleStyle(.checkbox).disabled(model.phase != .idle)
                Text("Adds word timing and voice analysis, so dictation may take longer. Off by default. Your choice is saved.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                Text("Loud words → ALL CAPS · strong emphasis → **bold** · lighter emphasis with a pitch lift → *italics*. Voice detection is approximate and needs a few words for comparison.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                Text("For reliable control: “bold on … bold off”, “italic on … italic off”, or “caps on … caps off”. For bullets: “start list … next item … end list”. Commands work when this checkbox is on.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                Text("Inserts Markdown markers. Formatting is rendered by apps that support Markdown.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Divider()
            VStack(alignment: .leading, spacing: 15) {
                Text("MAC PERMISSIONS").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Theme.muted)
                permissionRow("Microphone", detail: "Needed to hear your voice.", ready: model.microphoneReady) {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { Task { await model.activate() } }
                    else { model.openPrivacy("Privacy_Microphone") }
                }
                permissionRow("Input Monitoring", detail: "Needed to use Fn while another app is open.", ready: model.fnReady) {
                    model.requestFnPermission()
                    if !model.fnReady { model.openPrivacy("Privacy_ListenEvent") }
                }
                permissionRow("Accessibility", detail: "Needed to insert text into another app.", ready: model.accessibilityReady) {
                    model.requestInsertionPermission()
                }
                HStack(alignment: .top, spacing: 15) {
                    Text("Test typing starts a 10-second countdown. Click a text field in another app to receive a short sample, or a Markdown list when experimental formatting is on.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Button("Test typing…") { model.testTyping() }.controlSize(.small)
                        .disabled(model.phase != .idle || model.typingTestCountdown != nil || !model.accessibilityReady)
                }
                Text("After allowing Input Monitoring, macOS may ask you to quit and reopen Local Wispr.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                HStack(alignment: .top) {
                    Text("If Fn also starts Apple Dictation or the emoji picker, set “Press fn key to” to “Do Nothing” in Keyboard settings.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Button("Keyboard…") { model.openKeyboardSettings() }.controlSize(.small)
                }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Qwen 3.5 · 2B").font(.system(size: 13, weight: .medium))
                    Text(model.qwenReady ? "Connected locally · 127.0.0.1:11434" : (model.qwenIssue ?? "Checking Ollama…"))
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Check again") { model.refreshPermissions(); Task { await model.checkOllama() } }.controlSize(.small)
            }
            }.padding(30).padding(.top, -6)
            }
        }.frame(width: 540, height: 640).background(Theme.paper).foregroundStyle(Theme.ink).preferredColorScheme(.light)
        .onAppear { model.refreshPermissions() }
    }

    private func permissionRow(_ title: String, detail: String, ready: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle").foregroundStyle(ready ? Theme.accent : Theme.muted)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if !ready { Button("Allow…", action: action).controlSize(.small) }
        }
    }
}

import AVFoundation
