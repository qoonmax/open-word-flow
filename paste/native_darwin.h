#ifndef OPEN_WORD_FLOW_PASTE_NATIVE_DARWIN_H
#define OPEN_WORD_FLOW_PASTE_NATIVE_DARWIN_H

int owf_accessibility_trusted(int prompt);
long owf_clipboard_set(const char *text);
long owf_clipboard_change_count(void);
void *owf_clipboard_save(void);
void owf_clipboard_restore(void *snapshot);
void owf_clipboard_release(void *snapshot);
int owf_send_paste(void);

#endif
