package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"open-word-flow/asr"
	"open-word-flow/config"
	"open-word-flow/hotkey"
	"open-word-flow/paste"
	"open-word-flow/recording"
	"open-word-flow/ui"
)

// Model files, looked up by modelsDir.
const (
	modelFile    = "ggml-large-v3-turbo-q5_0.bin"
	vadModelFile = "ggml-silero-v6.2.0.bin"
)

func init() {
	// The ui package runs AppKit, which requires the main thread.
	runtime.LockOSThread()
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		ui.Alert(err.Error())
		os.Exit(1)
	}
}

func run() error {
	models := modelsDir()

	transcriber, err := asr.New(config.Transcriber{
		ModelPath:    filepath.Join(models, modelFile),
		VADModelPath: filepath.Join(models, vadModelFile),
	})
	if err != nil {
		return err
	}

	defer func() {
		_ = transcriber.Close()
	}()

	recorder, err := recording.New()
	if err != nil {
		return err
	}

	defer recorder.Close()

	if !paste.RequestAccess() {
		fmt.Println("Accessibility access is not granted yet: transcripts will only be copied to the clipboard.")
	}

	controller := recording.NewController(recorder)
	listener := hotkey.NewListener()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	fmt.Printf("Ready. Press %s to start or stop recording. Press Ctrl+C to exit.\n", listener)

	listenDone := make(chan error, 1)

	go func() {
		listenDone <- listener.Run(ctx, func() error {
			event, toggleErr := controller.Toggle()
			if toggleErr != nil {
				return toggleErr
			}

			if event.Recording {
				ui.Show(recorder.Level)
				fmt.Printf("Recording started. Press %s again to stop.\n", listener)

				return nil
			}

			ui.Processing()
			fmt.Printf("Recording stopped. Saved: %s\n", event.Path)

			if dictateErr := dictate(transcriber, event.Path); dictateErr != nil {
				fmt.Fprintln(os.Stderr, "error:", dictateErr)
			}

			ui.Hide()

			return nil
		})

		// Also ends the UI loop when the listener fails.
		stop()
	}()

	ui.Run(ctx)

	listenErr := <-listenDone

	event, stopped, err := controller.Stop()
	if err != nil {
		return err
	}

	if stopped {
		fmt.Printf("Recording stopped. Saved: %s\n", event.Path)
	}

	return listenErr
}

// dictate transcribes the recording at path and pastes the text into the focused app.
func dictate(transcriber *asr.Transcriber, path string) error {
	samples, err := asr.LoadWAV(path)
	if err != nil {
		return err
	}

	prefs := ui.LoadPreferences()

	segments, err := transcriber.Transcribe(samples, prefs.Language, prompt(prefs.Vocabulary))
	if err != nil {
		return fmt.Errorf("transcribe %s: %w", path, err)
	}

	parts := make([]string, 0, len(segments))
	for _, segment := range segments {
		if text := strings.TrimSpace(segment.Text); text != "" {
			parts = append(parts, text)
		}
	}

	if len(parts) == 0 {
		fmt.Println("No speech recognized.")

		return nil
	}

	text := strings.Join(parts, " ")
	fmt.Println("Transcript:", text)

	return paste.Text(text)
}

// modelsDir returns Contents/Resources/models inside the app bundle, or
// ./models when the bare binary runs from the repository.
func modelsDir() string {
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Join(filepath.Dir(exe), "..", "Resources", "models")
		if _, err := os.Stat(dir); err == nil {
			return dir
		}
	}

	return "models"
}

// prompt turns the Settings vocabulary, often one term per line, into whisper prompt text.
func prompt(vocabulary string) string {
	var terms []string

	for _, line := range strings.Split(vocabulary, "\n") {
		if term := strings.TrimSpace(line); term != "" {
			terms = append(terms, term)
		}
	}

	return strings.Join(terms, ", ")
}
