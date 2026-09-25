#import <AppKit/AppKit.h>

#include "native_darwin.h"

// Touched only on the main thread: sounds by ID, each indexed by owf_chime.
static NSMutableDictionary<NSString *, NSArray<NSSound *> *> *owf_chimes;

static NSSound *owf_sound(const void *wav, int length) {
    return [[[NSSound alloc] initWithData:[NSData dataWithBytes:wav length:length]] autorelease];
}

void owf_ui_add_sound(
    const char *id,
    const void *start, int start_length,
    const void *stop, int stop_length,
    const void *correct, int correct_length
) {
    @autoreleasepool {
        if (owf_chimes == nil) {
            owf_chimes = [[NSMutableDictionary alloc] init];
        }

        owf_chimes[@(id)] = @[
            owf_sound(start, start_length), owf_sound(stop, stop_length), owf_sound(correct, correct_length)
        ];
    }
}

// Cuts off the previous chime, so a quick Fn tap never plays two at once. An
// unknown sound, such as "off", is silent.
static void owf_play(NSString *sound, int chime) {
    static NSSound *playing;

    [playing stop];
    playing = owf_chimes[sound][chime];
    [playing play];
}

void owf_ui_chime(int chime) {
    dispatch_async(dispatch_get_main_queue(), ^{
        owf_play(owf_settings_sound(), chime);
    });
}

void owf_sound_preview(NSString *sound) {
    owf_play(sound, owf_chime_start);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        // Skip when another sound was picked meanwhile.
        if ([owf_settings_sound() isEqualToString:sound]) {
            owf_play(sound, owf_chime_stop);
        }
    });
}
