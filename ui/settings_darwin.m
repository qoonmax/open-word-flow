#import <AppKit/AppKit.h>

#include <string.h>

#include "native_darwin.h"

static NSString *const owf_language_key = @"language";
static NSString *const owf_vocabulary_key = @"vocabulary";
static NSString *const owf_default_language = @"auto";

// Whisper language codes offered in Settings; "auto" detects the language of each recording.
static NSString *const owf_languages[][2] = {
    {@"auto", @"Automatic"},
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

// Settings save as they change and apply to the next recording.
@implementation OWFSettingsController

- (void)languageChanged:(NSPopUpButton *)sender {
    [NSUserDefaults.standardUserDefaults setObject:sender.selectedItem.representedObject
                                            forKey:owf_language_key];
}

- (void)textDidChange:(NSNotification *)notification {
    NSString *vocabulary = [[owf_vocabulary_view.string copy] autorelease];
    [NSUserDefaults.standardUserDefaults setObject:vocabulary forKey:owf_vocabulary_key];
}

@end

static NSString *owf_setting(NSString *key, NSString *fallback) {
    return [NSUserDefaults.standardUserDefaults stringForKey:key] ?: fallback;
}

static NSPopUpButton *owf_language_popup(void) {
    NSPopUpButton *popup = [[[NSPopUpButton alloc] init] autorelease];
    NSString *current = owf_setting(owf_language_key, owf_default_language);

    for (size_t i = 0; i < sizeof(owf_languages) / sizeof(owf_languages[0]); i++) {
        [popup addItemWithTitle:owf_languages[i][1]];
        popup.lastItem.representedObject = owf_languages[i][0];

        if ([owf_languages[i][0] isEqualToString:current]) {
            [popup selectItem:popup.lastItem];
        }
    }

    popup.target = owf_settings;
    popup.action = @selector(languageChanged:);

    return popup;
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

static void owf_settings_create(void) {
    owf_settings = [[OWFSettingsController alloc] init];

    CGFloat contentWidth = owf_settings_width - 2 * owf_settings_inset;

    NSStackView *languageRow = [NSStackView stackViewWithViews:@[
        [NSTextField labelWithString:@"Language:"],
        owf_language_popup(),
    ]];
    languageRow.alignment = NSLayoutAttributeFirstBaseline;

    NSTextField *vocabularyTitle = [NSTextField labelWithString:@"Vocabulary"];
    vocabularyTitle.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];

    NSTextField *vocabularyHelp = [NSTextField wrappingLabelWithString:
        @"Names, terms, and English words you often say, one per line or comma-separated. "
        @"Whisper reads this as text spoken right before the recording, so it favors these "
        @"spellings. Keep it short: only the last ~200 tokens are used."];
    vocabularyHelp.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    vocabularyHelp.textColor = NSColor.secondaryLabelColor;
    vocabularyHelp.preferredMaxLayoutWidth = contentWidth;

    NSStackView *content = [NSStackView stackViewWithViews:@[
        languageRow,
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
    [content setCustomSpacing:20 afterView:languageRow];
    [content.widthAnchor constraintEqualToConstant:owf_settings_width].active = YES;

    owf_settings_window = [[NSWindow alloc] initWithContentRect:NSZeroRect
                                                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    owf_settings_window.title = @"Open Word Flow Settings";
    owf_settings_window.releasedWhenClosed = NO;
    owf_settings_window.contentView = content;
    [owf_settings_window setContentSize:content.fittingSize];
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
