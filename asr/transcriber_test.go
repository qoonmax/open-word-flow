package asr

import "testing"

func TestTranscribeEmptyRecording(t *testing.T) {
	// No model is loaded: an empty recording must return before whisper runs.
	segments, err := (&Transcriber{}).Transcribe(nil, "auto", "")
	if err != nil || segments != nil {
		t.Fatalf("Transcribe(empty) = %v, %v; want no segments and no error", segments, err)
	}
}
