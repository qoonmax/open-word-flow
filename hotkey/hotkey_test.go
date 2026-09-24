package hotkey

import (
	"testing"
	"time"
)

func TestTrigger(t *testing.T) {
	start := time.Now()
	at := func(ms int) time.Time { return start.Add(time.Duration(ms) * time.Millisecond) }
	fn := trigger{window: 400 * time.Millisecond}

	if fn.press(at(0), false) {
		t.Fatal("single press triggered")
	}

	if !fn.press(at(300), false) || !fn.recording {
		t.Fatal("double press within window did not start recording")
	}

	if fn.release(false) {
		t.Fatal("release stopped a double-press recording")
	}

	if fn.press(at(400), false) {
		t.Fatal("third press re-triggered right after a double press")
	}

	if fn.press(at(1000), false) {
		t.Fatal("presses 600ms apart triggered")
	}

	fn.reset()

	if fn.press(at(1100), false) {
		t.Fatal("press after another key triggered")
	}

	if !fn.press(at(1200), false) || fn.recording {
		t.Fatal("second double press did not stop recording")
	}

	if !fn.press(at(2000), true) || !fn.recording {
		t.Fatal("holding Fn did not start recording")
	}

	if !fn.release(true) || fn.recording {
		t.Fatal("releasing Fn did not stop recording")
	}

	if fn.release(true) {
		t.Fatal("release while idle triggered")
	}
}
