#ifndef OPEN_WORD_FLOW_HOTKEY_NATIVE_DARWIN_H
#define OPEN_WORD_FLOW_HOTKEY_NATIVE_DARWIN_H

#include <stdint.h>

enum {
    owf_event_error = -1,
    owf_event_none = 0,
    owf_event_fn_down = 1,
    owf_event_other_key = 2,
    owf_event_fn_up = 3,
    owf_event_control_fn_down = 4
};

typedef struct owf_fn_listener owf_fn_listener;

owf_fn_listener *owf_fn_listen(void);
int32_t owf_fn_wait(owf_fn_listener *listener, double timeout_seconds);
void owf_fn_close(owf_fn_listener *listener);

#endif
