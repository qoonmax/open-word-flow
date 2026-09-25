package ui

import (
	"bytes"
	"math"
	"testing"

	wav "github.com/go-audio/wav"
)

func TestChimes(t *testing.T) {
	for id, s := range sounds {
		for _, chime := range [][]byte{s.start, s.stop} {
			dec := wav.NewDecoder(bytes.NewReader(chime))

			buf, err := dec.FullPCMBuffer()
			if err != nil {
				t.Fatalf("%s: decode: %v", id, err)
			}

			if dec.SampleRate != chimeRate || dec.NumChans != 1 || dec.BitDepth != 16 {
				t.Fatalf("%s: format %d Hz, %d ch, %d bit", id, dec.SampleRate, dec.NumChans, dec.BitDepth)
			}

			data := buf.Data

			peak := 0
			for _, v := range data {
				peak = max(peak, v, -v)
			}

			if want := chimeVolume * math.MaxInt16; float64(peak) < want*0.99 || float64(peak) > want {
				t.Fatalf("%s: peak %d, want %.0f", id, peak, want)
			}

			// Silent edges: no clicks at start or end.
			if first, last := data[0], data[len(data)-1]; first != 0 || last > 100 || last < -100 {
				t.Fatalf("%s: edges %d, %d, want near 0", id, first, last)
			}
		}
	}
}
