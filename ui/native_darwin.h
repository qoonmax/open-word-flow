#ifndef OPEN_WORD_FLOW_UI_NATIVE_DARWIN_H
#define OPEN_WORD_FLOW_UI_NATIVE_DARWIN_H

void owf_ui_run(void);
void owf_ui_stop(void);
void owf_ui_alert(const char *message);
void owf_ui_show(void);
void owf_ui_processing(void);
void owf_ui_hide(void);
void owf_ui_set_level(double level);
// Registers the start, stop, and correct WAV files of a sound offered in
// Settings; call before owf_ui_run. Copies the files.
void owf_ui_add_sound(
    const char *id,
    const void *start, int start_length,
    const void *stop, int stop_length,
    const void *correct, int correct_length
);

// The chimes of a sound.
enum owf_chime {
    owf_chime_start = 0,
    owf_chime_stop = 1,
    owf_chime_correct = 2
};

// Plays a chime of the sound chosen in Settings.
void owf_ui_chime(int chime);
// Shows the island in its correction look while a correction is saved, unless
// a recording or transcription is in view.
void owf_ui_correcting(void);
// Shows that correction number was saved with segments, a JSON array of
// {"text", "kind"} objects where kind is 0 kept, 1 removed, or 2 added; then
// folds the island away.
void owf_ui_corrected(int number, const char *segments);
// Shows that no correction was saved and why, in English to translate; then
// folds the island away.
void owf_ui_not_corrected(const char *reason);
// Sets the corrections.jsonl that Settings lists; call before owf_ui_run.
void owf_settings_set_corrections_file(const char *path);
// Returns the corrected words of heard in fixed as a JSON array of {"text",
// "kind"} objects, kind 0 kept, 1 removed, or 2 added; free it. Implemented in Go.
char *owfSegmentsJSON(char *heard, char *fixed);
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
@class NSArray, NSString;
// Returns the island's spectrum as CGColors, blue to amber; loop repeats the
// first color to close a conic gradient. Settings borrows it for one look.
NSArray *owf_palette(BOOL loop);
// Returns english translated into the interface language chosen in Settings.
NSString *owf_text(NSString *english);
// Returns the ID of the sound chosen in Settings.
NSString *owf_settings_sound(void);
// Plays both chimes of sound, as heard around a recording.
void owf_sound_preview(NSString *sound);
#endif

#endif
