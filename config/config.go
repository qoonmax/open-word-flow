// Package config defines application-wide configuration.
package config

// Transcriber configures speech recognition.
type Transcriber struct {
	// ModelPath is the path to a ggml whisper model.
	ModelPath string
	// Language is an ISO 639-1 code such as "ru" or "en", or "auto".
	Language string
}
