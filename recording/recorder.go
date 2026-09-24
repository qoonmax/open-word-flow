// Package recording captures microphone input into ASR-compatible WAV files.
package recording

/*
#cgo darwin CFLAGS: -fblocks
#cgo darwin LDFLAGS: -framework AVFoundation -framework Foundation
#include "native_darwin.h"
#include <stdlib.h>
*/
import "C"

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"unsafe"
)

type (
	// Capture starts and stops one recording at a time.
	Capture interface {
		Start() (string, error)
		Stop() (string, error)
	}

	// Event describes the result of a recording state transition.
	Event struct {
		Recording bool
		Path      string
	}

	// Recorder captures the default macOS microphone.
	Recorder struct {
		mu     sync.Mutex
		dir    string
		handle *C.owf_native_recorder
		path   string
	}

	// Controller toggles a Capture between recording and stopped states.
	Controller struct {
		mu      sync.Mutex
		capture Capture
		active  bool
	}
)

const outputDirPattern = "open-word-flow-*"

// New requests microphone access and prepares a private application temp directory.
func New() (*Recorder, error) {
	if C.owf_microphone_permission() != 1 {
		return nil, errors.New(
			"microphone access is required; enable it in System Settings > Privacy & Security > Microphone, then restart Open Word Flow",
		)
	}

	dir, err := os.MkdirTemp("", outputDirPattern)
	if err != nil {
		return nil, fmt.Errorf("create recording temp directory: %w", err)
	}

	return &Recorder{dir: dir}, nil
}

// NewController creates a recording toggle controller.
func NewController(capture Capture) *Controller {
	return &Controller{capture: capture}
}

// Start begins recording into a new unique WAV file.
func (r *Recorder) Start() (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.handle != nil {
		return "", errors.New("recording is already active")
	}

	path, err := newOutputPath(r.dir)
	if err != nil {
		return "", err
	}

	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))

	var nativeErr *C.char

	handle := C.owf_recorder_start(cPath, &nativeErr)
	if handle == nil {
		_ = os.Remove(path)

		return "", nativeFailure("start microphone recording", nativeErr)
	}

	r.handle = handle
	r.path = path

	return path, nil
}

// Stop finishes the active WAV file and returns its path.
func (r *Recorder) Stop() (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.handle == nil {
		return "", errors.New("recording is not active")
	}

	C.owf_recorder_stop(r.handle)
	r.handle = nil

	path := r.path
	r.path = ""

	if _, err := os.Stat(path); err != nil {
		return "", fmt.Errorf("finish recording %s: %w", path, err)
	}

	return path, nil
}

// Level returns the current microphone input level in [0, 1], or 0 when idle.
func (r *Recorder) Level() float64 {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.handle == nil {
		return 0
	}

	return float64(C.owf_recorder_level(r.handle))
}

// Close stops an active recording and releases native resources.
func (r *Recorder) Close() {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.handle != nil {
		C.owf_recorder_stop(r.handle)
		r.handle = nil
	}
}

// Toggle starts recording when idle and stops it when active.
func (c *Controller) Toggle() (Event, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.active {
		path, err := c.capture.Stop()
		c.active = false

		return Event{Path: path}, err
	}

	path, err := c.capture.Start()
	if err != nil {
		return Event{}, err
	}

	c.active = true

	return Event{Recording: true, Path: path}, nil
}

// Stop stops recording if the controller is active.
func (c *Controller) Stop() (Event, bool, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.active {
		return Event{}, false, nil
	}

	path, err := c.capture.Stop()
	c.active = false

	return Event{Path: path}, true, err
}

func newOutputPath(dir string) (string, error) {
	file, err := os.CreateTemp(dir, "recording-*.wav")
	if err != nil {
		return "", fmt.Errorf("reserve recording filename: %w", err)
	}

	path := file.Name()

	if err := file.Close(); err != nil {
		return "", fmt.Errorf("close reserved recording file: %w", err)
	}

	if err := os.Remove(path); err != nil {
		return "", fmt.Errorf("prepare recording file %s: %w", path, err)
	}

	return filepath.Clean(path), nil
}

func nativeFailure(action string, nativeErr *C.char) error {
	if nativeErr == nil {
		return errors.New(action)
	}

	defer C.free(unsafe.Pointer(nativeErr))

	return fmt.Errorf("%s: %s", action, C.GoString(nativeErr))
}
