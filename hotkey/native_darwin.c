#include <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>

#include "native_darwin.h"

// Virtual key code of Fn / Globe (kVK_Function).
static const int64_t owf_key_fn = 63;
// macOS follows every Fn release with a synthetic key press of this code; it is part of the Fn tap.
static const int64_t owf_key_globe = 179;

struct owf_fn_listener {
    CFMachPortRef tap;
    CFRunLoopSourceRef source;
    int32_t event;
};

static CGEventRef owf_fn_callback(
    CGEventTapProxy proxy,
    CGEventType type,
    CGEventRef event,
    void *info
) {
    (void)proxy;
    owf_fn_listener *listener = info;

    switch (type) {
    case kCGEventTapDisabledByTimeout:
    case kCGEventTapDisabledByUserInput:
        CGEventTapEnable(listener->tap, true);
        break;
    case kCGEventFlagsChanged:
        if (CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) != owf_key_fn) {
            listener->event = owf_event_other_key;
        } else if ((CGEventGetFlags(event) & kCGEventFlagMaskSecondaryFn) != 0) {
            listener->event = owf_event_fn_down;
        } else {
            listener->event = owf_event_fn_up;
        }
        break;
    default:
        if (CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) != owf_key_globe) {
            listener->event = owf_event_other_key;
        }
        break;
    }

    return event;
}

owf_fn_listener *owf_fn_listen(void) {
    owf_fn_listener *listener = calloc(1, sizeof(owf_fn_listener));
    if (listener == NULL) {
        return NULL;
    }

    CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventKeyDown);
    listener->tap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionListenOnly,
        mask,
        owf_fn_callback,
        listener
    );
    if (listener->tap == NULL) {
        // Shows the Input Monitoring prompt; Accessibility access also permits the tap.
        CGRequestListenEventAccess();
        free(listener);
        return NULL;
    }

    listener->source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, listener->tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), listener->source, kCFRunLoopDefaultMode);
    CGEventTapEnable(listener->tap, true);

    return listener;
}

int32_t owf_fn_wait(owf_fn_listener *listener, double timeout_seconds) {
    if (listener == NULL || !CFMachPortIsValid(listener->tap)) {
        return owf_event_error;
    }

    listener->event = owf_event_none;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, timeout_seconds, true);

    return listener->event;
}

void owf_fn_close(owf_fn_listener *listener) {
    if (listener == NULL) {
        return;
    }

    CGEventTapEnable(listener->tap, false);
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), listener->source, kCFRunLoopDefaultMode);
    CFMachPortInvalidate(listener->tap);
    CFRelease(listener->source);
    CFRelease(listener->tap);
    free(listener);
}
