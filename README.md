# Open Word Flow

Open Word Flow is a local macOS dictation tool. A double press of the Fn (🌐)
key starts and stops recording; each clip is transcribed offline with
whisper.cpp and the text is pasted into the focused application (clipboard +
Cmd+V).

## Build and run

Requirements: macOS on Apple Silicon, Go, the Xcode Command Line Tools, and
CMake. whisper.cpp is a git submodule, built as static libraries under
`third_party/whisper.cpp/build_go`:

```sh
git submodule update --init
make whisper
third_party/whisper.cpp/models/download-ggml-model.sh large-v3-turbo-q5_0 models
third_party/whisper.cpp/models/download-vad-model.sh silero-v6.2.0 models
make build
./bin/open-word-flow
```

By default the model is loaded from `models/ggml-large-v3-turbo-q5_0.bin` and
the language is auto-detected. Silero voice activity detection
(`models/ggml-silero-v6.2.0.bin`) drops silence before transcription, so empty
or near-silent clips paste nothing instead of whisper hallucinations such as
"Thank you." Override any of them; `-vad-model ""` disables VAD:

```sh
./bin/open-word-flow -model path/to/ggml-model.bin -lang ru -vad-model path/to/vad.bin
```

Double-press Fn to start recording and double-press it again to stop (presses
at most 400 ms apart, no other keys in between). The transcript is printed
and pasted into the focused application through the clipboard; the previous
clipboard contents are restored half a second later unless something new was
copied in the meantime. Press `Ctrl+C` to exit; an
active clip is saved but not transcribed.

While recording, a black Dynamic Island–style indicator grows out of the
MacBook notch with a pulsing red dot and live microphone level bars, and folds
back into the notch when recording stops. On a screen without a notch it grows
from the top center of the main screen.

## macOS Fn settings

macOS reacts to Fn itself, and the application cannot suppress that. Set
**System Settings → Keyboard → Press 🌐 key to** to **Do Nothing**; otherwise
every double press also switches the input source twice or opens the emoji
picker. If **Keyboard → Dictation → Shortcut** is set to pressing 🌐 twice,
choose another shortcut, or macOS dictation starts too.

## Files and permissions

Recordings are written beneath the standard macOS temporary directory:

```text
.../open-word-flow-*/recording-*.wav
```

Names are unique. The application does not delete completed recordings.

macOS requires Microphone permission. The first run requests it using the
embedded `NSMicrophoneUsageDescription`. If access is denied, enable Open Word
Flow (or the terminal that launched it) in **System Settings → Privacy &
Security → Microphone**, then restart the program.

Listening for Fn and automatic paste require Accessibility permission. The
first run shows the macOS prompt; enable Open Word Flow (or the terminal that
launched it) in **System Settings → Privacy & Security → Accessibility**, then
restart the program. Input Monitoring alone is enough for listening to Fn, but
without Accessibility the transcript is only copied to the clipboard.
