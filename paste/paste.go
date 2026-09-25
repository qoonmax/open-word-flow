// Package paste inserts text into the focused macOS application and reads its
// selection.
package paste

/*
#cgo darwin LDFLAGS: -framework AppKit -framework ApplicationServices
#include "native_darwin.h"
#include <stdlib.h>
*/
import "C"

import (
	"errors"
	"time"
	"unsafe"
)

// restoreDelay gives the target application time to read the clipboard after
// Cmd+V before the previous contents are put back. Raise it if slow apps paste
// the old clipboard instead of the transcript.
const restoreDelay = 500 * time.Millisecond

// copyTimeout is how long Selection waits for the application to answer Cmd+C.
const copyTimeout = 500 * time.Millisecond

var errCopy = errors.New("copy transcript to clipboard")

// RequestAccess reports whether Accessibility access is granted and, if not,
// asks macOS to show the permission prompt.
func RequestAccess() bool {
	return C.owf_accessibility_trusted(1) == 1
}

// Text pastes text into the focused application through the clipboard and then
// restores the previous clipboard contents. Without Accessibility access it
// only copies text to the clipboard.
func Text(text string) error {
	cText := C.CString(text)
	defer C.free(unsafe.Pointer(cText))

	if C.owf_accessibility_trusted(0) != 1 {
		if C.owf_clipboard_set(cText) < 0 {
			return errCopy
		}

		return errors.New(
			"transcript copied to clipboard, but automatic paste needs Accessibility access; enable it in System Settings > Privacy & Security > Accessibility",
		)
	}

	saved := C.owf_clipboard_save()
	defer C.owf_clipboard_release(saved)

	changeCount := C.owf_clipboard_set(cText)
	if changeCount < 0 {
		C.owf_clipboard_restore(saved)

		return errCopy
	}

	if C.owf_send_command(C.owf_key_v) != 1 {
		return errors.New("transcript copied to clipboard, but sending Cmd+V failed")
	}

	time.Sleep(restoreDelay)

	// Keep anything the user copied in the meantime.
	if C.owf_clipboard_change_count() == changeCount {
		C.owf_clipboard_restore(saved)
	}

	return nil
}

// Selection copies the selection of the focused application with Cmd+C and
// returns it, then restores the previous clipboard contents. It returns ""
// when nothing was copied, such as when no text is selected.
func Selection() (string, error) {
	if C.owf_accessibility_trusted(0) != 1 {
		return "", errors.New(
			"reading the selection needs Accessibility access; enable it in System Settings > Privacy & Security > Accessibility",
		)
	}

	saved := C.owf_clipboard_save()
	defer C.owf_clipboard_release(saved)

	before := C.owf_clipboard_change_count()

	if C.owf_send_command(C.owf_key_c) != 1 {
		return "", errors.New("send Cmd+C")
	}

	var text *C.char

	// The change count moves as soon as the app clears the clipboard, which may
	// be a moment before the text is written.
	for deadline := time.Now().Add(copyTimeout); text == nil && time.Now().Before(deadline); {
		time.Sleep(10 * time.Millisecond)

		if C.owf_clipboard_change_count() != before {
			text = C.owf_clipboard_text()
		}
	}

	if C.owf_clipboard_change_count() != before {
		C.owf_clipboard_restore(saved)
	}

	if text == nil {
		return "", nil
	}

	defer C.free(unsafe.Pointer(text))

	return C.GoString(text), nil
}
