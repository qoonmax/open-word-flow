package hotkey

import (
	"testing"
	"time"
)

func TestDoubleTap(t *testing.T) {
	start := time.Now()
	at := func(ms int) time.Time { return start.Add(time.Duration(ms) * time.Millisecond) }
	detector := doubleTap{window: 400 * time.Millisecond}

	if detector.press(at(0)) {
		t.Fatal("single press triggered")
	}

	if !detector.press(at(300)) {
		t.Fatal("double press within window did not trigger")
	}

	if detector.press(at(400)) {
		t.Fatal("third press re-triggered right after a double press")
	}

	if detector.press(at(1000)) {
		t.Fatal("presses 600ms apart triggered")
	}

	detector.reset()

	if detector.press(at(1100)) {
		t.Fatal("press after another key triggered")
	}
}
