package asr

import (
	"fmt"
	"os"

	wav "github.com/go-audio/wav"
)

// SampleRate is the only sample rate whisper accepts.
const SampleRate = 16000

// LoadWAV reads a 16 kHz mono 16-bit PCM WAV file into normalized samples.
func LoadWAV(path string) ([]float32, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}

	defer func() {
		_ = f.Close()
	}()

	dec := wav.NewDecoder(f)

	buf, err := dec.FullPCMBuffer()
	if err != nil {
		return nil, fmt.Errorf("decode wav %s: %w", path, err)
	}

	if dec.SampleRate != SampleRate {
		return nil, fmt.Errorf("%s: sample rate %d, want %d", path, dec.SampleRate, SampleRate)
	}

	if dec.NumChans != 1 {
		return nil, fmt.Errorf("%s: %d channels, want mono", path, dec.NumChans)
	}

	if dec.BitDepth != 16 {
		return nil, fmt.Errorf("%s: bit depth %d, want 16", path, dec.BitDepth)
	}

	samples := make([]float32, len(buf.Data))
	for i, v := range buf.Data {
		samples[i] = float32(v) / 32768
	}

	return samples, nil
}
