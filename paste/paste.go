// Package paste inserts text into the focused macOS application.
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

	if C.owf_send_paste() != 1 {
		return errors.New("transcript copied to clipboard, but sending Cmd+V failed")
	}

	time.Sleep(restoreDelay)

	// Keep anything the user copied in the meantime.
	if C.owf_clipboard_change_count() == changeCount {
		C.owf_clipboard_restore(saved)
	}

	return nil
}
