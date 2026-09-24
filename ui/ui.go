// Package ui shows a recording indicator that grows out of the MacBook notch,
// like the iPhone Dynamic Island.
package ui

/*
#cgo darwin CFLAGS: -fblocks
#cgo darwin LDFLAGS: -framework AppKit -framework QuartzCore
#include "native_darwin.h"
*/
import "C"

import (
	"context"
	"time"
)

const levelInterval = time.Second / 30

// stopLevels ends the level updates of the visible indicator. Show and Hide
// are called from one goroutine at a time, so it needs no lock.
var stopLevels chan struct{}

// Run runs the AppKit event loop until ctx is canceled. AppKit requires the
// main thread: call Run from the main goroutine locked with
// runtime.LockOSThread in an init function.
func Run(ctx context.Context) {
	go func() {
		<-ctx.Done()
		C.owf_ui_stop()
	}()

	C.owf_ui_run()
}

// Show expands the indicator out of the notch and animates it with level,
// which reports the microphone input level in [0, 1].
func Show(level func() float64) {
	stopLevelUpdates()
	C.owf_ui_show()

	stop := make(chan struct{})
	stopLevels = stop

	go func() {
		ticker := time.NewTicker(levelInterval)
		defer ticker.Stop()

		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				C.owf_ui_set_level(C.double(level()))
			}
		}
	}()
}

// Hide collapses the indicator back into the notch.
func Hide() {
	stopLevelUpdates()
	C.owf_ui_hide()
}

func stopLevelUpdates() {
	if stopLevels != nil {
		close(stopLevels)
		stopLevels = nil
	}
}
