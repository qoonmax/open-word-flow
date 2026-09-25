// Package hotkey starts and stops recording with the macOS Fn (Globe) key:
// a double press toggles it, or in hold mode it lasts while Fn is held.
// Control+Fn reports a corrected transcript in either mode.
package hotkey

/*
#cgo darwin LDFLAGS: -framework ApplicationServices
#include "native_darwin.h"
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"time"
)

type (
	// Listener listens for Fn.
	Listener struct{}

	// trigger decides when Fn starts and stops recording. A double press is two
	// presses within window with no other keys in between.
	trigger struct {
		window    time.Duration
		last      time.Time
		recording bool
	}
)

// DoubleTapWindow is the maximum time between two Fn presses that counts as a double press.
const DoubleTapWindow = 400 * time.Millisecond

// NewListener creates an Fn listener.
func NewListener() *Listener {
	return &Listener{}
}

// Run listens for Fn until the context is canceled and invokes toggle each
// time recording should start or stop; calls alternate, starting with a start.
// hold, checked on every Fn event, reports whether hold mode is on. Pressing
// Fn while holding Control invokes correct instead.
func (l *Listener) Run(ctx context.Context, hold func() bool, toggle func() error, correct func()) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	listener := C.owf_fn_listen()
	if listener == nil {
		fmt.Println("Waiting for Accessibility or Input Monitoring access to listen for Fn...")
	}

	// On first launch macOS asks the user; start listening as soon as access is granted.
	for listener == nil {
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(time.Second):
			listener = C.owf_fn_listen()
		}
	}

	defer C.owf_fn_close(listener)

	fn := trigger{window: DoubleTapWindow}

	for ctx.Err() == nil {
		var switched bool

		switch C.owf_fn_wait(listener, 0.25) {
		case C.owf_event_error:
			return errors.New("listen for Fn key: macOS event tap was invalidated")
		case C.owf_event_other_key:
			fn.reset()
		case C.owf_event_fn_down:
			switched = fn.press(time.Now(), hold())
		case C.owf_event_fn_up:
			switched = fn.release(hold())
		case C.owf_event_control_fn_down:
			// Not the first press of a double press either.
			fn.reset()
			correct()
		}

		if !switched {
			continue
		}

		if err := toggle(); err != nil {
			return err
		}
	}

	return nil
}

// press records Fn going down at now and reports whether recording starts or stops.
func (t *trigger) press(now time.Time, hold bool) bool {
	if hold {
		started := !t.recording
		t.recording = true

		return started
	}

	if t.last.IsZero() || now.Sub(t.last) > t.window {
		t.last = now

		return false
	}

	t.reset()
	t.recording = !t.recording

	return true
}

// release records Fn going up and reports whether recording stops.
func (t *trigger) release(hold bool) bool {
	if !hold || !t.recording {
		return false
	}

	t.recording = false

	return true
}

func (t *trigger) reset() {
	t.last = time.Time{}
}
