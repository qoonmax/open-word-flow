#ifndef OPEN_WORD_FLOW_UI_NATIVE_DARWIN_H
#define OPEN_WORD_FLOW_UI_NATIVE_DARWIN_H

void owf_ui_run(void);
void owf_ui_stop(void);
void owf_ui_alert(const char *message);
void owf_ui_show(void);
void owf_ui_processing(void);
void owf_ui_hide(void);
void owf_ui_set_level(double level);
// Registers the start and stop WAV files of a sound offered in Settings; call
// before owf_ui_run. Copies the files.
void owf_ui_add_sound(const char *id, const void *start, int start_length, const void *stop, int stop_length);
// Plays the start or stop chime of the sound chosen in Settings.
void owf_ui_chime(int start);
char *owf_settings_language(void);
char *owf_settings_vocabulary(void);
// Reports whether recording lasts while Fn is held rather than between double presses.
int owf_settings_fn_hold(void);

// Shared between the ui sources; main thread only.
void owf_activate(void);
void owf_island_setup(void);
void owf_settings_open(void);
void owf_status_menu_reload(void);

#ifdef __OBJC__
@class NSString;
// Returns english translated into the interface language chosen in Settings.
NSString *owf_text(NSString *english);
// Returns the ID of the sound chosen in Settings.
NSString *owf_settings_sound(void);
// Plays both chimes of sound, as heard around a recording.
void owf_sound_preview(NSString *sound);
#endif

#endif
