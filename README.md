# Open Word Flow

Open Word Flow is a local macOS dictation app that lives in the menu bar. A
double press of the Fn (🌐) key starts and stops recording; each clip is
transcribed offline with whisper.cpp and the text is pasted into the focused
application.

## Build and install

Requirements: macOS 26 or later on Apple Silicon, Go, the Xcode Command Line
Tools, and CMake. whisper.cpp is a git submodule, built as static libraries
under `third_party/whisper.cpp/build_go`:

```sh
git submodule update --init
make whisper
third_party/whisper.cpp/models/download-ggml-model.sh large-v3-turbo-q5_0 models
third_party/whisper.cpp/models/download-vad-model.sh silero-v6.2.0 models
make app
```

`make app` builds `build/Open Word Flow.app` with both models inside and signs
it with your `Apple Development` certificate, so macOS keeps its permissions
across rebuilds. Without a certificate use `make app SIGN_IDENTITY=-`; macOS
then asks for Accessibility again after every rebuild. `make run` builds and
opens the app, and `make install` copies it to `/Applications`.

For development logs, run the binary inside the bundle from a terminal:

```sh
"build/Open Word Flow.app/Contents/MacOS/open-word-flow"
```

## Usage

Double-press Fn to start recording and double-press it again to stop (presses
at most 400 ms apart, no other keys in between). The transcript is pasted into
the focused application through the clipboard; the previous clipboard contents
are restored half a second later unless something new was copied in the
meantime. Silero voice activity detection drops silence before transcription,
so empty or near-silent clips paste nothing instead of whisper hallucinations
such as "Thank you."

**Settings…** in the menu bar icon sets the speech language (automatic by
default), the interface language (English or Russian, following macOS by
default; switches immediately), and a vocabulary: names, terms, and English words you often say.
whisper reads the vocabulary as text spoken right before the recording, which
favors those spellings. Changes apply to the next recording. **Quit** finishes
an active recording without transcribing it.

While recording, a black island grows out of the MacBook notch, continuing
it, with a red dot and a timer left of the camera and a gradient voice wave
right of it. A Siri-like glow lights the island from behind and swells as you
speak. After you stop, the wave rolls and the glow breathes while whisper
transcribes; the island folds back into the notch once the text is pasted. On
a screen without a notch it grows from the top center.

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

The first launch asks for Microphone and Accessibility access. If Microphone
access is denied, enable Open Word Flow in **System Settings → Privacy &
Security → Microphone** and relaunch it. Listening for Fn and automatic paste
need **Accessibility**; the app waits and starts listening as soon as it is
granted. Input Monitoring alone is enough for Fn, but without Accessibility the
transcript is only copied to the clipboard. When the binary is started from a
terminal, macOS applies the terminal's permissions instead.
