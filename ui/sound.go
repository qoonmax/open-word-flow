package ui

import (
	"bytes"
	"encoding/binary"
	"math"
)

type (
	// voice is the timbre shared by the notes of a chime.
	voice struct {
		// attack and decay in seconds: the fade-in against clicks and the time to fall to 1/e.
		attack, decay float64
		// overtone is the level of an octave above each note that fades faster, brightening the onset.
		overtone float64
	}

	// tone is a note of freq Hz starting at seconds; its pitch slides in from bend semitones away.
	tone struct {
		at, freq, bend float64
	}

	// sound is the set of chimes that marks the start and stop of a recording
	// and a press of Control+Fn.
	sound struct {
		start, stop, correct []byte
	}
)

const (
	chimeRate = 44100
	// chimeVolume is the peak amplitude; the system volume scales it further.
	chimeVolume = 0.25
	// glideTime is how fast a bent note slides to its pitch, in seconds to 1/e.
	glideTime = 0.03
)

// Note frequencies in Hz.
const (
	g4  = 392.00
	bb4 = 466.16
	b4  = 493.88
	d5  = 587.33
)

var (
	glass = voice{attack: 0.004, decay: 0.1, overtone: 0.3}
	pulse = voice{attack: 0.004, decay: 0.07}
	glow  = voice{attack: 0.015, decay: 0.16, overtone: 0.1}

	// sounds are the chime sets offered in Settings, by ID: soft and low, meant
	// to stay pleasant after hundreds of plays a day. Start rises, stop falls,
	// and correct repeats one note, so the three are told apart by ear.
	sounds = map[string]sound{
		"glass": {
			chime(glass, tone{0, g4, 0}, tone{0.07, d5, 0}),
			chime(glass, tone{0, d5, 0}, tone{0.07, b4, 0}),
			chime(glass, tone{0, d5, 0}, tone{0.1, d5, 0}),
		},
		"pulse": {
			chime(pulse, tone{0, d5, -5}),
			chime(pulse, tone{0, g4, 7}),
			chime(pulse, tone{0, d5, 0}, tone{0.09, d5, 0}),
		},
		// G major rolled up, G minor rolled down.
		"glow": {
			chime(glow, tone{0, g4, 0}, tone{0.045, b4, 0}, tone{0.09, d5, 0}),
			chime(glow, tone{0, d5, 0}, tone{0.045, bb4, 0}, tone{0.09, g4, 0}),
			chime(glow, tone{0, d5, 0}, tone{0.12, d5, 0}),
		},
	}
)

// chime renders tones, listed in order, as a 16-bit mono WAV file that lasts
// until the last one has faded out.
func chime(v voice, tones ...tone) []byte {
	length := tones[len(tones)-1].at + 7*v.decay // e^-7 is below -60 dB
	samples := make([]float64, int(length*chimeRate))
	peak := 0.0

	for i := range samples {
		t := float64(i) / chimeRate

		for _, n := range tones {
			samples[i] += v.note(n, t-n.at)
		}

		peak = math.Max(peak, math.Abs(samples[i]))
	}

	pcm := make([]int16, len(samples))
	for i, s := range samples {
		pcm[i] = int16(s / peak * chimeVolume * math.MaxInt16)
	}

	size := uint32(2 * len(pcm))

	var wav bytes.Buffer

	for _, field := range []any{
		[]byte("RIFF"), 36 + size, []byte("WAVEfmt "),
		uint32(16), uint16(1), uint16(1), uint32(chimeRate), uint32(2 * chimeRate), uint16(2), uint16(16),
		[]byte("data"), size, pcm,
	} {
		_ = binary.Write(&wav, binary.LittleEndian, field) // writing to a bytes.Buffer never fails
	}

	return wav.Bytes()
}

// note returns n t seconds after it starts: a sine that fades in, slides to
// its pitch, and decays exponentially.
func (v voice) note(n tone, t float64) float64 {
	if t < 0 {
		return 0
	}

	// The phase integrates the pitch as it slides from the bend to freq.
	slide := (math.Exp2(n.bend/12) - 1) * glideTime * (1 - math.Exp(-t/glideTime))
	phase := 2 * math.Pi * n.freq * (t + slide)
	envelope := math.Min(t/v.attack, 1) * math.Exp(-t/v.decay)

	return envelope * (math.Sin(phase) + v.overtone*math.Exp(-t/0.03)*math.Sin(2*phase))
}
