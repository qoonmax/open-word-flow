#ifndef OPEN_WORD_FLOW_PASTE_NATIVE_DARWIN_H
#define OPEN_WORD_FLOW_PASTE_NATIVE_DARWIN_H

// Virtual key codes of C and V (kVK_ANSI_C, kVK_ANSI_V); with Cmd they resolve
// to Copy and Paste on any layout.
enum {
    owf_key_c = 8,
    owf_key_v = 9
};

int owf_accessibility_trusted(int prompt);
long owf_clipboard_set(const char *text);
char *owf_clipboard_text(void);
long owf_clipboard_change_count(void);
void *owf_clipboard_save(void);
void owf_clipboard_restore(void *snapshot);
void owf_clipboard_release(void *snapshot);
// Presses Cmd with key in the focused application.
int owf_send_command(int key);

#endif
