package recording

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

type fakeCapture struct {
	startPath string
	stopPath  string
	startErr  error
	stopErr   error
	starts    int
	stops     int
}

func (f *fakeCapture) Start() (string, error) {
	f.starts++

	return f.startPath, f.startErr
}

func (f *fakeCapture) Stop() (string, error) {
	f.stops++

	return f.stopPath, f.stopErr
}

func TestControllerToggle(t *testing.T) {
	capture := &fakeCapture{
		startPath: "/tmp/started.wav",
		stopPath:  "/tmp/stopped.wav",
	}
	controller := NewController(capture)

	started, err := controller.Toggle()
	if err != nil {
		t.Fatalf("start toggle: %v", err)
	}

	if !started.Recording || started.Path != capture.startPath {
		t.Fatalf("unexpected start event: %#v", started)
	}

	stopped, err := controller.Toggle()
	if err != nil {
		t.Fatalf("stop toggle: %v", err)
	}

	if stopped.Recording || stopped.Path != capture.stopPath {
		t.Fatalf("unexpected stop event: %#v", stopped)
	}

	if capture.starts != 1 || capture.stops != 1 {
		t.Fatalf("unexpected calls: starts=%d stops=%d", capture.starts, capture.stops)
	}
}

func TestControllerKeepsIdleStateAfterStartFailure(t *testing.T) {
	capture := &fakeCapture{startErr: errors.New("start failed")}
	controller := NewController(capture)

	if _, err := controller.Toggle(); err == nil {
		t.Fatal("expected start error")
	}

	if _, err := controller.Toggle(); err == nil {
		t.Fatal("expected second start error")
	}

	if capture.starts != 2 || capture.stops != 0 {
		t.Fatalf("unexpected calls: starts=%d stops=%d", capture.starts, capture.stops)
	}
}

func TestNewOutputPathIsUniqueAndReservedOnlyByName(t *testing.T) {
	dir := t.TempDir()

	first, err := newOutputPath(dir)
	if err != nil {
		t.Fatalf("first path: %v", err)
	}

	second, err := newOutputPath(dir)
	if err != nil {
		t.Fatalf("second path: %v", err)
	}

	if first == second {
		t.Fatalf("paths are not unique: %s", first)
	}

	for _, path := range []string{first, second} {
		if filepath.Dir(path) != dir {
			t.Fatalf("path %s is outside %s", path, dir)
		}

		if filepath.Ext(path) != ".wav" {
			t.Fatalf("path %s does not have .wav extension", path)
		}

		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("reserved path should not exist yet: %v", err)
		}
	}
}
