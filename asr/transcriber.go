// Package asr wraps whisper.cpp for speech-to-text.
package asr

import (
	"fmt"
	"io"
	"os"
	"time"

	whisper "github.com/ggerganov/whisper.cpp/bindings/go/pkg/whisper"

	"open-word-flow/config"
)

type (
	// Segment is one recognized phrase with its position in the audio.
	Segment struct {
		Start time.Duration
		End   time.Duration
		Text  string
	}

	// Transcriber holds a loaded whisper model. Safe to reuse for many files;
	// create one Context per Transcribe call.
	Transcriber struct {
		model        whisper.Model
		language     string
		vadModelPath string
	}
)

// New loads the configured whisper model.
func New(cfg config.Transcriber) (*Transcriber, error) {
	// whisper only loads the VAD model on the first transcription; fail at startup instead.
	if cfg.VADModelPath != "" {
		if _, err := os.Stat(cfg.VADModelPath); err != nil {
			return nil, fmt.Errorf("VAD model: %w", err)
		}
	}

	model, err := whisper.New(cfg.ModelPath)
	if err != nil {
		return nil, fmt.Errorf("load model %s: %w", cfg.ModelPath, err)
	}

	return &Transcriber{
		model:        model,
		language:     cfg.Language,
		vadModelPath: cfg.VADModelPath,
	}, nil
}

// Close releases the loaded whisper model.
func (t *Transcriber) Close() error {
	return t.model.Close()
}

// Transcribe recognizes speech in samples (16 kHz mono, [-1,1]).
// onSegment, if non-nil, is called as each segment is decoded.
func (t *Transcriber) Transcribe(samples []float32, onSegment func(Segment)) ([]Segment, error) {
	ctx, err := t.model.NewContext()
	if err != nil {
		return nil, fmt.Errorf("new context: %w", err)
	}

	if err := ctx.SetLanguage(t.language); err != nil {
		return nil, fmt.Errorf("set language %q: %w", t.language, err)
	}

	if t.vadModelPath != "" {
		ctx.SetVAD(true)
		ctx.SetVADModelPath(t.vadModelPath)
	}

	var cb whisper.SegmentCallback
	if onSegment != nil {
		cb = func(s whisper.Segment) {
			onSegment(Segment{Start: s.Start, End: s.End, Text: s.Text})
		}
	}

	if err := ctx.Process(samples, nil, cb, nil); err != nil {
		return nil, fmt.Errorf("process: %w", err)
	}

	var out []Segment

	for {
		s, err := ctx.NextSegment()
		if err == io.EOF {
			break
		}

		if err != nil {
			return nil, fmt.Errorf("next segment: %w", err)
		}

		out = append(out, Segment{Start: s.Start, End: s.End, Text: s.Text})
	}

	return out, nil
}
