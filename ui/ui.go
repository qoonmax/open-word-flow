// Package ui runs the menu bar app: its Settings window and a recording
// indicator that grows out of the MacBook notch, like the iPhone Dynamic Island.
package ui

/*
#cgo darwin CFLAGS: -fblocks
#cgo darwin LDFLAGS: -framework AppKit -framework CoreImage -framework QuartzCore -framework CoreText
#include "native_darwin.h"
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"time"
	"unsafe"
)

// Preferences are the options set in the Settings window.
type Preferences struct {
	// Language is "auto" or an ISO 639-1 code such as "ru".
	Language string
	// Vocabulary lists words and phrases that transcription should favor.
	Vocabulary string
	// HoldFn records while Fn is held instead of between two double presses.
	HoldFn bool
}

const levelInterval = time.Second / 30

// stopLevels ends the level updates of the visible indicator. Show and Hide
// are called from one goroutine at a time, so it needs no lock.
var stopLevels chan struct{}

// Run runs the AppKit event loop until ctx is canceled. AppKit requires the
// main thread: call Run from the main goroutine locked with
// runtime.LockOSThread in an init function.
func Run(ctx context.Context) {
	for id, s := range sounds {
		cID := C.CString(id)
		C.owf_ui_add_sound(cID,
			unsafe.Pointer(&s.start[0]), C.int(len(s.start)),
			unsafe.Pointer(&s.stop[0]), C.int(len(s.stop)),
			unsafe.Pointer(&s.correct[0]), C.int(len(s.correct)))
		C.free(unsafe.Pointer(cID))
	}

	go func() {
		<-ctx.Done()
		C.owf_ui_stop()
	}()

	C.owf_ui_run()
}

// Alert shows message in a modal dialog; a Finder-launched app has no terminal.
func Alert(message string) {
	cMessage := C.CString(message)
	defer C.free(unsafe.Pointer(cMessage))

	C.owf_ui_alert(cMessage)
}

// LoadPreferences reads the current settings, so changes apply without a restart.
func LoadPreferences() Preferences {
	return Preferences{
		Language:   takeString(C.owf_settings_language()),
		Vocabulary: takeString(C.owf_settings_vocabulary()),
		HoldFn:     C.owf_settings_fn_hold() != 0,
	}
}

// Show chimes, expands the indicator out of the notch and animates it with
// level, which reports the microphone input level in [0, 1].
func Show(level func() float64) {
	stopLevelUpdates()
	C.owf_ui_chime(C.owf_chime_start)
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

// Processing chimes and shows that recording has stopped and transcription is
// running, until Hide.
func Processing() {
	stopLevelUpdates()
	C.owf_ui_chime(C.owf_chime_stop)
	C.owf_ui_processing()
}

// Correcting chimes and shows that a correction is being saved, unless the
// indicator is showing a recording.
func Correcting() {
	C.owf_ui_chime(C.owf_chime_correct)
	C.owf_ui_correcting()
}

// Corrected shows that correction number was saved, with the words of heard
// that fixed corrected, then hides the indicator.
func Corrected(number int, heard, fixed string) {
	cSegments := segmentsJSON(heard, fixed)
	defer C.free(unsafe.Pointer(cSegments))

	C.owf_ui_corrected(C.int(number), cSegments)
}

// SetCorrectionsFile tells Settings where the corrections it lists are kept.
// Call it before Run.
func SetCorrectionsFile(path string) {
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))

	C.owf_settings_set_corrections_file(cPath)
}

// segmentsJSON returns diff of heard and fixed as a JSON array in C memory;
// the caller frees it.
func segmentsJSON(heard, fixed string) *C.char {
	data, _ := json.Marshal(diff(heard, fixed)) // strings and ints always marshal

	return C.CString(string(data))
}

// NotCorrected shows that no correction was saved and why, then hides the
// indicator. reason is English; the indicator translates it.
func NotCorrected(reason string) {
	cReason := C.CString(reason)
	defer C.free(unsafe.Pointer(cReason))

	C.owf_ui_not_corrected(cReason)
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

func takeString(value *C.char) string {
	defer C.free(unsafe.Pointer(value))

	return C.GoString(value)
}

// owfSegmentsJSON is segmentsJSON for Settings, which lists corrections.
//
//export owfSegmentsJSON
func owfSegmentsJSON(heard, fixed *C.char) *C.char {
	return segmentsJSON(C.GoString(heard), C.GoString(fixed))
}
