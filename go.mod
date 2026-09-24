module open-word-flow

go 1.26

require (
	github.com/ggerganov/whisper.cpp/bindings/go v0.0.0
	github.com/go-audio/wav v1.1.0
)

require (
	github.com/go-audio/audio v1.0.0 // indirect
	github.com/go-audio/riff v1.0.0 // indirect
)

replace github.com/ggerganov/whisper.cpp/bindings/go => ./third_party/whisper.cpp/bindings/go
