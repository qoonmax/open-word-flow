#import <AppKit/AppKit.h>

#include <string.h>

#include "native_darwin.h"

static NSString *const owf_language_key = @"language";
static NSString *const owf_interface_language_key = @"interfaceLanguage";
static NSString *const owf_vocabulary_key = @"vocabulary";
static NSString *const owf_default_language = @"auto";
static NSString *const owf_system_language = @"system";

// Whisper language codes offered in Settings; "auto" detects the language of each recording.
static NSString *const owf_speech_languages[][2] = {
    {@"auto", @"Automatic"},
    {@"en", @"English"},
    {@"ru", @"Russian"},
};

static NSString *const owf_interface_languages[][2] = {
    {@"system", @"System"},
    {@"en", @"English"},
    {@"ru", @"Russian"},
};

static const CGFloat owf_settings_width = 480;
static const CGFloat owf_settings_inset = 20;

@interface OWFSettingsController : NSObject <NSTextViewDelegate>
@end

// Touched only on the main thread.
static OWFSettingsController *owf_settings;
static NSWindow *owf_settings_window;
static NSTextView *owf_vocabulary_view;

static void owf_settings_reload(void);

// Settings save as they change and apply to the next recording.
@implementation OWFSettingsController

- (void)popupChanged:(NSPopUpButton *)sender {
    [NSUserDefaults.standardUserDefaults setObject:sender.selectedItem.representedObject
                                            forKey:sender.identifier];

    if ([sender.identifier isEqualToString:owf_interface_language_key]) {
        // Rebuild after this action returns: the rebuild replaces the sender itself.
        dispatch_async(dispatch_get_main_queue(), ^{
            owf_status_menu_reload();
            owf_settings_reload();
        });
    }
}

- (void)textDidChange:(NSNotification *)notification {
    NSString *vocabulary = [[owf_vocabulary_view.string copy] autorelease];
    [NSUserDefaults.standardUserDefaults setObject:vocabulary forKey:owf_vocabulary_key];
}

@end

static NSString *owf_setting(NSString *key, NSString *fallback) {
    return [NSUserDefaults.standardUserDefaults stringForKey:key] ?: fallback;
}

// Russian interface strings; the English text is the key and the fallback.
static NSDictionary<NSString *, NSString *> *owf_russian(void) {
    static NSDictionary *strings;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        strings = [@{
            @"Double-press Fn to dictate": @"Дважды нажмите Fn для диктовки",
            @"Settings…": @"Настройки…",
            @"Quit Open Word Flow": @"Завершить Open Word Flow",
            @"Open Word Flow stopped": @"Open Word Flow остановлен",
            @"Open Word Flow Settings": @"Настройки Open Word Flow",
            @"Speech language:": @"Язык речи:",
            @"Interface language:": @"Язык интерфейса:",
            @"Automatic": @"Автоматически",
            @"System": @"Как в системе",
            @"English": @"Английский",
            @"Russian": @"Русский",
            @"Vocabulary": @"Словарь",
            @"Names, terms, and English words you often say, one per line or comma-separated. "
            @"Whisper reads this as text spoken right before the recording, so it favors these "
            @"spellings. Keep it short: only the last ~200 tokens are used.":
                @"Имена, термины и английские слова, которые вы часто произносите, — по одному "
                @"на строку или через запятую. Whisper считает этот текст сказанным прямо перед "
                @"записью и поэтому предпочитает такие написания. Пишите коротко: используются "
                @"только последние ~200 токенов.",
        } retain];
    });

    return strings;
}

NSString *owf_text(NSString *english) {
    NSString *language = owf_setting(owf_interface_language_key, owf_system_language);

    if ([language isEqualToString:owf_system_language]) {
        language = NSLocale.preferredLanguages.firstObject ?: @"en";
    }

    return [language hasPrefix:@"ru"] ? (owf_russian()[english] ?: english) : english;
}

static NSPopUpButton *owf_popup(
    NSString *const options[][2],
    size_t count,
    NSString *key,
    NSString *fallback
) {
    NSPopUpButton *popup = [[[NSPopUpButton alloc] init] autorelease];
    NSString *current = owf_setting(key, fallback);

    for (size_t i = 0; i < count; i++) {
        [popup addItemWithTitle:owf_text(options[i][1])];
        popup.lastItem.representedObject = options[i][0];

        if ([options[i][0] isEqualToString:current]) {
            [popup selectItem:popup.lastItem];
        }
    }

    popup.identifier = key;
    popup.target = owf_settings;
    popup.action = @selector(popupChanged:);

    return popup;
}

// Right-aligned text keeps form labels next to their controls even when the grid column is wider.
static NSTextField *owf_form_label(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.alignment = NSTextAlignmentRight;

    return label;
}

static NSGridView *owf_language_grid(void) {
    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[
            owf_form_label(owf_text(@"Speech language:")),
            owf_popup(
                owf_speech_languages,
                sizeof(owf_speech_languages) / sizeof(owf_speech_languages[0]),
                owf_language_key,
                owf_default_language
            ),
        ],
        @[
            owf_form_label(owf_text(@"Interface language:")),
            owf_popup(
                owf_interface_languages,
                sizeof(owf_interface_languages) / sizeof(owf_interface_languages[0]),
                owf_interface_language_key,
                owf_system_language
            ),
        ],
    ]];
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    grid.rowSpacing = 8;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    // Keep the grid at its natural width when a reload reuses the already sized window.
    [grid setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                     forOrientation:NSLayoutConstraintOrientationHorizontal];

    return grid;
}

static NSScrollView *owf_vocabulary_editor(CGFloat width) {
    NSScrollView *scroll = [NSTextView scrollableTextView];
    scroll.borderType = NSBezelBorder;
    [scroll.widthAnchor constraintEqualToConstant:width].active = YES;
    [scroll.heightAnchor constraintEqualToConstant:180].active = YES;

    owf_vocabulary_view = scroll.documentView;
    owf_vocabulary_view.richText = NO;
    owf_vocabulary_view.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
    owf_vocabulary_view.textContainerInset = NSMakeSize(4, 6);
    owf_vocabulary_view.automaticQuoteSubstitutionEnabled = NO;
    owf_vocabulary_view.automaticDashSubstitutionEnabled = NO;
    owf_vocabulary_view.automaticTextReplacementEnabled = NO;
    owf_vocabulary_view.string = owf_setting(owf_vocabulary_key, @"");
    owf_vocabulary_view.delegate = owf_settings;

    return scroll;
}

static NSView *owf_settings_content(void) {
    CGFloat contentWidth = owf_settings_width - 2 * owf_settings_inset;
    NSGridView *languages = owf_language_grid();

    NSTextField *vocabularyTitle = [NSTextField labelWithString:owf_text(@"Vocabulary")];
    vocabularyTitle.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];

    NSTextField *vocabularyHelp = [NSTextField wrappingLabelWithString:owf_text(
        @"Names, terms, and English words you often say, one per line or comma-separated. "
        @"Whisper reads this as text spoken right before the recording, so it favors these "
        @"spellings. Keep it short: only the last ~200 tokens are used."
    )];
    vocabularyHelp.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    vocabularyHelp.textColor = NSColor.secondaryLabelColor;
    vocabularyHelp.preferredMaxLayoutWidth = contentWidth;

    NSStackView *content = [NSStackView stackViewWithViews:@[
        languages,
        vocabularyTitle,
        vocabularyHelp,
        owf_vocabulary_editor(contentWidth),
    ]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 8;
    content.edgeInsets = NSEdgeInsetsMake(
        owf_settings_inset, owf_settings_inset, owf_settings_inset, owf_settings_inset
    );
    [content setCustomSpacing:20 afterView:languages];
    [content.widthAnchor constraintEqualToConstant:owf_settings_width].active = YES;

    return content;
}

// Builds the window contents in the current interface language, keeping the window's top edge in place.
static void owf_settings_reload(void) {
    NSView *content = owf_settings_content();
    NSRect old = owf_settings_window.frame;

    owf_settings_window.title = owf_text(@"Open Word Flow Settings");
    owf_settings_window.contentView = content;

    NSSize size = content.fittingSize;
    NSRect frame = [owf_settings_window frameRectForContentRect:NSMakeRect(0, 0, size.width, size.height)];
    frame.origin = NSMakePoint(old.origin.x, NSMaxY(old) - frame.size.height);
    [owf_settings_window setFrame:frame display:YES];
}

static void owf_settings_create(void) {
    owf_settings = [[OWFSettingsController alloc] init];
    owf_settings_window = [[NSWindow alloc] initWithContentRect:NSZeroRect
                                                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    owf_settings_window.releasedWhenClosed = NO;
    owf_settings_reload();
    [owf_settings_window center];
}

void owf_settings_open(void) {
    if (owf_settings_window == nil) {
        owf_settings_create();
    }

    owf_activate();
    [owf_settings_window makeKeyAndOrderFront:nil];
}

char *owf_settings_language(void) {
    @autoreleasepool {
        return strdup(owf_setting(owf_language_key, owf_default_language).UTF8String);
    }
}

char *owf_settings_vocabulary(void) {
    @autoreleasepool {
        return strdup(owf_setting(owf_vocabulary_key, @"").UTF8String);
    }
}
