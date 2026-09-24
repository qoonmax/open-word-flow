#ifndef OPEN_WORD_FLOW_UI_NATIVE_DARWIN_H
#define OPEN_WORD_FLOW_UI_NATIVE_DARWIN_H

void owf_ui_run(void);
void owf_ui_stop(void);
void owf_ui_alert(const char *message);
void owf_ui_show(void);
void owf_ui_processing(void);
void owf_ui_hide(void);
void owf_ui_set_level(double level);
char *owf_settings_language(void);
char *owf_settings_vocabulary(void);

// Shared between the ui sources; main thread only.
void owf_activate(void);
void owf_island_setup(void);
void owf_settings_open(void);
void owf_status_menu_reload(void);

#ifdef __OBJC__
@class NSString;
// Returns english translated into the interface language chosen in Settings.
NSString *owf_text(NSString *english);
#endif

#endif
