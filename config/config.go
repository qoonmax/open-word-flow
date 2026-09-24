// Package config defines application-wide configuration.
package config

// Transcriber configures speech recognition.
type Transcriber struct {
	// ModelPath is the path to a ggml whisper model.
	ModelPath string
	// VADModelPath is the path to a ggml Silero VAD model. Voice activity
	// detection skips silence, where whisper tends to hallucinate text.
	// Empty disables it.
	VADModelPath string
}
