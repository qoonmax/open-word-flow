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
#import <AppKit/AppKit.h>

// How a theme draws the island.
typedef struct {
    // A tilted card hanging under the notch, outlined in ink, with a hard
    // shadow and a display-weight timer, instead of a black shape that grows
    // out of the notch in a glow.
    BOOL floating;
    // Its body while recording, transcribing, and saving a correction.
    NSColor *fill[3];
    // Words, the timer, and a floating card's outlines.
    NSColor *ink;
    // A floating card's hard shadow while things go well, and when they do not.
    NSColor *shadow, *alert;
    // Saved and added words; nil for the spectrum's gradient.
    NSColor *mark;
    // The recording light.
    NSColor *dot;
    // Three beads that bounce beside a word while transcribing, in place of
    // the light, the timer, and the wave; nil rolls the wave instead.
    NSArray<NSColor *> *beads;
    // Corner radius of the shape grown out of the notch.
    CGFloat radius;
    CGFloat dot_size, bar_width, bar_gap, bar_height, timer_size;
    // Layout A+'s look, when halo holds its two colors: soft lights of them
    // left and right behind the island instead of the glow, content inset
    // from the island's sides, a spinning ring while transcribing, and icons
    // in the correction look. Otherwise 0 and nil keep the others' look.
    NSColor *halo[2];
    // Each ear's width beside the notch, the content's inset, the shoulders'
    // radius, and how many bars the wave has.
    CGFloat ear, inset, shoulder;
    int bars;
    // The family of the timer and the correction's number.
    NSString *mono;
} OWFIsland;

// How Settings lays out its controls.
typedef enum {
    // Rows in one card, tabs above it, and the fn key in the sidebar.
    OWFLayoutList,
    // Layouts of the design canvas, drawn to its coordinates with pages chosen
    // in the sidebar: F3, a grid of bright tiles; A+, the brand's dark look;
    // and F4+, its light, soft one.
    OWFLayoutBento,
    OWFLayoutBrand,
    OWFLayoutSoft,
} OWFLayout;

// A look of Settings and the island, chosen in Settings.
typedef struct {
    NSString *id;
    // English, translated with owf_text.
    NSString *name;
    // Forced on Settings; nil follows the macOS light or dark appearance.
    NSAppearance *appearance;
    OWFLayout layout;
    // The island's glow and wave, left to right; Settings uses it for its logo and fn key.
    NSArray<NSColor *> *spectrum;
    NSColor *accent;
    NSColor *canvas, *sidebar, *card;
    // Opacity of the spectrum washed over the sidebar; 0 for none.
    CGFloat wash;
    CGFloat card_radius;
    // A 2-point outline of cards; nil for a hairline.
    NSColor *outline;
    // Offset of a hard shadow under cards, in the outline's color; 0 for none.
    CGFloat shadow;
    // A system design for every font, such as monospaced; nil for the default.
    NSFontDescriptorSystemDesign font;
    // A family from ui/fonts for every font, and the PostScript name of the
    // face of the app's name and titles; the system font stands in for either
    // when it is not installed, as outside the app bundle.
    NSString *family;
    NSString *display;
    // The weight of the app's name and titles in the system font.
    NSFontWeight display_weight;
    OWFIsland island;
} OWFTheme;

extern NSString *const owf_theme_key;
// Returns the themes offered in Settings, the default first, and their count.
const OWFTheme *owf_themes(size_t *count);
// Returns the theme chosen in Settings.
const OWFTheme *owf_theme(void);
// Returns the theme's font of size and weight.
NSFont *owf_font(CGFloat size, NSFontWeight weight);
// Returns the theme's face of the app's name and titles in size.
NSFont *owf_display_font(CGFloat size);
// Returns a font of a family from ui/fonts at weight, or the system font's.
NSFont *owf_family(NSString *family, NSFontWeight weight, CGFloat size);
// Returns the outline of an icon of the design canvas on its 24-point grid.
NSBezierPath *owf_icon_path(NSString *name);
// Returns the theme's spectrum as CGColors; loop repeats the first color to
// close a conic gradient.
NSArray *owf_palette(BOOL loop);
// Returns the theme's spectrum at t in [0, 1], left to right.
NSColor *owf_spectrum_at(CGFloat t);
// Returns the sRGB color 0xRRGGBB.
NSColor *owf_hex(uint32_t rgb);
// Returns english translated into the interface language chosen in Settings.
NSString *owf_text(NSString *english);
// Returns the ID of the sound chosen in Settings.
NSString *owf_settings_sound(void);
// Plays both chimes of sound, as heard around a recording.
void owf_sound_preview(NSString *sound);
#endif

#endif
