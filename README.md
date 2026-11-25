# Local Wispr

A native macOS dictation app for this Intel iMac. Activate the app, click a text field in another app, hold **Fn**, speak, and release. Local Wispr inserts **only the cleaned text** from local Qwen 3.5 2B at your cursor. It defaults to `qwen3.5:2b-q4_K_M` to reduce memory use on this 8 GB Mac. The existing `qwen3.5:2b` Q8 model is also selectable in Settings.

Speech recognition uses [whisper.cpp](https://github.com/ggml-org/whisper.cpp/tree/v1.8.2) with the multilingual Whisper base model. Text correction uses [Ollama’s local chat API](https://docs.ollama.com/api/chat). There is no paid service, account, API key, or cloud fallback.

## Use

1. Open **Local Wispr** from `~/Applications`.
2. Click **Activate Wispr** and allow microphone access.
3. Allow **Local Wispr** under **System Settings → Privacy & Security → Input Monitoring** and **Accessibility**. Reopen the app if macOS asks.
4. Click inside a text box in another app. Hold **Fn** while speaking, then release it.
5. Keep that field and cursor focused while recognition and cleanup finish. The cleaned text is inserted automatically, replacing any text you selected. There is no manual paste step.

The microphone button starts and stops a recording for preview inside Local Wispr. **Copy text** and **⌘⇧C** remain available. Closing the window leaves the app available in the menu bar; use **Quit Local Wispr** to exit. Clicking **Wispr is on** pauses the Fn shortcut. Automatic insertion can be turned off in Settings.

The menu bar shows a microphone while listening, a yellow waveform during speech recognition and Qwen cleanup, and a green checkmark after insertion is confirmed in the target text field. The green checkmark returns to the normal grey/white waveform after four seconds. Preview-only results, failed insertions, and unverified typing do not show the green confirmation.

To check insertion without recording, click **Settings → Test typing…**, then click a text field in another app during the 10-second countdown. It types “Local Wispr typing works.” With experimental formatting enabled it tests a short Markdown list instead. You can cancel the countdown from the menu bar.

Choose a spoken language in Settings. English is the default; Thai and automatic language detection are also available. Automatic detection can be less reliable for short phrases. The compact base model has limited accuracy for some languages and accents.

If Fn also opens Apple Dictation or the emoji picker, open **System Settings → Keyboard** and set **Press fn key to → Do Nothing**. The app does not change system keyboard settings itself.

## Experimental voice formatting

Enable **Settings → Experimental voice formatting** to try Markdown emphasis and spoken lists. The checkbox is **off by default** and remembers your choice. Turning it off bypasses word timing, acoustic analysis, and formatting commands for subsequent recordings, keeping the ordinary dictation path.

When enabled, a word much louder than the surrounding words can become ALL CAPS, strong emphasis can become `**bold**`, and lighter emphasis with a pitch lift can become `*italic*`. This uses approximate word timing and relative loudness/pitch, not a model that understands vocal intent. It needs at least four usable words in the same recording for comparison. Microphone gain, noise, accents, and recognition errors can affect results; isolated words are left plain.

Explicit commands provide more predictable control:

- “bold on cucumbers bold off” → `**Cucumbers**`
- “italic on cucumbers italic off” → `*Cucumbers*`
- “caps on cucumbers caps off” → `CUCUMBERS`
- “start list cucumbers next item carrots next item apples end list” → three lines beginning with `- `.

Commands are recognized in English when the checkbox is on. Qwen cleans the remaining words; Markdown is applied afterwards. Words that Qwen replaces or removes may lose their emphasis rather than transferring it to an unrelated word. Plain text fields show the markers; Markdown viewers render them. This mode adds processing and may take longer, especially for lists.

List insertion requires a field that accepts direct Accessibility text replacement. Wispr never sends a Return key to create a newline, so it cannot accidentally submit the message that way. If the field rejects multiline replacement, the formatted result remains available in Local Wispr.

## Privacy and behavior

- Whisper runs inside the app. Audio and the raw transcript stay in memory and are discarded after processing; a failed cleanup keeps its raw transcript in memory so you can retry.
- The app sends text only to `127.0.0.1:11434`. It accepts only the two local Qwen tags listed above and rejects Ollama model entries marked as remote.
- Only the latest cleaned text is displayed. It stays in memory until cleared or the app quits. There is no transcript history.
- Copying is manual by default. Automatic copying is optional in Settings. Clipboard contents are managed by macOS and any clipboard utilities you use.
- Automatic insertion first tries Accessibility replacement of the selection, then verified replacement of the field value for both sentences and lists. The latter preserves all text outside the selection and restores the cursor after the inserted text. If both methods leave the field unchanged, single-line text can use individual Unicode typing events. Insertion does not use the clipboard or a paste shortcut; the separate automatic-copy preference still applies if enabled.
- “Inserted” appears only after reading back the expected text from the destination field. If the field does not expose its text for verification, the app says “Sent” and asks you to check. Destination text and selection are read only in memory, never logged or saved.
- If you switch apps, focus another field, or move the cursor before cleanup finishes, the app keeps the cleaned text in its window instead of inserting into the wrong place. Password fields and controls that do not expose an editable text field are excluded. Some custom editors may not support insertion; multiline text requires direct Accessibility replacement of the selection or the field value, with readback verification.
- Recordings finish automatically at two minutes. Processing begins when recording stops; text is not streamed while speaking.
- Review names, numbers, and specialized terms. Both speech recognition and a small correction model can make mistakes.

## Build

Requires macOS 14+, Apple Command Line Tools, Python 3, and Ollama. This build enables the CPU and Apple Accelerate backends, including on Intel Macs.

```sh
ollama pull qwen3.5:2b-q4_K_M
./scripts/build.sh --install
open "$HOME/Applications/Local Wispr.app"
```

The build script fetches the pinned whisper.cpp `v1.8.2` source, CMake if necessary, and the multilingual base model. Initial setup requires internet access. Dictation runs locally after setup. It uses an available Apple Development signing identity, with ad hoc signing as a fallback. The stable app identifier is `local.wispr.desktop`.

To validate speech recognition and Qwen together against the upstream public JFK audio sample, including a negative test for silence:

```sh
python3 Tests/smoke.py
```

Unicode encoding and insertion verification can also be checked without sending any events:

```sh
xcrun swiftc -swift-version 5 -parse-as-library Sources/TextInsertion.swift Tests/InsertionTests.swift -framework AppKit -framework ApplicationServices -o .build/insertion-tests
.build/insertion-tests
xcrun swiftc -swift-version 5 -parse-as-library Sources/DictationFormatting.swift Tests/FormattingTests.swift -o .build/formatting-tests
.build/formatting-tests
```

The app executable also accepts `--self-test /absolute/path/to/audio.wav` for diagnostics. Add `--experimental-formatting` to exercise word timing and acoustic formatting. `--format-text 'start list cucumbers next item carrots end list'` checks spoken commands and local Qwen without recording. These diagnostic commands print fixture transcripts to standard output; the graphical app shows only cleaned text.

## Implementation

`AudioRecorder` converts microphone input to 16 kHz mono samples. `SpeechEngine` owns one Whisper context behind a Swift actor, and runs optional acoustic analysis off the main actor. `DictationFormatting` interprets explicit commands and projects emphasis onto matching words after cleanup. List lines are cleaned in one schema-constrained Ollama request, with their number and order validated. `AppModel` handles recording, recognition, correction, and retry states. `FnKeyMonitor` uses a listen-only Core Graphics event tap with a missed-release watchdog. `TextInsertion` captures the destination and selection before recording, validates focus after cleanup, and inserts without activating another app or sending a Return key. `OllamaClient` makes local requests with thinking disabled and a prompt that preserves the speaker’s language and meaning.

The UI uses a warm paper surface, dark ink, and a single rust accent. One recording control and one text workspace keep the main action clear. Motion is limited to the audio meter, recording ring, and processing-state transitions.

This is an independent personal project, not affiliated with Wispr Flow. whisper.cpp and the Whisper model are MIT-licensed; their license is included in the app. The Qwen model is separately distributed through Ollama.
