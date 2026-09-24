#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>

#include <math.h>

#include "native_darwin.h"

// Layout in points. The black island grows out of the notch into two ears: a
// recording dot with a timer left of the camera, the voice wave right of it.
// A Siri-like glow lights the island from behind and swells with the voice.
static const CGFloat owf_ear_width = 72;
static const CGFloat owf_notchless_gap = 16;
static const CGFloat owf_notchless_height = 32;
static const CGFloat owf_notch_radius = 8;
static const CGFloat owf_island_radius = 14;
static const CGFloat owf_shoulder_radius = 6;
static const CGFloat owf_margin = 44;
static const CGFloat owf_glow_bloom_width = 20;
static const CGFloat owf_glow_blur = 14;
static const CFTimeInterval owf_glow_period = 3;
// Glow opacity in silence and at full voice.
static const float owf_glow_rest = 0.35;
static const float owf_glow_peak = 0.7;
// Share of the glow kept at the island's bottom edge; it fades out further down. The
// long bottom edge would otherwise outshine the short sides.
static const float owf_glow_below = 0.5;
static const CGFloat owf_dot_size = 6;
static const CGFloat owf_dot_gap = 6;
static const CGFloat owf_timer_font_size = 12;
static const CGFloat owf_bar_width = 3;
static const CGFloat owf_bar_gap = 2.5;
static const CGFloat owf_bar_min_height = 3;
static const CGFloat owf_bar_max_height = 16;
static const CGFloat owf_bar_weights[] = {0.45, 0.7, 0.9, 1.0, 0.9, 0.7, 0.45};

enum { owf_bar_count = sizeof(owf_bar_weights) / sizeof(owf_bar_weights[0]) };

@interface OWFPanel : NSPanel
@end

@implementation OWFPanel

// Borderless windows may cover the menu bar and the notch; never push the panel below them.
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen {
    return frameRect;
}

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (BOOL)canBecomeMainWindow {
    return NO;
}

@end

// Touched only on the main thread.
static OWFPanel *owf_panel;
static CALayer *owf_island;
static CAShapeLayer *owf_mask;
static CALayer *owf_content;
static CALayer *owf_glow;
static CALayer *owf_bloom;
static CAShapeLayer *owf_bloom_mask;
static CALayer *owf_ring;
static CAGradientLayer *owf_spin;
static CALayer *owf_dot;
static CATextLayer *owf_timer;
static CAGradientLayer *owf_wave;
static CALayer *owf_bars[owf_bar_count];
static CGPathRef owf_collapsed_path;
static CGPathRef owf_expanded_path;
static CFTimeInterval owf_started_at;
static int owf_timer_seconds;
static double owf_level;
static BOOL owf_expanded;

// Siri-like colors; the conic gradient repeats the first one to close the loop.
static NSArray *owf_palette(BOOL loop) {
    NSMutableArray *colors = [NSMutableArray array];
    const CGFloat rgb[][3] = {
        {0x3C, 0xB8, 0xFF},
        {0xA4, 0x5C, 0xFF},
        {0xFF, 0x5C, 0x9C},
        {0xFF, 0x9F, 0x45},
    };
    size_t count = sizeof(rgb) / sizeof(rgb[0]);

    for (size_t i = 0; i < count + (loop ? 1 : 0); i++) {
        const CGFloat *c = rgb[i % count];
        [colors addObject:(id)[NSColor colorWithSRGBRed:c[0] / 255 green:c[1] / 255 blue:c[2] / 255 alpha:1].CGColor];
    }

    return colors;
}

// Island outline: concave shoulders at the screen edge, rounded bottom corners.
// It is left open along the top edge, so the glow never draws there; fills close
// it implicitly. Every outline has the same elements, so Core Animation can morph
// one into another.
static CGPathRef owf_island_path(
    CGFloat cx,
    CGFloat top,
    CGFloat width,
    CGFloat height,
    CGFloat radius,
    CGFloat shoulder
) {
    CGFloat left = cx - width / 2;
    CGFloat right = cx + width / 2;
    CGFloat bottom = top - height;
    CGMutablePathRef path = CGPathCreateMutable();

    CGPathMoveToPoint(path, NULL, left - shoulder, top);
    CGPathAddQuadCurveToPoint(path, NULL, left, top, left, top - shoulder);
    CGPathAddLineToPoint(path, NULL, left, bottom + radius);
    CGPathAddQuadCurveToPoint(path, NULL, left, bottom, left + radius, bottom);
    CGPathAddLineToPoint(path, NULL, right - radius, bottom);
    CGPathAddQuadCurveToPoint(path, NULL, right, bottom, right, bottom + radius);
    CGPathAddLineToPoint(path, NULL, right, top - shoulder);
    CGPathAddQuadCurveToPoint(path, NULL, right, top, right + shoulder, top);

    return path;
}

static NSScreen *owf_notch_screen(void) {
    for (NSScreen *screen in NSScreen.screens) {
        if (screen.safeAreaInsets.top > 0) {
            return screen;
        }
    }

    return NSScreen.screens.firstObject;
}

static NSFont *owf_timer_font(void) {
    return [NSFont monospacedDigitSystemFontOfSize:owf_timer_font_size weight:NSFontWeightSemibold];
}

static void owf_set_bar_heights(CGFloat level) {
    CFTimeInterval now = CACurrentMediaTime();

    for (int i = 0; i < owf_bar_count; i++) {
        // A ripple travels across the bars: it shapes the voice level and keeps
        // a faint breathing motion in silence, so the wave never looks frozen.
        CGFloat ripple = 0.5 + 0.5 * sin(now * 7 + i * 0.9);
        // The square root lifts ordinary speech, which sits mid-scale, toward the full height.
        CGFloat voice = sqrt(level) * owf_bar_weights[i] * (0.65 + 0.35 * ripple);
        CGFloat scale = fmin(1, fmax(voice, 0.12 * ripple));
        CGFloat height = owf_bar_min_height + (owf_bar_max_height - owf_bar_min_height) * scale;
        owf_bars[i].bounds = CGRectMake(0, 0, owf_bar_width, height);
    }
}

static void owf_set_timer(int seconds) {
    owf_timer_seconds = seconds;
    owf_timer.string = [NSString stringWithFormat:@"%d:%02d", seconds / 60, seconds % 60];
}

// Returns the island to its recording look after a previous transcription.
static void owf_reset_state(void) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    for (int i = 0; i < owf_bar_count; i++) {
        [owf_bars[i] removeAnimationForKey:@"think"];
    }

    [owf_bloom removeAnimationForKey:@"think"];
    owf_dot.opacity = 1;
    owf_bloom.opacity = owf_glow_rest;
    owf_level = 0;
    owf_set_bar_heights(0);
    owf_set_timer(0);

    [CATransaction commit];
}

// Places the panel around the notch of the current screen; displays may change between recordings.
static void owf_layout(void) {
    NSScreen *screen = owf_notch_screen();
    NSRect frame = screen.frame;
    CGFloat notchHeight = screen.safeAreaInsets.top;
    CGFloat notchWidth = 0;
    CGFloat notchCenter = NSMidX(frame);

    if (notchHeight > 0) {
        CGFloat leftWidth = screen.auxiliaryTopLeftArea.size.width;
        notchWidth = frame.size.width - leftWidth - screen.auxiliaryTopRightArea.size.width;
        notchCenter = frame.origin.x + leftWidth + notchWidth / 2;
    }

    // The island fills the menu bar's height and never reaches past it into the
    // windows below; with the menu bar hidden it matches the notch.
    CGFloat menuBarHeight = NSMaxY(frame) - NSMaxY(screen.visibleFrame);
    CGFloat height = fmax(notchHeight, menuBarHeight);

    if (height == 0) {
        height = owf_notchless_height;
    }

    CGFloat gap = notchHeight > 0 ? notchWidth : owf_notchless_gap;
    CGFloat width = gap + 2 * owf_ear_width;
    CGFloat inset = owf_shoulder_radius + owf_margin;
    NSRect panelFrame = NSMakeRect(
        notchCenter - width / 2 - inset,
        NSMaxY(frame) - height - owf_margin,
        width + 2 * inset,
        height + owf_margin
    );
    [owf_panel setFrame:panelFrame display:NO];

    CGRect bounds = CGRectMake(0, 0, panelFrame.size.width, panelFrame.size.height);
    CGFloat cx = bounds.size.width / 2;
    CGFloat top = bounds.size.height;
    CGFloat middle = top - height / 2;
    CGFloat scale = screen.backingScaleFactor;

    CGPathRelease(owf_collapsed_path);
    CGPathRelease(owf_expanded_path);
    owf_collapsed_path = owf_island_path(
        cx, top, notchWidth, notchHeight, notchHeight > 0 ? owf_notch_radius : 0, 0
    );
    owf_expanded_path = owf_island_path(
        cx, top, width, height, owf_island_radius, owf_shoulder_radius
    );

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    for (CALayer *layer in @[owf_island, owf_content, owf_glow, owf_bloom, owf_ring]) {
        layer.frame = bounds;
    }

    for (CAShapeLayer *shape in @[owf_mask, owf_bloom_mask]) {
        shape.frame = bounds;
        shape.contentsScale = scale;
        shape.path = owf_collapsed_path;
    }

    // The spinning gradient covers the panel at any angle.
    CGFloat diagonal = hypot(bounds.size.width, bounds.size.height);
    owf_spin.bounds = CGRectMake(0, 0, diagonal, diagonal);
    owf_spin.position = CGPointMake(cx, middle);

    owf_content.opacity = 0;
    owf_glow.opacity = 0;
    owf_glow.mask.frame = bounds;
    ((CAGradientLayer *)owf_glow.mask).locations = @[@0, @(owf_margin / top), @1];

    // Dot and timer as one group, centered in the left ear.
    NSSize timerSize = [@"0:00" sizeWithAttributes:@{NSFontAttributeName: owf_timer_font()}];
    CGFloat groupWidth = owf_dot_size + owf_dot_gap + timerSize.width;
    CGFloat groupLeft = cx - gap / 2 - owf_ear_width / 2 - groupWidth / 2;
    owf_dot.position = CGPointMake(groupLeft + owf_dot_size / 2, middle);
    owf_timer.frame = CGRectMake(
        groupLeft + owf_dot_size + owf_dot_gap,
        middle - timerSize.height / 2,
        timerSize.width + owf_ear_width / 2,
        timerSize.height
    );
    owf_timer.contentsScale = scale;

    // The wave, centered in the right ear.
    CGFloat waveWidth = owf_bar_count * owf_bar_width + (owf_bar_count - 1) * owf_bar_gap;
    owf_wave.frame = CGRectMake(
        cx + gap / 2 + owf_ear_width / 2 - waveWidth / 2,
        middle - owf_bar_max_height / 2,
        waveWidth,
        owf_bar_max_height
    );
    owf_wave.mask.frame = owf_wave.bounds;

    for (int i = 0; i < owf_bar_count; i++) {
        owf_bars[i].position = CGPointMake(
            owf_bar_width / 2 + i * (owf_bar_width + owf_bar_gap), owf_bar_max_height / 2
        );
    }

    [CATransaction commit];
}

// Morphs the outline and fades content and glow: in after the island has started
// to grow, out before it shrinks, so nothing is clipped halfway.
static void owf_morph(CGPathRef target, BOOL expand) {
    // Without an animation in flight the presentation layer may be stale.
    CAShapeLayer *presentation = owf_mask.presentationLayer;
    CGPathRef from = presentation != nil && [owf_mask animationForKey:@"path"] != nil
                         ? presentation.path
                         : owf_mask.path;
    CABasicAnimation *morph;

    if (expand) {
        CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:@"path"];
        spring.mass = 1;
        spring.stiffness = 260;
        spring.damping = 22;
        spring.duration = spring.settlingDuration;
        morph = spring;
    } else {
        morph = [CABasicAnimation animationWithKeyPath:@"path"];
        morph.duration = 0.3;
        morph.beginTime = CACurrentMediaTime() + 0.1;
        morph.fillMode = kCAFillModeBackwards;
        morph.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.4:0:0.2:1];
    }

    morph.fromValue = (id)from;
    morph.toValue = (id)target;

    CALayer *content = owf_content.presentationLayer ?: owf_content;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(content.opacity);
    fade.toValue = expand ? @1.0 : @0.0;
    fade.duration = expand ? 0.3 : 0.15;

    if (expand) {
        fade.beginTime = CACurrentMediaTime() + 0.12;
        fade.fillMode = kCAFillModeBackwards;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (!expand) {
        [CATransaction setCompletionBlock:^{
            if (!owf_expanded) {
                [owf_panel orderOut:nil];
            }
        }];
    }

    for (CAShapeLayer *shape in @[owf_mask, owf_bloom_mask]) {
        shape.path = target;
        [shape addAnimation:morph forKey:@"path"];
    }

    for (CALayer *layer in @[owf_content, owf_glow]) {
        layer.opacity = expand ? 1 : 0;
        [layer addAnimation:fade forKey:@"fade"];
    }

    [CATransaction commit];
}

static CAShapeLayer *owf_stroke(CGFloat width) {
    CAShapeLayer *stroke = [[CAShapeLayer alloc] init];
    stroke.fillColor = nil;
    stroke.strokeColor = CGColorGetConstantColor(kCGColorBlack);
    stroke.lineWidth = width;
    stroke.lineCap = kCALineCapRound;
    stroke.lineJoin = kCALineJoinRound;

    return stroke;
}

// A spinning conic gradient seen through a stroke of the outline.
static CALayer *owf_glow_ring(CAShapeLayer *stroke) {
    CAGradientLayer *spin = [[CAGradientLayer alloc] init];
    spin.type = kCAGradientLayerConic;
    spin.colors = owf_palette(YES);
    spin.startPoint = CGPointMake(0.5, 0.5);
    spin.endPoint = CGPointMake(0.5, 1);

    CABasicAnimation *rotate = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    rotate.fromValue = @0;
    rotate.toValue = @(-2 * M_PI);
    rotate.duration = owf_glow_period;
    rotate.repeatCount = HUGE_VALF;
    [spin addAnimation:rotate forKey:@"spin"];
    owf_spin = spin;

    owf_ring = [[CALayer alloc] init];
    owf_ring.mask = stroke;
    [owf_ring addSublayer:spin];

    return owf_ring;
}

// The glow sits behind the island, so the black shape covers its inner half and
// the light seems to come from behind the island.
static void owf_glow_setup(CALayer *root) {
    owf_glow = [[CALayer alloc] init];
    [root addSublayer:owf_glow];

    // Full glow beside the island, dimmer and shorter below it.
    CAGradientLayer *falloff = [[CAGradientLayer alloc] init];
    falloff.colors = @[
        (id)CGColorGetConstantColor(kCGColorClear),
        (id)[NSColor colorWithWhite:0 alpha:owf_glow_below].CGColor,
        (id)CGColorGetConstantColor(kCGColorBlack),
    ];
    falloff.startPoint = CGPointMake(0.5, 0);
    falloff.endPoint = CGPointMake(0.5, 1);
    owf_glow.mask = falloff;

    // Blurring a layer whose child is masked keeps the bloom soft past the stroke.
    owf_bloom_mask = owf_stroke(owf_glow_bloom_width);
    owf_bloom = [[CALayer alloc] init];
    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blur setValue:@(owf_glow_blur) forKey:kCIInputRadiusKey];
    owf_bloom.filters = @[blur];
    [owf_bloom addSublayer:owf_glow_ring(owf_bloom_mask)];
    [owf_glow addSublayer:owf_bloom];
}

static void owf_indicator_setup(void) {
    owf_dot = [[CALayer alloc] init];
    owf_dot.backgroundColor = NSColor.systemRedColor.CGColor;
    owf_dot.bounds = CGRectMake(0, 0, owf_dot_size, owf_dot_size);
    owf_dot.cornerRadius = owf_dot_size / 2;
    [owf_content addSublayer:owf_dot];

    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    pulse.fromValue = @1.0;
    pulse.toValue = @0.7;
    pulse.duration = 0.8;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [owf_dot addAnimation:pulse forKey:@"pulse"];

    owf_timer = [[CATextLayer alloc] init];
    owf_timer.font = (CFTypeRef)owf_timer_font();
    owf_timer.fontSize = owf_timer_font_size;
    owf_timer.foregroundColor = [NSColor colorWithWhite:1 alpha:0.92].CGColor;
    [owf_content addSublayer:owf_timer];
}

// The bars form a mask over a horizontal gradient in the glow's colors.
static void owf_wave_setup(void) {
    owf_wave = [[CAGradientLayer alloc] init];
    owf_wave.colors = owf_palette(NO);
    owf_wave.startPoint = CGPointMake(0, 0.5);
    owf_wave.endPoint = CGPointMake(1, 0.5);
    owf_wave.mask = [[CALayer alloc] init];
    [owf_content addSublayer:owf_wave];

    for (int i = 0; i < owf_bar_count; i++) {
        owf_bars[i] = [[CALayer alloc] init];
        owf_bars[i].backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        owf_bars[i].cornerRadius = owf_bar_width / 2;
        [owf_wave.mask addSublayer:owf_bars[i]];
    }
}

void owf_island_setup(void) {
    owf_panel = [[OWFPanel alloc]
        initWithContentRect:NSZeroRect
                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    owf_panel.opaque = NO;
    owf_panel.backgroundColor = NSColor.clearColor;
    owf_panel.hasShadow = NO;
    owf_panel.ignoresMouseEvents = YES;
    owf_panel.hidesOnDeactivate = NO;
    // Above the menu bar, on every Space, and over full-screen apps.
    owf_panel.level = NSMainMenuWindowLevel + 3;
    owf_panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                   NSWindowCollectionBehaviorStationary |
                                   NSWindowCollectionBehaviorFullScreenAuxiliary |
                                   NSWindowCollectionBehaviorIgnoresCycle;

    NSView *view = owf_panel.contentView;
    view.wantsLayer = YES;
    view.layerUsesCoreImageFilters = YES;

    owf_glow_setup(view.layer);

    // A black layer clipped by the animated outline, continuing the notch.
    owf_island = [[CALayer alloc] init];
    owf_island.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    owf_mask = [[CAShapeLayer alloc] init];
    owf_mask.fillColor = CGColorGetConstantColor(kCGColorBlack);
    owf_island.mask = owf_mask;
    [view.layer addSublayer:owf_island];

    owf_content = [[CALayer alloc] init];
    [owf_island addSublayer:owf_content];

    owf_indicator_setup();
    owf_wave_setup();
}

void owf_ui_show(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (owf_expanded) {
            return;
        }

        // Mid-collapse the geometry is still valid; morph back from the current outline.
        if (!owf_panel.visible) {
            owf_layout();
        }

        owf_reset_state();
        owf_started_at = CACurrentMediaTime();
        owf_expanded = YES;
        [owf_panel orderFrontRegardless];
        owf_morph(owf_expanded_path, YES);
    });
}

// Recording has stopped and the transcription runs: the timer stops, the wave
// rolls on its own, and the glow breathes until owf_ui_hide.
void owf_ui_processing(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!owf_expanded) {
            return;
        }

        CFTimeInterval now = CACurrentMediaTime();

        [CATransaction begin];
        [CATransaction setAnimationDuration:0.25];
        owf_dot.opacity = 0.3;

        for (int i = 0; i < owf_bar_count; i++) {
            CGFloat peak = owf_bar_min_height + (owf_bar_max_height - owf_bar_min_height) * 0.6 * owf_bar_weights[i];
            CABasicAnimation *roll = [CABasicAnimation animationWithKeyPath:@"bounds.size.height"];
            roll.fromValue = @(owf_bar_min_height);
            roll.toValue = @(peak);
            roll.duration = 0.45;
            roll.autoreverses = YES;
            roll.repeatCount = HUGE_VALF;
            roll.beginTime = now + i * 0.08;
            roll.fillMode = kCAFillModeBackwards;
            roll.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            owf_bars[i].bounds = CGRectMake(0, 0, owf_bar_width, owf_bar_min_height);
            [owf_bars[i] addAnimation:roll forKey:@"think"];
        }

        CABasicAnimation *breathe = [CABasicAnimation animationWithKeyPath:@"opacity"];
        breathe.fromValue = @(owf_glow_rest * 0.7);
        breathe.toValue = @(owf_glow_peak);
        breathe.duration = 0.7;
        breathe.autoreverses = YES;
        breathe.repeatCount = HUGE_VALF;
        breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [owf_bloom addAnimation:breathe forKey:@"think"];

        [CATransaction commit];
    });
}

void owf_ui_hide(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!owf_expanded) {
            return;
        }

        owf_expanded = NO;
        owf_morph(owf_collapsed_path, NO);
    });
}

void owf_ui_set_level(double level) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!owf_expanded) {
            return;
        }

        // Fast attack, slow release keeps the bars from flickering.
        owf_level = fmax(level, owf_level * 0.85);

        [CATransaction begin];
        [CATransaction setAnimationDuration:0.08];
        owf_set_bar_heights(owf_level);
        // The glow swells with the voice.
        owf_bloom.opacity = owf_glow_rest + (owf_glow_peak - owf_glow_rest) * sqrt(owf_level);
        [CATransaction commit];

        int seconds = (int)(CACurrentMediaTime() - owf_started_at);

        if (seconds != owf_timer_seconds) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            owf_set_timer(seconds);
            [CATransaction commit];
        }
    });
}
