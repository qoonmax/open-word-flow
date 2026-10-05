#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <CoreText/CoreText.h>
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

// The canvas's layouts draw at its size, A+ and F4+ taller for the theme's row.
static NSSize owf_settings_size(void) {
    switch (owf_theme()->layout) {
    case OWFLayoutList:
        return NSMakeSize(800, 724);
    case OWFLayoutBrand:
        return NSMakeSize(960, 889);
    case OWFLayoutSoft:
        return NSMakeSize(960, 828);
    default:
        return NSMakeSize(960, 820);
    }
}

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

// The Bento layout, defined with it; owf_select_titles maps a menu's key to its drawn title.
static NSMutableDictionary *owf_select_titles;
static void owf_bento_forget(void);
static void owf_bento_nav_style(void);
static void owf_bento_counts(void);
static CGFloat owf_bento_list(NSView *list);
static CGFloat owf_brand_list(NSView *list);
static CGFloat owf_soft_list(NSView *list);
static NSView *owf_bento_content(void);
static void owf_select_tab(NSInteger tab);

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
    [owf_select_titles[sender.identifier] setString:sender.titleOfSelectedItem];

    if ([sender.identifier isEqualToString:owf_sound_key]) {
        owf_sound_preview(sender.selectedItem.representedObject);
    }

    // The menu hint follows both the interface language and the Fn mode.
    owf_status_menu_reload();

    if ([sender.identifier isEqualToString:owf_interface_language_key] ||
        [sender.identifier isEqualToString:owf_theme_key]) {
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

    if (owf_theme()->layout != OWFLayoutList) {
        // The Dictation card and both buttons show the mode; rebuild after this action returns.
        dispatch_async(dispatch_get_main_queue(), ^{
            owf_settings_reload();
        });
    }
}

- (void)navChanged:(NSButton *)sender {
    owf_select_tab(sender.tag);
}

- (void)previewSound:(id)sender {
    owf_sound_preview(owf_settings_sound());
}

- (void)textDidChange:(NSNotification *)notification {
    NSString *vocabulary = [[owf_vocabulary_view.string copy] autorelease];
    [NSUserDefaults.standardUserDefaults setObject:vocabulary forKey:owf_vocabulary_key];
}

- (void)tabChanged:(NSSegmentedControl *)sender {
    owf_select_tab(sender.selectedSegment);
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
            @"Transcribing": @"Распознаю",
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
            @"Double-press Fn to start.\nDouble-press again to finish.": @"Дважды нажмите Fn, чтобы начать.\nНажмите Fn ещё раз для завершения.",
            @"Hold Fn while you speak.\nRelease to finish.": @"Удерживайте Fn, пока говорите.\nОтпустите для завершения.",
            @"Sounds": @"Звуки",
            @"Start and stop cues": @"Сигналы начала и конца записи",
            @"Speech language": @"Язык речи",
            @"Language you dictate in": @"На каком языке вы говорите",
            @"Interface language": @"Язык интерфейса",
            @"Make yourself at home": @"Привычный язык приложения",
            @"Theme": @"Тема",
            @"Settings and the recording indicator": @"Настройки и индикатор записи",
            @"Classic": @"Классическая",
            @"Terminal": @"Терминал",
            @"Bento": @"Бенто",
            @"Soft Spectrum": @"Мягкий спектр",
            @"Recognizing": @"Распознаю",
            @"select text and press %@": @"выделите текст и нажмите %@",
            @"Select text and press": @"Выделите текст и нажмите",
            @"Dictation · Fn key": @"Диктовка · клавиша Fn",
            @"Sound and language": @"Звук и язык",
            @"Names and terms — one per line or separated by commas.": @"Имена и термины — по одному на строку или через запятую.",
            @"Names and terms, one per line or separated by commas": @"Имена и термины, по одному на строку или через запятую",
            @"only the last %@ tokens count": @"учитываются последние %@ токенов",
            @"Preview sound": @"Прослушать звук",
            @"Names and terms, one per line or separated by commas.": @"Имена и термины, по одному на строку или через запятую.",
            @"Keep it short: only the last ~200 tokens are used.": @"Пишите коротко: учитываются последние ~200 токенов.",
            @"Changes saved automatically": @"Изменения сохраняются автоматически",
            @"On your Mac": @"На вашем Mac",
            @"Offline transcription.\nYour voice stays here.": @"Работает без интернета.\nВаш голос остаётся здесь.",
            @"Today": @"Сегодня",
            @"Yesterday": @"Вчера",
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

static NSPopUpButton *owf_theme_popup(void) {
    NSPopUpButton *popup = owf_popup(NULL, 0, owf_theme_key, nil);
    size_t count;
    const OWFTheme *themes = owf_themes(&count);

    for (size_t i = 0; i < count; i++) {
        [popup addItemWithTitle:owf_text(themes[i].name)];
        popup.lastItem.representedObject = themes[i].id;

        if (&themes[i] == owf_theme()) {
            [popup selectItem:popup.lastItem];
        }
    }

    return popup;
}

// Drawing semantic colors also refreshes the surfaces when macOS changes theme.
@interface OWFSurface : NSView
@property BOOL sidebar;
@property BOOL canvas;
@property BOOL key;
// A card's fill and hard shadow instead of the theme's.
@property(retain) NSColor *fill;
@property(retain) NSColor *shade;
// The card without its hard shadow.
@property(readonly) NSRect face;
@end

@implementation OWFSurface
- (void)dealloc {
    [_fill release];
    [_shade release];
    [super dealloc];
}

- (NSRect)face {
    CGFloat shadow = owf_theme()->shadow;
    return NSMakeRect(0, shadow, NSWidth(self.bounds) - shadow, NSHeight(self.bounds) - shadow);
}

- (void)drawRect:(NSRect)dirtyRect {
    const OWFTheme *theme = owf_theme();

    if (self.canvas) {
        [theme->canvas setFill];
        NSRectFill(self.bounds);
    } else if (self.sidebar) {
        [theme->sidebar setFill];
        NSRectFill(self.bounds);
        if (theme->wash > 0 && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency) {
            // A faint wash of the island's spectrum.
            NSMutableArray *colors = [NSMutableArray array];
            for (NSColor *color in theme->spectrum) {
                [colors addObject:[color colorWithAlphaComponent:theme->wash]];
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
        CGFloat line = theme->outline == nil ? 1 : 2;
        CGFloat radius = theme->card_radius;
        NSRect face = NSInsetRect(self.face, line / 2, line / 2);
        if (theme->shadow > 0) {
            [self.shade ?: theme->outline setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSOffsetRect(face, theme->shadow, -theme->shadow)
                                             xRadius:radius yRadius:radius] fill];
        }
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:face xRadius:radius yRadius:radius];
        path.lineWidth = line;
        [self.fill ?: theme->card setFill];
        [path fill];
        [theme->outline ?: [NSColor.labelColor colorWithAlphaComponent:0.10] setStroke];
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
    label.font = owf_font(size, weight);
    label.textColor = color;
    label.selectable = NO;
    [parent addSubview:label];
    return label;
}

// A label in the theme's face of the app's name and titles.
static NSTextField *owf_title(NSView *parent, NSString *text, NSRect frame, CGFloat size, NSColor *color) {
    NSTextField *label = owf_label(parent, text, frame, size, NSFontWeightRegular, color);
    label.font = owf_display_font(size);
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
    for (int i = 0; i < 2; i++) {
        owf_modes[i].state = owf_settings_fn_hold() == i ? NSControlStateValueOn : NSControlStateValueOff;
    }

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
    NSDictionary *space = @{NSFontAttributeName: owf_font(owf_body_size, NSFontWeightRegular),
                            NSParagraphStyleAttributeName: paragraph};

    for (NSDictionary *part in parts) {
        int kind = [part[@"kind"] intValue];
        NSMutableDictionary *style = [[space mutableCopy] autorelease];
        style[NSForegroundColorAttributeName] = kind == 0 ? NSColor.labelColor
                                              : kind == 1 ? NSColor.secondaryLabelColor : owf_theme()->accent;

        if (kind == 1) {
            style[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
        } else if (kind == 2) {
            style[NSFontAttributeName] = owf_font(owf_body_size, NSFontWeightMedium);
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
    when.font = owf_font(owf_caption_size, NSFontWeightRegular);
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
        title.font = owf_font(owf_caption_size, NSFontWeightMedium);
        title.textColor = NSColor.secondaryLabelColor;
        title.frame = NSMakeRect(18, y, width - 40, 17);
        [list addSubview:title];

        fields[i] = [NSTextField textFieldWithString:entry[keys[i]]];
        fields[i].frame = NSMakeRect(20, y + 23, width - 40, 60);
        fields[i].font = owf_font(owf_body_size, NSFontWeightRegular);
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
        button.font = owf_font(owf_body_size, NSFontWeightRegular);
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

    switch (owf_theme()->layout) {
    case OWFLayoutBento:
        // The cards' shadows and the canvas's bottom padding.
        y = owf_bento_list(list) + 34;
        break;
    case OWFLayoutBrand:
        y = owf_brand_list(list) + 24;
        break;
    case OWFLayoutSoft:
        y = owf_soft_list(list) + 28;
        break;
    default:
        break;
    }

    if (owf_theme()->layout != OWFLayoutList) {
        owf_bento_counts();
    }

    for (NSInteger i = (NSInteger)owf_corrections.count - 1; i >= 0 && owf_theme()->layout == OWFLayoutList; i--) {
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

static void owf_select_tab(NSInteger tab) {
    // The sidebar shows the open page; rebuild it.
    if (owf_theme()->layout == OWFLayoutBrand || owf_theme()->layout == OWFLayoutSoft) {
        owf_settings_tab = tab;
        owf_corrections_editing = -1;
        owf_settings_reload();
        owf_reveal(tab == 0 ? owf_general_view : owf_corrections_view, 0);
        return;
    }

    owf_settings_tab = tab;
    owf_tabs.selectedSegment = tab;
    owf_corrections_editing = -1;
    owf_corrections_reload();
    owf_show_tab(YES);
}

static void owf_show_tab(BOOL animate) {
    owf_bento_nav_style();
    owf_general_view.hidden = owf_settings_tab != 0;
    owf_corrections_view.hidden = owf_settings_tab != 1;

    if (animate) {
        owf_reveal(owf_settings_tab == 0 ? owf_general_view : owf_corrections_view, 0);
    }
}

// The Corrections tab shares the same content edges as General.
static NSView *owf_corrections_content(NSRect frame) {
    NSView *view = [[[NSView alloc] initWithFrame:frame] autorelease];
    owf_label(view, @"Heard and corrected text, saved with Control+Fn.", NSMakeRect(0, 523, 508, 36), owf_caption_size,
              NSFontWeightRegular, NSColor.secondaryLabelColor);

    OWFSurface *card = [[[OWFSurface alloc] initWithFrame:NSMakeRect(0, 76, 508, 440)] autorelease];
    [view addSubview:card];
    owf_corrections_scroll = [[[NSScrollView alloc] initWithFrame:NSInsetRect(card.face, 2, 6)] autorelease];
    owf_corrections_scroll.drawsBackground = NO;
    owf_corrections_scroll.hasVerticalScroller = YES;
    owf_corrections_scroll.autohidesScrollers = YES;
    owf_corrections_scroll.documentView = [[[OWFFlippedView alloc] initWithFrame:owf_corrections_scroll.bounds] autorelease];
    [card addSubview:owf_corrections_scroll];

    owf_corrections_empty = [[[NSView alloc] initWithFrame:NSMakeRect(44, 156, 420, 132)] autorelease];
    [card addSubview:owf_corrections_empty];
    owf_symbol(owf_corrections_empty, @"text.badge.checkmark", NSMakeRect(193, 94, 34, 34), owf_theme()->accent);
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
        button.font = owf_font(owf_body_size, NSFontWeightRegular);
        [button sizeToFit];
        [view addSubview:button];
    }

    // Bezels are inset 6 points; line their edges up with the card's.
    [show setFrameOrigin:NSMakePoint(-6, 34)];
    [clear setFrameOrigin:NSMakePoint(508 + 6 - NSWidth(clear.frame), 34)];
    return view;
}

// The settings chosen from a menu, as shown: title, hint, and symbol.
static NSString *const owf_options[][3] = {
    {@"Sounds", @"Start and stop cues", @"speaker.wave.2"},
    {@"Speech language", @"Language you dictate in", @"waveform"},
    {@"Interface language", @"Make yourself at home", @"character.bubble"},
    {@"Theme", @"Settings and the recording indicator", @"paintpalette"},
};

enum { owf_option_count = sizeof(owf_options) / sizeof(owf_options[0]) };

static NSPopUpButton *owf_option_popup(int option) {
    NSPopUpButton *popup =
        option == 0 ? owf_popup(owf_sounds, sizeof(owf_sounds) / sizeof(owf_sounds[0]), owf_sound_key, owf_default_sound)
        : option == 1 ? owf_popup(owf_speech_languages, sizeof(owf_speech_languages) / sizeof(owf_speech_languages[0]), owf_language_key, owf_default_language)
        : option == 2 ? owf_popup(owf_interface_languages, sizeof(owf_interface_languages) / sizeof(owf_interface_languages[0]), owf_interface_language_key, owf_system_language)
        : owf_theme_popup();
    popup.font = owf_font(owf_body_size, NSFontWeightRegular);
    [popup setAccessibilityLabel:owf_text(owf_options[option][0])];
    return popup;
}

// The Dictation radios, the first at origin and the second below it.
static void owf_mode_radios(NSView *parent, NSPoint origin, NSFontWeight weight, NSColor *tint) {
    NSArray *modeTitles = @[owf_text(@"Double press"), owf_text(@"Press and hold")];
    for (NSInteger i = 0; i < 2; i++) {
        NSButton *mode = [NSButton radioButtonWithTitle:modeTitles[i] target:owf_settings action:@selector(modeChanged:)];
        mode.tag = i;
        mode.frame = NSMakeRect(origin.x, origin.y - i * 28, 184, 24);
        mode.font = owf_font(owf_body_size, weight);
        mode.contentTintColor = tint;
        mode.attributedTitle = [[[NSAttributedString alloc] initWithString:modeTitles[i]
            attributes:@{NSFontAttributeName: mode.font, NSForegroundColorAttributeName: NSColor.labelColor}] autorelease];
        mode.state = owf_settings_fn_hold() == i ? NSControlStateValueOn : NSControlStateValueOff;
        [parent addSubview:mode];
        owf_modes[i] = mode;
    }
}

static NSButton *owf_preview_button(NSView *parent, NSRect frame) {
    NSButton *preview = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:owf_text(@"Preview sound")]
                                         target:owf_settings action:@selector(previewSound:)];
    preview.frame = frame;
    preview.bezelStyle = NSBezelStyleRounded;
    preview.toolTip = owf_text(@"Preview sound");
    [preview setAccessibilityLabel:owf_text(@"Preview sound")];
    [parent addSubview:preview];
    return preview;
}

static void owf_vocabulary_editor(NSView *parent, NSRect frame) {
    NSScrollView *scroll = [NSTextView scrollableTextView];
    scroll.frame = frame;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;
    scroll.autohidesScrollers = YES;
    owf_vocabulary_view = scroll.documentView;
    owf_vocabulary_view.richText = NO;
    owf_vocabulary_view.drawsBackground = NO;
    owf_vocabulary_view.font = owf_font(owf_body_size, NSFontWeightRegular);
    NSMutableParagraphStyle *vocabularyStyle = [[[NSMutableParagraphStyle alloc] init] autorelease];
    vocabularyStyle.lineSpacing = 3;
    owf_vocabulary_view.defaultParagraphStyle = vocabularyStyle;
    owf_vocabulary_view.textColor = NSColor.labelColor;
    owf_vocabulary_view.insertionPointColor = owf_theme()->accent;
    owf_vocabulary_view.textContainerInset = NSMakeSize(7, 7);
    owf_vocabulary_view.automaticQuoteSubstitutionEnabled = NO;
    owf_vocabulary_view.automaticDashSubstitutionEnabled = NO;
    owf_vocabulary_view.automaticTextReplacementEnabled = NO;
    owf_vocabulary_view.allowsUndo = YES;
    owf_vocabulary_view.string = owf_setting(owf_vocabulary_key, @"");
    owf_vocabulary_view.delegate = owf_settings;
    [owf_vocabulary_view setAccessibilityLabel:owf_text(@"Vocabulary")];
    [owf_vocabulary_view setAccessibilityHelp:owf_text(@"Names and terms, one per line or separated by commas.")];
    [parent addSubview:scroll];
}

// Whether macOS dims its text or not, the privacy note sits at the bottom of the sidebar.
static NSTextField *owf_privacy(NSView *parent, CGFloat x, CGFloat bottom, CGFloat width, NSColor *tint) {
    // The last line ends on the same baseline as the body's last line.
    CGFloat privacy = owf_label_above(parent, @"Offline transcription.\nYour voice stays here.", x, bottom, width) + 8;
    NSTextField *title = owf_label(parent, @"On your Mac", NSMakeRect(x + 26, privacy, width - 29, 20),
                                   owf_caption_size, NSFontWeightSemibold, NSColor.labelColor);
    owf_label_symbol(parent, @"lock.shield", x, title, tint);
    return title;
}

// Settings as rows in one card, the sidebar holding the fn key.
static void owf_list_sidebar(NSView *sidebar) {
    // The logo's top lines up with the cap height of the Settings title.
    owf_spectrum_symbol(sidebar, @"waveform", 28, 659, 34);
    owf_title(sidebar, @"Open\nWord Flow", NSMakeRect(28, 523, 184, 86), 31, NSColor.labelColor);
    owf_label(sidebar, @"Speak freely. Stay in your flow.", NSMakeRect(28, 465, 172, 46), 13,
              NSFontWeightRegular, NSColor.secondaryLabelColor);

    OWFSurface *key = owf_key(sidebar, NSMakeRect(28, 343, 76, 76));
    owf_label(key, @"fn", NSMakeRect(16, 13, 50, 38), 30, NSFontWeightMedium, [NSColor colorWithWhite:1 alpha:0.92]);
    owf_symbol(key, @"globe", NSMakeRect(48, 46, 16, 16), [NSColor colorWithWhite:1 alpha:0.55]);
    owf_shortcut_hint = owf_label(sidebar, @"", NSMakeRect(28, 251, 184, 72), owf_caption_size,
                                  NSFontWeightRegular, NSColor.secondaryLabelColor);
    owf_update_shortcut();
    owf_privacy(sidebar, 28, 32, 184, owf_theme()->accent);
}

static void owf_list_general(NSView *general) {
    NSTextField *saved = owf_label(general, @"Changes saved automatically", NSMakeRect(24, 13, 484, 18),
                                    owf_caption_size, NSFontWeightRegular, NSColor.secondaryLabelColor);
    owf_label_symbol(general, @"checkmark.circle", 0, saved, NSColor.secondaryLabelColor);

    // Dictation is a preference, not navigation: native radios share the other settings' card.
    OWFSurface *options = [[[OWFSurface alloc] initWithFrame:NSMakeRect(0, 223, 508, 332)] autorelease];
    [general addSubview:options];
    owf_symbol(options, @"keyboard", NSMakeRect(17, 287, 22, 22), owf_theme()->accent);
    owf_label(options, @"Dictation", NSMakeRect(52, 299, 249, 19), owf_body_size, NSFontWeightMedium, NSColor.labelColor);
    owf_label(options, @"Fn key behavior", NSMakeRect(52, 278, 249, 18), owf_caption_size,
              NSFontWeightRegular, NSColor.secondaryLabelColor);
    owf_mode_radios(options, NSMakePoint(306, 300), NSFontWeightRegular, owf_theme()->accent);
    NSBox *modeDivider = [[[NSBox alloc] initWithFrame:NSMakeRect(52, 256, 438, 1)] autorelease];
    modeDivider.boxType = NSBoxSeparator;
    [options addSubview:modeDivider];
    for (int i = 0; i < owf_option_count; i++) {
        CGFloat y = 192 - i * 64;
        owf_symbol(options, owf_options[i][2], NSMakeRect(17, y + 21, 22, 22), owf_theme()->accent);
        owf_label(options, owf_options[i][0], NSMakeRect(52, y + 33, 249, 19), owf_body_size, NSFontWeightMedium, NSColor.labelColor);
        owf_label(options, owf_options[i][1], NSMakeRect(52, y + 12, 249, 18), owf_caption_size, NSFontWeightRegular, NSColor.secondaryLabelColor);
        NSPopUpButton *popup = owf_option_popup(i);
        popup.frame = NSMakeRect(306, y + 19, i == 0 ? 143 : 184, 28);
        [options addSubview:popup];
        if (i > 0) {
            NSBox *divider = [[[NSBox alloc] initWithFrame:NSMakeRect(52, y + 63, 438, 1)] autorelease];
            divider.boxType = NSBoxSeparator;
            [options addSubview:divider];
        }
    }
    owf_preview_button(options, NSMakeRect(458, 211, 32, 28));

    owf_label(general, @"Vocabulary", NSMakeRect(0, 185, 508, 23), owf_body_size, NSFontWeightSemibold, NSColor.labelColor);
    owf_label(general, @"Names and terms, one per line or separated by commas.", NSMakeRect(0, 161, 508, 20),
              owf_caption_size, NSFontWeightRegular, NSColor.secondaryLabelColor);
    CGFloat editorBottom = owf_label_above(general, @"Keep it short: only the last ~200 tokens are used.", 0, 43, 508) + 8;
    OWFSurface *editor = [[[OWFSurface alloc] initWithFrame:NSMakeRect(0, editorBottom, 508, 153 - editorBottom)] autorelease];
    [general addSubview:editor];
    owf_vocabulary_editor(editor, NSInsetRect(editor.face, 7, 7));
}

// Layout F3 of the design canvas, drawn to its coordinates: the origin at the
// window's top left and one point per CSS pixel. Text sits on the baselines a
// browser gives it: Blink rounds a font's ascent and descent to whole pixels
// and floors the half-leading of a line box.
enum {
    owf_ink = 0x17141F, owf_cream = 0xFFF6EC, owf_lavender = 0xEDE9FF, owf_yellow = 0xFFD84D, owf_sky = 0x8FDDFF,
    owf_pink = 0xFF9ED2, owf_coral = 0xFF7A59, owf_hint = 0x2C2833, owf_muted = 0x4A4556, owf_note = 0x5E586A,
    owf_struck = 0x3A3545,
};
// The sidebar's width; both tabs' views start at its edge.
static const CGFloat owf_bento_left = 256;

// The design's 24-point line icons as absolute M, L, C, and Z commands.
static NSString *owf_icon_commands(NSString *name) {
    static NSDictionary *icons;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        icons = [@{
            @"sliders": @"M4 6L14 6M18 6L20 6M4 12L8 12M12 12L20 12M4 18L16 18M18 6C18 7.105 17.105 8 16 8C14.895 8 14 7.105 14 6C14 4.895 14.895 4 16 4C17.105 4 18 4.895 18 6ZM12 12C12 13.105 11.105 14 10 14C8.895 14 8 13.105 8 12C8 10.895 8.895 10 10 10C11.105 10 12 10.895 12 12ZM20 18C20 19.105 19.105 20 18 20C16.895 20 16 19.105 16 18C16 16.895 16.895 16 18 16C19.105 16 20 16.895 20 18Z",
            @"pencil": @"M13 20L20 20M16.5 3.5C18.232 1.768 21.232 4.768 19.5 6.5L7 19L3 20L4 16L16.5 3.5Z",
            @"shield": @"M12 3L19 6L19 12C19 16.5 16 19.5 12 21C8 19.5 5 16.5 5 12L5 6L12 3Z",
            @"check": @"M5 12.5L9.5 17L19 7.5",
            @"globe": @"M21 12C21 16.971 16.971 21 12 21C7.029 21 3 16.971 3 12C3 7.029 7.029 3 12 3C16.971 3 21 7.029 21 12ZM3 12L21 12M12 3C14.5 5.7 15.8 8.7 15.8 12C15.8 15.3 14.5 18.3 12 21C9.5 18.3 8.2 15.3 8.2 12C8.2 8.7 9.5 5.7 12 3Z",
            @"speaker": @"M4 9.5L7 9.5L12 5.5L12 18.5L7 14.5L4 14.5L4 9.5ZM16 9C17.789 10.578 17.789 13.422 16 15M18.5 6.5C21.675 9.444 21.675 14.556 18.5 17.5",
            @"waveform": @"M4 10L4 14M8 7L8 17M12 4L12 20M16 8L16 16M20 11L20 13",
            @"bubble": @"M5 4L19 4C20.097 4 21 4.903 21 6L21 15C21 16.097 20.097 17 19 17L12 17L7 21L7 17L5 17C3.903 17 3 16.097 3 15L3 6C3 4.903 3.903 4 5 4ZM9 14L12 7L15 14M10.2 11.5L13.8 11.5",
            @"chevron": @"M6 9L12 15L18 9",
            @"play": @"M7 4L7 20L21 12L7 4Z",
            @"folder": @"M3 7C3 5.903 3.903 5 5 5L9 5L11 7L19 7C20.097 7 21 7.903 21 9L21 17C21 18.097 20.097 19 19 19L5 19C3.903 19 3 18.097 3 17L3 7Z",
            @"trash": @"M4 7L20 7M10 11L10 17M14 11L14 17M6 7L7 19C7 20.097 7.903 21 9 21L15 21C16.097 21 17 20.097 17 19L18 7M9 7L9 4L15 4L15 7",
            @"edit": @"M12 4L6 4C4.903 4 4 4.903 4 6L4 18C4 19.097 4.903 20 6 20L18 20C19.097 20 20 19.097 20 18L20 12M17.5 3.5C19.232 1.768 22.232 4.768 20.5 6.5L12 15L8 16L9 12L17.5 3.5Z",
            @"shield.lock": @"M12 3L19 6L19 12C19 16.5 16 19.5 12 21C8 19.5 5 16.5 5 12L5 6ZM10 11L14 11C14.552 11 15 11.448 15 12L15 15C15 15.552 14.552 16 14 16L10 16C9.448 16 9 15.552 9 15L9 12C9 11.448 9.448 11 10 11ZM10.5 11L10.5 9.5C10.5 8.672 11.172 8 12 8C12.828 8 13.5 8.672 13.5 9.5L13.5 11",
            @"updown": @"M8 9L12 5L16 9M8 15L12 19L16 15",
            @"play.brand": @"M7 4.5L7 19.5L20 12Z",
            @"book": @"M2 4L8 4C10.209 4 12 5.791 12 8L12 21C12 19.343 10.657 18 9 18L2 18ZM22 4L16 4C13.791 4 12 5.791 12 8L12 21C12 19.343 13.343 18 15 18L22 18Z",
            @"file": @"M14 3L7 3C5.895 3 5 3.895 5 5L5 19C5 20.105 5.895 21 7 21L17 21C18.105 21 19 20.105 19 19L19 8ZM14 3L14 8L19 8",
            @"x": @"M6 6L18 18M18 6L6 18",
            @"palette": @"M12 3C7.029 3 3 7.029 3 12C3 16.971 7.029 21 12 21C13.1 21 13.8 20.2 13.8 19.2C13.8 18.7 13.6 18.3 13.3 18C13 17.7 12.8 17.3 12.8 16.8C12.8 15.8 13.6 15 14.6 15L17 15C19.209 15 21 13.209 21 11C21 6.6 17 3 12 3ZM8.7 11C8.7 11.663 8.163 12.2 7.5 12.2C6.837 12.2 6.3 11.663 6.3 11C6.3 10.337 6.837 9.8 7.5 9.8C8.163 9.8 8.7 10.337 8.7 11ZM11.2 7.5C11.2 8.163 10.663 8.7 10 8.7C9.337 8.7 8.8 8.163 8.8 7.5C8.8 6.837 9.337 6.3 10 6.3C10.663 6.3 11.2 6.837 11.2 7.5ZM15.7 7.5C15.7 8.163 15.163 8.7 14.5 8.7C13.837 8.7 13.3 8.163 13.3 7.5C13.3 6.837 13.837 6.3 14.5 6.3C15.163 6.3 15.7 6.837 15.7 7.5Z",
        } retain];
    });

    return icons[name];
}

@interface OWFIcon : NSView
@property(copy) NSString *name;
@property(retain) NSColor *color;
// Stroke width on the 24-point grid; 0 fills the shape instead.
@property CGFloat stroke;
@end

@implementation OWFIcon
- (BOOL)isFlipped {
    return YES;
}

- (void)dealloc {
    [_name release];
    [_color release];
    [super dealloc];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *path = owf_icon_path(self.name);
    NSAffineTransform *scale = [NSAffineTransform transform];
    [scale scaleBy:NSWidth(self.bounds) / 24];
    [path transformUsingAffineTransform:scale];
    [self.color set];

    if (self.stroke > 0) {
        path.lineWidth = self.stroke * NSWidth(self.bounds) / 24;
        path.lineCapStyle = NSLineCapStyleRound;
        path.lineJoinStyle = NSLineJoinStyleRound;
        [path stroke];
    } else {
        [path fill];
    }
}
@end

NSBezierPath *owf_icon_path(NSString *name) {
    NSBezierPath *path = [NSBezierPath bezierPath];
    NSScanner *scanner = [NSScanner scannerWithString:owf_icon_commands(name)];
    NSCharacterSet *commands = [NSCharacterSet characterSetWithCharactersInString:@"MLCZ"];
    NSString *letters;
    double v[6];

    while ([scanner scanCharactersFromSet:commands intoString:&letters]) {
        if ([letters containsString:@"Z"]) {
            [path closePath];
        }

        unichar command = [letters characterAtIndex:letters.length - 1];
        if (command == 'Z') {
            continue;
        }

        for (int i = 0; i < (command == 'C' ? 6 : 2); i++) {
            [scanner scanDouble:&v[i]];
        }

        if (command == 'M') {
            [path moveToPoint:NSMakePoint(v[0], v[1])];
        } else if (command == 'L') {
            [path lineToPoint:NSMakePoint(v[0], v[1])];
        } else {
            [path curveToPoint:NSMakePoint(v[4], v[5]) controlPoint1:NSMakePoint(v[0], v[1])
                 controlPoint2:NSMakePoint(v[2], v[3])];
        }
    }

    return path;
}

// A CSS box: a fill, a border inside its edge, 2 points unless line says
// otherwise, a 1-point highlight inset along its top, and a hard shadow offset
// right and down. Its frame spans the shadow; subviews sit on the box itself.
@interface OWFBox : NSView
@property(retain) NSColor *fill, *stroke, *shade, *highlight;
@property CGFloat radius, offset, line;
@end

@implementation OWFBox
- (BOOL)isFlipped {
    return YES;
}

- (void)dealloc {
    [_fill release];
    [_stroke release];
    [_shade release];
    [_highlight release];
    [super dealloc];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect face = NSMakeRect(0, 0, NSWidth(self.bounds) - self.offset, NSHeight(self.bounds) - self.offset);
    CGFloat radius = fmin(self.radius, fmin(NSWidth(face), NSHeight(face)) / 2);
    CGFloat line = self.line > 0 ? self.line : 2;

    if (self.shade != nil) {
        [self.shade setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSOffsetRect(face, self.offset, self.offset)
                                         xRadius:radius yRadius:radius] fill];
    }

    if (self.fill != nil) {
        NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:face xRadius:radius yRadius:radius];
        [self.fill setFill];
        [body fill];

        // The highlight, then the fill again a point lower, leaves the
        // highlight along the top edge and up into the corners.
        if (self.highlight != nil) {
            [NSGraphicsContext saveGraphicsState];
            [body addClip];
            [self.highlight setFill];
            [body fill];
            [self.fill setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSOffsetRect(face, 0, 1) xRadius:radius yRadius:radius] fill];
            [NSGraphicsContext restoreGraphicsState];
        }
    }

    if (self.stroke != nil) {
        NSBezierPath *edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(face, line / 2, line / 2)
                                                             xRadius:fmax(radius - line / 2, 0)
                                                             yRadius:fmax(radius - line / 2, 0)];
        edge.lineWidth = line;
        [self.stroke setStroke];
        [edge stroke];
    }
}
@end

// A CSS box-shadow with blur under the box added after it: the box's shape,
// moved by x and y and blurred by Core Image, not by Quartz shadows, whose
// offsets flip between a window's layers and a snapshot's bitmap.
@interface OWFShadow : NSView
@property(retain) NSColor *color;
@property CGFloat radius, x, y, blur, margin;
@end

@implementation OWFShadow {
    CGImageRef _image;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)dealloc {
    [_color release];
    CGImageRelease(_image);
    [super dealloc];
}

- (NSView *)hitTest:(NSPoint)point {
    return nil;
}

- (void)drawRect:(NSRect)dirtyRect {
    if (_image == NULL) {
        CGFloat scale = self.window.backingScaleFactor > 0 ? self.window.backingScaleFactor : 2;
        size_t width = ceil(NSWidth(self.bounds) * scale), height = ceil(NSHeight(self.bounds) * scale);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        // Top down, as the view is.
        CGContextTranslateCTM(bitmap, 0, height);
        CGContextScaleCTM(bitmap, scale, -scale);
        NSRect face = NSOffsetRect(NSInsetRect(self.bounds, self.margin, self.margin), self.x, self.y);
        CGPathRef path = CGPathCreateWithRoundedRect(face, self.radius, self.radius, NULL);
        CGContextAddPath(bitmap, path);
        CGContextSetFillColorWithColor(bitmap, self.color.CGColor);
        CGContextFillPath(bitmap);
        CGPathRelease(path);
        CGImageRef shape = CGBitmapContextCreateImage(bitmap);

        // CSS blurs with a standard deviation of half the blur radius.
        CIImage *blurred = [[CIImage imageWithCGImage:shape] imageByApplyingGaussianBlurWithSigma:self.blur / 2 * scale];
        CIContext *context = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: (id)space}];
        _image = [context createCGImage:blurred fromRect:CGRectMake(0, 0, width, height)];
        CGImageRelease(shape);
        CGContextRelease(bitmap);
        CGColorSpaceRelease(space);
    }

    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    // The image is bottom up; the view is flipped.
    CGContextTranslateCTM(context, 0, NSHeight(self.bounds));
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, self.bounds, _image);
    CGContextRestoreGState(context);
}
@end

// Adds a blurred shadow of the box face would have; add the box right after.
static void owf_blur(NSView *parent, NSRect face, CGFloat radius, NSColor *color, CGFloat x, CGFloat y, CGFloat blur) {
    CGFloat margin = blur * 1.5 + fmax(fabs(x), fabs(y));
    OWFShadow *shadow = [[[OWFShadow alloc] initWithFrame:NSInsetRect(face, -margin, -margin)] autorelease];
    shadow.color = color;
    shadow.radius = radius;
    shadow.x = x;
    shadow.y = y;
    shadow.blur = blur;
    shadow.margin = margin;
    [parent addSubview:shadow];
}

// Lines of text drawn from a first baseline, pitch apart, broken between words
// to fit the width, as CSS lays out a block of text.
@interface OWFText : NSView
@property(copy, nonatomic) NSAttributedString *text;
// The attributes of words set with setString:, which an empty text cannot hold.
@property(copy) NSDictionary *style;
@property CGFloat baseline, pitch;
@property NSTextAlignment alignment;
// One line cut short with an ellipsis instead of wrapping.
@property BOOL oneLine;
@property(readonly) NSUInteger lineCount;
// Replaces the words and keeps the style.
- (void)setString:(NSString *)string;
@end

@implementation OWFText {
    NSArray *_lines;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)dealloc {
    [_text release];
    [_style release];
    [_lines release];
    [super dealloc];
}

- (void)setText:(NSAttributedString *)text {
    [_text release];
    _text = [text copy];
    NSMutableArray *lines = [NSMutableArray array];

    if (self.oneLine) {
        CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)text);
        NSAttributedString *dots = [[[NSAttributedString alloc] initWithString:@"…"
            attributes:text.length > 0 ? [text attributesAtIndex:0 effectiveRange:NULL] : @{}] autorelease];
        CTLineRef ellipsis = CTLineCreateWithAttributedString((CFAttributedStringRef)dots);
        CTLineRef cut = CTLineCreateTruncatedLine(line, NSWidth(self.bounds), kCTLineTruncationEnd, ellipsis);
        [lines addObject:(id)(cut ?: line)];
        if (cut != NULL) CFRelease(cut);
        CFRelease(ellipsis);
        CFRelease(line);
    } else {
        CTTypesetterRef setter = CTTypesetterCreateWithAttributedString((CFAttributedStringRef)text);
        for (CFIndex start = 0; start < (CFIndex)text.length;) {
            CFIndex count = CTTypesetterSuggestLineBreak(setter, start, NSWidth(self.bounds));
            if (count <= 0) break;
            CTLineRef line = CTTypesetterCreateLine(setter, CFRangeMake(start, count));
            [lines addObject:(id)line];
            CFRelease(line);
            start += count;
        }
        CFRelease(setter);
    }

    [_lines release];
    _lines = [lines retain];
    [self setAccessibilityElement:YES];
    [self setAccessibilityRole:NSAccessibilityStaticTextRole];
    [self setAccessibilityValue:text.string];
    self.needsDisplay = YES;
}

- (void)setString:(NSString *)string {
    self.text = [[[NSAttributedString alloc] initWithString:string ?: @"" attributes:self.style ?: @{}] autorelease];
}

- (NSUInteger)lineCount {
    return _lines.count;
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));

    for (NSUInteger i = 0; i < _lines.count; i++) {
        CTLineRef line = (CTLineRef)_lines[i];
        CGFloat width = CTLineGetTypographicBounds(line, NULL, NULL, NULL) - CTLineGetTrailingWhitespaceWidth(line);
        CGFloat x = self.alignment == NSTextAlignmentCenter ? (NSWidth(self.bounds) - width) / 2
                  : self.alignment == NSTextAlignmentRight ? NSWidth(self.bounds) - width : 0;
        CGContextSetTextPosition(context, x, self.baseline + i * self.pitch);
        CTLineDraw(line, context);
    }
}
@end

// Where Blink paints a baseline at y: on the nearest device pixel of a 2x display.
static CGFloat owf_snap(CGFloat y) {
    return round(y * 2) / 2;
}

// A font's ascent and descent as Blink holds them on a 2x display: rounded to
// device pixels.
static CGFloat owf_ascent(NSFont *font) {
    return owf_snap(font.ascender);
}

static CGFloat owf_line_box(NSFont *font) {
    return owf_snap(font.ascender) + owf_snap(-font.descender);
}

// The baseline of one line of text centered in a box height high, as flex centers it.
static CGFloat owf_middle(NSFont *font, CGFloat top, CGFloat height) {
    return owf_snap(top + (height - owf_line_box(font)) / 2 + owf_ascent(font));
}

// The first baseline of text whose line boxes start at top and are line high,
// or as high as the font's for 0, as Blink lays it out: exact half-leading,
// then the baseline snapped to a device pixel.
static CGFloat owf_first_baseline(NSFont *font, CGFloat top, CGFloat line) {
    return owf_snap(top + (line > 0 ? (line - owf_line_box(font)) / 2 : 0) + owf_ascent(font));
}

// Text in font and color, spaced apart by CSS letter-spacing: tracking, which
// keeps the font's kerning, where a kern of 0 would turn it off.
static NSDictionary *owf_style(NSFont *font, NSColor *color, CGFloat spacing) {
    return @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        (id)kCTForegroundColorAttributeName: (id)color.CGColor,
        (id)kCTTrackingAttributeName: @(spacing),
    };
}

static CGFloat owf_text_width(NSString *string, NSDictionary *style) {
    NSAttributedString *text = [[[NSAttributedString alloc] initWithString:string attributes:style] autorelease];
    CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)text);
    CGFloat width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line);
    return width;
}

static NSUInteger owf_line_count(NSString *string, NSDictionary *style, CGFloat width) {
    NSAttributedString *text = [[[NSAttributedString alloc] initWithString:string attributes:style] autorelease];
    CTTypesetterRef setter = CTTypesetterCreateWithAttributedString((CFAttributedStringRef)text);
    NSUInteger lines = 0;
    CFIndex start = 0;

    while (start < (CFIndex)text.length) {
        CFIndex count = CTTypesetterSuggestLineBreak(setter, start, width);
        if (count <= 0) break;
        start += count;
        lines++;
    }

    CFRelease(setter);
    return lines;
}

// Text in parent with its first baseline at baseline, wrapped to width, lines
// pitch apart or as far as the font's line box for 0.
static OWFText *owf_text_at(NSView *parent, NSString *string, NSDictionary *style, CGFloat x, CGFloat baseline,
                            CGFloat width, CGFloat pitch) {
    NSFont *font = style[NSFontAttributeName];
    CGFloat above = ceil(font.ascender) + 4;
    OWFText *text = [[[OWFText alloc] initWithFrame:NSMakeRect(x, baseline - above, width, 1)] autorelease];
    text.baseline = above;
    text.pitch = pitch > 0 ? pitch : owf_line_box(font);
    text.style = style;
    text.text = [[[NSAttributedString alloc] initWithString:string attributes:style] autorelease];
    CGFloat lines = fmax(text.lineCount, 1);
    [text setFrameSize:NSMakeSize(width, above + (lines - 1) * text.pitch + ceil(-font.descender) + 4)];
    [parent addSubview:text];
    return text;
}

static OWFBox *owf_box(NSView *parent, NSRect face, NSColor *fill, NSColor *stroke, CGFloat radius,
                       NSColor *shade, CGFloat offset) {
    // Blink paints a box's edges on device pixels.
    CGFloat left = round(NSMinX(face) * 2) / 2, top = round(NSMinY(face) * 2) / 2;
    face = NSMakeRect(left, top, round(NSMaxX(face) * 2) / 2 - left, round(NSMaxY(face) * 2) / 2 - top);
    OWFBox *box = [[[OWFBox alloc] initWithFrame:NSMakeRect(NSMinX(face), NSMinY(face), NSWidth(face) + offset,
                                                            NSHeight(face) + offset)] autorelease];
    box.fill = fill;
    box.stroke = stroke;
    box.radius = radius;
    box.shade = shade;
    box.offset = shade == nil ? 0 : offset;
    [parent addSubview:box];
    return box;
}

static OWFIcon *owf_icon(NSView *parent, NSString *name, NSRect frame, NSColor *color, CGFloat stroke) {
    OWFIcon *icon = [[[OWFIcon alloc] initWithFrame:frame] autorelease];
    icon.name = name;
    icon.color = color;
    icon.stroke = stroke;
    [icon setAccessibilityElement:NO];
    [parent addSubview:icon];
    return icon;
}

// An invisible button over a drawn one, which takes its clicks and speaks for it.
static NSButton *owf_hit(NSView *parent, NSRect frame, NSString *label, SEL action, NSInteger tag) {
    NSButton *button = [NSButton buttonWithTitle:@"" target:owf_settings action:action];
    button.bordered = NO;
    button.frame = frame;
    button.tag = tag;
    button.toolTip = label;
    [button setAccessibilityLabel:label];
    [parent addSubview:button];
    return button;
}

// A count badge that fits its number: at least min wide, pad on each side,
// its edge at x, the left edge or, when right, the right one.
typedef struct {
    CGFloat x, min, pad;
    BOOL right;
} OWFFit;

// Rebuilt with the window; nil under the other themes.
static OWFBox *owf_nav[2];
static OWFText *owf_nav_titles[2];
static OWFIcon *owf_nav_icons[2];
static OWFBox *owf_count_badges[2];
static OWFText *owf_count_texts[2];
static OWFBox *owf_clear_box;
static OWFFit owf_count_fits[2];

static void owf_bento_forget(void) {
    for (int i = 0; i < 2; i++) {
        owf_nav[i] = nil;
        owf_nav_titles[i] = nil;
        owf_nav_icons[i] = nil;
        owf_count_badges[i] = nil;
        owf_count_texts[i] = nil;
    }

    owf_clear_box = nil;
    owf_count_fits[0] = owf_count_fits[1] = (OWFFit){0};
    [owf_select_titles release];
    owf_select_titles = [[NSMutableDictionary alloc] init];
}

// The sidebar link of the open tab is a white card; the other is bare.
static void owf_bento_nav_style(void) {
    NSColor *ink = owf_hex(owf_ink);
    NSString *titles[] = {@"General", @"Corrections"};

    for (int i = 0; i < 2 && owf_nav[i] != nil; i++) {
        BOOL open = owf_settings_tab == i;
        NSColor *color = open ? ink : NSColor.whiteColor;
        owf_nav[i].fill = open ? NSColor.whiteColor : nil;
        owf_nav[i].stroke = open ? ink : nil;
        owf_nav[i].shade = open ? ink : nil;
        owf_nav[i].needsDisplay = YES;
        owf_nav_icons[i].color = color;
        owf_nav_icons[i].needsDisplay = YES;
        owf_nav_titles[i].text = [[[NSAttributedString alloc] initWithString:owf_text(titles[i])
            attributes:owf_style(owf_font(15, open ? NSFontWeightHeavy : NSFontWeightBold), color, 0)] autorelease];
    }
}

// A menu drawn as the design's select: a white box with the chosen title and a
// chevron, over the invisible pop-up that does the choosing.
static void owf_bento_select(NSView *parent, NSPopUpButton *popup, NSRect face, CGFloat chevron) {
    NSColor *ink = owf_hex(owf_ink);
    OWFBox *box = owf_box(parent, face, NSColor.whiteColor, ink, 12, nil, 0);
    OWFText *title = [[[OWFText alloc] initWithFrame:NSMakeRect(14, 0, NSWidth(face) - chevron - 16 - 20, 42)] autorelease];
    title.oneLine = YES;
    title.baseline = 26.5;
    title.style = owf_style(owf_font(14, NSFontWeightBold), ink, 0);
    [title setString:popup.titleOfSelectedItem];
    [box addSubview:title];
    owf_icon(box, @"chevron", NSMakeRect(NSWidth(face) - chevron - 16, 13, 16, 16), ink, 2.2);
    popup.frame = box.bounds;
    popup.alphaValue = 0;
    [box addSubview:popup];
    owf_select_titles[popup.identifier] = title;
}

// A pill button of the Corrections tab: an optional icon and a bold title.
static OWFBox *owf_bento_pill(NSView *parent, CGFloat right, CGFloat top, NSString *title, NSString *icon,
                              BOOL dark, SEL action) {
    NSColor *ink = owf_hex(owf_ink), *text = dark ? owf_hex(owf_cream) : ink;
    NSDictionary *style = owf_style(owf_font(13.5, NSFontWeightHeavy), text, 0);
    CGFloat inset = icon == nil ? 16 : 38;
    CGFloat width = ceil(owf_text_width(owf_text(title), style)) + inset + 16;
    OWFBox *pill = owf_box(parent, NSMakeRect(right - width, top, width, 44), dark ? ink : NSColor.whiteColor, ink, 22,
                           dark ? owf_hex(owf_coral) : ink, 3);
    if (icon != nil) {
        owf_icon(pill, icon, NSMakeRect(16, 14, 16, 16), text, 2.2);
    }
    owf_text_at(pill, owf_text(title), style, inset, 27, width - inset, 0);
    owf_hit(pill, NSMakeRect(0, 0, width, 44), owf_text(title), action, 0);
    return pill;
}

static void owf_bento_sidebar(NSView *root) {
    NSColor *ink = owf_hex(owf_ink), *white = NSColor.whiteColor, *lavender = owf_hex(owf_lavender);
    OWFBox *side = owf_box(root, NSMakeRect(0, 0, owf_bento_left, 820), owf_theme()->sidebar, nil, 0, nil, 0);

    const uint32_t colors[] = {owf_sky, 0xFFFFFF, owf_pink, owf_yellow, owf_coral, 0xFFFFFF, owf_sky};
    const CGFloat heights[] = {22, 42, 56, 30, 48, 18, 34};
    for (int i = 0; i < 7; i++) {
        owf_box(side, NSMakeRect(20 + i * 15, 100 - heights[i] / 2, 10, heights[i]), owf_hex(colors[i]), nil, 5, nil, 0);
    }

    NSFont *wordmark = owf_display_font(26);
    NSArray *name = [owf_text(@"Open\nWord Flow") componentsSeparatedByString:@"\n"];
    for (NSUInteger i = 0; i < name.count; i++) {
        owf_text_at(side, name[i], owf_style(wordmark, white, 0), 20, owf_first_baseline(wordmark, 146, 28.08) + i * 28.08,
                    216, 0);
    }

    CGFloat top = 146 + name.count * 28.08 + 10;
    NSFont *tagline = owf_font(14, NSFontWeightSemibold);
    OWFText *motto = owf_text_at(side, owf_text(@"Speak freely. Stay in your flow."), owf_style(tagline, lavender, 0), 20,
                                 owf_first_baseline(tagline, top, 19.6), 216, 19.6);
    top += motto.lineCount * 19.6 + 36;

    NSString *const titles[] = {@"General", @"Corrections"};
    NSString *const icons[] = {@"sliders", @"pencil"};
    for (int i = 0; i < 2; i++) {
        CGFloat y = top + i * 56;
        // Clear until owf_bento_nav_style shades the open tab's link.
        owf_nav[i] = owf_box(side, NSMakeRect(20, y, 216, 48), nil, nil, 14, NSColor.clearColor, 3);
        owf_nav_icons[i] = owf_icon(owf_nav[i], icons[i], NSMakeRect(16, 15, 18, 18), white, 2.2);
        owf_nav_titles[i] = owf_text_at(owf_nav[i], owf_text(titles[i]), owf_style(owf_font(15, NSFontWeightBold), white, 0),
                                        46, 29.5, 120, 0);
        if (i == 1) {
            // The count sits inside the Corrections link, right-aligned, under the link's click target.
            owf_count_badges[0] = owf_box(owf_nav[1], NSMakeRect(174, 11, 26, 26), owf_hex(owf_yellow), ink, 13, nil, 0);
            owf_count_texts[0] = owf_text_at(owf_count_badges[0], @"", owf_style(owf_font(13, NSFontWeightHeavy), ink, 0),
                                             0, 18, 26, 0);
            owf_count_texts[0].alignment = NSTextAlignmentCenter;
        }
        owf_hit(owf_nav[i], NSMakeRect(0, 0, 216, 48), owf_text(titles[i]), @selector(navChanged:), i);
    }
    owf_bento_nav_style();

    NSDictionary *bodyStyle = owf_style(owf_font(13, NSFontWeightMedium), lavender, 0);
    NSString *body = [owf_text(@"Offline transcription.\nYour voice stays here.") stringByReplacingOccurrencesOfString:@"\n"
                                                                                                          withString:@" "];
    CGFloat height = 14 + 19 + 4 + owf_line_count(body, bodyStyle, 184) * 18.85 + 14;
    OWFBox *privacy = owf_box(side, NSMakeRect(20, 820 - 24 - height, 216, height), [NSColor colorWithWhite:1 alpha:0.12],
                              nil, 16, nil, 0);
    owf_icon(privacy, @"shield", NSMakeRect(16, 15.5, 16, 16), white, 2.2);
    owf_text_at(privacy, owf_text(@"On your Mac"), owf_style(owf_font(14, NSFontWeightHeavy), white, 0), 40, 29, 176, 0);
    owf_text_at(privacy, body, bodyStyle, 16, 51, 184, 18.85);
}

static void owf_bento_general(NSView *view) {
    NSColor *ink = owf_hex(owf_ink), *white = NSColor.whiteColor, *cream = owf_hex(owf_cream);
    CGFloat left = 300 - owf_bento_left, width = 616;

    NSFont *display = owf_display_font(36);
    owf_text_at(view, owf_text(@"General"), owf_style(display, ink, 0), left, owf_first_baseline(display, 38, 39.6), 400, 0);
    NSDictionary *savedStyle = owf_style(owf_font(12.5, NSFontWeightBold), ink, 0);
    NSString *saved = owf_text(@"Changes saved automatically");
    CGFloat savedWidth = ceil(owf_text_width(saved, savedStyle)) + 48;
    OWFBox *chip = owf_box(view, NSMakeRect(left + width - savedWidth, 41.3, savedWidth, 33), white, ink, 16.5, nil, 0);
    owf_icon(chip, @"check", NSMakeRect(14, 9.5, 14, 14), ink, 2.2);
    owf_text_at(chip, saved, savedStyle, 34, 21, savedWidth - 34, 0);

    // A 12-column grid: the Dictation tile over 7 columns and the mode over 5,
    // three menus over 4 each, and the vocabulary across.
    CGFloat column = (width - 11 * 16) / 12;
    CGFloat heroWidth = 7 * column + 6 * 16, modeWidth = width - heroWidth - 16, tileWidth = 4 * column + 3 * 16;
    CGFloat top = 38 + 39.6 + 22;
    BOOL hold = owf_settings_fn_hold();
    NSArray *instruction = [owf_text(hold ? @"Hold Fn while you speak.\nRelease to finish."
                                          : @"Double-press Fn to start.\nDouble-press again to finish.")
                            componentsSeparatedByString:@"\n"];
    NSFont *statementFont = owf_display_font(18), *subFont = owf_font(14.5, NSFontWeightSemibold);
    NSDictionary *statementStyle = owf_style(statementFont, ink, 0);
    NSDictionary *subStyle = owf_style(subFont, owf_hex(owf_hint), 0);
    NSDictionary *modeTitleStyle = owf_style(owf_font(13, NSFontWeightHeavy), cream, 0);
    NSString *statement = instruction.firstObject ?: @"", *sub = instruction.count > 1 ? instruction[1] : @"";
    NSUInteger statementLines = owf_line_count(statement, statementStyle, heroWidth - 48);
    NSUInteger subLines = owf_line_count(sub, subStyle, heroWidth - 48);
    NSUInteger modeLines = owf_line_count(owf_text(@"Fn key behavior"), modeTitleStyle, modeWidth - 40);
    CGFloat row = fmax(2 + 20 + 84 + 18 + 17 + 6 + statementLines * 22.5 + 4 + subLines * owf_line_box(subFont) + 20 + 2,
                       2 + 18 + modeLines * 17.55 + 10 + 56 + 10 + 56 + 18 + 2);

    OWFBox *hero = owf_box(view, NSMakeRect(left, top, heroWidth, row), owf_hex(owf_yellow), ink, 24, ink, 5);
    OWFBox *key = owf_box(hero, NSMakeRect(24, 22, 84, 84), ink, nil, 20, owf_hex(owf_coral), 4);
    key.frameCenterRotation = -4;
    owf_icon(key, @"globe", NSMakeRect(61, 10, 13, 13), owf_hex(0xB7B0C8), 1.8);
    owf_text_at(key, @"fn", owf_style(owf_display_font(32), white, 0), 13, 71, 70, 0);
    NSFont *overline = owf_font(12, NSFontWeightHeavy);
    owf_text_at(hero, [owf_text(@"Dictation") uppercaseStringWithLocale:NSLocale.currentLocale],
                owf_style(overline, ink, 0.96), 24, 124 + owf_ascent(overline), heroWidth - 48, 0);
    owf_text_at(hero, statement, statementStyle, 24, owf_first_baseline(statementFont, 147, 22.5), heroWidth - 48, 22.5);
    owf_text_at(hero, sub, subStyle, 24, owf_first_baseline(subFont, 147 + statementLines * 22.5 + 4, 0), heroWidth - 48, 0);

    OWFBox *mode = owf_box(view, NSMakeRect(left + heroWidth + 16, top, modeWidth, row), ink, ink, 24, owf_hex(owf_pink), 5);
    owf_text_at(mode, owf_text(@"Fn key behavior"), modeTitleStyle, 20, 20 - 1 + 14, modeWidth - 40, 17.55);
    NSString *const modes[] = {@"Double press", @"Press and hold"};
    for (NSInteger i = 0; i < 2; i++) {
        BOOL on = hold == i;
        NSColor *color = on ? ink : cream;
        CGFloat y = row - 2 - 18 - 56 - (1 - i) * 66;
        OWFBox *button = owf_box(mode, NSMakeRect(20, y, modeWidth - 40, 56), on ? owf_hex(owf_yellow) : nil,
                                 on ? owf_hex(owf_yellow) : [cream colorWithAlphaComponent:0.35], 16, nil, 0);
        if (i == 0) {
            owf_box(button, NSMakeRect(16, 24.5, 7, 7), color, nil, 4, nil, 0);
            owf_box(button, NSMakeRect(28, 24.5, 7, 7), color, nil, 4, nil, 0);
        } else {
            owf_box(button, NSMakeRect(16, 25, 22, 6), color, nil, 3, nil, 0);
        }
        owf_text_at(button, owf_text(modes[i]), owf_style(owf_font(14, NSFontWeightHeavy), color, 0), 50, 33.5,
                    modeWidth - 90, 0);
        owf_modes[i] = owf_hit(button, NSMakeRect(0, 0, modeWidth - 40, 56), owf_text(modes[i]), @selector(modeChanged:), i);
        [owf_modes[i] setButtonType:NSButtonTypePushOnPushOff];
        owf_modes[i].state = on ? NSControlStateValueOn : NSControlStateValueOff;
    }

    // Titles and hints lead; each menu sits at the bottom of its tile. Three
    // menus share a row; the theme's tile ends the vocabulary's.
    const uint32_t fills[] = {owf_sky, owf_pink, owf_coral, owf_yellow};
    NSString *const icons[] = {@"speaker", @"waveform", @"bubble", @"palette"};
    NSDictionary *hintStyle = owf_style(owf_font(12.5, NSFontWeightSemibold), owf_hex(owf_hint), 0);
    NSUInteger hintLines = 1;
    for (int i = 0; i < 3; i++) {
        hintLines = MAX(hintLines, owf_line_count(owf_text(owf_options[i][1]), hintStyle, tileWidth - 36));
    }
    CGFloat tileHeight = 163 + hintLines * 16.875, tileTop = top + row + 16;

    // The vocabulary over 8 columns: its title, help, editor, and note stacked.
    CGFloat wordsTop = tileTop + tileHeight + 16, wordsWidth = width - tileWidth - 16;
    NSFont *helpFont = owf_font(12.5, NSFontWeightSemibold);
    NSDictionary *helpStyle = owf_style(helpFont, owf_hex(owf_muted), 0);
    NSDictionary *noteStyle = owf_style(helpFont, owf_hex(owf_note), 0);
    NSString *help = owf_text(@"Names and terms, one per line or separated by commas.");
    NSString *note = owf_text(@"Keep it short: only the last ~200 tokens are used.");
    CGFloat helpBaseline = owf_first_baseline(helpFont, 50, 16.875);
    CGFloat editorTop = helpBaseline + (owf_line_count(help, helpStyle, wordsWidth - 44) - 1) * 16.875 + 15;
    CGFloat noteBaseline = editorTop + 72 + 23;
    CGFloat wordsHeight = noteBaseline + (owf_line_count(note, noteStyle, wordsWidth - 44) - 1) * 16.875 + 24;
    CGFloat themeHeight = 163 + owf_line_count(owf_text(owf_options[3][1]), hintStyle, tileWidth - 36) * 16.875;
    CGFloat lastHeight = fmax(wordsHeight, themeHeight);

    for (int i = 0; i < owf_option_count; i++) {
        NSRect frame = i < 3 ? NSMakeRect(left + i * (tileWidth + 16), tileTop, tileWidth, tileHeight)
                             : NSMakeRect(left + wordsWidth + 16, wordsTop, tileWidth, lastHeight);
        OWFBox *tile = owf_box(view, frame, owf_hex(fills[i]), ink, 22, ink, 4);
        OWFBox *circle = owf_box(tile, NSMakeRect(18, 18, 36, 36), white, ink, 18, nil, 0);
        owf_icon(circle, icons[i], NSMakeRect(10, 10, 16, 16), ink, 2.2);
        owf_text_at(tile, owf_text(owf_options[i][0]), owf_style(owf_font(15, NSFontWeightHeavy), ink, 0), 18, 82,
                    tileWidth - 36, 0);
        owf_text_at(tile, owf_text(owf_options[i][1]), hintStyle, 18, 89 - 1 + 13, tileWidth - 36, 16.875);
        CGFloat selectTop = NSHeight(frame) - 2 - 16 - 42;
        CGFloat selectWidth = tileWidth - 36 - (i == 0 ? 50 : 0);
        owf_bento_select(tile, owf_option_popup(i), NSMakeRect(18, selectTop, selectWidth, 42), i == 0 ? 9 : 10);
        if (i == 0) {
            OWFBox *play = owf_box(tile, NSMakeRect(18 + selectWidth + 8, selectTop, 42, 42), ink, ink, 21, nil, 0);
            owf_icon(play, @"play", NSMakeRect(14.5, 14.5, 13, 13), white, 0);
            owf_hit(play, NSMakeRect(0, 0, 42, 42), owf_text(@"Preview sound"), @selector(previewSound:), 0);
        }
    }

    OWFBox *words = owf_box(view, NSMakeRect(left, wordsTop, wordsWidth, lastHeight), white, ink, 22, ink, 4);
    owf_text_at(words, owf_text(@"Vocabulary"), owf_style(owf_display_font(18), ink, 0), 22, 41, wordsWidth - 44, 0);
    owf_text_at(words, help, helpStyle, 22, helpBaseline, wordsWidth - 44, 16.875);
    OWFBox *editor = owf_box(words, NSMakeRect(22, editorTop, wordsWidth - 44, 72), cream, ink, 14, nil, 0);
    owf_vocabulary_editor(editor, NSInsetRect(editor.bounds, 2, 2));
    NSMutableParagraphStyle *lines = [[[NSMutableParagraphStyle alloc] init] autorelease];
    lines.minimumLineHeight = 22.5;
    lines.maximumLineHeight = 22.5;
    owf_vocabulary_view.font = owf_font(15, NSFontWeightSemibold);
    owf_vocabulary_view.textColor = ink;
    owf_vocabulary_view.insertionPointColor = ink;
    owf_vocabulary_view.defaultParagraphStyle = lines;
    owf_vocabulary_view.typingAttributes = @{NSFontAttributeName: owf_vocabulary_view.font, NSForegroundColorAttributeName: ink,
                                             NSParagraphStyleAttributeName: lines};
    [owf_vocabulary_view.textStorage setAttributes:owf_vocabulary_view.typingAttributes
                                             range:NSMakeRange(0, owf_vocabulary_view.string.length)];
    owf_vocabulary_view.textContainerInset = NSMakeSize(11, 10);
    owf_text_at(words, note, noteStyle, 22, noteBaseline, wordsWidth - 44, 16.875);
}

// The parts of a correction as {"text", "kind"}: 0 kept, 1 removed, 2 added.
static NSArray *owf_correction_segments(NSDictionary *entry) {
    char *json = owfSegmentsJSON((char *)[entry[@"heard"] UTF8String], (char *)[entry[@"fixed"] UTF8String]);
    NSArray *parts = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:strlen(json)] options:0 error:NULL];
    free(json);
    return [parts isKindOfClass:NSArray.class] ? parts : @[];
}

// A correction's words in context, 17 points on 34-point lines: removed words
// struck through, added ones on white stickers tilted this way and that.
@interface OWFWords : NSView
- (instancetype)initWithSegments:(NSArray *)segments width:(CGFloat)width tilt:(NSInteger)tilt;
@property(readonly) NSUInteger lineCount;
@end

@implementation OWFWords {
    NSArray *_tokens;
}

- (instancetype)initWithSegments:(NSArray *)segments width:(CGFloat)width tilt:(NSInteger)tilt {
    NSDictionary *plain = owf_style(owf_font(17, NSFontWeightSemibold), owf_hex(owf_ink), 0);
    NSMutableArray *tokens = [NSMutableArray array];
    CGFloat space = owf_text_width(@" ", plain), x = 0;
    NSUInteger line = 0;

    for (NSDictionary *segment in segments) {
        int kind = [segment[@"kind"] intValue];
        NSString *text = [segment[@"text"] isKindOfClass:NSString.class] ? segment[@"text"] : @"";
        NSArray *words = kind == 2 ? @[text] : [text componentsSeparatedByString:@" "];

        for (NSString *word in words) {
            if (word.length == 0) continue;
            NSDictionary *style = kind == 2 ? owf_style(owf_font(17, NSFontWeightHeavy), owf_hex(owf_ink), 0)
                                : owf_style(owf_font(17, NSFontWeightSemibold), owf_hex(kind == 1 ? owf_struck : owf_ink), 0);
            CGFloat wide = owf_text_width(word, style) + (kind == 2 ? 20 : 0);
            if (x > 0 && x + space + wide > width) {
                line++;
                x = 0;
            } else if (x > 0) {
                x += space;
            }
            [tokens addObject:@{@"text": word, @"kind": @(kind), @"x": @(x), @"line": @(line), @"width": @(wide),
                                @"style": style, @"tilt": @(kind == 2 ? (tilt++ % 2 == 0 ? -2.0 : 1.5) : 0)}];
            x += wide;
        }
    }

    self = [super initWithFrame:NSMakeRect(0, 0, width, (line + 1) * 34)];
    if (self != nil) {
        _tokens = [tokens retain];
    }
    return self;
}

- (void)dealloc {
    [_tokens release];
    [super dealloc];
}

- (BOOL)isFlipped {
    return YES;
}

- (NSUInteger)lineCount {
    return NSHeight(self.frame) / 34;
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    NSColor *ink = owf_hex(owf_ink);

    for (NSDictionary *token in _tokens) {
        int kind = [token[@"kind"] intValue];
        CGFloat x = [token[@"x"] doubleValue], width = [token[@"width"] doubleValue];
        CGFloat baseline = 23 + [token[@"line"] intValue] * 34;
        NSAttributedString *text = [[[NSAttributedString alloc] initWithString:token[@"text"]
                                                                    attributes:token[@"style"]] autorelease];
        CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)text);
        CGContextSaveGState(context);

        if (kind == 2) {
            // An inline block 29.5 high whose text shares the line's baseline.
            NSRect face = NSMakeRect(x, baseline - 21, width, 29.5);
            NSAffineTransform *tilt = [NSAffineTransform transform];
            [tilt translateXBy:NSMidX(face) yBy:NSMidY(face)];
            [tilt rotateByDegrees:[token[@"tilt"] doubleValue]];
            [tilt translateXBy:-NSMidX(face) yBy:-NSMidY(face)];
            [tilt concat];
            [ink setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSOffsetRect(face, 2, 2) xRadius:8 yRadius:8] fill];
            [NSColor.whiteColor setFill];
            [[NSBezierPath bezierPathWithRoundedRect:face xRadius:8 yRadius:8] fill];
            NSBezierPath *edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(face, 1, 1) xRadius:7 yRadius:7];
            edge.lineWidth = 2;
            [ink setStroke];
            [edge stroke];
            x += 10;
        } else if (kind == 1) {
            [ink setFill];
            NSRectFill(NSMakeRect(x, baseline - 6.5, width, 2));
        }

        CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));
        CGContextSetTextPosition(context, x, baseline);
        CTLineDraw(line, context);
        CGContextRestoreGState(context);
        CFRelease(line);
    }
}
@end

// When a correction was saved, or nil.
static NSDate *owf_correction_time(id time) {
    if (![time isKindOfClass:NSString.class]) {
        return nil;
    }

    // Go writes fractions of a second that the ISO 8601 parser rejects.
    NSString *seconds = [time stringByReplacingOccurrencesOfString:@"\\.[0-9]+" withString:@""
                                                           options:NSRegularExpressionSearch
                                                             range:NSMakeRange(0, [time length])];
    return [[[[NSISO8601DateFormatter alloc] init] autorelease] dateFromString:seconds];
}

static NSDateFormatter *owf_formatter(NSString *template) {
    NSDateFormatter *format = [[[NSDateFormatter alloc] init] autorelease];
    format.locale = [NSLocale localeWithLocaleIdentifier:owf_russian_interface() ? @"ru_RU" : @"en_US"];
    [format setLocalizedDateFormatFromTemplate:template];
    return format;
}

// The heading of a day of corrections: Today, Yesterday, or the date.
static NSString *owf_correction_day(NSDate *date) {
    if (date == nil) return @"";
    if ([NSCalendar.currentCalendar isDateInToday:date]) return owf_text(@"Today");
    if ([NSCalendar.currentCalendar isDateInYesterday:date]) return owf_text(@"Yesterday");
    return [owf_formatter(@"dMMMM") stringFromDate:date];
}

static const uint32_t owf_card_fills[] = {owf_sky, owf_pink, owf_yellow};

// A card of correction index, face in the list, with its time, buttons, and words.
static void owf_bento_card(NSView *list, NSInteger index, NSRect face, uint32_t fill, OWFWords *words) {
    NSColor *ink = owf_hex(owf_ink), *white = NSColor.whiteColor;
    OWFBox *card = owf_box(list, face, owf_hex(fill), ink, 22, ink, 4);
    NSDate *date = owf_correction_time(owf_corrections[index][@"time"]);

    if (date != nil) {
        NSDictionary *timeStyle = owf_style(owf_font(12.5, NSFontWeightHeavy), ink, 0);
        NSString *time = [owf_formatter(@"jmm") stringFromDate:date];
        CGFloat timeWidth = ceil(owf_text_width(time, timeStyle)) + 24;
        OWFBox *chip = owf_box(card, NSMakeRect(24, 22.5, timeWidth, 27), white, ink, 13.5, nil, 0);
        owf_text_at(chip, time, timeStyle, 12, 18, timeWidth - 12, 0);
    }

    NSString *const labels[] = {@"Edit", @"Delete"};
    NSString *const icons[] = {@"edit", @"trash"};
    SEL actions[] = {@selector(editCorrection:), @selector(deleteCorrection:)};
    for (int i = 0; i < 2; i++) {
        OWFBox *button = owf_box(card, NSMakeRect(NSWidth(face) - 18 - 88 + i * 48, 16, 40, 40), white, ink, 20, nil, 0);
        owf_icon(button, icons[i], NSMakeRect(12, 12, 16, 16), ink, 2.2);
        owf_hit(button, NSMakeRect(0, 0, 40, 40), owf_text(labels[i]), actions[i], index);
    }

    [words setFrameOrigin:NSMakePoint(24, 66)];
    [words setAccessibilityElement:YES];
    [words setAccessibilityRole:NSAccessibilityStaticTextRole];
    [words setAccessibilityValue:owf_corrections[index][@"fixed"]];
    words.toolTip = owf_corrections[index][@"fixed"];
    [card addSubview:words];
}

// Correction index as two editable fields with Cancel and Save, across the list at top; returns its height.
static CGFloat owf_bento_edit_card(NSView *list, NSInteger index, CGFloat top, CGFloat width, uint32_t fill) {
    NSColor *ink = owf_hex(owf_ink), *white = NSColor.whiteColor;
    NSDictionary *entry = owf_corrections[index];
    NSString *const titles[] = {@"Heard", @"Corrected"};
    NSString *const keys[] = {@"heard", @"fixed"};
    NSFont *font = owf_font(15, NSFontWeightSemibold);
    CGFloat heights[2], y = 16;

    for (int i = 0; i < 2; i++) {
        NSUInteger lines = MAX(owf_line_count(entry[keys[i]], owf_style(font, ink, 0), width - 42 - 28), 1);
        heights[i] = fmax(44, lines * 22.5 + 20);
    }

    OWFBox *card = owf_box(list, NSMakeRect(0, top, width, 16 + 2 * (17 + 8) + heights[0] + heights[1] + 14 + 16 + 44 + 20),
                           owf_hex(fill), ink, 22, ink, 4);
    NSTextField *fields[2];
    for (int i = 0; i < 2; i++) {
        owf_text_at(card, owf_text(titles[i]), owf_style(owf_font(12.5, NSFontWeightHeavy), ink, 0), 24, y + 13, 300, 0);
        OWFBox *box = owf_box(card, NSMakeRect(24, y + 25, width - 42, heights[i]), white, ink, 14, nil, 0);
        fields[i] = [NSTextField textFieldWithString:entry[keys[i]]];
        fields[i].frame = NSMakeRect(12, 10, width - 42 - 24, heights[i] - 20);
        fields[i].font = font;
        fields[i].textColor = ink;
        fields[i].bezeled = NO;
        fields[i].bordered = NO;
        fields[i].drawsBackground = NO;
        fields[i].focusRingType = NSFocusRingTypeNone;
        fields[i].usesSingleLineMode = NO;
        fields[i].cell.wraps = YES;
        fields[i].cell.scrollable = NO;
        [fields[i] setAccessibilityLabel:owf_text(titles[i])];
        [box addSubview:fields[i]];
        y += 25 + heights[i] + (i == 0 ? 14 : 16);
    }

    owf_edit_heard = fields[0];
    owf_edit_fixed = fields[1];
    OWFBox *save = owf_bento_pill(card, width - 18 - 3, y, @"Save", nil, YES, @selector(saveCorrection:));
    ((NSButton *)save.subviews.lastObject).keyEquivalent = @"\r";
    OWFBox *cancel = owf_bento_pill(card, NSMinX(save.frame) - 10, y, @"Cancel", nil, NO, @selector(cancelCorrection:));
    ((NSButton *)cancel.subviews.lastObject).keyEquivalent = @"\033";
    return NSHeight(card.frame) - 4;
}

// The corrections grouped by day, newest first, as cards two to a row, a card
// across when its words run past two lines at half width. Returns the height.
static CGFloat owf_bento_list(NSView *list) {
    NSColor *ink = owf_hex(owf_ink);
    CGFloat width = 616, half = (width - 16) / 2;
    __block CGFloat y = 0;
    NSInteger shown = 0;
    NSString *day = nil;
    NSMutableArray *row = [NSMutableArray array];

    // Lays out the cards waiting in row: one or two halves, or one across.
    void (^flush)(void) = ^{
        if (row.count == 0) return;
        CGFloat height = 0;
        for (NSDictionary *card in row) height = fmax(height, [card[@"height"] doubleValue]);
        for (NSUInteger i = 0; i < row.count; i++) {
            NSDictionary *card = row[i];
            CGFloat cardWidth = [card[@"full"] boolValue] ? width : half;
            owf_bento_card(list, [card[@"index"] integerValue], NSMakeRect(i * (half + 16), y, cardWidth, height),
                           (uint32_t)[card[@"fill"] unsignedIntValue], card[@"words"]);
        }
        y += height + 16;
        [row removeAllObjects];
    };

    for (NSInteger i = (NSInteger)owf_corrections.count - 1; i >= 0; i--) {
        NSDate *date = owf_correction_time(owf_corrections[i][@"time"]);
        NSString *heading = owf_correction_day(date);

        if (day == nil || ![heading isEqualToString:day]) {
            flush();
            y = y == 0 ? 0 : y - 16 + 28;
            day = heading;
            if (heading.length > 0) {
                NSDictionary *style = owf_style(owf_font(13, NSFontWeightHeavy), owf_hex(owf_cream), 0.52);
                CGFloat chipWidth = ceil(owf_text_width(heading, style)) + 32;
                OWFBox *chip = owf_box(list, NSMakeRect(0, y, chipWidth, 32), ink, ink, 16, nil, 0);
                owf_text_at(chip, heading, style, 16, 21, chipWidth - 16, 0);
                y += 32 + 16;
            }
        }

        uint32_t fill = owf_card_fills[shown % 3];
        NSInteger tilt = shown % 3 == 2 ? 1 : 0;
        shown++;

        if (i == owf_corrections_editing) {
            flush();
            y += owf_bento_edit_card(list, i, y, width, fill) + 16;
            continue;
        }

        NSArray *segments = owf_correction_segments(owf_corrections[i]);
        OWFWords *words = [[[OWFWords alloc] initWithSegments:segments width:half - 42 tilt:tilt] autorelease];
        BOOL full = words.lineCount > 2;
        if (full) {
            words = [[[OWFWords alloc] initWithSegments:segments width:width - 42 tilt:tilt] autorelease];
            flush();
        }

        [row addObject:@{@"index": @(i), @"full": @(full), @"fill": @(fill), @"words": words,
                         @"height": @(86 + words.lineCount * 34)}];
        if (full || row.count == 2) flush();
    }

    flush();
    return y == 0 ? 0 : y - 16;
}

// The kbd chips of a shortcut in running text, such as Ctrl and Fn.
static CGFloat owf_bento_key(NSView *parent, NSString *key, CGFloat x) {
    NSColor *ink = owf_hex(owf_ink);
    NSDictionary *style = owf_style(owf_font(12.5, NSFontWeightHeavy), ink, 0);
    CGFloat width = ceil(owf_text_width(key, style)) + 20;
    OWFBox *chip = owf_box(parent, NSMakeRect(x, 95, width, 25), NSColor.whiteColor, ink, 8, ink, 2);
    owf_text_at(chip, key, style, 10, 17, width - 10, 0);
    return x + width;
}

static void owf_bento_corrections(NSView *view) {
    NSColor *ink = owf_hex(owf_ink);
    CGFloat left = 300 - owf_bento_left, right = 916 - owf_bento_left;

    NSFont *display = owf_display_font(36);
    NSDictionary *titleStyle = owf_style(display, ink, 0);
    owf_text_at(view, owf_text(@"Corrections"), titleStyle, left, owf_first_baseline(display, 40.2, 39.6), 300, 0);
    CGFloat badgeLeft = left + ceil(owf_text_width(owf_text(@"Corrections"), titleStyle)) + 12;
    owf_count_badges[1] = owf_box(view, NSMakeRect(badgeLeft, 41, 38, 38), owf_hex(owf_yellow), ink, 19, ink, 2);
    owf_count_badges[1].frameCenterRotation = 8;
    NSFont *count = owf_display_font(17);
    owf_count_texts[1] = owf_text_at(owf_count_badges[1], @"", owf_style(count, ink, 0), 0,
                                     2 + (34 - owf_line_box(count)) / 2 + owf_ascent(count), 38, 0);
    owf_count_texts[1].alignment = NSTextAlignmentCenter;

    // "…saved with Ctrl+Fn." with the keys as chips on the line.
    NSDictionary *lineStyle = owf_style(owf_font(15, NSFontWeightSemibold), owf_hex(owf_muted), 0);
    NSString *line = owf_text(@"Heard and corrected text, saved with Control+Fn.");
    NSRange space = [line rangeOfString:@" " options:NSBackwardsSearch];
    NSString *shortcut = space.location == NSNotFound ? @"" : [line substringFromIndex:NSMaxRange(space)];
    NSArray *keys = [[shortcut stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"."]]
                     componentsSeparatedByString:@"+"];
    CGFloat baseline = owf_first_baseline(lineStyle[NSFontAttributeName], 94, 25.5), x = left;

    if (keys.count < 2) {
        owf_text_at(view, line, lineStyle, left, baseline, 616, 25.5);
    } else {
        NSString *lead = [line substringToIndex:NSMaxRange(space)];
        owf_text_at(view, lead, lineStyle, x, baseline, 616, 0);
        x += owf_text_width(lead, lineStyle);
        for (NSUInteger i = 0; i < keys.count; i++) {
            if (i > 0) {
                owf_text_at(view, @" + ", lineStyle, x, baseline, 40, 0);
                x += owf_text_width(@" + ", lineStyle);
            }
            x = owf_bento_key(view, keys[i], x);
        }
        owf_text_at(view, @".", lineStyle, x, baseline, 20, 0);
    }

    // The file and its buttons in a card at the bottom, as in every theme.
    CGFloat footerTop = 820 - 24 - 4 - 66;
    OWFBox *footer = owf_box(view, NSMakeRect(left, footerTop, right - left, 66), NSColor.whiteColor, ink, 22, ink, 4);
    owf_icon(footer, @"file", NSMakeRect(20, 25, 16, 16), ink, 2.2);
    NSFont *file = owf_font(14, NSFontWeightHeavy);
    owf_text_at(footer, owf_corrections_file.lastPathComponent ?: @"corrections.jsonl", owf_style(file, ink, 0), 46,
                owf_middle(file, 0, 66), 220, 0);
    owf_clear_box = owf_bento_pill(footer, right - left - 10, 10, @"Clear All…", @"trash", YES, @selector(clearCorrections:));
    owf_corrections_clear = owf_clear_box.subviews.lastObject;
    owf_bento_pill(footer, NSMinX(owf_clear_box.frame) - 10, 10, @"Show File", @"folder", NO, @selector(showCorrectionsFile:));

    owf_corrections_scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(left, 147.5, 624, footerTop - 12 - 147.5)]
                              autorelease];
    owf_corrections_scroll.drawsBackground = NO;
    owf_corrections_scroll.hasVerticalScroller = YES;
    owf_corrections_scroll.autohidesScrollers = YES;
    owf_corrections_scroll.scrollerStyle = NSScrollerStyleOverlay;
    owf_corrections_scroll.documentView = [[[OWFFlippedView alloc] initWithFrame:owf_corrections_scroll.bounds] autorelease];
    [view addSubview:owf_corrections_scroll];

    owf_corrections_empty = [[[OWFFlippedView alloc] initWithFrame:NSMakeRect(left, 180, 616, 120)] autorelease];
    [view addSubview:owf_corrections_empty];
    owf_text_at(owf_corrections_empty, owf_text(@"No corrections yet"), owf_style(owf_display_font(20), ink, 0), 0, 30, 616, 0)
        .alignment = NSTextAlignmentCenter;
    owf_text_at(owf_corrections_empty, owf_text(@"Fix a pasted transcript, select the corrected text, then press Control+Fn."),
                owf_style(owf_font(14, NSFontWeightSemibold), owf_hex(owf_muted), 0), 98, 62, 420, 20)
        .alignment = NSTextAlignmentCenter;
}

// Shows the count of corrections on both badges, and none at 0.
static void owf_bento_counts(void) {
    NSString *count = [NSString stringWithFormat:@"%lu", (unsigned long)owf_corrections.count];

    for (int i = 0; i < 2; i++) {
        owf_count_badges[i].hidden = owf_corrections.count == 0;
        [owf_count_texts[i] setString:count];

        OWFFit fit = owf_count_fits[i];
        if (fit.min > 0 && owf_count_badges[i] != nil) {
            CGFloat width = fmax(fit.min, owf_text_width(count, owf_count_texts[i].style) + 2 * fit.pad);
            NSRect frame = owf_count_badges[i].frame;
            owf_count_badges[i].frame = NSMakeRect(fit.right ? fit.x - width : fit.x, NSMinY(frame), width, NSHeight(frame));
            [owf_count_texts[i] setFrameSize:NSMakeSize(width, NSHeight(owf_count_texts[i].frame))];
        }
    }

    owf_clear_box.alphaValue = owf_corrections.count > 0 ? 1 : 0.45;
}

static NSView *owf_bento_content(void) {
    OWFBox *root = [[[OWFBox alloc] initWithFrame:NSMakeRect(0, 0, 960, 820)] autorelease];
    root.fill = owf_theme()->canvas;
    owf_bento_sidebar(root);

    owf_general_view = [[[OWFFlippedView alloc] initWithFrame:NSMakeRect(owf_bento_left, 0, 960 - owf_bento_left, 820)] autorelease];
    [root addSubview:owf_general_view];
    owf_bento_general(owf_general_view);
    owf_corrections_view = [[[OWFFlippedView alloc] initWithFrame:owf_general_view.frame] autorelease];
    [root addSubview:owf_corrections_view];
    owf_bento_corrections(owf_corrections_view);
    return root;
}

// Shared by layouts A+ and F4+, drawn to the canvas's coordinates as Bento is.

static NSColor *owf_rgba(uint32_t rgb, CGFloat alpha) {
    return [owf_hex(rgb) colorWithAlphaComponent:alpha];
}

static NSColor *owf_white(CGFloat alpha) {
    return [NSColor colorWithWhite:1 alpha:alpha];
}

static NSString *owf_upper(NSString *text) {
    return [owf_text(text) uppercaseStringWithLocale:NSLocale.currentLocale];
}

// How many corrections, as a count reads: 1 correction, 3 правки, 5 правок.
static NSString *owf_count_label(NSUInteger count) {
    if (!owf_russian_interface()) {
        return [NSString stringWithFormat:count == 1 ? @"%lu correction" : @"%lu corrections", (unsigned long)count];
    }

    NSUInteger tens = count % 100, ones = count % 10;
    NSString *form = tens >= 11 && tens <= 14 ? @"правок" : ones == 1 ? @"правка" : ones >= 2 && ones <= 4 ? @"правки" : @"правок";
    return [NSString stringWithFormat:@"%lu %@", (unsigned long)count, form];
}

// The words of a correction on lines line apart: kept words plain, removed
// ones struck through, added ones on chips, as the canvas's del and ins draw
// them. Chips of pad at each side sit on the line as inline backgrounds, or,
// with chip set, as inline blocks of that line height tilted in turn.
typedef struct {
    NSFont *font, *bold;
    NSColor *color, *removed, *strike, *added, *underline;
    NSArray<NSColor *> *fills;
    CGFloat line, thickness, pad, radius, chip;
    BOOL tilt;
    // The fill of the first chip.
    NSUInteger first;
} OWFWordsStyle;

@interface OWFInline : NSView
- (instancetype)initWithSegments:(NSArray *)segments width:(CGFloat)width style:(OWFWordsStyle)style;
@property(readonly) NSUInteger lineCount;
@end

@implementation OWFInline {
    NSArray *_tokens;
    OWFWordsStyle _style;
    NSUInteger _lines;
}

- (instancetype)initWithSegments:(NSArray *)segments width:(CGFloat)width style:(OWFWordsStyle)style {
    NSDictionary *plain = owf_style(style.font, style.color, 0);
    NSMutableArray *tokens = [NSMutableArray array];
    CGFloat space = owf_text_width(@" ", plain), x = 0;
    NSUInteger line = 0, chips = style.first;

    for (NSDictionary *segment in segments) {
        int kind = [segment[@"kind"] intValue];
        NSString *text = [segment[@"text"] isKindOfClass:NSString.class] ? segment[@"text"] : @"";
        NSArray *words = kind == 0 ? [text componentsSeparatedByString:@" "] : @[text];

        for (NSString *word in words) {
            if (word.length == 0) continue;
            NSDictionary *font = owf_style(kind == 2 ? style.bold : style.font,
                                           kind == 0 ? style.color : kind == 1 ? style.removed : style.added, 0);
            CGFloat wide = owf_text_width(word, font) + (kind == 2 ? 2 * style.pad : 0);
            if (x > 0 && x + space + wide > width) {
                line++;
                x = 0;
            } else if (x > 0) {
                x += space;
            }
            [tokens addObject:@{@"text": word, @"kind": @(kind), @"x": @(x), @"line": @(line), @"width": @(wide),
                                @"style": font, @"chip": @(kind == 2 ? chips++ : 0)}];
            x += wide;
        }
    }

    self = [super initWithFrame:NSMakeRect(0, 0, width, (line + 1) * style.line)];
    if (self != nil) {
        _tokens = [tokens retain];
        _style = style;
        [_style.font retain];
        [_style.bold retain];
        [_style.color retain];
        [_style.removed retain];
        [_style.strike retain];
        [_style.added retain];
        [_style.underline retain];
        [_style.fills retain];
        _lines = line + 1;
    }
    return self;
}

- (void)dealloc {
    [_tokens release];
    [_style.font release];
    [_style.bold release];
    [_style.color release];
    [_style.removed release];
    [_style.strike release];
    [_style.added release];
    [_style.underline release];
    [_style.fills release];
    [super dealloc];
}

- (BOOL)isFlipped {
    return YES;
}

- (NSUInteger)lineCount {
    return _lines;
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    OWFWordsStyle style = _style;
    CGFloat first = floor((style.line - owf_line_box(style.font)) / 2) + owf_ascent(style.font);

    for (NSDictionary *token in _tokens) {
        int kind = [token[@"kind"] intValue];
        CGFloat x = [token[@"x"] doubleValue], width = [token[@"width"] doubleValue];
        CGFloat baseline = first + [token[@"line"] intValue] * style.line;
        NSDictionary *font = token[@"style"];
        NSAttributedString *text = [[[NSAttributedString alloc] initWithString:token[@"text"] attributes:font] autorelease];
        CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)text);
        CGContextSaveGState(context);

        if (kind == 2) {
            NSFont *bold = style.bold;
            NSUInteger chip = [token[@"chip"] unsignedIntegerValue];
            NSRect face = style.chip > 0
                ? NSMakeRect(x, baseline - floor((style.chip - owf_line_box(bold)) / 2) - owf_ascent(bold), width, style.chip)
                : NSMakeRect(x, baseline - owf_ascent(bold) - 1, width, owf_line_box(bold) + 2);

            if (style.tilt) {
                // The fills and tilts of the canvas's stickers: -1.5, 1, -1.5 degrees.
                CGFloat degrees = chip % 3 == 1 ? 1 : -1.5;
                NSAffineTransform *tilt = [NSAffineTransform transform];
                [tilt translateXBy:NSMidX(face) yBy:NSMidY(face)];
                [tilt rotateByDegrees:degrees];
                [tilt translateXBy:-NSMidX(face) yBy:-NSMidY(face)];
                [tilt concat];
            }

            NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:face xRadius:style.radius yRadius:style.radius];
            [style.fills[chip % style.fills.count] setFill];
            [body fill];

            if (style.underline != nil) {
                [body addClip];
                [style.underline setFill];
                NSRectFillUsingOperation(NSMakeRect(NSMinX(face), NSMaxY(face) - 1.5, width, 1.5), NSCompositingOperationSourceOver);
            }

            x += style.pad;
        } else if (kind == 1) {
            // The line through sits where the font puts it, in the canvas's thickness.
            CGFloat middle = baseline - ((NSFont *)font[NSFontAttributeName]).xHeight / 2;
            [style.strike setFill];
            NSRectFillUsingOperation(NSMakeRect(x, middle - style.thickness / 2, width, style.thickness),
                                     NSCompositingOperationSourceOver);
        }

        CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));
        CGContextSetTextPosition(context, x, baseline);
        CTLineDraw(line, context);
        CGContextRestoreGState(context);
        CFRelease(line);
    }
}
@end

// A menu drawn as the canvas's select: a box with the chosen title at x and a
// chevron icon in its frame, over the invisible pop-up that does the choosing.
static void owf_canvas_select(OWFBox *box, NSPopUpButton *popup, NSDictionary *style, CGFloat x, NSString *chevron,
                              NSRect chevronFrame, NSColor *chevronColor, CGFloat stroke) {
    NSFont *font = style[NSFontAttributeName];
    OWFText *title = [[[OWFText alloc] initWithFrame:NSMakeRect(x, 0, NSMinX(chevronFrame) - x - 4, NSHeight(box.bounds))]
                      autorelease];
    title.oneLine = YES;
    title.baseline = owf_middle(font, 0, NSHeight(box.bounds));
    title.style = style;
    [title setString:popup.titleOfSelectedItem];
    [box addSubview:title];
    owf_icon(box, chevron, chevronFrame, chevronColor, stroke);
    popup.frame = box.bounds;
    popup.alphaValue = 0;
    [box addSubview:popup];
    owf_select_titles[popup.identifier] = title;
}

// A count badge of which, 0 in the sidebar and 1 on the Corrections page, that
// owf_bento_counts fills and fits.
static void owf_count_badge(int which, NSView *parent, OWFFit fit, CGFloat top, CGFloat height, NSColor *fill,
                            NSColor *stroke, NSDictionary *style) {
    OWFBox *badge = owf_box(parent, NSMakeRect(fit.right ? fit.x - fit.min : fit.x, top, fit.min, height), fill, stroke,
                            height / 2, nil, 0);
    badge.line = 1;
    NSFont *font = style[NSFontAttributeName];
    owf_count_badges[which] = badge;
    owf_count_texts[which] = owf_text_at(badge, @"", style, 0, owf_middle(font, 0, height), fit.min, 0);
    owf_count_texts[which].alignment = NSTextAlignmentCenter;
    owf_count_fits[which] = fit;
}

// "…saved with Ctrl+Fn." with the keys drawn by key, which returns the x after it.
static void owf_shortcut_line(NSView *view, NSDictionary *style, CGFloat x, CGFloat baseline, CGFloat width,
                              CGFloat (^key)(NSString *, CGFloat)) {
    NSString *line = owf_text(@"Heard and corrected text, saved with Control+Fn.");
    NSRange space = [line rangeOfString:@" " options:NSBackwardsSearch];
    NSString *shortcut = space.location == NSNotFound ? @"" : [line substringFromIndex:NSMaxRange(space)];
    NSArray *keys = [[shortcut stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"."]]
                     componentsSeparatedByString:@"+"];

    if (keys.count < 2) {
        owf_text_at(view, line, style, x, baseline, width, 0);
        return;
    }

    NSString *lead = [line substringToIndex:NSMaxRange(space)];
    owf_text_at(view, lead, style, x, baseline, width, 0);
    x += owf_text_width(lead, style);
    for (NSUInteger i = 0; i < keys.count; i++) {
        if (i > 0) {
            owf_text_at(view, @" + ", style, x, baseline, 40, 0);
            x += owf_text_width(@" + ", style);
        }
        x = key(keys[i], x);
    }
    owf_text_at(view, @".", style, x, baseline, 20, 0);
}

// Layout A+ of the design canvas. Colors by their role on the canvas.
enum {
    owf_brand_accent = 0xAC8DFF, owf_brand_title = 0xF6F3FA, owf_brand_body = 0xF3F0F7, owf_brand_muted = 0xA8A2B3,
    owf_brand_dim = 0x8F899B, owf_brand_faint = 0x6E6879, owf_brand_soft = 0xC9C3D4, owf_brand_card = 0x1B1821,
    owf_brand_coral = 0xF28A6C, owf_brand_mint = 0x5FD0B0, owf_brand_prose = 0xE6E1EE,
};
static const CGFloat owf_brand_left = 248;
static const uint32_t owf_brand_bars[] = {0x7C8CFF, 0x9587FF, 0xAE84F7, 0xC680E6, 0xDC7ECB, 0xEB82A6, 0xF28A6C};

static NSFont *owf_onest(NSFontWeight weight, CGFloat size) {
    return owf_family(@"Onest", weight, size);
}

static NSFont *owf_unbounded(NSFontWeight weight, CGFloat size) {
    return owf_family(@"Unbounded", weight, size);
}

static NSFont *owf_mono(NSFontWeight weight, CGFloat size) {
    return owf_family(@"JetBrains Mono", weight, size);
}

static void owf_brand_sidebar(NSView *root, CGFloat height) {
    NSColor *accent = owf_hex(owf_brand_accent), *title = owf_hex(owf_brand_title);
    OWFBox *side = owf_box(root, NSMakeRect(0, 0, owf_brand_left, height), owf_theme()->sidebar, nil, 0, nil, 0);
    owf_box(side, NSMakeRect(owf_brand_left - 1, 0, 1, height), owf_white(0.06), nil, 0, nil, 0);

    const CGFloat heights[] = {10, 20, 30, 18, 26, 14, 8};
    for (int i = 0; i < 7; i++) {
        owf_box(side, NSMakeRect(24 + i * 7, 72 + (32 - heights[i]) / 2, 4, heights[i]), owf_hex(owf_brand_bars[i]), nil, 2,
                nil, 0);
    }

    NSFont *wordmark = owf_unbounded(NSFontWeightSemibold, 20);
    NSArray *name = [owf_text(@"Open\nWord Flow") componentsSeparatedByString:@"\n"];
    for (NSUInteger i = 0; i < name.count; i++) {
        owf_text_at(side, name[i], owf_style(wordmark, title, -0.2), 24, owf_first_baseline(wordmark, 118, 23) + i * 23,
                    200, 0);
    }

    CGFloat top = 118 + name.count * 23 + 14;
    NSFont *tagline = owf_onest(NSFontWeightRegular, 13);
    OWFText *motto = owf_text_at(side, owf_text(@"Speak freely. Stay in your flow."),
                                 owf_style(tagline, owf_hex(owf_brand_muted), 0), 24,
                                 owf_first_baseline(tagline, top, 18.85), 200, 18.85);
    top += motto.lineCount * 18.85 + 36;

    NSString *const titles[] = {@"General", @"Corrections"};
    NSString *const icons[] = {@"sliders", @"pencil"};
    NSFont *link = owf_onest(NSFontWeightMedium, 14.5);
    for (int i = 0; i < 2; i++) {
        BOOL open = owf_settings_tab == i;
        OWFBox *item = owf_box(side, NSMakeRect(16, top + i * 48, 215, 44), open ? owf_rgba(owf_brand_accent, 0.14) : nil,
                               open ? owf_rgba(owf_brand_accent, 0.22) : nil, 10, nil, 0);
        item.line = 1;
        owf_icon(item, icons[i], NSMakeRect(12, 13, 18, 18), open ? accent : owf_hex(owf_brand_dim), 1.75);
        owf_text_at(item, owf_text(titles[i]), owf_style(link, open ? title : owf_hex(owf_brand_soft), 0), 42,
                    owf_middle(link, 0, 44), 140, 0);
        if (i == 1) {
            owf_count_badge(0, item, (OWFFit){203, 22, 6, YES}, 11, 22, owf_hex(owf_brand_coral), nil,
                            owf_style(owf_mono(NSFontWeightMedium, 12), owf_hex(0x1A1216), 0));
        }
        owf_hit(item, NSMakeRect(0, 0, 215, 44), owf_text(titles[i]), @selector(navChanged:), i);
    }

    NSFont *heading = owf_onest(NSFontWeightSemibold, 13.5), *body = owf_onest(NSFontWeightRegular, 12.5);
    NSDictionary *bodyStyle = owf_style(body, owf_hex(owf_brand_muted), 0);
    NSString *text = [owf_text(@"Offline transcription.\nYour voice stays here.") stringByReplacingOccurrencesOfString:@"\n"
                                                                                                          withString:@" "];
    CGFloat row = fmax(16, owf_line_box(heading));
    CGFloat box = 1 + 14 + row + 6 + owf_line_count(text, bodyStyle, 181) * 18.125 + 14 + 1;
    OWFBox *privacy = owf_box(side, NSMakeRect(16, height - 20 - box, 215, box), owf_white(0.03), owf_white(0.06), 12, nil, 0);
    privacy.line = 1;
    owf_icon(privacy, @"shield.lock", NSMakeRect(17, 15 + (row - 16) / 2, 16, 16), accent, 1.75);
    owf_text_at(privacy, owf_text(@"On your Mac"), owf_style(heading, owf_hex(owf_brand_body), 0), 41,
                owf_middle(heading, 15, row), 170, 0);
    owf_text_at(privacy, text, bodyStyle, 17, owf_first_baseline(body, 15 + row + 6, 18.125), 181, 18.125);
}

static void owf_brand_general(NSView *view) {
    NSColor *accent = owf_hex(owf_brand_accent), *title = owf_hex(owf_brand_title), *muted = owf_hex(owf_brand_muted);
    CGFloat left = 48, width = 616;

    NSFont *h1 = owf_unbounded(NSFontWeightSemibold, 26);
    owf_text_at(view, owf_text(@"General"), owf_style(h1, title, -0.26), left, owf_first_baseline(h1, 44, 33.8), 400, 0);

    // The autosave note as a pill with a green light.
    NSFont *noteFont = owf_onest(NSFontWeightRegular, 12.5);
    NSDictionary *noteStyle = owf_style(noteFont, muted, 0);
    NSString *saved = owf_text(@"Changes saved automatically");
    CGFloat pillWidth = 1 + 10 + 6 + 8 + owf_text_width(saved, noteStyle) + 12 + 1;
    OWFBox *pill = owf_box(view, NSMakeRect(left + width - pillWidth, 44 + (33.8 - 32) / 2, pillWidth, 32),
                           owf_hex(owf_brand_card), owf_white(0.06), 16, nil, 0);
    pill.line = 1;
    owf_box(pill, NSMakeRect(8, 10, 12, 12), owf_rgba(owf_brand_mint, 0.16), nil, 6, nil, 0);
    owf_box(pill, NSMakeRect(11, 13, 6, 6), owf_hex(owf_brand_mint), nil, 3, nil, 0);
    owf_text_at(pill, saved, noteStyle, 25, owf_middle(noteFont, 1, 30), pillWidth - 25, 0);

    // The Dictation card: the fn key, what the mode asks for, and the mode.
    BOOL hold = owf_settings_fn_hold();
    NSArray *instruction = [owf_text(hold ? @"Hold Fn while you speak.\nRelease to finish."
                                          : @"Double-press Fn to start.\nDouble-press again to finish.")
                            componentsSeparatedByString:@"\n"];
    NSString *statement = instruction.firstObject ?: @"", *sub = instruction.count > 1 ? instruction[1] : @"";
    NSFont *overline = owf_onest(NSFontWeightSemibold, 11.5), *lead = owf_unbounded(NSFontWeightMedium, 18);
    NSFont *subFont = owf_onest(NSFontWeightRegular, 14), *modeFont = owf_onest(NSFontWeightMedium, 13.5);
    NSDictionary *leadStyle = owf_style(lead, title, 0), *subStyle = owf_style(subFont, muted, 0);
    CGFloat column = 426;
    NSUInteger leadLines = owf_line_count(statement, leadStyle, column), subLines = owf_line_count(sub, subStyle, column);
    CGFloat columnHeight = owf_line_box(overline) + 10 + leadLines * 23.4 + 6 + subLines * 20.3 + 18 + 48;
    CGFloat inner = fmax(104, columnHeight), top = 44 + 33.8 + 28;
    OWFBox *hero = owf_box(view, NSMakeRect(left, top, width, 1 + 24 + inner + 24 + 1), owf_hex(0x1B1822),
                           owf_rgba(owf_brand_accent, 0.22), 18, nil, 0);
    hero.line = 1;

    NSRect keyFace = NSMakeRect(29, 25 + (inner - 104) / 2, 104, 104);
    owf_blur(hero, keyFace, 24, [NSColor colorWithWhite:0 alpha:0.45], 0, 14, 28);
    OWFBox *ring = owf_box(hero, NSInsetRect(keyFace, -1, -1), nil, owf_white(0.07), 25, nil, 0);
    ring.line = 1;
    OWFBox *key = owf_box(hero, keyFace, owf_hex(0x08070A), nil, 24, nil, 0);
    OWFBox *cap = owf_box(key, NSMakeRect(5, 4, 94, 90), owf_hex(0x1E1A25), nil, 19, nil, 0);
    cap.highlight = owf_white(0.09);
    const CGFloat bars[] = {5, 9, 12, 7, 10, 6, 4};
    for (int i = 0; i < 7; i++) {
        owf_box(cap, NSMakeRect(13 + i * 4, 13 + (12 - bars[i]) / 2, 2, bars[i]), owf_hex(owf_brand_bars[i]), nil, 1, nil, 0);
    }
    owf_icon(cap, @"globe", NSMakeRect(67, 11, 15, 15), owf_hex(owf_brand_dim), 1.75);
    NSFont *fn = owf_onest(NSFontWeightMedium, 40);
    owf_text_at(cap, @"fn", owf_style(fn, title, -0.8), 13, owf_first_baseline(fn, 40, 40), 70, 0);

    CGFloat x = 161, y = 25 + (inner - columnHeight) / 2;
    owf_text_at(hero, owf_upper(@"Dictation · Fn key"), owf_style(overline, accent, 0.92), x, y + owf_ascent(overline),
                column, 0);
    y += owf_line_box(overline) + 10;
    owf_text_at(hero, statement, leadStyle, x, owf_first_baseline(lead, y, 23.4), column, 23.4);
    y += leadLines * 23.4 + 6;
    owf_text_at(hero, sub, subStyle, x, owf_first_baseline(subFont, y, 20.3), column, 20.3);
    y += subLines * 20.3 + 18;

    NSString *const modes[] = {@"Double press", @"Press and hold"};
    CGFloat buttons[2];
    for (int i = 0; i < 2; i++) {
        buttons[i] = 16 + 20 + 10 + owf_text_width(owf_text(modes[i]), owf_style(modeFont, title, 0)) + 16;
    }
    OWFBox *segment = owf_box(hero, NSMakeRect(x, y, 1 + 4 + buttons[0] + 4 + buttons[1] + 4 + 1, 48), owf_hex(0x131016),
                              owf_white(0.06), 12, nil, 0);
    segment.line = 1;
    for (NSInteger i = 0; i < 2; i++) {
        BOOL on = hold == i;
        NSColor *glyph = on ? accent : owf_hex(owf_brand_faint);
        OWFBox *button = owf_box(segment, NSMakeRect(5 + (i == 0 ? 0 : buttons[0] + 4), 5, buttons[i], 38),
                                 on ? owf_rgba(owf_brand_accent, 0.18) : nil, on ? owf_rgba(owf_brand_accent, 0.45) : nil,
                                 9, nil, 0);
        button.line = 1;
        if (i == 0) {
            owf_box(button, NSMakeRect(16, 16, 6, 6), glyph, nil, 3, nil, 0);
            owf_box(button, NSMakeRect(27, 16, 6, 6), glyph, nil, 3, nil, 0);
        } else {
            owf_box(button, NSMakeRect(16, 16.5, 20, 5), glyph, nil, 2.5, nil, 0);
        }
        owf_text_at(button, owf_text(modes[i]), owf_style(modeFont, on ? title : muted, 0), 46,
                    owf_middle(modeFont, 0, 38), buttons[i] - 46, 0);
        owf_modes[i] = owf_hit(button, NSMakeRect(0, 0, buttons[i], 38), owf_text(modes[i]), @selector(modeChanged:), i);
        [owf_modes[i] setButtonType:NSButtonTypePushOnPushOff];
        owf_modes[i].state = on ? NSControlStateValueOn : NSControlStateValueOff;
    }

    // Sound and language, and the theme, in rows of one card.
    NSFont *h2 = owf_onest(NSFontWeightSemibold, 12);
    NSDictionary *h2Style = owf_style(h2, owf_hex(owf_brand_dim), 0.96);
    top += NSHeight(hero.frame) + 32;
    owf_text_at(view, owf_upper(@"Sound and language"), h2Style, left, top + owf_ascent(h2), width, 0);
    top += owf_line_box(h2) + 12;

    const uint32_t tints[] = {0x7C8CFF, 0xC680E6, 0xF28A6C, owf_brand_mint};
    const uint32_t inks[] = {0x93A0FF, 0xD39AEE, 0xF5A084, 0x86DEC4};
    NSString *const icons[] = {@"speaker", @"waveform", @"bubble", @"palette"};
    NSFont *labelFont = owf_onest(NSFontWeightMedium, 14.5), *hintFont = owf_onest(NSFontWeightRegular, 13);
    NSFont *selectFont = owf_onest(NSFontWeightRegular, 14);
    OWFBox *card = owf_box(view, NSMakeRect(left, top, width, 2 + owf_option_count * 69 - 1), owf_hex(owf_brand_card),
                           owf_white(0.07), 16, nil, 0);
    card.line = 1;
    for (int i = 0; i < owf_option_count; i++) {
        CGFloat row = 1 + i * 69;
        OWFBox *tile = owf_box(card, NSMakeRect(21, row + 16, 36, 36), owf_rgba(tints[i], 0.14), nil, 10, nil, 0);
        owf_icon(tile, icons[i], NSMakeRect(9, 9, 18, 18), owf_hex(inks[i]), 1.75);
        CGFloat text = owf_line_box(labelFont) + 3 + owf_line_box(hintFont), textTop = row + (68 - text) / 2;
        owf_text_at(card, owf_text(owf_options[i][0]), owf_style(labelFont, owf_hex(owf_brand_body), 0), 73,
                    textTop + owf_ascent(labelFont), 300, 0);
        owf_text_at(card, owf_text(owf_options[i][1]), owf_style(hintFont, muted, 0), 73,
                    textTop + owf_line_box(labelFont) + 3 + owf_ascent(hintFont), 300, 0);

        CGFloat selectWidth = i == 0 ? 156 : 204;
        OWFBox *select = owf_box(card, NSMakeRect(391, row + 14, selectWidth, 40), owf_hex(0x25212C), owf_white(0.08), 10,
                                 nil, 0);
        select.line = 1;
        owf_canvas_select(select, owf_option_popup(i), owf_style(selectFont, owf_hex(owf_brand_body), 0), 15, @"updown",
                          NSMakeRect(selectWidth - 28, 12, 16, 16), muted, 1.75);
        if (i == 0) {
            OWFBox *play = owf_box(card, NSMakeRect(391 + selectWidth + 8, row + 14, 40, 40),
                                   owf_rgba(owf_brand_accent, 0.14), owf_rgba(owf_brand_accent, 0.22), 10, nil, 0);
            play.line = 1;
            owf_icon(play, @"play.brand", NSMakeRect(13, 13, 14, 14), accent, 0);
            owf_hit(play, NSMakeRect(0, 0, 40, 40), owf_text(@"Preview sound"), @selector(previewSound:), 0);
        }
        if (i < owf_option_count - 1) {
            owf_box(card, NSMakeRect(21, row + 68, width - 42, 1), owf_white(0.06), nil, 0, nil, 0);
        }
    }

    // The vocabulary, with its hint and limit in a strip below.
    top += NSHeight(card.frame) + 32;
    owf_text_at(view, owf_upper(@"Vocabulary"), h2Style, left, top + owf_ascent(h2), width, 0);
    top += owf_line_box(h2) + 12;

    NSFont *helpFont = owf_onest(NSFontWeightRegular, 12.5), *limitFont = owf_onest(NSFontWeightRegular, 12);
    NSFont *limitMono = owf_mono(NSFontWeightRegular, 12);
    NSDictionary *helpStyle = owf_style(helpFont, muted, 0), *limitStyle = owf_style(limitFont, owf_hex(owf_brand_dim), 0);
    NSDictionary *monoStyle = owf_style(limitMono, owf_hex(owf_brand_soft), 0);
    NSArray *limit = [owf_text(@"only the last %@ tokens count") componentsSeparatedByString:@"%@"];
    NSString *before = limit.firstObject ?: @"", *after = limit.count > 1 ? limit[1] : @"";
    CGFloat limitWidth = owf_text_width(before, limitStyle) + owf_text_width(@"~200", monoStyle) +
                         owf_text_width(after, limitStyle);
    NSString *help = owf_text(@"Names and terms — one per line or separated by commas.");
    CGFloat helpWidth = width - 2 - 40 - ceil(limitWidth) - 16;
    NSUInteger helpLines = owf_line_count(help, helpStyle, helpWidth);
    CGFloat strip = fmax(helpLines * owf_line_box(helpFont), owf_line_box(limitFont));
    CGFloat footer = 1 + 11 + strip + 11;
    OWFBox *words = owf_box(view, NSMakeRect(left, top, width, 1 + 84 + footer + 1), owf_hex(owf_brand_card),
                            owf_white(0.07), 16, nil, 0);
    words.line = 1;
    // The strip's faint white over the card, square at the top and round below.
    NSColor *stripFill = owf_hex(0x1E1B24);
    owf_box(words, NSMakeRect(1, 85, width - 2, footer), stripFill, nil, 15, nil, 0);
    owf_box(words, NSMakeRect(1, 85, width - 2, 16), stripFill, nil, 0, nil, 0);
    owf_box(words, NSMakeRect(1, 85, width - 2, 1), owf_white(0.06), nil, 0, nil, 0);
    CGFloat stripTop = 86 + 11;
    owf_text_at(words, help, helpStyle, 21, owf_first_baseline(helpFont, stripTop + (strip - helpLines * owf_line_box(helpFont)) / 2, 0),
                helpWidth, 0);
    CGFloat limitBaseline = owf_middle(limitFont, stripTop, strip), limitX = width - 21 - limitWidth;
    owf_text_at(words, before, limitStyle, limitX, limitBaseline, 300, 0);
    limitX += owf_text_width(before, limitStyle);
    owf_text_at(words, @"~200", monoStyle, limitX, limitBaseline, 60, 0);
    limitX += owf_text_width(@"~200", monoStyle);
    owf_text_at(words, after, limitStyle, limitX, limitBaseline, 200, 0);

    owf_vocabulary_editor(words, NSMakeRect(1, 1, width - 2, 84));
    NSFont *mono = owf_mono(NSFontWeightRegular, 13.5);
    NSMutableParagraphStyle *lines = [[[NSMutableParagraphStyle alloc] init] autorelease];
    lines.minimumLineHeight = 21.6;
    lines.maximumLineHeight = 21.6;
    NSColor *ink = owf_hex(owf_brand_body);
    owf_vocabulary_view.font = mono;
    owf_vocabulary_view.textColor = ink;
    owf_vocabulary_view.insertionPointColor = accent;
    owf_vocabulary_view.defaultParagraphStyle = lines;
    owf_vocabulary_view.typingAttributes = @{NSFontAttributeName: mono, NSForegroundColorAttributeName: ink,
                                             NSParagraphStyleAttributeName: lines,
                                             NSBaselineOffsetAttributeName: @(floor((21.6 - owf_line_box(mono)) / 2))};
    [owf_vocabulary_view.textStorage setAttributes:owf_vocabulary_view.typingAttributes
                                             range:NSMakeRange(0, owf_vocabulary_view.string.length)];
    owf_vocabulary_view.textContainer.lineFragmentPadding = 0;
    owf_vocabulary_view.textContainerInset = NSMakeSize(20, 16);
}

static OWFWordsStyle owf_brand_words(void) {
    return (OWFWordsStyle){
        .font = owf_onest(NSFontWeightRegular, 15),
        .bold = owf_onest(NSFontWeightMedium, 15),
        .color = owf_hex(owf_brand_prose),
        .removed = owf_hex(owf_brand_dim),
        .strike = owf_hex(owf_brand_coral),
        .added = owf_hex(0xC9B5FF),
        .underline = owf_rgba(owf_brand_accent, 0.3),
        .fills = @[owf_rgba(owf_brand_accent, 0.14)],
        .line = 26.25,
        .thickness = 1.5,
        .pad = 6,
        .radius = 6,
    };
}

// A button of the canvas's footers: an icon and a title in a box, right-aligned at right.
static OWFBox *owf_brand_button(NSView *parent, CGFloat right, CGFloat top, NSString *title, NSString *icon,
                                NSColor *fill, NSColor *stroke, NSColor *color, SEL action) {
    NSFont *font = owf_onest(NSFontWeightMedium, 13.5);
    NSDictionary *style = owf_style(font, color, 0);
    CGFloat width = 1 + 14 + 16 + 8 + owf_text_width(owf_text(title), style) + 14 + 1;
    OWFBox *button = owf_box(parent, NSMakeRect(right - width, top, width, 36), fill, stroke, 9, nil, 0);
    button.line = 1;
    owf_icon(button, icon, NSMakeRect(15, 10, 16, 16), color, 1.75);
    owf_text_at(button, owf_text(title), style, 39, owf_middle(font, 0, 36), width - 39, 0);
    owf_hit(button, NSMakeRect(0, 0, width, 36), owf_text(title), action, 0);
    return button;
}

// The corrections of one day, newest first, in a card of rows; returns its height.
static CGFloat owf_brand_day(NSView *list, NSArray<NSNumber *> *indices, CGFloat top) {
    CGFloat width = 616;
    NSFont *time = owf_mono(NSFontWeightRegular, 13);
    NSMutableArray *rows = [NSMutableArray array];
    CGFloat height = 1;

    for (NSNumber *index in indices) {
        NSInteger i = index.integerValue;
        OWFInline *words = [[[OWFInline alloc] initWithSegments:owf_correction_segments(owf_corrections[i]) width:422
                                                          style:owf_brand_words()] autorelease];
        CGFloat row = 18 + fmax(fmax(4 + owf_line_box(time), 1 + words.lineCount * 26.25), 36) + 18;
        [rows addObject:@{@"index": index, @"words": words, @"height": @(row)}];
        height += row + 1;
    }

    OWFBox *card = owf_box(list, NSMakeRect(0, top, width, height), owf_hex(owf_brand_card), owf_white(0.07), 16, nil, 0);
    card.line = 1;
    CGFloat y = 1;
    NSString *const labels[] = {@"Edit", @"Delete"};
    NSString *const icons[] = {@"edit", @"trash"};
    SEL actions[] = {@selector(editCorrection:), @selector(deleteCorrection:)};

    for (NSUInteger r = 0; r < rows.count; r++) {
        NSInteger i = [rows[r][@"index"] integerValue];
        NSDate *date = owf_correction_time(owf_corrections[i][@"time"]);
        OWFInline *words = rows[r][@"words"];
        // A line shorter than the buttons sits on their middle.
        CGFloat middle = owf_snap(fmax(36 - 1 - words.lineCount * 26.25, 0) / 2);
        if (date != nil) {
            owf_text_at(card, [owf_formatter(@"jmm") stringFromDate:date], owf_style(time, owf_hex(owf_brand_dim), 0), 25,
                        y + 18 + middle + 4 + owf_ascent(time), 60, 0);
        }
        [words setFrameOrigin:NSMakePoint(93, y + 19 + middle)];
        [words setAccessibilityElement:YES];
        [words setAccessibilityRole:NSAccessibilityStaticTextRole];
        [words setAccessibilityValue:owf_corrections[i][@"fixed"]];
        words.toolTip = owf_corrections[i][@"fixed"];
        [card addSubview:words];
        for (int b = 0; b < 2; b++) {
            NSRect frame = NSMakeRect(width - 1 - 12 - 72 + b * 36, y + 18, 36, 36);
            owf_icon(card, icons[b], NSInsetRect(frame, 9.5, 9.5), owf_hex(owf_brand_faint), 1.75);
            owf_hit(card, frame, owf_text(labels[b]), actions[b], i);
        }
        y += [rows[r][@"height"] doubleValue];
        if (r < rows.count - 1) {
            owf_box(card, NSMakeRect(1, y, width - 2, 1), owf_white(0.06), nil, 0, nil, 0);
        }
        y += 1;
    }

    return height;
}

// Correction index as two fields with Cancel and Save, in a card at top; returns its height.
static CGFloat owf_canvas_edit(NSView *list, NSInteger index, CGFloat top, CGFloat width, NSColor *fill, NSColor *stroke,
                               NSColor *field, NSColor *text, NSColor *label, NSFont *font, NSFont *labelFont,
                               OWFBox *(^button)(NSView *, CGFloat, CGFloat, NSString *, BOOL, SEL)) {
    NSDictionary *entry = owf_corrections[index];
    NSString *const titles[] = {@"Heard", @"Corrected"};
    NSString *const keys[] = {@"heard", @"fixed"};
    CGFloat heights[2], y = 18;

    for (int i = 0; i < 2; i++) {
        NSUInteger lines = MAX(owf_line_count(entry[keys[i]], owf_style(font, text, 0), width - 48 - 24), 1);
        heights[i] = fmax(44, lines * 22 + 20);
    }

    OWFBox *card = owf_box(list, NSMakeRect(0, top, width, 18 + 2 * 24 + heights[0] + heights[1] + 12 + 16 + 40 + 18),
                           fill, stroke, 16, nil, 0);
    card.line = 1;
    NSTextField *fields[2];
    for (int i = 0; i < 2; i++) {
        owf_text_at(card, owf_text(titles[i]), owf_style(labelFont, label, 0), 24, y + owf_ascent(labelFont), 300, 0);
        OWFBox *box = owf_box(card, NSMakeRect(24, y + 24, width - 48, heights[i]), field, stroke, 10, nil, 0);
        box.line = 1;
        fields[i] = [NSTextField textFieldWithString:entry[keys[i]]];
        fields[i].frame = NSMakeRect(12, 10, width - 48 - 24, heights[i] - 20);
        fields[i].font = font;
        fields[i].textColor = text;
        fields[i].bezeled = NO;
        fields[i].bordered = NO;
        fields[i].drawsBackground = NO;
        fields[i].focusRingType = NSFocusRingTypeNone;
        fields[i].usesSingleLineMode = NO;
        fields[i].cell.wraps = YES;
        fields[i].cell.scrollable = NO;
        [fields[i] setAccessibilityLabel:owf_text(titles[i])];
        [box addSubview:fields[i]];
        y += 24 + heights[i] + (i == 0 ? 12 : 16);
    }

    owf_edit_heard = fields[0];
    owf_edit_fixed = fields[1];
    OWFBox *save = button(card, width - 24, y, @"Save", YES, @selector(saveCorrection:));
    ((NSButton *)save.subviews.lastObject).keyEquivalent = @"\r";
    OWFBox *cancel = button(card, NSMinX(save.frame) - 8, y, @"Cancel", NO, @selector(cancelCorrection:));
    ((NSButton *)cancel.subviews.lastObject).keyEquivalent = @"\033";
    return NSHeight(card.frame);
}

// The newest first corrections grouped by day, each day under its heading.
static NSArray<NSArray *> *owf_correction_days(void) {
    NSMutableArray *days = [NSMutableArray array];
    NSString *day = nil;

    for (NSInteger i = (NSInteger)owf_corrections.count - 1; i >= 0; i--) {
        NSString *heading = owf_correction_day(owf_correction_time(owf_corrections[i][@"time"]));
        if (day == nil || ![heading isEqualToString:day]) {
            [days addObject:@[heading, [NSMutableArray array]]];
            day = heading;
        }
        [days.lastObject[1] addObject:@(i)];
    }

    return days;
}

static CGFloat owf_brand_list(NSView *list) {
    CGFloat width = 616, y = 32;
    NSFont *h2 = owf_onest(NSFontWeightSemibold, 12), *count = owf_onest(NSFontWeightRegular, 12);

    for (NSArray *day in owf_correction_days()) {
        CGFloat row = fmax(owf_line_box(h2), owf_line_box(count));
        NSDictionary *h2Style = owf_style(h2, owf_hex(owf_brand_dim), 0.96);
        NSString *heading = [day[0] uppercaseStringWithLocale:NSLocale.currentLocale];
        NSString *total = owf_count_label([day[1] count]);
        NSDictionary *countStyle = owf_style(count, owf_hex(owf_brand_faint), 0);
        CGFloat headingWidth = owf_text_width(heading, h2Style), totalWidth = owf_text_width(total, countStyle);
        owf_text_at(list, heading, h2Style, 0, owf_middle(h2, y, row), headingWidth + 4, 0);
        owf_text_at(list, total, countStyle, width - totalWidth, owf_middle(count, y, row), totalWidth + 4, 0);
        owf_box(list, NSMakeRect(headingWidth + 12, y + (row - 1) / 2, width - headingWidth - totalWidth - 24, 1),
                owf_white(0.06), nil, 0, nil, 0);
        y += row + 12;

        NSMutableArray *run = [NSMutableArray array];
        for (NSNumber *index in day[1]) {
            if (index.integerValue != owf_corrections_editing) {
                [run addObject:index];
                continue;
            }
            if (run.count > 0) {
                y += owf_brand_day(list, run, y) + 12;
                [run removeAllObjects];
            }
            y += owf_canvas_edit(list, index.integerValue, y, width, owf_hex(owf_brand_card), owf_white(0.07),
                                 owf_hex(0x25212C), owf_hex(owf_brand_body), owf_hex(owf_brand_dim),
                                 owf_onest(NSFontWeightRegular, 15), owf_onest(NSFontWeightSemibold, 12),
                                 ^OWFBox *(NSView *parent, CGFloat right, CGFloat top, NSString *title, BOOL primary, SEL action) {
                                     NSColor *accent = owf_hex(owf_brand_accent);
                                     return owf_brand_button(parent, right, top, title, primary ? @"check" : @"x",
                                                             primary ? owf_rgba(owf_brand_accent, 0.14) : owf_hex(0x221E29),
                                                             primary ? owf_rgba(owf_brand_accent, 0.3) : owf_white(0.08),
                                                             primary ? accent : owf_hex(owf_brand_body), action);
                                 }) + 12;
        }
        if (run.count > 0) {
            y += owf_brand_day(list, run, y);
        } else {
            y -= 12;
        }
        y += 24 + 32;
    }

    return y - 32;
}

// The key chips of a shortcut in running text, as the canvas's kbd: a 2-point bottom border.
static CGFloat owf_brand_key(NSView *parent, NSString *key, CGFloat x, CGFloat baseline) {
    NSFont *font = owf_mono(NSFontWeightRegular, 12);
    NSDictionary *style = owf_style(font, owf_hex(owf_brand_prose), 0);
    CGFloat width = 1 + 7 + owf_text_width(key, style) + 7 + 1, top = baseline - owf_ascent(font) - 2;
    OWFBox *edge = owf_box(parent, NSMakeRect(x, top, width, owf_line_box(font) + 5), owf_white(0.1), nil, 6, nil, 0);
    owf_box(edge, NSMakeRect(1, 1, width - 2, owf_line_box(font) + 2), owf_hex(0x26212E), nil, 5, nil, 0);
    owf_text_at(edge, key, style, 8, 2 + owf_ascent(font), width - 8, 0);
    return x + width;
}

static void owf_brand_corrections(NSView *view, CGFloat height) {
    NSColor *accent = owf_hex(owf_brand_accent), *title = owf_hex(owf_brand_title);
    CGFloat left = 48, width = 616;

    NSFont *h1 = owf_unbounded(NSFontWeightSemibold, 26);
    NSDictionary *h1Style = owf_style(h1, title, -0.26);
    owf_text_at(view, owf_text(@"Corrections"), h1Style, left, owf_first_baseline(h1, 44, 33.8), 400, 0);
    owf_count_badge(1, view, (OWFFit){left + owf_text_width(owf_text(@"Corrections"), h1Style) + 12, 26, 9, NO},
                    44 + (33.8 - 26) / 2, 26, owf_rgba(owf_brand_accent, 0.14), owf_rgba(owf_brand_accent, 0.3),
                    owf_style(owf_mono(NSFontWeightMedium, 13), accent, 0));

    NSFont *lineFont = owf_onest(NSFontWeightRegular, 14);
    CGFloat baseline = owf_first_baseline(lineFont, 44 + 33.8 + 10, 22.4);
    owf_shortcut_line(view, owf_style(lineFont, owf_hex(owf_brand_muted), 0), left, baseline, width,
                      ^CGFloat(NSString *key, CGFloat x) {
                          return owf_brand_key(view, key, x, baseline);
                      });

    CGFloat footerTop = height - 40 - 62, listTop = 44 + 33.8 + 10 + 22.4;
    owf_corrections_scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(left, listTop, width + 8,
                                                                             footerTop - listTop)] autorelease];
    owf_corrections_scroll.drawsBackground = NO;
    owf_corrections_scroll.hasVerticalScroller = YES;
    owf_corrections_scroll.autohidesScrollers = YES;
    owf_corrections_scroll.scrollerStyle = NSScrollerStyleOverlay;
    owf_corrections_scroll.documentView = [[[OWFFlippedView alloc] initWithFrame:owf_corrections_scroll.bounds] autorelease];
    [view addSubview:owf_corrections_scroll];

    owf_corrections_empty = [[[OWFFlippedView alloc] initWithFrame:NSMakeRect(left, listTop + 32, width, 120)] autorelease];
    [view addSubview:owf_corrections_empty];
    owf_text_at(owf_corrections_empty, owf_text(@"No corrections yet"),
                owf_style(owf_unbounded(NSFontWeightMedium, 18), title, 0), 0, 30, width, 0).alignment = NSTextAlignmentCenter;
    owf_text_at(owf_corrections_empty, owf_text(@"Fix a pasted transcript, select the corrected text, then press Control+Fn."),
                owf_style(owf_onest(NSFontWeightRegular, 14), owf_hex(owf_brand_muted), 0), 98, 62, 420, 20.3)
        .alignment = NSTextAlignmentCenter;

    OWFBox *footer = owf_box(view, NSMakeRect(left, footerTop, width, 62), owf_hex(0x17141C), owf_white(0.06), 14, nil, 0);
    footer.line = 1;
    owf_icon(footer, @"file", NSMakeRect(17, 23, 16, 16), owf_hex(owf_brand_dim), 1.75);
    NSFont *file = owf_mono(NSFontWeightRegular, 12.5);
    owf_text_at(footer, owf_corrections_file.lastPathComponent ?: @"corrections.jsonl",
                owf_style(file, owf_hex(owf_brand_soft), 0), 43, owf_middle(file, 13, 36), 200, 0);
    owf_clear_box = owf_brand_button(footer, width - 13, 13, @"Clear All…", @"trash", owf_rgba(owf_brand_coral, 0.08),
                                     owf_rgba(owf_brand_coral, 0.28), owf_hex(0xF5A084), @selector(clearCorrections:));
    owf_corrections_clear = owf_clear_box.subviews.lastObject;
    owf_brand_button(footer, NSMinX(owf_clear_box.frame) - 8, 13, @"Show File", @"folder", owf_hex(0x221E29),
                     owf_white(0.08), owf_hex(owf_brand_body), @selector(showCorrectionsFile:));
}

static NSView *owf_brand_content(NSSize size) {
    OWFBox *root = [[[OWFBox alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)] autorelease];
    root.fill = owf_theme()->canvas;
    owf_brand_sidebar(root, size.height);

    NSRect page = NSMakeRect(owf_brand_left, 0, size.width - owf_brand_left, size.height);
    owf_general_view = [[[OWFFlippedView alloc] initWithFrame:page] autorelease];
    [root addSubview:owf_general_view];
    owf_brand_general(owf_general_view);
    owf_corrections_view = [[[OWFFlippedView alloc] initWithFrame:page] autorelease];
    [root addSubview:owf_corrections_view];
    owf_brand_corrections(owf_corrections_view, size.height);
    return root;
}


// Layout F4+ of the design canvas: white cards with soft shadows on lavender,
// pastel tiles, a tilted fn key, and stickers for added words.
enum {
    owf_soft_violet = 0x5B3DF5, owf_soft_ink = 0x1F1B2B, owf_soft_muted = 0x5E586A, owf_soft_dim = 0x4A4556,
    owf_soft_faint = 0x8C84A0, owf_soft_field = 0xF4F0FF, owf_soft_lilac = 0xF1ECFF, owf_soft_mist = 0xF7F4FF,
    owf_soft_line = 0xF1ECFA, owf_soft_coral = 0xFF7A59,
};
static const CGFloat owf_soft_left = 246;

static NSFont *owf_manrope(NSFontWeight weight, CGFloat size) {
    return owf_family(@"Manrope", weight, size);
}

static NSFont *owf_dela(CGFloat size) {
    return [NSFont fontWithName:@"DelaGothicOne-Regular" size:size] ?: [NSFont systemFontOfSize:size weight:NSFontWeightBlack];
}

// A white card with the canvas's two soft shadows under it: a close dark one
// and a violet one y lower, blurred by blur.
static OWFBox *owf_soft_card(NSView *parent, NSRect face, CGFloat radius, CGFloat y, CGFloat blur, CGFloat alpha) {
    owf_blur(parent, face, radius, owf_rgba(owf_soft_ink, 0.04), 0, 1, 2);
    owf_blur(parent, face, radius, owf_rgba(owf_soft_violet, alpha), 0, y, blur);
    return owf_box(parent, face, NSColor.whiteColor, nil, radius, nil, 0);
}

static void owf_soft_sidebar(NSView *root, CGFloat height) {
    NSColor *violet = owf_hex(owf_soft_violet), *ink = owf_hex(owf_soft_ink);
    NSRect face = NSMakeRect(10, 10, 236, height - 20);
    owf_blur(root, face, 18, owf_rgba(owf_soft_ink, 0.04), 0, 1, 2);
    owf_blur(root, face, 18, owf_rgba(owf_soft_violet, 0.06), 0, 8, 28);
    OWFBox *side = owf_box(root, face, NSColor.whiteColor, nil, 18, nil, 0);

    const uint32_t colors[] = {0x8FDDFF, 0xB9A8FF, 0xFF9ED2, 0xFFD84D, 0xFF9C80, 0xB9A8FF, 0x8FDDFF};
    const CGFloat heights[] = {22, 42, 56, 30, 48, 18, 34};
    for (int i = 0; i < 7; i++) {
        owf_box(side, NSMakeRect(20 + i * 15, 62 + (56 - heights[i]) / 2, 10, heights[i]), owf_hex(colors[i]), nil, 5, nil, 0);
    }

    NSFont *wordmark = owf_dela(25);
    NSArray *name = [owf_text(@"Open\nWord Flow") componentsSeparatedByString:@"\n"];
    for (NSUInteger i = 0; i < name.count; i++) {
        owf_text_at(side, name[i], owf_style(wordmark, violet, 0), 20, owf_first_baseline(wordmark, 136, 27) + i * 27, 196, 0);
    }

    CGFloat top = 136 + name.count * 27 + 10;
    NSFont *tagline = owf_manrope(NSFontWeightSemibold, 14);
    OWFText *motto = owf_text_at(side, owf_text(@"Speak freely. Stay in your flow."),
                                 owf_style(tagline, owf_hex(owf_soft_muted), 0), 20,
                                 owf_first_baseline(tagline, top, 19.6), 196, 19.6);
    top += motto.lineCount * 19.6 + 32;

    NSString *const titles[] = {@"General", @"Corrections"};
    NSString *const icons[] = {@"sliders", @"pencil"};
    for (int i = 0; i < 2; i++) {
        BOOL open = owf_settings_tab == i;
        NSColor *color = open ? violet : owf_hex(owf_soft_dim);
        NSFont *font = owf_manrope(open ? NSFontWeightHeavy : NSFontWeightBold, 15);
        OWFBox *item = owf_box(side, NSMakeRect(14, top + i * 50, 208, 46), open ? owf_hex(owf_soft_lilac) : nil, nil, 14,
                               nil, 0);
        owf_icon(item, icons[i], NSMakeRect(14, 14, 18, 18), color, 2.1);
        owf_text_at(item, owf_text(titles[i]), owf_style(font, color, 0), 44, owf_middle(font, 0, 46), 140, 0);
        if (i == 1) {
            owf_count_badge(0, item, (OWFFit){194, 26, 8, YES}, 10, 26, owf_hex(0xFFE78A), nil,
                            owf_style(owf_manrope(NSFontWeightHeavy, 13), ink, 0));
        }
        owf_hit(item, NSMakeRect(0, 0, 208, 46), owf_text(titles[i]), @selector(navChanged:), i);
    }

    NSFont *heading = owf_manrope(NSFontWeightHeavy, 14), *body = owf_manrope(NSFontWeightMedium, 13);
    NSDictionary *bodyStyle = owf_style(body, owf_hex(owf_soft_muted), 0);
    NSString *text = [owf_text(@"Offline transcription.\nYour voice stays here.") stringByReplacingOccurrencesOfString:@"\n"
                                                                                                          withString:@" "];
    CGFloat row = fmax(16, owf_line_box(heading));
    CGFloat box = 14 + row + 5 + owf_line_count(text, bodyStyle, 176) * 18.85 + 14;
    OWFBox *privacy = owf_box(side, NSMakeRect(14, height - 20 - 14 - box, 208, box), owf_hex(owf_soft_mist), nil, 14, nil, 0);
    owf_icon(privacy, @"shield", NSMakeRect(16, 14 + (row - 16) / 2, 16, 16), violet, 2.1);
    owf_text_at(privacy, owf_text(@"On your Mac"), owf_style(heading, ink, 0), 40, owf_middle(heading, 14, row), 160, 0);
    owf_text_at(privacy, text, bodyStyle, 16, owf_first_baseline(body, 14 + row + 5, 18.85), 176, 18.85);
}

static void owf_soft_general(NSView *view) {
    NSColor *violet = owf_hex(owf_soft_violet), *ink = owf_hex(owf_soft_ink), *muted = owf_hex(owf_soft_muted);
    CGFloat left = 44, width = 626;

    NSFont *h1 = owf_dela(34);
    owf_text_at(view, owf_text(@"General"), owf_style(h1, ink, 0), left, owf_first_baseline(h1, 38, 37.4), 400, 0);

    NSFont *pillFont = owf_manrope(NSFontWeightBold, 12.5);
    NSDictionary *pillStyle = owf_style(pillFont, owf_hex(owf_soft_dim), 0);
    NSString *saved = owf_text(@"Changes saved automatically");
    CGFloat pillWidth = 11 + 14 + 6 + owf_text_width(saved, pillStyle) + 13;
    NSRect pillFace = NSMakeRect(left + width - pillWidth, 38 + (37.4 - 32) / 2, pillWidth, 32);
    owf_blur(view, pillFace, 16, owf_rgba(owf_soft_ink, 0.04), 0, 1, 2);
    OWFBox *pill = owf_box(view, pillFace, NSColor.whiteColor, nil, 16, nil, 0);
    owf_icon(pill, @"check", NSMakeRect(11, 9, 14, 14), violet, 2.1);
    owf_text_at(pill, saved, pillStyle, 31, owf_middle(pillFont, 0, 32), pillWidth - 31, 0);

    // The Dictation card: the tilted fn key, what the mode asks for, and the mode.
    BOOL hold = owf_settings_fn_hold();
    NSArray *instruction = [owf_text(hold ? @"Hold Fn while you speak.\nRelease to finish."
                                          : @"Double-press Fn to start.\nDouble-press again to finish.")
                            componentsSeparatedByString:@"\n"];
    NSString *statement = instruction.firstObject ?: @"", *sub = instruction.count > 1 ? instruction[1] : @"";
    NSFont *overline = owf_manrope(NSFontWeightHeavy, 11.5), *lead = owf_manrope(NSFontWeightHeavy, 21);
    NSFont *subFont = owf_manrope(NSFontWeightSemibold, 15), *modeFont = owf_manrope(NSFontWeightHeavy, 14);
    NSDictionary *leadStyle = owf_style(lead, ink, -0.21), *subStyle = owf_style(subFont, owf_hex(0x5C4E24), 0);
    CGFloat column = 454;
    NSUInteger leadLines = owf_line_count(statement, leadStyle, column), subLines = owf_line_count(sub, subStyle, column);
    CGFloat columnHeight = owf_line_box(overline) + 8 + leadLines * 26.25 + 4 + subLines * owf_line_box(subFont) + 14 + 48;
    CGFloat inner = fmax(100, columnHeight), top = 38 + 37.4 + 22;
    OWFBox *hero = owf_box(view, NSMakeRect(left, top, width, 22 + inner + 22), owf_hex(0xFFEFA8), nil, 26, nil, 0);

    NSRect keyFace = NSMakeRect(24, 22 + (inner - 100) / 2, 100, 100);
    owf_blur(hero, keyFace, 24, owf_rgba(0x221A36, 0.22), 0, 12, 24);
    hero.subviews.lastObject.frameCenterRotation = -4;
    OWFBox *key = owf_box(hero, keyFace, owf_hex(0x221A36), nil, 24, nil, 0);
    key.frameCenterRotation = -4;
    OWFBox *cap = owf_box(key, NSMakeRect(4, 3, 92, 88), owf_hex(0x30264C), nil, 20, nil, 0);
    cap.highlight = owf_white(0.1);
    owf_icon(cap, @"globe", NSMakeRect(67, 10, 14, 14), owf_hex(0xB7B0C8), 1.8);
    NSFont *fn = owf_dela(36);
    owf_text_at(cap, @"fn", owf_style(fn, NSColor.whiteColor, 0), 12, owf_first_baseline(fn, 43, 36), 70, 0);

    CGFloat x = 148, y = 22 + (inner - columnHeight) / 2;
    owf_text_at(hero, owf_upper(@"Dictation · Fn key"), owf_style(overline, owf_hex(0x7A5F12), 0.92), x,
                owf_snap(y + owf_ascent(overline)), column, 0);
    y += owf_line_box(overline) + 8;
    owf_text_at(hero, statement, leadStyle, x, owf_first_baseline(lead, y, 26.25), column, 26.25);
    y += leadLines * 26.25 + 4;
    owf_text_at(hero, sub, subStyle, x, owf_first_baseline(subFont, y, 0), column, 0);
    y += subLines * owf_line_box(subFont) + 14;

    NSString *const modes[] = {@"Double press", @"Press and hold"};
    CGFloat buttons[2];
    for (int i = 0; i < 2; i++) {
        buttons[i] = 18 + owf_text_width(owf_text(modes[i]), owf_style(modeFont, ink, 0)) + 18;
    }
    OWFBox *segment = owf_box(hero, NSMakeRect(x, y, 4 + buttons[0] + 4 + buttons[1] + 4, 48), owf_white(0.7), nil, 24,
                              nil, 0);
    for (NSInteger i = 0; i < 2; i++) {
        BOOL on = hold == i;
        NSRect face = NSMakeRect(4 + (i == 0 ? 0 : buttons[0] + 4), 4, buttons[i], 40);
        if (on) {
            owf_blur(segment, face, 20, owf_rgba(owf_soft_violet, 0.28), 0, 6, 14);
        }
        OWFBox *button = owf_box(segment, face, on ? violet : nil, nil, 20, nil, 0);
        owf_text_at(button, owf_text(modes[i]), owf_style(modeFont, on ? NSColor.whiteColor : ink, 0), 18,
                    owf_middle(modeFont, 0, 40), buttons[i] - 18, 0);
        owf_modes[i] = owf_hit(button, NSMakeRect(0, 0, buttons[i], 40), owf_text(modes[i]), @selector(modeChanged:), i);
        [owf_modes[i] setButtonType:NSButtonTypePushOnPushOff];
        owf_modes[i].state = on ? NSControlStateValueOn : NSControlStateValueOff;
    }

    // Sound and language, and the theme, in rows of one card.
    top += NSHeight(hero.frame) + 20;
    const uint32_t tints[] = {0xDDF3FF, 0xFFE0F0, 0xFFE3DA, 0xFFF1B8};
    const uint32_t inks[] = {0x1E6E96, 0xB0306E, 0xC2410C, 0x7A5F12};
    NSString *const icons[] = {@"speaker", @"waveform", @"bubble", @"palette"};
    NSFont *labelFont = owf_manrope(NSFontWeightHeavy, 15.5), *hintFont = owf_manrope(NSFontWeightMedium, 13);
    NSFont *selectFont = owf_manrope(NSFontWeightBold, 14.5);
    OWFBox *card = owf_soft_card(view, NSMakeRect(left, top, width, owf_option_count * 73 - 1), 24, 10, 28, 0.06);
    for (int i = 0; i < owf_option_count; i++) {
        CGFloat row = i * 73;
        OWFBox *tile = owf_box(card, NSMakeRect(22, row + 15, 42, 42), owf_hex(tints[i]), nil, 14, nil, 0);
        owf_icon(tile, icons[i], NSMakeRect(11.5, 11.5, 19, 19), owf_hex(inks[i]), 2.1);
        CGFloat text = owf_line_box(labelFont) + 2 + owf_line_box(hintFont), textTop = row + (72 - text) / 2;
        owf_text_at(card, owf_text(owf_options[i][0]), owf_style(labelFont, ink, 0), 80,
                    owf_snap(textTop + owf_ascent(labelFont)), 300, 0);
        owf_text_at(card, owf_text(owf_options[i][1]), owf_style(hintFont, muted, 0), 80,
                    owf_snap(textTop + owf_line_box(labelFont) + 2 + owf_ascent(hintFont)), 300, 0);

        CGFloat selectWidth = i == 0 ? 160 : 212;
        OWFBox *select = owf_box(card, NSMakeRect(392, row + 14, selectWidth, 44), owf_hex(owf_soft_field), nil, 14, nil, 0);
        owf_canvas_select(select, owf_option_popup(i), owf_style(selectFont, ink, 0), 16, @"chevron",
                          NSMakeRect(selectWidth - 30, 13, 18, 18), violet, 2.1);
        if (i == 0) {
            OWFBox *play = owf_box(card, NSMakeRect(392 + selectWidth + 8, row + 14, 44, 44), owf_hex(owf_soft_lilac), nil,
                                   22, nil, 0);
            owf_icon(play, @"play", NSMakeRect(15, 15, 14, 14), violet, 0);
            owf_hit(play, NSMakeRect(0, 0, 44, 44), owf_text(@"Preview sound"), @selector(previewSound:), 0);
        }
        if (i < owf_option_count - 1) {
            owf_box(card, NSMakeRect(22, row + 72, width - 44, 1), owf_hex(owf_soft_line), nil, 0, nil, 0);
        }
    }

    // The vocabulary: a row like the others, the field, and its limit.
    top += NSHeight(card.frame) + 20;
    NSFont *noteFont = owf_manrope(NSFontWeightSemibold, 12.5);
    CGFloat head = fmax(42, owf_line_box(labelFont) + 2 + owf_line_box(hintFont));
    OWFBox *words = owf_soft_card(view, NSMakeRect(left, top, width, 18 + head + 14 + 76 + 10 + owf_line_box(noteFont) + 18),
                                  24, 10, 28, 0.06);
    OWFBox *book = owf_box(words, NSMakeRect(22, 18 + (head - 42) / 2, 42, 42), owf_hex(0xD8F5E6), nil, 14, nil, 0);
    owf_icon(book, @"book", NSMakeRect(11.5, 11.5, 19, 19), owf_hex(0x1F7A55), 2.1);
    CGFloat textTop = 18 + (head - owf_line_box(labelFont) - 2 - owf_line_box(hintFont)) / 2;
    owf_text_at(words, owf_text(@"Vocabulary"), owf_style(labelFont, ink, 0), 80, owf_snap(textTop + owf_ascent(labelFont)),
                400, 0);
    owf_text_at(words, owf_text(@"Names and terms, one per line or separated by commas"), owf_style(hintFont, muted, 0), 80,
                owf_snap(textTop + owf_line_box(labelFont) + 2 + owf_ascent(hintFont)), 500, 0);
    OWFBox *field = owf_box(words, NSMakeRect(22, 18 + head + 14, width - 44, 76), owf_hex(owf_soft_mist), nil, 16, nil, 0);
    owf_text_at(words, owf_text(@"Keep it short: only the last ~200 tokens are used."),
                owf_style(noteFont, owf_hex(0x6B6578), 0), 24,
                owf_snap(18 + head + 14 + 76 + 10 + owf_ascent(noteFont)), width - 48, 0);

    owf_vocabulary_editor(field, field.bounds);
    NSFont *font = owf_manrope(NSFontWeightSemibold, 15);
    NSMutableParagraphStyle *lines = [[[NSMutableParagraphStyle alloc] init] autorelease];
    lines.minimumLineHeight = 22.5;
    lines.maximumLineHeight = 22.5;
    owf_vocabulary_view.font = font;
    owf_vocabulary_view.textColor = ink;
    owf_vocabulary_view.insertionPointColor = violet;
    owf_vocabulary_view.defaultParagraphStyle = lines;
    owf_vocabulary_view.typingAttributes = @{NSFontAttributeName: font, NSForegroundColorAttributeName: ink,
                                             NSParagraphStyleAttributeName: lines,
                                             NSBaselineOffsetAttributeName: @(floor((22.5 - owf_line_box(font)) / 2))};
    [owf_vocabulary_view.textStorage setAttributes:owf_vocabulary_view.typingAttributes
                                             range:NSMakeRange(0, owf_vocabulary_view.string.length)];
    owf_vocabulary_view.textContainer.lineFragmentPadding = 0;
    owf_vocabulary_view.textContainerInset = NSMakeSize(16, 12);
}

static OWFWordsStyle owf_soft_words(NSUInteger first) {
    return (OWFWordsStyle){
        .font = owf_manrope(NSFontWeightMedium, 16),
        .bold = owf_manrope(NSFontWeightHeavy, 16),
        .color = owf_hex(owf_soft_ink),
        .removed = owf_hex(owf_soft_faint),
        .strike = owf_hex(owf_soft_coral),
        .added = owf_hex(owf_soft_ink),
        .fills = @[owf_hex(0xFFE78A), owf_hex(0xCDEFFF), owf_hex(0xFFD6EB)],
        .line = 32,
        .thickness = 2,
        .pad = 9,
        .radius = 10,
        .chip = 25.6,
        .tilt = YES,
        .first = first,
    };
}

// A pill button of the canvas's footer: an icon and a title, right-aligned at right.
static OWFBox *owf_soft_button(NSView *parent, CGFloat right, CGFloat top, NSString *title, NSString *icon, NSColor *fill,
                               NSColor *color, SEL action) {
    NSFont *font = owf_manrope(NSFontWeightHeavy, 13.5);
    NSDictionary *style = owf_style(font, color, 0);
    CGFloat width = 16 + 16 + 6 + owf_text_width(owf_text(title), style) + 16;
    OWFBox *button = owf_box(parent, NSMakeRect(right - width, top, width, 42), fill, nil, 21, nil, 0);
    owf_icon(button, icon, NSMakeRect(16, 13, 16, 16), color, 2.1);
    owf_text_at(button, owf_text(title), style, 38, owf_middle(font, 0, 42), width - 38, 0);
    owf_hit(button, NSMakeRect(0, 0, width, 42), owf_text(title), action, 0);
    return button;
}

// A card of correction index at top with its time, words, and buttons; returns its height.
static CGFloat owf_soft_entry(NSView *list, NSInteger index, CGFloat top, NSUInteger card) {
    CGFloat width = 626;
    NSFont *timeFont = owf_manrope(NSFontWeightHeavy, 12.5);
    // The canvas starts each card's stickers at the next fill every other card.
    OWFInline *words = [[[OWFInline alloc] initWithSegments:owf_correction_segments(owf_corrections[index]) width:500
                                                      style:owf_soft_words(card / 2)] autorelease];
    CGFloat chip = 3 + owf_line_box(timeFont) + 3;
    // The time is an inline block on a line of the card's 16-point text,
    // whose strut reaches past the chip's top and bottom.
    NSFont *strut = owf_manrope(NSFontWeightRegular, 16);
    CGFloat above = fmax(owf_ascent(strut), 3 + owf_ascent(timeFont));
    CGFloat line = above + fmax(owf_line_box(strut) - owf_ascent(strut), chip - 3 - owf_ascent(timeFont));
    CGFloat pillTop = 16 + above - 3 - owf_ascent(timeFont);
    CGFloat height = 16 + fmax(line + 6 + words.lineCount * 32, 36) + 18;
    OWFBox *entry = owf_soft_card(list, NSMakeRect(0, top, width, height), 22, 8, 24, 0.05);

    NSDate *date = owf_correction_time(owf_corrections[index][@"time"]);
    if (date != nil) {
        NSString *time = [owf_formatter(@"jmm") stringFromDate:date];
        NSDictionary *style = owf_style(timeFont, owf_hex(owf_soft_violet), 0);
        CGFloat timeWidth = 10 + owf_text_width(time, style) + 10;
        OWFBox *pill = owf_box(entry, NSMakeRect(22, pillTop, timeWidth, chip), owf_hex(owf_soft_field), nil, chip / 2, nil, 0);
        owf_text_at(pill, time, style, 10, owf_snap(3 + owf_ascent(timeFont)), timeWidth, 0);
    }

    [words setFrameOrigin:NSMakePoint(22, 16 + line + 6)];
    [words setAccessibilityElement:YES];
    [words setAccessibilityRole:NSAccessibilityStaticTextRole];
    [words setAccessibilityValue:owf_corrections[index][@"fixed"]];
    words.toolTip = owf_corrections[index][@"fixed"];
    [entry addSubview:words];

    NSString *const labels[] = {@"Edit", @"Delete"};
    NSString *const icons[] = {@"edit", @"trash"};
    SEL actions[] = {@selector(editCorrection:), @selector(deleteCorrection:)};
    for (int b = 0; b < 2; b++) {
        NSRect frame = NSMakeRect(width - 14 - 74 + b * 38, 16, 36, 36);
        owf_icon(entry, icons[b], NSInsetRect(frame, 9.5, 9.5), owf_hex(owf_soft_faint), 2.1);
        owf_hit(entry, frame, owf_text(labels[b]), actions[b], index);
    }

    return height;
}

static CGFloat owf_soft_list(NSView *document) {
    CGFloat width = 626, y = 26;
    // Inside 20 points of room for the cards' shadows at the sides.
    OWFFlippedView *list = [[[OWFFlippedView alloc] initWithFrame:NSMakeRect(20, 0, width, 1)] autorelease];
    [document addSubview:list];
    NSUInteger card = 0;
    NSFont *dayFont = owf_manrope(NSFontWeightHeavy, 13), *countFont = owf_manrope(NSFontWeightBold, 12.5);

    for (NSArray *day in owf_correction_days()) {
        NSDictionary *dayStyle = owf_style(dayFont, owf_hex(0x8C2358), 0.52);
        NSDictionary *countStyle = owf_style(countFont, owf_hex(owf_soft_faint), 0);
        NSString *total = owf_count_label([day[1] count]);
        CGFloat chipWidth = 14 + owf_text_width(day[0], dayStyle) + 14, chip = 6 + owf_line_box(dayFont) + 6;
        CGFloat totalWidth = owf_text_width(total, countStyle);
        OWFBox *heading = owf_box(list, NSMakeRect(0, y, chipWidth, chip), owf_hex(0xFFE0F0), nil, chip / 2, nil, 0);
        owf_text_at(heading, day[0], dayStyle, 14, owf_middle(dayFont, 0, chip), chipWidth, 0);
        owf_box(list, NSMakeRect(chipWidth + 12, y + (chip - 1.5) / 2, width - chipWidth - totalWidth - 24, 1.5),
                owf_hex(0xE9E2F7), nil, 1, nil, 0);
        owf_text_at(list, total, countStyle, width - totalWidth, owf_middle(countFont, y, chip), totalWidth + 4, 0);
        y += chip + 14;

        for (NSNumber *index in day[1]) {
            if (index.integerValue == owf_corrections_editing) {
                y += owf_canvas_edit(list, index.integerValue, y, width, NSColor.whiteColor, owf_hex(owf_soft_line),
                                     owf_hex(owf_soft_mist), owf_hex(owf_soft_ink), owf_hex(owf_soft_faint),
                                     owf_manrope(NSFontWeightMedium, 15), owf_manrope(NSFontWeightHeavy, 12.5),
                                     ^OWFBox *(NSView *parent, CGFloat right, CGFloat top, NSString *title, BOOL primary,
                                               SEL action) {
                                         return owf_soft_button(parent, right, top, title, primary ? @"check" : @"x",
                                                                primary ? owf_hex(owf_soft_violet) : owf_hex(owf_soft_lilac),
                                                                primary ? NSColor.whiteColor : owf_hex(owf_soft_violet),
                                                                action);
                                     }) + 12;
            } else {
                y += owf_soft_entry(list, index.integerValue, y, card) + 12;
            }
            card++;
        }
        y += 28 - 12 + 26;
    }

    [list setFrameSize:NSMakeSize(width, y)];
    return y - 26;
}

// The key chips of a shortcut in running text: white, a hairline below, a soft shadow.
static CGFloat owf_soft_key(NSView *parent, NSString *key, CGFloat x, CGFloat baseline) {
    NSFont *font = owf_manrope(NSFontWeightHeavy, 12.5);
    NSDictionary *style = owf_style(font, owf_hex(owf_soft_ink), 0);
    CGFloat width = 9 + owf_text_width(key, style) + 9, height = 3 + owf_line_box(font) + 3;
    NSRect face = NSMakeRect(x, baseline - owf_ascent(font) - 3, width, height);
    owf_blur(parent, face, 9, owf_rgba(owf_soft_violet, 0.08), 0, 2, 6);
    owf_box(parent, NSOffsetRect(face, 0, 1), owf_hex(0xE2DAF3), nil, 9, nil, 0);
    OWFBox *chip = owf_box(parent, face, NSColor.whiteColor, nil, 9, nil, 0);
    owf_text_at(chip, key, style, 9, 3 + owf_ascent(font), width, 0);
    return x + width;
}

static void owf_soft_corrections(NSView *view, CGFloat height) {
    NSColor *ink = owf_hex(owf_soft_ink), *violet = owf_hex(owf_soft_violet);
    CGFloat left = 44, width = 626;

    NSFont *h1 = owf_dela(34);
    NSDictionary *h1Style = owf_style(h1, ink, 0);
    owf_text_at(view, owf_text(@"Corrections"), h1Style, left, owf_first_baseline(h1, 38, 37.4), 400, 0);
    owf_count_badge(1, view, (OWFFit){left + owf_text_width(owf_text(@"Corrections"), h1Style) + 12, 34, 10, NO},
                    38 + (37.4 - 34) / 2, 34, owf_hex(0xFFE78A), nil, owf_style(owf_dela(15), ink, 0));
    owf_count_badges[1].frameCenterRotation = 6;

    NSFont *lineFont = owf_manrope(NSFontWeightSemibold, 15);
    CGFloat baseline = owf_first_baseline(lineFont, 38 + 37.4 + 12, 25.5);
    owf_shortcut_line(view, owf_style(lineFont, owf_hex(owf_soft_muted), 0), left, baseline, width,
                      ^CGFloat(NSString *key, CGFloat x) {
                          return owf_soft_key(view, key, x, baseline);
                      });

    CGFloat footerTop = height - 10 - 24 - 58, listTop = 38 + 37.4 + 12 + 25.5;
    owf_corrections_scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(left - 20, listTop, width + 40,
                                                                             footerTop - listTop)] autorelease];
    owf_corrections_scroll.drawsBackground = NO;
    owf_corrections_scroll.hasVerticalScroller = YES;
    owf_corrections_scroll.autohidesScrollers = YES;
    owf_corrections_scroll.scrollerStyle = NSScrollerStyleOverlay;
    owf_corrections_scroll.documentView = [[[OWFFlippedView alloc] initWithFrame:owf_corrections_scroll.bounds] autorelease];
    [view addSubview:owf_corrections_scroll];

    owf_corrections_empty = [[[OWFFlippedView alloc] initWithFrame:NSMakeRect(left, listTop + 26, width, 120)] autorelease];
    [view addSubview:owf_corrections_empty];
    owf_text_at(owf_corrections_empty, owf_text(@"No corrections yet"), owf_style(owf_dela(20), ink, 0), 0, 30, width, 0)
        .alignment = NSTextAlignmentCenter;
    owf_text_at(owf_corrections_empty, owf_text(@"Fix a pasted transcript, select the corrected text, then press Control+Fn."),
                owf_style(owf_manrope(NSFontWeightSemibold, 14), owf_hex(owf_soft_muted), 0), 103, 62, 420, 20)
        .alignment = NSTextAlignmentCenter;

    OWFBox *footer = owf_soft_card(view, NSMakeRect(left, footerTop, width, 58), 22, 8, 24, 0.05);
    owf_icon(footer, @"file", NSMakeRect(16, 20.5, 17, 17), violet, 2.1);
    NSFont *file = owf_manrope(NSFontWeightHeavy, 14);
    owf_text_at(footer, owf_corrections_file.lastPathComponent ?: @"corrections.jsonl", owf_style(file, ink, 0), 43,
                owf_middle(file, 0, 58), 220, 0);
    owf_clear_box = owf_soft_button(footer, width - 8, 8, @"Clear All…", @"trash", owf_hex(0xFFE9E2), owf_hex(0xA63A1B),
                                    @selector(clearCorrections:));
    owf_corrections_clear = owf_clear_box.subviews.lastObject;
    owf_soft_button(footer, NSMinX(owf_clear_box.frame) - 8, 8, @"Show File", @"folder", owf_hex(owf_soft_lilac), violet,
                    @selector(showCorrectionsFile:));
}

static NSView *owf_soft_content(NSSize size) {
    OWFBox *root = [[[OWFBox alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)] autorelease];
    root.fill = owf_theme()->canvas;
    owf_soft_sidebar(root, size.height);

    NSRect page = NSMakeRect(owf_soft_left, 0, size.width - owf_soft_left, size.height);
    owf_general_view = [[[OWFFlippedView alloc] initWithFrame:page] autorelease];
    [root addSubview:owf_general_view];
    owf_soft_general(owf_general_view);
    owf_corrections_view = [[[OWFFlippedView alloc] initWithFrame:page] autorelease];
    [root addSubview:owf_corrections_view];
    owf_soft_corrections(owf_corrections_view, size.height);
    return root;
}

static NSView *owf_settings_content(void) {
    // Views of the previous build are gone with it.
    owf_bento_forget();
    owf_tabs = nil;
    owf_shortcut_hint = nil;
    owf_modes[0] = owf_modes[1] = nil;

    if (owf_theme()->layout != OWFLayoutList) {
        OWFLayout layout = owf_theme()->layout;
        NSView *root = layout == OWFLayoutBento ? owf_bento_content()
                     : layout == OWFLayoutSoft ? owf_soft_content(owf_settings_size()) : owf_brand_content(owf_settings_size());
        owf_corrections_reload();
        owf_show_tab(NO);
        return root;
    }

    CGFloat height = owf_settings_size().height;
    OWFSurface *root = [[[OWFSurface alloc] initWithFrame:NSMakeRect(0, 0, owf_settings_size().width, height)] autorelease];
    root.canvas = YES;
    OWFSurface *sidebar = [[[OWFSurface alloc] initWithFrame:NSMakeRect(0, 0, 228, height)] autorelease];
    sidebar.sidebar = YES;
    [root addSubview:sidebar];
    owf_list_sidebar(sidebar);

    NSView *body = [[[NSView alloc] initWithFrame:NSMakeRect(260, 0, 508, height)] autorelease];
    [root addSubview:body];
    owf_title(body, @"Settings", NSMakeRect(0, 627, 508, 38), 26, NSColor.labelColor);

    // Navigation gets its own row, so localized titles and counts cannot collide.
    owf_tabs = [NSSegmentedControl segmentedControlWithLabels:@[owf_text(@"General"), owf_text(@"Corrections")]
                                                 trackingMode:NSSegmentSwitchTrackingSelectOne
                                                       target:owf_settings action:@selector(tabChanged:)];
    owf_tabs.font = owf_font(owf_body_size, NSFontWeightRegular);
    owf_tabs.segmentStyle = NSSegmentStyleRounded;
    owf_tabs.selectedSegmentBezelColor = [NSColor colorWithWhite:0.40 alpha:1];
    owf_tabs.frame = NSMakeRect(-5.5, 578, 519, 32);
    [owf_tabs setWidth:253.5 forSegment:0];
    [owf_tabs setWidth:253.5 forSegment:1];
    [owf_tabs setAccessibilityLabel:owf_text(@"Settings")];
    owf_tabs.selectedSegment = owf_settings_tab;

    owf_general_view = [[[NSView alloc] initWithFrame:body.bounds] autorelease];
    [body addSubview:owf_general_view];
    owf_corrections_view = owf_corrections_content(body.bounds);
    [body addSubview:owf_corrections_view];
    // Above both tabs' views, which span the body and would take its clicks.
    [body addSubview:owf_tabs];

    owf_list_general(owf_general_view);

    owf_corrections_reload();
    owf_show_tab(NO);
    return root;
}

// The window's buttons where the canvas draws its three lights, 20 points
// apart from the first's center, first points from the top left; an empty
// toolbar makes the titlebar tall enough to hold them there.
static void owf_place_lights(void) {
    OWFLayout layout = owf_theme()->layout;
    BOOL canvas = layout != OWFLayoutList;

    if (canvas != (owf_settings_window.toolbar != nil)) {
        owf_settings_window.toolbar = canvas ? [[[NSToolbar alloc] initWithIdentifier:@"OWFLights"] autorelease] : nil;
        owf_settings_window.toolbarStyle = NSWindowToolbarStyleUnified;
    }

    if (!canvas) {
        return;
    }

    [owf_settings_window layoutIfNeeded];
    CGFloat first = layout == OWFLayoutSoft ? 32 : 26, height = NSHeight(owf_settings_window.frame);
    for (int i = 0; i < 3; i++) {
        NSButton *button = [owf_settings_window standardWindowButton:(NSWindowButton)i];
        NSSize size = button.frame.size;
        NSRect target = NSMakeRect(first + 20 * i - size.width / 2, height - first - size.height / 2, size.width, size.height);
        [button setFrameOrigin:[button.superview convertRect:target fromView:nil].origin];
    }
}

// Builds the window contents in the current interface language, keeping the window's top edge in place.
static void owf_settings_reload(void) {
    NSView *content = owf_settings_content();
    NSRect old = owf_settings_window.frame;

    owf_settings_window.title = owf_text(@"Open Word Flow Settings");
    content.appearance = owf_theme()->appearance;
    owf_settings_window.contentView = content;

    NSSize size = owf_settings_size();
    NSRect frame = [owf_settings_window frameRectForContentRect:NSMakeRect(0, 0, size.width, size.height)];
    frame.origin = NSMakePoint(old.origin.x, NSMaxY(old) - frame.size.height);
    [owf_settings_window setFrame:frame display:YES];
    owf_place_lights();
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
    // AppKit lays out the titlebar again as the window gains and loses focus.
    for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification,
                                      NSWindowDidResizeNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:owf_settings_window queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            owf_place_lights();
        }];
    }
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
