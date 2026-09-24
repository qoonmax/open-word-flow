// Package hotkey listens for a double press of the macOS Fn (Globe) key.
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
	// Listener listens for a double press of Fn.
	Listener struct{}

	// doubleTap detects two presses within window with no other keys in between.
	doubleTap struct {
		window time.Duration
		last   time.Time
	}
)

// DoubleTapWindow is the maximum time between two Fn presses that counts as a double press.
const DoubleTapWindow = 400 * time.Millisecond

// NewListener creates a double-Fn listener.
func NewListener() *Listener {
	return &Listener{}
}

// String returns a user-facing shortcut name.
func (l *Listener) String() string {
	return "Fn twice"
}

// Run listens for a double press of Fn and invokes callback until the context is canceled.
func (l *Listener) Run(ctx context.Context, callback func() error) error {
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

	detector := doubleTap{window: DoubleTapWindow}

	for ctx.Err() == nil {
		switch C.owf_fn_wait(listener, 0.25) {
		case C.owf_event_error:
			return errors.New("listen for Fn key: macOS event tap was invalidated")
		case C.owf_event_other_key:
			detector.reset()
		case C.owf_event_fn_down:
			if !detector.press(time.Now()) {
				continue
			}

			if err := callback(); err != nil {
				return err
			}
		}
	}

	return nil
}

// press records a press at now and reports whether it completes a double press.
func (d *doubleTap) press(now time.Time) bool {
	if !d.last.IsZero() && now.Sub(d.last) <= d.window {
		d.reset()

		return true
	}

	d.last = now

	return false
}

func (d *doubleTap) reset() {
	d.last = time.Time{}
}
