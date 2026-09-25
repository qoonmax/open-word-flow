// Standalone UI smoke check: no microphone, model, hotkey, or paste services.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <assert.h>
#import "../settings_darwin.m"
#import "../island_darwin.m"

void owf_activate(void) { [NSApp activate]; }
void owf_status_menu_reload(void) {}
// Go computes the real diff; here every correction replaces all its words.
char *owfSegmentsJSON(char *heard, char *fixed) {
    NSArray *parts = @[@{@"text": @(heard), @"kind": @1}, @{@"text": @(fixed), @"kind": @2}];
    NSData *json = [NSJSONSerialization dataWithJSONObject:parts options:0 error:NULL];
    return strdup([[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] autorelease].UTF8String);
}
// A scratch file, never the user's corrections.
static NSString *const corrections_file = @"/tmp/owf-ui-check/corrections.jsonl";
static NSString *previewed_sound;
void owf_sound_preview(NSString *sound) { previewed_sound = sound; }

static void capture(NSView *view, NSString *name) {
    [view displayIfNeeded];
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

static void check_settings(void) {
    // The standalone executable uses its own preferences domain.
    assert(![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.openwordflow.app"]);
    assert(clickable(owf_tabs));
    // No text, such as the title, reaches under the tabs to show its text cursor there.
    for (NSView *view in owf_tabs.superview.subviews) {
        if ([view isKindOfClass:NSTextField.class]) assert(!NSIntersectsRect(view.frame, owf_tabs.frame));
    }
    NSSegmentedControl *mode = [NSSegmentedControl segmentedControlWithLabels:@[@"Double", @"Hold"]
                                                              trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                    target:nil action:nil];
    mode.selectedSegment = 1;
    [owf_settings modeChanged:mode];
    assert(owf_settings_fn_hold());
    mode.selectedSegment = 0;
    [owf_settings modeChanged:mode];
    assert(!owf_settings_fn_hold());
    owf_vocabulary_view.string = @"Open Word Flow\nAppKit\nQuartzCore";
    [owf_settings textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:owf_vocabulary_view]];
    for (NSString *language in @[@"en", @"ru"]) {
        for (NSString *theme in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
            [NSUserDefaults.standardUserDefaults setObject:language forKey:owf_interface_language_key];
            owf_settings_window.appearance = [NSAppearance appearanceNamed:theme];
            owf_settings_reload();
            assert([owf_vocabulary_view.string isEqualToString:@"Open Word Flow\nAppKit\nQuartzCore"]);
            assert(NSWidth(owf_settings_window.contentView.bounds) == owf_settings_width);
            assert(NSHeight(owf_settings_window.contentView.bounds) == owf_settings_height);
            [owf_settings_window.contentView layoutSubtreeIfNeeded];
            capture(owf_settings_window.contentView, [NSString stringWithFormat:@"settings-%@-%@.png", language, theme]);
            owf_tabs.selectedSegment = 1;
            [owf_settings tabChanged:owf_tabs];
            assert(owf_general_view.hidden && !owf_corrections_view.hidden && owf_corrections.count == 3);
            [owf_settings_window.contentView layoutSubtreeIfNeeded];
            capture(owf_settings_window.contentView, [NSString stringWithFormat:@"corrections-%@-%@.png", language, theme]);
            owf_tabs.selectedSegment = 0;
            [owf_settings tabChanged:owf_tabs];
        }
    }
    // Editing and deleting rewrite the file, newest first on screen, oldest first on disk.
    owf_tabs.selectedSegment = 1;
    [owf_settings tabChanged:owf_tabs];
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
    capture(owf_settings_window.contentView, @"corrections-empty.png");
    owf_tabs.selectedSegment = 0;
    [owf_settings tabChanged:owf_tabs];
    NSPopUpButton *sound = owf_popup(owf_sounds, 4, owf_sound_key, owf_default_sound);
    [sound selectItemAtIndex:1];
    [owf_settings popupChanged:sound];
    assert([owf_settings_sound() isEqualToString:@"pulse"]);
    assert([previewed_sound isEqualToString:@"pulse"]);
    [owf_settings previewSound:nil];
    assert([previewed_sound isEqualToString:@"pulse"]);
}

int main(void) {
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
        owf_settings_open();
        owf_island_setup();
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
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            assert(owf_expanded && !owf_processing && owf_panel.visible);
            assert(owf_level == 0.8);
            capture(owf_panel.contentView, @"island-recording.png");
            owf_ui_processing();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            assert(owf_processing && owf_timer.opacity < 1);
            // Transcription must never look frozen, with or without Reduce Motion.
            assert([owf_bloom animationForKey:@"think"] != nil);
            assert([owf_bars[0] animationForKey:@"think"] != nil);
            capture(owf_panel.contentView, @"island-processing.png");
            owf_ui_hide();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            assert(!owf_expanded && !owf_panel.visible);
            owf_ui_show();
            owf_ui_set_level(2); // Input is clamped, even for an invalid caller.
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            assert(owf_expanded && !owf_processing && owf_level == 1);
            if (!owf_reduce_motion()) assert([owf_dot animationForKey:@"pulse"] != nil);
            // A correction never takes over a recording.
            owf_ui_correcting();
            dispatch_async(dispatch_get_main_queue(), ^{
                assert(!owf_correcting && !owf_dot.hidden && owf_fix_label.hidden);
                owf_ui_hide();
            });
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            assert(!owf_expanded && !owf_panel.visible);
            owf_ui_correcting();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 7 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            assert(owf_expanded && owf_correcting && !owf_fix_label.hidden && owf_dot.hidden);
            assert(!owf_fix_row.hidden && owf_fix_number.hidden && owf_wave.hidden);
            assert([owf_fix_status animationForKey:@"shimmer"] != nil);
            capture(owf_panel.contentView, @"island-correcting.png");
            owf_ui_corrected(12, "[{\"text\":\"… проверь логи в\",\"kind\":0},"
                                 "{\"text\":\"грин готс,\",\"kind\":1},{\"text\":\"Gringotts,\",\"kind\":2},"
                                 "{\"text\":\"там после деплоя …\",\"kind\":0}]");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 7.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            assert(!owf_fix_number.hidden && !owf_fix_status.hidden);
            assert([owf_fix_status animationForKey:@"shimmer"] == nil);
            // Every part of the look fits inside the island.
            for (CALayer *layer in @[owf_fix_label, owf_fix_number, owf_fix_status, owf_fix_row]) {
                assert(CGPathContainsPoint(owf_correction_path, NULL, CGPointMake(CGRectGetMinX(layer.frame), CGRectGetMidY(layer.frame)), NO));
                assert(CGPathContainsPoint(owf_correction_path, NULL, CGPointMake(CGRectGetMaxX(layer.frame), CGRectGetMidY(layer.frame)), NO));
            }
            capture(owf_panel.contentView, @"island-corrected.png");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 9 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            // The result folds away on its own.
            assert(!owf_expanded && !owf_panel.visible);
            owf_ui_correcting();
            owf_ui_not_corrected("Not like a recent dictation");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 9.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            assert(owf_fix_number.hidden && !owf_fix_status.hidden);
            capture(owf_panel.contentView, @"island-not-corrected.png");
            // A recording replaces the result at once.
            owf_ui_show();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 11 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            // The fold scheduled for the result left the recording alone.
            assert(owf_expanded && !owf_correcting && !owf_dot.hidden && owf_fix_label.hidden);
            assert(owf_fix_row.hidden && owf_fix_status.hidden && !owf_wave.hidden);
            puts("UI checks passed; snapshots: /tmp/owf-ui-check");
            [NSApp terminate:nil];
        });
        [NSApp run];
    }
}
