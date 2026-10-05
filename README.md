# Open Word Flow

Open Word Flow is a local macOS dictation app that lives in the menu bar. A
double press of the Fn (🌐) key starts and stops recording, or you hold Fn
while speaking; each clip is
transcribed offline with whisper.cpp and the text is pasted into the focused
application.

## Build and install

Requirements: macOS 26 or later on Apple Silicon, Go, the Xcode Command Line
Tools, and CMake. whisper.cpp is a git submodule, built as static libraries
under `third_party/whisper.cpp/build_go`:

```sh
make setup
```

`make setup` initializes the submodule, builds whisper.cpp, downloads both
models, and builds and opens the app. Install Go 1.26 or later, CMake, and
Xcode Command Line Tools (`xcode-select --install`) beforehand; with Homebrew,
Go and CMake can be installed using `brew install go cmake`. Setup uses ad-hoc
signing by default; use `make setup SIGN_IDENTITY="Apple Development"` if you
have a development certificate. Allow Microphone and Accessibility on first
launch, and configure Fn as described below.

After changing application code, quit the running app and use
`make run SIGN_IDENTITY=-` to rebuild and open it, or
`make install SIGN_IDENTITY=-` to rebuild and copy it to `/Applications`.
With a development certificate, omit `SIGN_IDENTITY=-`. Models are downloaded
only when missing, including during `make app`, `make run`, or `make install`.
Run `make setup` again after changing the whisper.cpp submodule or cleaning its
build directory. `make build` produces only the bare executable; use
`make app` for the complete app bundle.

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
at most 400 ms apart, no other keys in between), or switch **Dictation** in
Settings to holding Fn, and recording lasts while Fn is held. The transcript is
pasted into the focused application through the clipboard; the previous clipboard contents
are restored half a second later unless something new was copied in the
meantime. Silero voice activity detection drops silence before transcription,
so empty or near-silent clips paste nothing instead of whisper hallucinations
such as "Thank you."

**Settings…** in the menu bar icon sets the Fn mode, the speech language
(automatic by default), the interface language (English or Russian, following macOS by
default; switches immediately), and a vocabulary: names, terms, and English words you often say.
whisper reads the vocabulary as text spoken right before the recording, which
favors those spellings. Changes apply to the next recording. **Quit** finishes
an active recording without transcribing it.

To collect recognition errors, fix a pasted transcript, select the corrected
text, hold Control, and press Fn, in either Dictation mode. The app copies the
selection, pairs it with the most similar of the last ten transcripts, and
appends both as a JSON line to
`~/Library/Application Support/Open Word Flow/corrections.jsonl`, skipping a
pair it has just saved. Each press plays the correction chime of the chosen
sound, and the island widens and grows a row under the notch: while it saves,
it reads "Saving…"; then it shows the number of the correction and the
corrected words in context, with the misheard ones struck through. When
nothing is saved, the row says why: nothing was dictated or selected, the selection was unchanged, or it
resembled no recent transcript. Transcripts are kept only in memory until then,
so they are gone after a restart. The **Corrections** tab in Settings lists the
saved pairs, newest first, with the corrected words marked; each can be edited
or deleted, **Clear All…** deletes them all, and **Show File** reveals
`corrections.jsonl` in Finder.

While recording, a graphite island expands from the MacBook notch, with a
coral recording light, a timer, and a multicolor waveform that responds to your
voice. A soft blue, violet, rose, and amber glow traces its silhouette. On
displays without a notch, it appears as a floating capsule. While transcribing,
the light turns silver, the timer stops and dims, and a traveling wave signals
processing. The island folds away when the text is pasted, without taking focus.

Settings share the island's look: the same spectrum colors the logo, and the
fn key in the shortcut guide is island black with the same glow. They follow
the macOS light or dark appearance, with a shortcut guide,
a sound preview button, and an automatically saved vocabulary. Both surfaces
reduce ambient motion and bounce under Reduce Motion while retaining a brief,
smooth island reveal; the sidebar also respects Reduce Transparency.

To check the native interface without loading models, recording audio, or
pasting text, run `make ui-check` from a logged-in macOS desktop session. This
uses separate preview preferences, checks controls and recording transitions,
and writes light/dark English/Russian snapshots to `/tmp/owf-ui-check`.

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
