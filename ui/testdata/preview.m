// Standalone UI smoke check: no microphone, model, hotkey, or paste services.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#include <assert.h>
#import "../theme_darwin.m"
#import "../settings_darwin.m"
#import "../island_darwin.m"

void owf_activate(void) { [NSApp activate]; }
void owf_status_menu_reload(void) {}
// The design canvas's corrections by what was heard, as Go's diff gives them.
static NSDictionary *mockup_segments;
// Go computes the real diff; here every correction replaces all its words.
char *owfSegmentsJSON(char *heard, char *fixed) {
    NSArray *parts = mockup_segments[@(heard)] ?: @[@{@"text": @(heard), @"kind": @1}, @{@"text": @(fixed), @"kind": @2}];
    NSData *json = [NSJSONSerialization dataWithJSONObject:parts options:0 error:NULL];
    return strdup([[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] autorelease].UTF8String);
}
// A scratch file, never the user's corrections.
static NSString *const corrections_file = @"/tmp/owf-ui-check/corrections.jsonl";
static NSString *previewed_sound;
void owf_sound_preview(NSString *sound) { previewed_sound = sound; }

static void capture(NSView *view, NSString *name) {
    [view display];
    NSBitmapImageRep *image = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:image];
    NSString *path = [@"/tmp/owf-ui-check" stringByAppendingPathComponent:name];
    assert([[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES]);
}

// Reports whether a click at the middle of view reaches it.
static BOOL clickable(NSView *view) {
    NSView *content = view.window.contentView;
    NSPoint middle = [view convertPoint:NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds)) toView:nil];
    NSView *hit = [content hitTest:[content.superview convertPoint:middle fromView:nil]];
    return hit == view || [hit isDescendantOf:view];
}

// A theme of the design canvas with the data of its boards, to compare the two
// pixel by pixel: <theme>-general.png and <theme>-corrections.png.
static void capture_mockup(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *corrections = [NSString stringWithContentsOfFile:corrections_file encoding:NSUTF8StringEncoding error:NULL];
    NSDictionary *saved = defaults.dictionaryRepresentation;
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *yesterday = [calendar dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:NSDate.date options:0];
    NSISO8601DateFormatter *iso = [[[NSISO8601DateFormatter alloc] init] autorelease];
    iso.timeZone = NSTimeZone.localTimeZone;
    NSString *(^at)(NSInteger, NSInteger) = ^(NSInteger hour, NSInteger minute) {
        return [iso stringFromDate:[calendar dateBySettingHour:hour minute:minute second:0 ofDate:yesterday options:0]];
    };
    mockup_segments = [@{
        @"тогда эта команда newmake?": @[@{@"text": @"… тогда эта команда ", @"kind": @0},
            @{@"text": @"newmake?", @"kind": @1}, @{@"text": @"не в make?", @"kind": @2}],
        @"у меня есть конфидестоп": @[@{@"text": @"у меня есть ", @"kind": @0},
            @{@"text": @"конфидестоп", @"kind": @1}, @{@"text": @"Comfy Desktop", @"kind": @2}],
        @"инверсити заобскейлила coin": @[@{@"text": @"… результат работы другой ", @"kind": @0},
            @{@"text": @"инверсити", @"kind": @1}, @{@"text": @"нейросети", @"kind": @2},
            @{@"text": @" внешней она ", @"kind": @0},
            @{@"text": @"заобскейлила", @"kind": @1}, @{@"text": @"заапскейлила", @"kind": @2},
            @{@"text": @" достаточно неплохо в … с вот этим ", @"kind": @0},
            @{@"text": @"coin", @"kind": @1}, @{@"text": @"qwen", @"kind": @2}, @{@"text": @" image 2.1 и …", @"kind": @0}],
    } retain];
    NSMutableString *lines = [NSMutableString string];
    NSArray *entries = @[@[at(17, 30), @"тогда эта команда newmake?"], @[at(21, 39), @"у меня есть конфидестоп"],
                         @[at(21, 42), @"инверсити заобскейлила coin"]];
    for (NSArray *entry in entries) {
        NSDictionary *line = @{@"time": entry[0], @"heard": entry[1], @"fixed": entry[1]};
        NSData *json = [NSJSONSerialization dataWithJSONObject:line options:0 error:NULL];
        [lines appendFormat:@"%@\n", [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] autorelease]];
    }
    assert([lines writeToFile:corrections_file atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    [defaults setObject:@"ru" forKey:owf_interface_language_key];
    [defaults setObject:@"pulse" forKey:owf_sound_key];
    [defaults setObject:@"ru" forKey:owf_language_key];
    [defaults setObject:owf_fn_hold forKey:owf_fn_mode_key];
    [defaults setObject:@"gringotts, travel rule" forKey:owf_vocabulary_key];
    owf_settings_reload();
    capture(owf_settings_window.contentView, [NSString stringWithFormat:@"%@-general.png", owf_theme()->id]);
    owf_select_tab(1);
    capture(owf_settings_window.contentView, [NSString stringWithFormat:@"%@-corrections.png", owf_theme()->id]);
    owf_select_tab(0);

    for (NSString *key in @[owf_interface_language_key, owf_sound_key, owf_language_key, owf_fn_mode_key, owf_vocabulary_key]) {
        [defaults setObject:saved[key] forKey:key];
    }
    [corrections writeToFile:corrections_file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [mockup_segments release];
    mockup_segments = nil;
    owf_settings_reload();
}

static void check_settings(void) {
    // The standalone executable uses its own preferences domain.
    assert(![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.openwordflow.app"]);
    // The list layout's tabs, rows, and native controls; the canvas's layouts follow.
    [NSUserDefaults.standardUserDefaults setObject:@"terminal" forKey:owf_theme_key];
    owf_settings_reload();
    assert(clickable(owf_tabs));
    // No text, such as the title, reaches under the tabs to show its text cursor there.
    for (NSView *view in owf_tabs.superview.subviews) {
        if ([view isKindOfClass:NSTextField.class]) assert(!NSIntersectsRect(view.frame, owf_tabs.frame));
    }
    assert(clickable(owf_modes[0]) && clickable(owf_modes[1]));
    [owf_modes[1] performClick:nil];
    assert(owf_settings_fn_hold());
    assert(owf_modes[1].state == NSControlStateValueOn && owf_modes[0].state == NSControlStateValueOff);
    [owf_modes[0] performClick:nil];
    assert(!owf_settings_fn_hold());
    assert(owf_modes[0].state == NSControlStateValueOn && owf_modes[1].state == NSControlStateValueOff);
    owf_vocabulary_view.string = @"Open Word Flow\nAppKit\nQuartzCore";
    [owf_settings textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:owf_vocabulary_view]];
    for (NSString *language in @[@"en", @"ru"]) {
        for (NSString *theme in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
            [NSUserDefaults.standardUserDefaults setObject:language forKey:owf_interface_language_key];
            owf_settings_window.appearance = [NSAppearance appearanceNamed:theme];
            owf_settings_reload();
            assert([owf_vocabulary_view.string isEqualToString:@"Open Word Flow\nAppKit\nQuartzCore"]);
            assert(NSWidth(owf_settings_window.contentView.bounds) == owf_settings_size().width);
            assert(NSHeight(owf_settings_window.contentView.bounds) == owf_settings_size().height);
            [owf_settings_window.contentView layoutSubtreeIfNeeded];
            capture(owf_settings_window.contentView, [NSString stringWithFormat:@"settings-%@-%@.png", language, theme]);
            owf_select_tab(1);
            assert(owf_general_view.hidden && !owf_corrections_view.hidden && owf_corrections.count == 3);
            [owf_settings_window.contentView layoutSubtreeIfNeeded];
            capture(owf_settings_window.contentView, [NSString stringWithFormat:@"corrections-%@-%@.png", language, theme]);
            owf_select_tab(0);
        }
    }
    // Editing and deleting rewrite the file, newest first on screen, oldest first on disk.
    owf_select_tab(1);
    assert(clickable(owf_tabs));
    for (NSView *view in [owf_corrections_scroll.documentView subviews]) {
        if ([view isKindOfClass:NSButton.class]) assert(clickable(view));
    }
    NSButton *edit = [[[NSButton alloc] init] autorelease];
    edit.tag = 2;
    [owf_settings editCorrection:edit];
    assert(owf_edit_fixed != nil && [owf_edit_heard.stringValue isEqualToString:@"открой мейн точка гоу"]);
    [owf_settings_window.contentView layoutSubtreeIfNeeded];
    capture(owf_settings_window.contentView, @"corrections-editing.png");
    owf_edit_fixed.stringValue = @"открой main.go ";
    [owf_settings saveCorrection:nil];
    assert(owf_corrections_editing == -1 && [owf_corrections[2][@"fixed"] isEqualToString:@"открой main.go"]);
    assert([owf_corrections[2][@"time"] isEqualToString:@"2026-09-25T18:03:00.5+02:00"]);
    [owf_settings deleteCorrection:edit];
    assert(owf_corrections_read().count == 2 && [[owf_tabs labelForSegment:1] hasSuffix:@"2"]);
    owf_corrections_write(@[]);
    owf_corrections_reload();
    assert(owf_corrections.count == 0 && !owf_corrections_empty.hidden);
    assert(!owf_corrections_clear.enabled);
    capture(owf_settings_window.contentView, @"corrections-empty.png");
    // Long corrections wrap instead of hiding the corrected text behind an ellipsis.
    owf_corrections_write(@[@{@"time": @"2026-09-25T18:03:00+02:00",
        @"heard": @"Нужно проверить настройки приложения, переключение языка интерфейса и сохранение длинных исправлений в истории диктовки.",
        @"fixed": @"Нужно проверить настройки Open Word Flow, переключение языка интерфейса и сохранение длинных исправлений в истории диктовки."}]);
    owf_corrections_reload();
    assert(owf_corrections_clear.enabled);
    NSTextField *longWords = owf_corrections_scroll.documentView.subviews.firstObject;
    assert(NSHeight(longWords.frame) > 40);
    capture(owf_settings_window.contentView, @"corrections-long.png");
    NSMutableDictionary *longEntry = [[owf_corrections[0] mutableCopy] autorelease];
    longEntry[@"fixed"] = [@[longEntry[@"fixed"], longEntry[@"fixed"], longEntry[@"fixed"]] componentsJoinedByString:@"\n"];
    owf_corrections_write(@[longEntry]);
    owf_corrections_reload();
    edit.tag = 0;
    [owf_settings editCorrection:edit];
    assert(NSHeight(owf_edit_fixed.frame) > 60);
    [owf_settings cancelCorrection:nil];
    owf_select_tab(0);
    NSPopUpButton *sound = owf_popup(owf_sounds, 4, owf_sound_key, owf_default_sound);
    [sound selectItemAtIndex:1];
    [owf_settings popupChanged:sound];
    assert([owf_settings_sound() isEqualToString:@"pulse"]);
    assert([previewed_sound isEqualToString:@"pulse"]);
    [owf_settings previewSound:nil];
    assert([previewed_sound isEqualToString:@"pulse"]);
    // Choosing a theme saves it, and the rebuilt window takes its look.
    size_t count;
    const OWFTheme *themes = owf_themes(&count);
    assert(count > 1);
    for (size_t i = 0; i < count; i++) {
        NSPopUpButton *theme = owf_theme_popup();
        [theme selectItemAtIndex:i];
        [owf_settings popupChanged:theme];
        assert(owf_theme() == &themes[i]);
        // A theme's bundled fonts load instead of falling back to the system font.
        if (themes[i].family != nil) assert([owf_font(13, NSFontWeightBold).familyName isEqualToString:themes[i].family]);
        if (themes[i].display != nil) assert([owf_display_font(20).fontName isEqualToString:themes[i].display]);
        owf_settings_reload();
        assert(owf_settings_window.contentView.appearance == themes[i].appearance);
        assert((themes[i].layout != OWFLayoutList || clickable(owf_tabs)) && clickable(owf_modes[0]));
        // The window's buttons stand where the canvas draws its lights.
        if (themes[i].layout != OWFLayoutList) {
            NSButton *close = [owf_settings_window standardWindowButton:NSWindowCloseButton];
            NSRect frame = [close convertRect:close.bounds toView:nil];
            CGFloat first = themes[i].layout == OWFLayoutSoft ? 32 : 26;
            assert(NSMidX(frame) == first && NSHeight(owf_settings_window.frame) - NSMidY(frame) == first);
        }
        capture(owf_settings_window.contentView, [NSString stringWithFormat:@"settings-theme-%@.png", themes[i].id]);
        owf_select_tab(1);
        capture(owf_settings_window.contentView, [NSString stringWithFormat:@"corrections-theme-%@.png", themes[i].id]);
        owf_select_tab(0);
        if (themes[i].layout != OWFLayoutList) capture_mockup();
    }
    [NSUserDefaults.standardUserDefaults removeObjectForKey:owf_theme_key];
    owf_settings_reload();
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [[NSFileManager defaultManager] createDirectoryAtPath:@"/tmp/owf-ui-check"
                                 withIntermediateDirectories:YES attributes:nil error:nil];
        assert([@"{\"time\":\"2026-09-25T13:15:28.05775+02:00\",\"heard\":\"допустим, technews, random\",\"fixed\":\"допустим, tech-news, random\"}\n"
                 "{\"time\":\"2026-09-25T15:42:10+02:00\",\"heard\":\"проверь логи в грин готс\",\"fixed\":\"проверь логи в Gringotts\"}\n"
                 "not a correction\n"
                 "{\"time\":\"2026-09-25T18:03:00.5+02:00\",\"heard\":\"открой мейн точка гоу\",\"fixed\":\"открой main.go\"}\n"
                 writeToFile:corrections_file atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        owf_settings_set_corrections_file(corrections_file.UTF8String);
        // The app bundle has macOS load these; the bare executable registers them itself.
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@"ui/fonts" error:NULL]) {
            if ([name.pathExtension isEqualToString:@"ttf"]) {
                NSURL *url = [NSURL fileURLWithPath:[@"ui/fonts" stringByAppendingPathComponent:name]];
                assert(CTFontManagerRegisterFontsForURL((CFURLRef)url, kCTFontManagerScopeProcess, NULL));
            }
        }
        owf_settings_open();
        owf_island_setup();
        if (argc > 1 && strcmp(argv[1], "--interactive") == 0) {
            [NSApp run];
            return 0;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            check_settings();
            owf_ui_show();
            owf_ui_set_level(0.8);
            dispatch_async(dispatch_get_main_queue(), ^{
                // Even with Reduce Motion enabled, opening must animate from the
                // notch instead of switching straight to the expanded outline.
                CABasicAnimation *reveal = (id)[owf_mask animationForKey:@"path"];
                assert(reveal != nil && reveal.duration >= 0.3);
                assert(CGPathGetBoundingBox((CGPathRef)reveal.fromValue).size.width <
                       CGPathGetBoundingBox((CGPathRef)reveal.toValue).size.width);
                assert([owf_bloom_mask animationForKey:@"path"] != nil);
            });
            // The island steps count from here, however long the Settings checks took.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                assert(owf_expanded && !owf_processing && owf_panel.visible);
                assert(owf_level == 0.8);
                capture(owf_panel.contentView, @"island-recording.png");
                owf_ui_processing();
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                assert(owf_processing && owf_timer.opacity < 1);
                // Transcription must never look frozen, with or without Reduce Motion:
                // the glow breathes, or on A+ the ring shows with dots lighting in turn.
                assert(owf_halo() ? !owf_spinner.hidden && owf_dot.hidden : [owf_bloom animationForKey:@"think"] != nil);
                assert([owf_bars[0] animationForKey:@"think"] != nil);
                capture(owf_panel.contentView, @"island-processing.png");
                owf_ui_hide();
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                assert(!owf_expanded && !owf_panel.visible);
                // The island takes a theme chosen while it was hidden.
                [NSUserDefaults.standardUserDefaults setObject:@"terminal" forKey:owf_theme_key];
                owf_ui_show();
                owf_ui_set_level(2); // Input is clamped, even for an invalid caller.
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                assert(owf_expanded && !owf_processing && owf_level == 1);
                assert(CGColorEqualToColor(owf_dot.backgroundColor, owf_theme()->island.dot.CGColor));
                capture(owf_panel.contentView, @"island-terminal.png");
                if (!owf_reduce_motion()) assert([owf_dot animationForKey:@"pulse"] != nil);
                // A correction never takes over a recording.
                owf_ui_correcting();
                dispatch_async(dispatch_get_main_queue(), ^{
                    assert(!owf_correcting && !owf_dot.hidden && owf_fix_label.hidden);
                    owf_ui_hide();
                });
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                assert(!owf_expanded && !owf_panel.visible);
                [NSUserDefaults.standardUserDefaults removeObjectForKey:owf_theme_key];
                owf_ui_correcting();
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                assert(owf_expanded && owf_correcting && !owf_fix_label.hidden && owf_dot.hidden);
                assert(!owf_fix_row.hidden && owf_fix_number.hidden && owf_wave.hidden);
                assert([owf_fix_status animationForKey:@"shimmer"] != nil);
                capture(owf_panel.contentView, @"island-correcting.png");
                owf_ui_corrected(12, "[{\"text\":\"… проверь логи в\",\"kind\":0},"
                                     "{\"text\":\"грин готс,\",\"kind\":1},{\"text\":\"Gringotts,\",\"kind\":2},"
                                     "{\"text\":\"там после деплоя …\",\"kind\":0}]");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                assert(!owf_fix_number.hidden && !owf_fix_status.hidden);
                assert([owf_fix_status animationForKey:@"shimmer"] == nil);
                // Every part of the look fits inside the island.
                for (CALayer *layer in @[owf_fix_label, owf_fix_number, owf_fix_status, owf_fix_row]) {
                    assert(CGPathContainsPoint(owf_correction_path, NULL, CGPointMake(CGRectGetMinX(layer.frame), CGRectGetMidY(layer.frame)), NO));
                    assert(CGPathContainsPoint(owf_correction_path, NULL, CGPointMake(CGRectGetMaxX(layer.frame), CGRectGetMidY(layer.frame)), NO));
                }
                capture(owf_panel.contentView, @"island-corrected.png");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                // The result folds away on its own.
                assert(!owf_expanded && !owf_panel.visible);
                owf_ui_correcting();
                // The longest reason, with what to do.
                owf_ui_not_corrected("Nothing selected");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                assert(owf_fix_number.hidden && !owf_fix_status.hidden);
                CGRect row = owf_fix_row.frame;
                assert(CGPathContainsPoint(owf_correction_path, NULL, CGPointMake(CGRectGetMinX(row), CGRectGetMinY(row)), NO));
                assert(CGPathContainsPoint(owf_correction_path, NULL, CGPointMake(CGRectGetMaxX(row), CGRectGetMinY(row)), NO));
                capture(owf_panel.contentView, @"island-not-corrected.png");
                // A recording replaces the result at once.
                owf_ui_show();
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                // The fold scheduled for the result left the recording alone.
                assert(owf_expanded && !owf_correcting && !owf_dot.hidden && owf_fix_label.hidden);
                assert(owf_fix_row.hidden && owf_fix_status.hidden && !owf_wave.hidden);
                owf_ui_hide();
            });
            // A floating card hangs under the notch, recording and with a correction.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 11 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                assert(!owf_expanded && !owf_panel.visible);
                [NSUserDefaults.standardUserDefaults setObject:@"bento" forKey:owf_theme_key];
                owf_ui_show();
                owf_ui_set_level(0.8);
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                assert(owf_theme()->island.floating && owf_glow.hidden && owf_shadow.opacity == 1);
                // The card hangs below the notch, clear of the menu bar's top.
                CGRect card = CGPathGetBoundingBox(owf_expanded_path);
                assert(CGRectGetMaxY(card) < NSHeight(owf_panel.contentView.bounds));
                for (CALayer *layer in @[owf_dot, owf_timer, owf_wave]) {
                    assert(CGRectContainsRect(card, layer.frame));
                }
                // A voice shrinks one of the card's bars; the rest stand tall.
                int small = 0;
                for (int i = 0; i < owf_card_bar_count; i++) small += owf_bars[i].transform.m22 < 1;
                assert(small == 1 && owf_bars[owf_card_bar_count].hidden);
                capture(owf_panel.contentView, @"island-bento-recording.png");
                owf_ui_processing();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3), dispatch_get_main_queue(), ^{
                    // It trades the timer and the wave for a word and hopping beads.
                    assert(!owf_busy.hidden && owf_timer.hidden && owf_wave.hidden);
                    assert([owf_beads[0] animationForKey:@"think"] != nil);
                    assert(CGRectContainsRect(CGPathGetBoundingBox(owf_expanded_path), owf_busy.frame));
                    capture(owf_panel.contentView, @"island-bento-processing.png");
                    owf_ui_hide();
                });
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 13 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                owf_ui_correcting();
                owf_ui_corrected(4, "[{\"text\":\"у меня есть\",\"kind\":0},"
                                    "{\"text\":\"конфидестоп\",\"kind\":1},{\"text\":\"Comfy Desktop\",\"kind\":2}]");
                // Timers this far out may fire a second late; count from here.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                    assert(owf_expanded && owf_correcting && !owf_fix_number.hidden);
                    for (CALayer *layer in @[owf_fix_label, owf_fix_number, owf_fix_status, owf_fix_row]) {
                        assert(CGPathContainsPoint(owf_correction_path, NULL, CGPointMake(CGRectGetMinX(layer.frame), CGRectGetMidY(layer.frame)), NO));
                        assert(CGPathContainsPoint(owf_correction_path, NULL, CGPointMake(CGRectGetMaxX(layer.frame), CGRectGetMidY(layer.frame)), NO));
                    }
                    capture(owf_panel.contentView, @"island-bento-corrected.png");
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:owf_theme_key];
                    puts("UI checks passed; snapshots: /tmp/owf-ui-check");
                    [NSApp terminate:nil];
                });
            });
        });
        [NSApp run];
    }
}
