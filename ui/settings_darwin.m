#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>

#include <string.h>

#include "native_darwin.h"

static NSString *const owf_language_key = @"language";
static NSString *const owf_interface_language_key = @"interfaceLanguage";
static NSString *const owf_vocabulary_key = @"vocabulary";
static NSString *const owf_fn_mode_key = @"fnMode";
static NSString *const owf_sound_key = @"sound";
static NSString *const owf_default_language = @"auto";
static NSString *const owf_system_language = @"system";
static NSString *const owf_fn_double = @"double";
static NSString *const owf_fn_hold = @"hold";
static NSString *const owf_default_sound = @"glass";

// IDs match the sounds in sound.go; any other ID is silent.
static NSString *const owf_sounds[][2] = {
    {@"glass", @"Glass"},
    {@"pulse", @"Pulse"},
    {@"glow", @"Glow"},
    {@"off", @"Off"},
};

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

static const CGFloat owf_settings_width = 800;
static const CGFloat owf_settings_height = 660;
static const CGFloat owf_body_size = 13;
static const CGFloat owf_caption_size = 12;

@interface OWFSettingsController : NSObject <NSTextViewDelegate>
@end

// Touched only on the main thread.
static OWFSettingsController *owf_settings;
static NSWindow *owf_settings_window;
static NSTextView *owf_vocabulary_view;
static NSTextField *owf_shortcut_hint;
static NSButton *owf_modes[2];
static void owf_update_shortcut(void);

static void owf_settings_reload(void);

// The Corrections tab: the pairs saved with Control+Fn in owf_corrections_file,
// oldest first as in the file, and the one being edited, or -1.
static NSString *owf_corrections_file;
static NSMutableArray<NSDictionary *> *owf_corrections;
static NSInteger owf_corrections_editing = -1;
static NSInteger owf_settings_tab;
static NSSegmentedControl *owf_tabs;
static NSView *owf_general_view;
static NSView *owf_corrections_view;
static NSScrollView *owf_corrections_scroll;
static NSView *owf_corrections_empty;
static NSButton *owf_corrections_clear;
static NSTextField *owf_edit_heard;
static NSTextField *owf_edit_fixed;
static void owf_show_tab(BOOL animate);
static void owf_corrections_reload(void);
static NSMutableArray<NSDictionary *> *owf_corrections_read(void);
static void owf_corrections_write(NSArray<NSDictionary *> *corrections);
static void owf_corrections_change(NSDictionary *old, NSDictionary *replacement);

// Settings save as they change and apply to the next recording.
@implementation OWFSettingsController

- (void)popupChanged:(NSPopUpButton *)sender {
    [NSUserDefaults.standardUserDefaults setObject:sender.selectedItem.representedObject
                                            forKey:sender.identifier];

    if ([sender.identifier isEqualToString:owf_sound_key]) {
        owf_sound_preview(sender.selectedItem.representedObject);
    }

    // The menu hint follows both the interface language and the Fn mode.
    owf_status_menu_reload();

    if ([sender.identifier isEqualToString:owf_interface_language_key]) {
        // Rebuild after this action returns: the rebuild replaces the sender itself.
        dispatch_async(dispatch_get_main_queue(), ^{
            owf_settings_reload();
        });
    }
}

- (void)modeChanged:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setObject:sender.tag == 1 ? owf_fn_hold : owf_fn_double
                                            forKey:owf_fn_mode_key];
    owf_update_shortcut();
    owf_status_menu_reload();
}

- (void)previewSound:(id)sender {
    owf_sound_preview(owf_settings_sound());
}

- (void)textDidChange:(NSNotification *)notification {
    NSString *vocabulary = [[owf_vocabulary_view.string copy] autorelease];
    [NSUserDefaults.standardUserDefaults setObject:vocabulary forKey:owf_vocabulary_key];
}

- (void)tabChanged:(NSSegmentedControl *)sender {
    owf_settings_tab = sender.selectedSegment;
    owf_corrections_editing = -1;
    owf_corrections_reload();
    owf_show_tab(YES);
}

- (void)editCorrection:(NSButton *)sender {
    owf_corrections_editing = sender.tag;
    owf_corrections_reload();
    [owf_settings_window makeFirstResponder:owf_edit_fixed];
    [owf_edit_fixed scrollRectToVisible:owf_edit_fixed.bounds];
}

- (void)deleteCorrection:(NSButton *)sender {
    owf_corrections_change(owf_corrections[sender.tag], nil);
}

- (void)saveCorrection:(id)sender {
    NSMutableDictionary *edited = [[owf_corrections[owf_corrections_editing] mutableCopy] autorelease];
    edited[@"heard"] = [owf_edit_heard.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    edited[@"fixed"] = [owf_edit_fixed.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSDictionary *old = owf_corrections[owf_corrections_editing];
    owf_corrections_editing = -1;
    owf_corrections_change(old, edited);
}

- (void)cancelCorrection:(id)sender {
    owf_corrections_editing = -1;
    owf_corrections_reload();
}

- (void)clearCorrections:(id)sender {
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = owf_text(@"Delete all corrections?");
    alert.informativeText = owf_text(@"This can't be undone.");
    [alert addButtonWithTitle:owf_text(@"Delete All")].hasDestructiveAction = YES;
    [alert addButtonWithTitle:owf_text(@"Cancel")];
    [alert beginSheetModalForWindow:owf_settings_window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            owf_corrections_write(@[]);
            owf_corrections_editing = -1;
            owf_corrections_reload();
        }
    }];
}

- (void)showCorrectionsFile:(id)sender {
    NSURL *file = [NSURL fileURLWithPath:owf_corrections_file];

    if ([file checkResourceIsReachableAndReturnError:NULL]) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[file]];
    } else {
        NSBeep();
    }
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
            @"Hold Fn to dictate": @"Удерживайте Fn для диктовки",
            @"Dictation:": @"Диктовка:",
            @"Double-press Fn to start and stop": @"Двойное нажатие Fn: старт и стоп",
            @"Hold Fn while speaking": @"Удерживать Fn во время речи",
            @"Sounds:": @"Звуки:",
            @"Glass": @"Стекло",
            @"Pulse": @"Импульс",
            @"Glow": @"Сияние",
            @"Off": @"Выключены",
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
            @"Recording": @"Запись",
            @"Transcribing": @"Распознавание",
            @"Saving correction": @"Сохранение правки",
            @"Correction saved": @"Правка сохранена",
            @"Correction not saved": @"Правка не сохранена",
            @"Correction": @"Правка",
            @"#%d": @"№%d",
            @"Saving…": @"Сохраняю…",
            @"Saved": @"Сохранено",
            @"Not saved": @"Не сохранено",
            @"Comparing with dictation": @"Сравниваю с диктовкой",
            @"Nothing dictated yet": @"Ещё ничего не надиктовано",
            @"Nothing selected": @"Ничего не выделено",
            @"Text unchanged": @"Текст не изменился",
            @"Not like a recent dictation": @"Не похоже на недавнюю диктовку",
            @"Couldn't save": @"Не удалось сохранить",
            @"General": @"Основные",
            @"Corrections": @"Правки",
            @"Heard and corrected text, saved with Control+Fn.": @"Распознанный и исправленный текст, сохранённый по Ctrl+Fn.",
            @"No corrections yet": @"Пока нет правок",
            @"Fix a pasted transcript, select the corrected text, then press Control+Fn.":
                @"Исправьте вставленный текст, выделите исправленный фрагмент и нажмите Ctrl+Fn.",
            @"Heard": @"Распознано",
            @"Corrected": @"Исправлено",
            @"Edit": @"Изменить",
            @"Delete": @"Удалить",
            @"Save": @"Сохранить",
            @"Cancel": @"Отмена",
            @"Show File": @"Показать файл",
            @"Clear All…": @"Очистить всё…",
            @"Delete all corrections?": @"Удалить все правки?",
            @"This can't be undone.": @"Это действие нельзя отменить.",
            @"Delete All": @"Удалить все",
            @"Settings": @"Настройки",
            @"Speak freely. Stay in your flow.": @"Говорите. Не теряйте мысль.",
            @"Dictation": @"Диктовка",
            @"Fn key behavior": @"Управление клавишей Fn",
            @"Double press": @"Двойное нажатие",
            @"Press and hold": @"Удерживание",
            @"Double-press Fn to start.\nDouble-press again to finish.": @"Дважды Fn: начать запись.\nЕщё дважды: завершить.",
            @"Hold Fn while you speak.\nRelease to finish.": @"Удерживайте Fn, пока говорите.\nОтпустите для завершения.",
            @"Sounds": @"Звуки",
            @"Start and stop cues": @"Сигналы начала и конца записи",
            @"Speech language": @"Язык речи",
            @"Language you dictate in": @"На каком языке вы говорите",
            @"Interface language": @"Язык интерфейса",
            @"Make yourself at home": @"Привычный язык приложения",
            @"Preview sound": @"Прослушать звук",
            @"Names and terms, one per line or separated by commas.": @"Имена и термины, по одному на строку или через запятую.",
            @"Keep it short: only the last ~200 tokens are used.": @"Пишите коротко: учитываются последние ~200 токенов.",
            @"Changes saved automatically": @"Изменения сохраняются автоматически",
            @"On your Mac": @"На вашем Mac",
            @"Offline transcription.\nYour voice stays here.": @"Работает без интернета.\nВаш голос остаётся здесь.",
        } retain];
    });

    return strings;
}

static BOOL owf_russian_interface(void) {
    NSString *language = owf_setting(owf_interface_language_key, owf_system_language);

    if ([language isEqualToString:owf_system_language]) {
        language = NSLocale.preferredLanguages.firstObject ?: @"en";
    }

    return [language hasPrefix:@"ru"];
}

NSString *owf_text(NSString *english) {
    return owf_russian_interface() ? (owf_russian()[english] ?: english) : english;
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

// The violet of the island's spectrum, deepened on light backgrounds for contrast.
// AppKit colors resolve with the window appearance; no fixed light/dark theme.
static NSColor *owf_accent(void) {
    return [NSColor colorWithName:@"Flow accent" dynamicProvider:^NSColor *(NSAppearance *appearance) {
        BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
                     isEqualToString:NSAppearanceNameDarkAqua];
        return dark ? [NSColor colorWithSRGBRed:0.73 green:0.55 blue:1 alpha:1]
                    : [NSColor colorWithSRGBRed:0.45 green:0.25 blue:0.85 alpha:1];
    }];
}

// Drawing semantic colors also refreshes the surfaces when macOS changes theme.
@interface OWFSurface : NSView
@property BOOL sidebar;
@property BOOL canvas;
@property BOOL key;
@end

@implementation OWFSurface
- (void)drawRect:(NSRect)dirtyRect {
    if (self.canvas) {
        [NSColor.windowBackgroundColor setFill];
        NSRectFill(self.bounds);
    } else if (self.sidebar) {
        [NSColor.windowBackgroundColor setFill];
        NSRectFill(self.bounds);
        if (!NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency) {
            // A faint wash of the island's spectrum.
            NSMutableArray *colors = [NSMutableArray array];
            for (id color in owf_palette(NO)) {
                [colors addObject:[[NSColor colorWithCGColor:(CGColorRef)color] colorWithAlphaComponent:0.09]];
            }
            [[[[NSGradient alloc] initWithColors:colors] autorelease] drawInRect:self.bounds angle:75];
        }
        [[NSColor.labelColor colorWithAlphaComponent:0.08] setFill];
        NSRectFillUsingOperation(NSMakeRect(NSWidth(self.bounds) - 1, 0, 1, NSHeight(self.bounds)), NSCompositingOperationSourceOver);
    } else if (self.key) {
        // The island's material in either appearance: black, a faint reflection
        // along the bottom, and a hairline edge.
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                                          xRadius:16 yRadius:16];
        [NSColor.blackColor setFill];
        [path fill];
        NSGradient *sheen = [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0.18 alpha:0.35]
                                                          endingColor:NSColor.clearColor] autorelease];
        [sheen drawInBezierPath:path angle:90];
        [[NSColor colorWithWhite:1 alpha:0.10] setStroke];
        [path stroke];
    } else {
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                                          xRadius:12 yRadius:12];
        [NSColor.controlBackgroundColor setFill];
        [path fill];
        [[NSColor.labelColor colorWithAlphaComponent:0.10] setStroke];
        [path stroke];
    }
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
@end

static NSTextField *owf_label(NSView *parent, NSString *text, NSRect frame, CGFloat size,
                            NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField wrappingLabelWithString:owf_text(text)];
    // Labels inset their text by 2 points; shift it onto the frame's edge so text
    // lines up with the icons and cards around it.
    label.frame = NSOffsetRect(frame, -2, 0);
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.selectable = NO;
    [parent addSubview:label];
    return label;
}

static NSImageView *owf_symbol(NSView *parent, NSString *name, NSRect frame, NSColor *color) {
    NSImageView *icon = [[[NSImageView alloc] initWithFrame:frame] autorelease];
    icon.image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:frame.size.height - 4
                                                                              weight:NSFontWeightMedium];
    icon.contentTintColor = color;
    [icon setAccessibilityElement:NO];
    [parent addSubview:icon];
    return icon;
}

// Align an inline symbol to the text's cap height, not the label's padded frame.
static void owf_label_symbol(NSView *parent, NSString *name, CGFloat x, NSTextField *label, NSColor *color) {
    CGFloat size = 18;
    CGFloat baseline = NSMaxY(label.frame) - label.firstBaselineOffsetFromTop;
    owf_symbol(parent, name, NSMakeRect(x, round(baseline + (label.font.capHeight - size) / 2), size, size), color);
}

// Places a label of wrapped text with its last line ending at bottom and returns its top.
static CGFloat owf_label_above(NSView *parent, NSString *text, CGFloat x, CGFloat bottom, CGFloat width) {
    NSTextField *label = owf_label(parent, text, NSMakeRect(x, bottom, width, 0), 12, NSFontWeightRegular,
                                   NSColor.secondaryLabelColor);
    CGFloat height = [label.cell cellSizeForBounds:NSMakeRect(0, 0, width, CGFLOAT_MAX)].height;
    [label setFrameSize:NSMakeSize(width, height)];
    return bottom + height;
}

// A symbol filled with the island's spectrum, left to right, as the island's wave is.
static void owf_spectrum_symbol(NSView *parent, NSString *name, CGFloat x, CGFloat top, CGFloat size) {
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:size
                                                                                      weight:NSFontWeightMedium];
    NSImage *image = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
        imageWithSymbolConfiguration:config];
    NSView *view = [[[NSView alloc] initWithFrame:NSMakeRect(x, top - image.size.height, image.size.width,
                                                             image.size.height)] autorelease];
    CAGradientLayer *spectrum = [CAGradientLayer layer];
    spectrum.colors = owf_palette(NO);
    spectrum.startPoint = CGPointMake(0, 0.5);
    spectrum.endPoint = CGPointMake(1, 0.5);
    CALayer *mask = [CALayer layer];
    mask.frame = view.bounds;
    mask.contentsScale = [image recommendedLayerContentsScale:NSScreen.mainScreen.backingScaleFactor];
    mask.contents = [image layerContentsForContentsScale:mask.contentsScale];
    spectrum.mask = mask;
    view.layer = spectrum;
    view.wantsLayer = YES;
    [parent addSubview:view];
}

// The fn key looks like the island: black, lit from behind by the same spectrum.
static OWFSurface *owf_key(NSView *parent, NSRect frame) {
    CGFloat spread = 28;
    NSView *glow = [[[NSView alloc] initWithFrame:NSInsetRect(frame, -spread, -spread)] autorelease];
    CAShapeLayer *stroke = [CAShapeLayer layer];
    CGPathRef path = CGPathCreateWithRoundedRect(CGRectMake(spread, spread, NSWidth(frame), NSHeight(frame)), 16, 16, NULL);
    stroke.path = path;
    CGPathRelease(path);
    stroke.frame = glow.bounds;
    stroke.fillColor = nil;
    stroke.strokeColor = CGColorGetConstantColor(kCGColorBlack);
    stroke.lineWidth = 10;
    CAGradientLayer *spectrum = [CAGradientLayer layer];
    spectrum.type = kCAGradientLayerConic;
    spectrum.colors = owf_palette(YES);
    spectrum.startPoint = CGPointMake(0.5, 0.5);
    spectrum.endPoint = CGPointMake(0.5, 1);
    spectrum.frame = glow.bounds;
    spectrum.mask = stroke;
    CALayer *halo = [CALayer layer];
    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blur setValue:@9 forKey:kCIInputRadiusKey];
    halo.filters = @[blur];
    halo.opacity = 0.6;
    [halo addSublayer:spectrum];
    glow.layer = halo;
    glow.wantsLayer = YES;
    glow.layerUsesCoreImageFilters = YES;
    [parent addSubview:glow];

    OWFSurface *key = [[[OWFSurface alloc] initWithFrame:frame] autorelease];
    key.key = YES;
    // The key is always black; keep AppKit's dark-label vibrancy from erasing its white legend.
    key.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    [parent addSubview:key];
    return key;
}

static void owf_reveal(NSView *view, CFTimeInterval delay) {
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) return;
    view.wantsLayer = YES;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0;
    fade.toValue = @1;
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
    slide.fromValue = @(-8);
    slide.toValue = @0;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[fade, slide];
    group.duration = 0.45;
    group.beginTime = CACurrentMediaTime() + delay;
    group.fillMode = kCAFillModeBackwards;
    group.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2:0.8:0.2:1];
    [view.layer addAnimation:group forKey:@"reveal"];
}

static void owf_update_shortcut(void) {
    owf_shortcut_hint.stringValue = owf_text(owf_settings_fn_hold()
        ? @"Hold Fn while you speak.\nRelease to finish."
        : @"Double-press Fn to start.\nDouble-press again to finish.");
    owf_reveal(owf_shortcut_hint, 0);
}

// Lays out the Corrections list top down, as a table does.
@interface OWFFlippedView : NSView
@end

@implementation OWFFlippedView
- (BOOL)isFlipped {
    return YES;
}
@end

void owf_settings_set_corrections_file(const char *path) {
    [owf_corrections_file release];
    owf_corrections_file = [@(path) copy];
}

// Reads the corrections, oldest first, skipping lines that are not corrections.
static NSMutableArray<NSDictionary *> *owf_corrections_read(void) {
    NSMutableArray *corrections = [NSMutableArray array];
    NSString *text = owf_corrections_file == nil ? nil
        : [NSString stringWithContentsOfFile:owf_corrections_file encoding:NSUTF8StringEncoding error:NULL];

    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSDictionary *entry = line.length == 0 ? nil
            : [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];

        if ([entry isKindOfClass:NSDictionary.class] && [entry[@"heard"] isKindOfClass:NSString.class] &&
            [entry[@"fixed"] isKindOfClass:NSString.class]) {
            [corrections addObject:entry];
        }
    }

    return corrections;
}

// Writes corrections as the app saves them: one JSON object per line, private to the user.
static void owf_corrections_write(NSArray<NSDictionary *> *corrections) {
    NSMutableData *text = [NSMutableData data];

    for (NSDictionary *entry in corrections) {
        [text appendData:[NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingWithoutEscapingSlashes error:NULL]];
        [text appendBytes:"\n" length:1];
    }

    if (![text writeToFile:owf_corrections_file atomically:YES]) {
        NSBeep();
        return;
    }

    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:owf_corrections_file error:NULL];
}

// Replaces old with replacement, or deletes it when replacement is nil, in the
// file as it is now, so corrections saved since the list was shown stay.
// ponytail: a correction saved at the very instant of this rewrite is lost.
static void owf_corrections_change(NSDictionary *old, NSDictionary *replacement) {
    NSMutableArray *corrections = owf_corrections_read();
    NSUInteger index = [corrections indexOfObject:old];

    if (index != NSNotFound) {
        if (replacement == nil) {
            [corrections removeObjectAtIndex:index];
        } else {
            corrections[index] = replacement;
        }

        owf_corrections_write(corrections);
    }

    owf_corrections_reload();
}

// The corrected words of entry in context: kept words quiet, removed ones
// struck through, added ones in the accent color.
static NSAttributedString *owf_correction_words(NSDictionary *entry) {
    char *json = owfSegmentsJSON((char *)[entry[@"heard"] UTF8String], (char *)[entry[@"fixed"] UTF8String]);
    NSArray *parts = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:strlen(json)] options:0 error:NULL];
    free(json);

    NSMutableAttributedString *words = [[[NSMutableAttributedString alloc] init] autorelease];
    NSMutableParagraphStyle *paragraph = [[[NSMutableParagraphStyle alloc] init] autorelease];
    paragraph.lineSpacing = 3;
    NSDictionary *space = @{NSFontAttributeName: [NSFont systemFontOfSize:owf_body_size],
                            NSParagraphStyleAttributeName: paragraph};

    for (NSDictionary *part in parts) {
        int kind = [part[@"kind"] intValue];
        NSMutableDictionary *style = [[space mutableCopy] autorelease];
        style[NSForegroundColorAttributeName] = kind == 0 ? NSColor.labelColor
                                              : kind == 1 ? NSColor.secondaryLabelColor : owf_accent();

        if (kind == 1) {
            style[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
        } else if (kind == 2) {
            style[NSFontAttributeName] = [NSFont systemFontOfSize:owf_body_size weight:NSFontWeightMedium];
        }

        if (words.length > 0) {
            [words appendAttributedString:[[[NSAttributedString alloc] initWithString:@" " attributes:space] autorelease]];
        }

        [words appendAttributedString:[[[NSAttributedString alloc] initWithString:part[@"text"] attributes:style] autorelease]];
    }

    return words;
}

// When a correction was saved, relative to today, in the interface language.
static NSString *owf_correction_date(id time) {
    if (![time isKindOfClass:NSString.class]) {
        return @"";
    }

    // Go writes fractions of a second that the ISO 8601 parser rejects.
    NSString *seconds = [time stringByReplacingOccurrencesOfString:@"\\.[0-9]+" withString:@""
                                                           options:NSRegularExpressionSearch
                                                             range:NSMakeRange(0, [time length])];
    NSDate *date = [[[[NSISO8601DateFormatter alloc] init] autorelease] dateFromString:seconds];
    NSDateFormatter *format = [[[NSDateFormatter alloc] init] autorelease];
    format.locale = [NSLocale localeWithLocaleIdentifier:owf_russian_interface() ? @"ru_RU" : @"en_US"];
    format.dateStyle = NSDateFormatterMediumStyle;
    format.timeStyle = NSDateFormatterShortStyle;
    format.doesRelativeDateFormatting = YES;

    return date == nil ? @"" : [format stringFromDate:date];
}

static NSButton *owf_row_button(NSView *list, NSString *symbol, NSString *label, SEL action, NSInteger index, NSRect frame) {
    // The square symbol is shorter at the same point size; balance its visible height with the trash.
    CGFloat size = [symbol isEqualToString:@"square.and.pencil"] ? 16 : 14;
    NSImage *image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:owf_text(label)]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightMedium]];
    NSButton *button = [NSButton buttonWithImage:image
                                         target:owf_settings
                                         action:action];
    button.bordered = NO;
    button.frame = frame;
    button.tag = index;
    button.toolTip = owf_text(label);
    button.contentTintColor = NSColor.secondaryLabelColor;
    [list addSubview:button];
    return button;
}

// Adds the row of correction index at top and returns its height.
static CGFloat owf_correction_row(NSView *list, NSInteger index, CGFloat top, CGFloat width) {
    NSDictionary *entry = owf_corrections[index];
    NSTextField *words = [NSTextField labelWithAttributedString:owf_correction_words(entry)];
    words.usesSingleLineMode = NO;
    words.lineBreakMode = NSLineBreakByWordWrapping;
    words.cell.wraps = YES;
    CGFloat textWidth = width - 112;
    CGFloat textHeight = ceil([words.cell cellSizeForBounds:NSMakeRect(0, 0, textWidth, CGFLOAT_MAX)].height);
    words.frame = NSMakeRect(18, top + 14, textWidth, textHeight);
    words.selectable = YES;
    words.toolTip = entry[@"fixed"];
    [list addSubview:words];

    NSTextField *when = [NSTextField labelWithString:owf_correction_date(entry[@"time"])];
    when.font = [NSFont systemFontOfSize:owf_caption_size];
    when.textColor = NSColor.secondaryLabelColor;
    when.frame = NSMakeRect(18, NSMaxY(words.frame) + 6, textWidth, 17);
    [list addSubview:when];

    // Half-point optical correction: both glyphs then share their visible top and bottom edges.
    owf_row_button(list, @"square.and.pencil", @"Edit", @selector(editCorrection:), index, NSMakeRect(width - 80, top + 11.5, 30, 30));
    owf_row_button(list, @"trash", @"Delete", @selector(deleteCorrection:), index, NSMakeRect(width - 44, top + 12, 30, 30));
    return NSMaxY(when.frame) + 14 - top;
}

// Adds correction index as two editable fields with Cancel and Save at top and returns its height.
static CGFloat owf_edit_row(NSView *list, NSInteger index, CGFloat top, CGFloat width) {
    NSDictionary *entry = owf_corrections[index];
    NSString *titles[] = {@"Heard", @"Corrected"};
    NSString *keys[] = {@"heard", @"fixed"};
    NSTextField *fields[2];
    CGFloat y = top + 16;

    for (int i = 0; i < 2; i++) {
        NSTextField *title = [NSTextField labelWithString:owf_text(titles[i])];
        title.font = [NSFont systemFontOfSize:owf_caption_size weight:NSFontWeightMedium];
        title.textColor = NSColor.secondaryLabelColor;
        title.frame = NSMakeRect(18, y, width - 40, 17);
        [list addSubview:title];

        fields[i] = [NSTextField textFieldWithString:entry[keys[i]]];
        fields[i].frame = NSMakeRect(20, y + 23, width - 40, 60);
        fields[i].font = [NSFont systemFontOfSize:owf_body_size];
        fields[i].usesSingleLineMode = NO;
        fields[i].cell.wraps = YES;
        fields[i].cell.scrollable = NO;
        CGFloat fieldHeight = fmax(60, ceil([fields[i].cell cellSizeForBounds:
            NSMakeRect(0, 0, width - 40, CGFLOAT_MAX)].height) + 12);
        [fields[i] setFrameSize:NSMakeSize(width - 40, fieldHeight)];
        [fields[i] setAccessibilityLabel:owf_text(titles[i])];
        [list addSubview:fields[i]];
        y += 23 + fieldHeight + 16;
    }

    owf_edit_heard = fields[0];
    owf_edit_fixed = fields[1];

    NSButton *save = [NSButton buttonWithTitle:owf_text(@"Save") target:owf_settings action:@selector(saveCorrection:)];
    save.keyEquivalent = @"\r";
    save.bezelColor = [NSColor colorWithSRGBRed:0.50 green:0.30 blue:0.93 alpha:1];
    NSButton *cancel = [NSButton buttonWithTitle:owf_text(@"Cancel") target:owf_settings action:@selector(cancelCorrection:)];
    cancel.keyEquivalent = @"\033";
    CGFloat right = width - 14;

    for (NSButton *button in @[save, cancel]) {
        button.font = [NSFont systemFontOfSize:owf_body_size];
        [button sizeToFit];
        right -= NSWidth(button.frame);
        [button setFrameOrigin:NSMakePoint(right, y)];
        right -= 8;
        [list addSubview:button];
    }

    return y + NSHeight(save.frame) + 14 - top;
}

static NSString *owf_corrections_title(void) {
    return owf_corrections.count == 0 ? owf_text(@"Corrections")
        : [NSString stringWithFormat:@"%@ · %lu", owf_text(@"Corrections"), (unsigned long)owf_corrections.count];
}

// Rereads the corrections and lists them, newest first.
static void owf_corrections_reload(void) {
    [owf_corrections release];
    owf_corrections = [owf_corrections_read() retain];
    [owf_tabs setLabel:owf_corrections_title() forSegment:1];

    NSView *list = owf_corrections_scroll.documentView;
    [list.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

    CGFloat width = owf_corrections_scroll.contentSize.width;
    CGFloat y = 0;

    for (NSInteger i = (NSInteger)owf_corrections.count - 1; i >= 0; i--) {
        y += i == owf_corrections_editing ? owf_edit_row(list, i, y, width) : owf_correction_row(list, i, y, width);

        if (i > 0) {
            NSBox *divider = [[[NSBox alloc] initWithFrame:NSMakeRect(16, y, width - 32, 1)] autorelease];
            divider.boxType = NSBoxSeparator;
            [list addSubview:divider];
        }
    }

    [list setFrameSize:NSMakeSize(width, fmax(y, owf_corrections_scroll.contentSize.height))];
    owf_corrections_empty.hidden = owf_corrections.count > 0;
    owf_corrections_clear.enabled = owf_corrections.count > 0;
}

static void owf_show_tab(BOOL animate) {
    owf_general_view.hidden = owf_settings_tab != 0;
    owf_corrections_view.hidden = owf_settings_tab != 1;

    if (animate) {
        owf_reveal(owf_settings_tab == 0 ? owf_general_view : owf_corrections_view, 0);
    }
}

// The Corrections tab shares the same content edges as General.
static NSView *owf_corrections_content(NSRect frame) {
    NSView *view = [[[NSView alloc] initWithFrame:frame] autorelease];
    owf_label(view, @"Heard and corrected text, saved with Control+Fn.", NSMakeRect(0, 459, 508, 36), owf_caption_size,
              NSFontWeightRegular, NSColor.secondaryLabelColor);

    OWFSurface *card = [[[OWFSurface alloc] initWithFrame:NSMakeRect(0, 76, 508, 376)] autorelease];
    [view addSubview:card];
    owf_corrections_scroll = [[[NSScrollView alloc] initWithFrame:NSInsetRect(card.bounds, 1, 6)] autorelease];
    owf_corrections_scroll.drawsBackground = NO;
    owf_corrections_scroll.hasVerticalScroller = YES;
    owf_corrections_scroll.autohidesScrollers = YES;
    owf_corrections_scroll.documentView = [[[OWFFlippedView alloc] initWithFrame:owf_corrections_scroll.bounds] autorelease];
    [card addSubview:owf_corrections_scroll];

    owf_corrections_empty = [[[NSView alloc] initWithFrame:NSMakeRect(44, 124, 420, 132)] autorelease];
    [card addSubview:owf_corrections_empty];
    owf_symbol(owf_corrections_empty, @"text.badge.checkmark", NSMakeRect(193, 94, 34, 34), owf_accent());
    NSTextField *emptyTitle = owf_label(owf_corrections_empty, @"No corrections yet", NSMakeRect(0, 60, 420, 22),
                                       owf_body_size, NSFontWeightSemibold, NSColor.labelColor);
    emptyTitle.alignment = NSTextAlignmentCenter;
    NSTextField *emptyHint = owf_label(owf_corrections_empty,
        @"Fix a pasted transcript, select the corrected text, then press Control+Fn.", NSMakeRect(24, 8, 372, 44),
        owf_body_size, NSFontWeightRegular, NSColor.secondaryLabelColor);
    emptyHint.alignment = NSTextAlignmentCenter;

    NSButton *show = [NSButton buttonWithTitle:owf_text(@"Show File") target:owf_settings action:@selector(showCorrectionsFile:)];
    NSButton *clear = [NSButton buttonWithTitle:owf_text(@"Clear All…") target:owf_settings action:@selector(clearCorrections:)];
    clear.hasDestructiveAction = YES;
    owf_corrections_clear = clear;

    for (NSButton *button in @[show, clear]) {
        button.font = [NSFont systemFontOfSize:owf_body_size];
        [button sizeToFit];
        [view addSubview:button];
    }

    // Bezels are inset 6 points; line their edges up with the card's.
    [show setFrameOrigin:NSMakePoint(-6, 34)];
    [clear setFrameOrigin:NSMakePoint(508 + 6 - NSWidth(clear.frame), 34)];
    return view;
}

static NSView *owf_settings_content(void) {
    OWFSurface *root = [[[OWFSurface alloc] initWithFrame:NSMakeRect(0, 0, owf_settings_width, owf_settings_height)] autorelease];
    root.canvas = YES;
    OWFSurface *sidebar = [[[OWFSurface alloc] initWithFrame:NSMakeRect(0, 0, 228, owf_settings_height)] autorelease];
    sidebar.sidebar = YES;
    [root addSubview:sidebar];
    // The logo's top lines up with the cap height of the Settings title.
    owf_spectrum_symbol(sidebar, @"waveform", 28, 595, 34);
    owf_label(sidebar, @"Open\nWord Flow", NSMakeRect(28, 459, 184, 86), 31, NSFontWeightSemibold, NSColor.labelColor);
    owf_label(sidebar, @"Speak freely. Stay in your flow.", NSMakeRect(28, 401, 172, 46), 13,
              NSFontWeightRegular, NSColor.secondaryLabelColor);

    OWFSurface *key = owf_key(sidebar, NSMakeRect(28, 279, 76, 76));
    owf_label(key, @"fn", NSMakeRect(16, 13, 50, 38), 30, NSFontWeightMedium, [NSColor colorWithWhite:1 alpha:0.92]);
    owf_symbol(key, @"globe", NSMakeRect(48, 46, 16, 16), [NSColor colorWithWhite:1 alpha:0.55]);
    owf_shortcut_hint = owf_label(sidebar, @"", NSMakeRect(28, 203, 184, 56), owf_caption_size,
                                  NSFontWeightRegular, NSColor.secondaryLabelColor);
    owf_update_shortcut();
    // The last line ends on the same baseline as the body's last line.
    CGFloat privacy = owf_label_above(sidebar, @"Offline transcription.\nYour voice stays here.", 28, 32, 184) + 8;
    NSTextField *privacyTitle = owf_label(sidebar, @"On your Mac", NSMakeRect(54, privacy, 155, 20),
                                          owf_caption_size, NSFontWeightSemibold, NSColor.labelColor);
    owf_label_symbol(sidebar, @"lock.shield", 28, privacyTitle, owf_accent());

    NSView *body = [[[NSView alloc] initWithFrame:NSMakeRect(260, 0, 508, owf_settings_height)] autorelease];
    [root addSubview:body];
    owf_label(body, @"Settings", NSMakeRect(0, 563, 508, 38), 26, NSFontWeightSemibold, NSColor.labelColor);

    // Navigation gets its own row, so localized titles and counts cannot collide.
    owf_tabs = [NSSegmentedControl segmentedControlWithLabels:@[owf_text(@"General"), owf_text(@"Corrections")]
                                                 trackingMode:NSSegmentSwitchTrackingSelectOne
                                                       target:owf_settings action:@selector(tabChanged:)];
    owf_tabs.font = [NSFont systemFontOfSize:owf_body_size];
    owf_tabs.segmentStyle = NSSegmentStyleRounded;
    owf_tabs.selectedSegmentBezelColor = [NSColor colorWithWhite:0.40 alpha:1];
    owf_tabs.frame = NSMakeRect(-5.5, 514, 519, 32);
    [owf_tabs setWidth:253.5 forSegment:0];
    [owf_tabs setWidth:253.5 forSegment:1];
    [owf_tabs setAccessibilityLabel:owf_text(@"Settings")];
    owf_tabs.selectedSegment = owf_settings_tab;

    owf_general_view = [[[NSView alloc] initWithFrame:body.bounds] autorelease];
    NSView *general = owf_general_view;
    [body addSubview:general];
    owf_corrections_view = owf_corrections_content(body.bounds);
    [body addSubview:owf_corrections_view];
    // Above both tabs' views, which span the body and would take its clicks.
    [body addSubview:owf_tabs];
    NSTextField *saved = owf_label(general, @"Changes saved automatically", NSMakeRect(24, 13, 484, 18),
                                    owf_caption_size, NSFontWeightRegular, NSColor.secondaryLabelColor);
    owf_label_symbol(general, @"checkmark.circle", 0, saved, NSColor.secondaryLabelColor);

    // Dictation is a preference, not navigation: native radios share the other settings' card.
    OWFSurface *options = [[[OWFSurface alloc] initWithFrame:NSMakeRect(0, 223, 508, 268)] autorelease];
    [general addSubview:options];
    owf_symbol(options, @"keyboard", NSMakeRect(17, 223, 22, 22), owf_accent());
    owf_label(options, @"Dictation", NSMakeRect(52, 235, 249, 19), owf_body_size, NSFontWeightMedium, NSColor.labelColor);
    owf_label(options, @"Fn key behavior", NSMakeRect(52, 214, 249, 18), owf_caption_size,
              NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSArray *modeTitles = @[owf_text(@"Double press"), owf_text(@"Press and hold")];
    for (NSInteger i = 0; i < 2; i++) {
        NSButton *mode = [NSButton radioButtonWithTitle:modeTitles[i] target:owf_settings action:@selector(modeChanged:)];
        mode.tag = i;
        mode.frame = NSMakeRect(306, 236 - i * 28, 184, 24);
        mode.font = [NSFont systemFontOfSize:owf_body_size];
        mode.contentTintColor = owf_accent();
        mode.attributedTitle = [[[NSAttributedString alloc] initWithString:modeTitles[i]
            attributes:@{NSFontAttributeName: mode.font, NSForegroundColorAttributeName: NSColor.labelColor}] autorelease];
        mode.state = owf_settings_fn_hold() == i ? NSControlStateValueOn : NSControlStateValueOff;
        [options addSubview:mode];
        owf_modes[i] = mode;
    }
    NSBox *modeDivider = [[[NSBox alloc] initWithFrame:NSMakeRect(52, 192, 438, 1)] autorelease];
    modeDivider.boxType = NSBoxSeparator;
    [options addSubview:modeDivider];
    NSString *titles[] = {@"Sounds", @"Speech language", @"Interface language"};
    NSString *hints[] = {@"Start and stop cues", @"Language you dictate in", @"Make yourself at home"};
    NSString *icons[] = {@"speaker.wave.2", @"waveform", @"character.bubble"};
    NSPopUpButton *popups[] = {
        owf_popup(owf_sounds, sizeof(owf_sounds) / sizeof(owf_sounds[0]), owf_sound_key, owf_default_sound),
        owf_popup(owf_speech_languages, sizeof(owf_speech_languages) / sizeof(owf_speech_languages[0]), owf_language_key, owf_default_language),
        owf_popup(owf_interface_languages, sizeof(owf_interface_languages) / sizeof(owf_interface_languages[0]), owf_interface_language_key, owf_system_language),
    };
    for (int i = 0; i < 3; i++) {
        CGFloat y = 128 - i * 64;
        owf_symbol(options, icons[i], NSMakeRect(17, y + 21, 22, 22), owf_accent());
        owf_label(options, titles[i], NSMakeRect(52, y + 33, 249, 19), owf_body_size, NSFontWeightMedium, NSColor.labelColor);
        owf_label(options, hints[i], NSMakeRect(52, y + 12, 249, 18), owf_caption_size, NSFontWeightRegular, NSColor.secondaryLabelColor);
        popups[i].frame = NSMakeRect(306, y + 19, i == 0 ? 143 : 184, 28);
        popups[i].font = [NSFont systemFontOfSize:owf_body_size];
        [popups[i] setAccessibilityLabel:owf_text(titles[i])];
        [options addSubview:popups[i]];
        if (i > 0) {
            NSBox *divider = [[[NSBox alloc] initWithFrame:NSMakeRect(52, y + 63, 438, 1)] autorelease];
            divider.boxType = NSBoxSeparator;
            [options addSubview:divider];
        }
    }
    NSButton *preview = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:owf_text(@"Preview sound")]
                                         target:owf_settings action:@selector(previewSound:)];
    preview.frame = NSMakeRect(458, 147, 32, 28);
    preview.bezelStyle = NSBezelStyleRounded;
    preview.toolTip = owf_text(@"Preview sound");
    [preview setAccessibilityLabel:owf_text(@"Preview sound")];
    [options addSubview:preview];

    owf_label(general, @"Vocabulary", NSMakeRect(0, 185, 508, 23), owf_body_size, NSFontWeightSemibold, NSColor.labelColor);
    owf_label(general, @"Names and terms, one per line or separated by commas.", NSMakeRect(0, 161, 508, 20),
              owf_caption_size, NSFontWeightRegular, NSColor.secondaryLabelColor);
    CGFloat editorBottom = owf_label_above(general, @"Keep it short: only the last ~200 tokens are used.", 0, 43, 508) + 8;
    OWFSurface *editor = [[[OWFSurface alloc] initWithFrame:NSMakeRect(0, editorBottom, 508, 153 - editorBottom)] autorelease];
    [general addSubview:editor];
    NSScrollView *scroll = [NSTextView scrollableTextView];
    scroll.frame = NSInsetRect(editor.bounds, 7, 7);
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;
    scroll.autohidesScrollers = YES;
    owf_vocabulary_view = scroll.documentView;
    owf_vocabulary_view.richText = NO;
    owf_vocabulary_view.drawsBackground = NO;
    owf_vocabulary_view.font = [NSFont systemFontOfSize:owf_body_size];
    NSMutableParagraphStyle *vocabularyStyle = [[[NSMutableParagraphStyle alloc] init] autorelease];
    vocabularyStyle.lineSpacing = 3;
    owf_vocabulary_view.defaultParagraphStyle = vocabularyStyle;
    owf_vocabulary_view.textColor = NSColor.labelColor;
    owf_vocabulary_view.insertionPointColor = owf_accent();
    owf_vocabulary_view.textContainerInset = NSMakeSize(7, 7);
    owf_vocabulary_view.automaticQuoteSubstitutionEnabled = NO;
    owf_vocabulary_view.automaticDashSubstitutionEnabled = NO;
    owf_vocabulary_view.automaticTextReplacementEnabled = NO;
    owf_vocabulary_view.allowsUndo = YES;
    owf_vocabulary_view.string = owf_setting(owf_vocabulary_key, @"");
    owf_vocabulary_view.delegate = owf_settings;
    [owf_vocabulary_view setAccessibilityLabel:owf_text(@"Vocabulary")];
    [owf_vocabulary_view setAccessibilityHelp:owf_text(@"Names and terms, one per line or separated by commas.")];
    [editor addSubview:scroll];
    owf_corrections_reload();
    owf_show_tab(NO);
    return root;
}

// Builds the window contents in the current interface language, keeping the window's top edge in place.
static void owf_settings_reload(void) {
    NSView *content = owf_settings_content();
    NSRect old = owf_settings_window.frame;

    owf_settings_window.title = owf_text(@"Open Word Flow Settings");
    owf_settings_window.contentView = content;

    NSSize size = NSMakeSize(owf_settings_width, owf_settings_height);
    NSRect frame = [owf_settings_window frameRectForContentRect:NSMakeRect(0, 0, size.width, size.height)];
    frame.origin = NSMakePoint(old.origin.x, NSMaxY(old) - frame.size.height);
    [owf_settings_window setFrame:frame display:YES];
}

static void owf_settings_create(void) {
    owf_settings = [[OWFSettingsController alloc] init];
    owf_settings_window = [[NSWindow alloc] initWithContentRect:NSZeroRect
                                                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    owf_settings_window.releasedWhenClosed = NO;
    owf_settings_window.titlebarAppearsTransparent = YES;
    owf_settings_window.titleVisibility = NSWindowTitleHidden;
    owf_settings_window.movableByWindowBackground = YES;
    owf_settings_window.backgroundColor = NSColor.windowBackgroundColor;
    // Corrections saved with Control+Fn in other apps appear on return to Settings.
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidBecomeKeyNotification
                                                    object:owf_settings_window
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        if (owf_corrections_editing < 0) {
            owf_corrections_reload();
        }
    }];
    owf_settings_reload();
    [owf_settings_window center];
}

void owf_settings_open(void) {
    if (owf_settings_window == nil) {
        owf_settings_create();
    }

    owf_activate();
    BOOL opening = !owf_settings_window.visible;
    [owf_settings_window makeKeyAndOrderFront:nil];
    if (opening) {
        NSUInteger index = 0;
        for (NSView *view in owf_settings_window.contentView.subviews) {
            owf_reveal(view, 0.04 * index++);
        }
    }
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

int owf_settings_fn_hold(void) {
    @autoreleasepool {
        return [owf_setting(owf_fn_mode_key, owf_fn_double) isEqualToString:owf_fn_hold];
    }
}

NSString *owf_settings_sound(void) {
    return owf_setting(owf_sound_key, owf_default_sound);
}
