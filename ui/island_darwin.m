#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>

#include <math.h>

#include "native_darwin.h"

// Layout in points. The black island grows out of the notch into two ears: a
// recording dot with a timer left of the camera, the voice wave right of it.
// A soft spectrum of light traces the silhouette and swells with the voice.
static const CGFloat owf_ear_width = 76;
static const CGFloat owf_notchless_gap = 12;
static const CGFloat owf_notchless_height = 38;
static const CGFloat owf_notch_radius = 8;
static const CGFloat owf_island_radius = 14;
static const CGFloat owf_shoulder_radius = 6;
static const CGFloat owf_margin = 56;
static const CGFloat owf_glow_bloom_width = 16;
static const CGFloat owf_glow_blur = 12;
static const CFTimeInterval owf_glow_period = 5;
// Glow opacity in silence and at full voice.
static const float owf_glow_rest = 0.50;
static const float owf_glow_peak = 0.80;
static const CGFloat owf_dot_size = 6;
static const CGFloat owf_dot_gap = 6;
// One size and weight for every word on the island.
static const CGFloat owf_font_size = 13;
static const CGFloat owf_bar_width = 2;
static const CGFloat owf_bar_gap = 2.5;
static const CGFloat owf_bar_min_height = 3;
static const CGFloat owf_bar_max_height = 19;
static const CGFloat owf_bar_weights[] = {0.3, 0.5, 0.75, 0.9, 1.0, 0.9, 0.75, 0.5, 0.3};
// Space between "Correction" and its number, from the island's sides to the
// ears' content, and at least between that content and the notch.
static const CGFloat owf_fix_gap = 4;
static const CGFloat owf_fix_padding = 22;
static const CGFloat owf_fix_notch_gap = 12;
// The row under the notch that shows the correction, how far below the notch
// its words are centered, and the island's corner radius around it; the words
// get a little more room below, where the corners round off.
static const CGFloat owf_fix_row_height = 40;
static const CGFloat owf_fix_row_middle = 18;
static const CGFloat owf_fix_radius = 20;
// How long a correction result stays in view before the island folds away.
static const int64_t owf_result_time = 1200 * NSEC_PER_MSEC;

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
static CAShapeLayer *owf_edge;
static CAGradientLayer *owf_sheen;
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
static CALayer *owf_fix_label;
static CALayer *owf_fix_number;
static CALayer *owf_fix_status;
static CALayer *owf_fix_row;
static CGPathRef owf_collapsed_path;
static CGPathRef owf_expanded_path;
static CGPathRef owf_correction_path;
// Where the correction look starts its left ear's content, ends its right
// ear's, and centers its row, how wide the row may be, and the screen scale;
// set by owf_layout.
static CGPoint owf_fix_left;
static CGPoint owf_fix_right;
static CGPoint owf_fix_row_center;
static CGFloat owf_fix_row_width;
static CGFloat owf_scale;
static CFTimeInterval owf_started_at;
static int owf_timer_seconds;
static double owf_level;
static BOOL owf_expanded;
static BOOL owf_processing;
static BOOL owf_correcting;
// Counts corrections, so the fold scheduled after one skips a later one.
static unsigned owf_fix_count;

static BOOL owf_reduce_motion(void) {
    return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
}

NSArray *owf_palette(BOOL loop) {
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
    return [NSFont monospacedDigitSystemFontOfSize:owf_font_size weight:NSFontWeightRegular];
}

// Marks words that owf_rich_set draws in the glow's colors.
static NSString *const owf_gradient_key = @"OWFGradient";

// Words of the correction look in white at alpha, or in the glow's colors when gradient.
static NSAttributedString *owf_words(NSString *text, CGFloat alpha, BOOL gradient) {
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    attributes[NSFontAttributeName] = [NSFont systemFontOfSize:owf_font_size];
    attributes[NSForegroundColorAttributeName] = [NSColor colorWithWhite:1 alpha:alpha];

    if (gradient) {
        attributes[owf_gradient_key] = @YES;
    }

    return [[[NSAttributedString alloc] initWithString:text attributes:attributes] autorelease];
}

static NSString *owf_number(int number) {
    return [NSString stringWithFormat:owf_text(@"#%d"), number];
}

static void owf_set_bar_heights(CGFloat level) {
    CFTimeInterval now = CACurrentMediaTime();

    for (int i = 0; i < owf_bar_count; i++) {
        // A ripple travels across the bars: it shapes the voice level and keeps
        // a faint breathing motion in silence, so the wave never looks frozen.
        CGFloat ripple = owf_reduce_motion() ? 0.5 : 0.5 + 0.5 * sin(now * 7 + i * 0.9);
        // The square root lifts ordinary speech, which sits mid-scale, toward the full height.
        CGFloat voice = sqrt(level) * owf_bar_weights[i] * (0.65 + 0.35 * ripple);
        CGFloat scale = fmin(1, fmax(voice, 0.12 * ripple));
        CGFloat height = owf_bar_min_height + (owf_bar_max_height - owf_bar_min_height) * scale;
        owf_bars[i].transform = CATransform3DMakeScale(1, height / owf_bar_max_height, 1);
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
    owf_processing = NO;
    owf_correcting = NO;
    owf_dot.hidden = NO;
    owf_timer.hidden = NO;
    owf_wave.hidden = NO;
    for (CALayer *layer in @[owf_fix_label, owf_fix_number, owf_fix_status, owf_fix_row]) {
        layer.hidden = YES;
        [layer removeAllAnimations];
    }

    owf_dot.opacity = 1;
    owf_timer.opacity = 1;
    owf_dot.backgroundColor = [NSColor colorWithSRGBRed:0.98 green:0.40 blue:0.36 alpha:1].CGColor;
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

    // A notched display keeps the indicator within the menu bar. Other screens
    // use a floating capsule with a consistent minimum height.
    CGFloat menuBarHeight = NSMaxY(frame) - NSMaxY(screen.visibleFrame);
    CGFloat height = notchHeight > 0 ? fmax(notchHeight, menuBarHeight) : fmax(owf_notchless_height, menuBarHeight);

    if (height == 0) {
        height = owf_notchless_height;
    }

    CGFloat gap = notchHeight > 0 ? notchWidth : owf_notchless_gap;
    CGFloat width = gap + 2 * owf_ear_width;

    // The correction look widens the ears to fit its words in the chosen
    // language and adds a row under the notch.
    CGFloat leftWords = owf_words(owf_text(@"Correction"), 1, NO).size.width + owf_fix_gap +
                        owf_words(owf_number(9999), 1, NO).size.width;
    CGFloat rightWords = fmax(
        owf_words(owf_text(@"Saving…"), 1, NO).size.width,
        fmax(owf_words(owf_text(@"Saved"), 1, NO).size.width, owf_words(owf_text(@"Not saved"), 1, NO).size.width)
    );
    CGFloat fixEar = fmax(owf_ear_width, ceil(fmax(leftWords, rightWords)) + owf_fix_padding + owf_fix_notch_gap);
    CGFloat fixWidth = gap + 2 * fixEar;
    CGFloat fixHeight = height + owf_fix_row_height;

    // The panel fits the larger of both looks.
    CGFloat panelWidth = fmax(width, fixWidth);
    CGFloat inset = owf_shoulder_radius + owf_margin;
    NSRect panelFrame = NSMakeRect(
        notchCenter - panelWidth / 2 - inset,
        NSMaxY(frame) - fixHeight - owf_margin,
        panelWidth + 2 * inset,
        fixHeight + owf_margin
    );
    [owf_panel setFrame:panelFrame display:NO];

    CGRect bounds = CGRectMake(0, 0, panelFrame.size.width, panelFrame.size.height);
    CGFloat cx = bounds.size.width / 2;
    CGFloat top = bounds.size.height;
    CGFloat middle = top - height / 2;
    CGFloat scale = screen.backingScaleFactor;

    CGPathRelease(owf_collapsed_path);
    CGPathRelease(owf_expanded_path);
    CGPathRelease(owf_correction_path);
    owf_collapsed_path = owf_island_path(
        cx, top, notchWidth, notchHeight, notchHeight > 0 ? owf_notch_radius : 0, 0
    );
    if (notchHeight > 0) {
        owf_expanded_path = owf_island_path(cx, top, width, height, owf_island_radius, owf_shoulder_radius);
        owf_correction_path = owf_island_path(cx, top, fixWidth, fixHeight, owf_fix_radius, owf_shoulder_radius);
    } else {
        // An independent floating capsule on external displays, with room above its rim.
        top -= 8;
        middle -= 8;
        CGPathRelease(owf_collapsed_path);
        owf_collapsed_path = CGPathCreateWithRoundedRect(CGRectMake(cx - 24, top - height, 48, height), height / 2, height / 2, NULL);
        owf_expanded_path = CGPathCreateWithRoundedRect(CGRectMake(cx - width / 2, top - height, width, height), height / 2, height / 2, NULL);
        owf_correction_path = CGPathCreateWithRoundedRect(
            CGRectMake(cx - fixWidth / 2, top - fixHeight, fixWidth, fixHeight), height / 2, height / 2, NULL
        );
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    for (CALayer *layer in @[owf_island, owf_content, owf_glow, owf_bloom, owf_ring, owf_sheen]) {
        layer.frame = bounds;
    }

    for (CAShapeLayer *shape in @[owf_mask, owf_bloom_mask, owf_edge]) {
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

    // Dot and timer as one group, centered in the left ear.
    NSSize timerSize = [@"0:00" sizeWithAttributes:@{NSFontAttributeName: owf_timer_font()}];
    CGFloat timerWidth = [@"00:00" sizeWithAttributes:@{NSFontAttributeName: owf_timer_font()}].width;
    CGFloat groupWidth = owf_dot_size + owf_dot_gap + timerWidth;
    CGFloat groupLeft = cx - gap / 2 - owf_ear_width / 2 - groupWidth / 2;
    owf_dot.position = CGPointMake(groupLeft + owf_dot_size / 2, middle);
    owf_timer.frame = CGRectMake(
        groupLeft + owf_dot_size + owf_dot_gap,
        middle - timerSize.height / 2,
        timerWidth + 8,
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

    // The correction look; owf_fix_place arranges it around these points.
    // The ears' content keeps to the island's sides, so both stay the same
    // distance from them whatever their width in each state and language.
    owf_fix_left = CGPointMake(cx - gap / 2 - fixEar + owf_fix_padding, middle);
    owf_fix_right = CGPointMake(cx + gap / 2 + fixEar - owf_fix_padding, middle);
    owf_fix_row_center = CGPointMake(cx, top - height - owf_fix_row_middle);
    owf_fix_row_width = fixWidth - 2 * (owf_fix_radius + 4);
    owf_scale = scale;

    [CATransaction commit];
}

// Morphs the outline and fades content and glow: in after the island has started
// to grow, out before it shrinks, so nothing is clipped halfway.
static void owf_morph(CGPathRef target, BOOL expand) {
    BOOL reduce = owf_reduce_motion();
    // Reduce Motion suppresses bounce and ambient loops, but keeps a short,
    // continuous reveal instead of making the island abruptly pop into place.
    // Without an animation in flight the presentation layer may be stale.
    CAShapeLayer *presentation = owf_mask.presentationLayer;
    CGPathRef from = presentation != nil && [owf_mask animationForKey:@"path"] != nil
                         ? presentation.path
                         : owf_mask.path;
    CABasicAnimation *morph;

    if (expand && !reduce) {
        CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:@"path"];
        spring.mass = 1;
        spring.stiffness = 260;
        spring.damping = 22;
        spring.duration = spring.settlingDuration;
        morph = spring;
    } else {
        morph = [CABasicAnimation animationWithKeyPath:@"path"];
        morph.duration = expand ? 0.38 : 0.25;
        morph.beginTime = CACurrentMediaTime() + (expand ? 0 : 0.08);
        morph.fillMode = kCAFillModeBackwards;
        morph.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.4:0:0.2:1];
    }

    morph.fromValue = (id)from;
    morph.toValue = (id)target;

    CALayer *content = owf_content.presentationLayer ?: owf_content;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(content.opacity);
    fade.toValue = expand ? @1.0 : @0.0;
    fade.duration = expand ? (reduce ? 0.20 : 0.3) : 0.15;

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
                [owf_spin removeAllAnimations];
                [owf_dot removeAllAnimations];
                [owf_bloom removeAllAnimations];
                for (int i = 0; i < owf_bar_count; i++) [owf_bars[i] removeAllAnimations];
            }
        }];
    }

    for (CAShapeLayer *shape in @[owf_mask, owf_bloom_mask, owf_edge]) {
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

    // The same blur softens every edge; no directional mask dims the bottom.
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
    owf_dot.backgroundColor = [NSColor colorWithSRGBRed:0.98 green:0.40 blue:0.36 alpha:1].CGColor;
    owf_dot.bounds = CGRectMake(0, 0, owf_dot_size, owf_dot_size);
    owf_dot.cornerRadius = owf_dot_size / 2;
    [owf_content addSublayer:owf_dot];

    owf_timer = [[CATextLayer alloc] init];
    owf_timer.font = (CFTypeRef)owf_timer_font();
    owf_timer.fontSize = owf_font_size;
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
        owf_bars[i].bounds = CGRectMake(0, 0, owf_bar_width, owf_bar_max_height);
        [owf_wave.mask addSublayer:owf_bars[i]];
    }
}

// A line of text: its plain words, and the glow's gradient seen through the
// words marked with owf_gradient_key, both drawn by owf_rich_set.
static CALayer *owf_rich_layer(void) {
    CALayer *rich = [[CALayer alloc] init];
    CAGradientLayer *gradient = [[CAGradientLayer alloc] init];
    gradient.colors = owf_palette(NO);
    gradient.startPoint = CGPointMake(0, 0.5);
    gradient.endPoint = CGPointMake(1, 0.5);
    gradient.mask = [[CALayer alloc] init];
    rich.hidden = YES;
    [rich addSublayer:[[CALayer alloc] init]];
    [rich addSublayer:gradient];

    return rich;
}

// Draws text on one line into rich, truncated to width, and sizes rich to it.
static void owf_rich_set(CALayer *rich, NSAttributedString *text, CGFloat width) {
    NSMutableAttributedString *line = [[text mutableCopy] autorelease];
    NSMutableParagraphStyle *style = [[[NSMutableParagraphStyle alloc] init] autorelease];
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    [line addAttribute:NSParagraphStyleAttributeName value:style range:NSMakeRange(0, line.length)];

    NSStringDrawingOptions options = NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine;
    NSRect fit = [line boundingRectWithSize:NSMakeSize(width, CGFLOAT_MAX) options:options];
    NSSize size = NSMakeSize(fmin(ceil(fit.size.width), width), ceil(fit.size.height));
    CGRect bounds = CGRectMake(0, 0, size.width, size.height);
    CALayer *plain = rich.sublayers[0];
    CAGradientLayer *gradient = (CAGradientLayer *)rich.sublayers[1];

    // The same line twice, each time with the other part made clear, so both
    // images share one layout.
    for (int marked = 0; marked < 2; marked++) {
        NSMutableAttributedString *part = [[line mutableCopy] autorelease];
        [line enumerateAttribute:owf_gradient_key
                         inRange:NSMakeRange(0, line.length)
                         options:0
                      usingBlock:^(id value, NSRange range, BOOL *stop) {
            if ((value != nil) != marked) {
                [part addAttribute:NSForegroundColorAttributeName value:NSColor.clearColor range:range];
                [part addAttribute:NSStrikethroughColorAttributeName value:NSColor.clearColor range:range];
            }
        }];

        NSImage *image = [NSImage imageWithSize:size flipped:YES drawingHandler:^BOOL(NSRect rect) {
            [part drawWithRect:rect options:options];
            return YES;
        }];
        CALayer *layer = marked ? gradient.mask : plain;
        CGFloat scale = [image recommendedLayerContentsScale:owf_scale];
        layer.contents = [image layerContentsForContentsScale:scale];
        layer.contentsScale = scale;
        layer.frame = bounds;
    }

    gradient.frame = bounds;
    rich.bounds = bounds;
}

// Places layer with its left edge at left, centered on y, on whole pixels.
static void owf_place(CALayer *layer, CGFloat left, CGFloat y) {
    CGSize size = layer.bounds.size;
    layer.frame = CGRectMake(
        round(left * owf_scale) / owf_scale, round((y - size.height / 2) * owf_scale) / owf_scale, size.width, size.height
    );
}

// Lines up the words of each ear, and centers the row, after their content changed.
static void owf_fix_place(void) {
    owf_place(owf_fix_label, owf_fix_left.x, owf_fix_left.y);
    owf_place(owf_fix_number, owf_fix_left.x + owf_fix_label.bounds.size.width + owf_fix_gap, owf_fix_left.y);
    owf_place(owf_fix_status, owf_fix_right.x - owf_fix_status.bounds.size.width, owf_fix_right.y);

    owf_place(owf_fix_row, owf_fix_row_center.x - owf_fix_row.bounds.size.width / 2, owf_fix_row_center.y);
}

// The correction look, in words only: "Correction" in the left ear, the status
// in the right one, and under the notch the corrected words or why none were
// saved. Once saved, the number of the correction follows "Correction", and
// the glow's colors mark the status and the corrected words.
static void owf_correction_setup(void) {
    owf_fix_label = owf_rich_layer();
    owf_fix_number = owf_rich_layer();
    owf_fix_status = owf_rich_layer();
    owf_fix_row = owf_rich_layer();

    for (CALayer *layer in @[owf_fix_label, owf_fix_number, owf_fix_status, owf_fix_row]) {
        [owf_content addSublayer:layer];
    }
}

// Rolls the bars and breathes the glow to show work in progress, until owf_reset_state.
// Progress must stay visible under Reduce Motion: the bars then stand still
// and a wave of light runs across them instead, since fades are not motion.
static void owf_think(void) {
    CFTimeInterval now = CACurrentMediaTime();
    BOOL reduce = owf_reduce_motion();

    for (int i = 0; i < owf_bar_count; i++) {
        CGFloat peak = owf_bar_min_height + (owf_bar_max_height - owf_bar_min_height) * 0.6 * owf_bar_weights[i];
        CABasicAnimation *roll = [CABasicAnimation animationWithKeyPath:reduce ? @"opacity" : @"transform.scale.y"];
        roll.fromValue = reduce ? @0.25 : @(owf_bar_min_height / owf_bar_max_height);
        roll.toValue = reduce ? @1.0 : @(peak / owf_bar_max_height);
        roll.duration = 0.45;
        roll.autoreverses = YES;
        roll.repeatCount = HUGE_VALF;
        roll.beginTime = now + i * 0.08;
        roll.fillMode = kCAFillModeBackwards;
        roll.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        owf_bars[i].transform = CATransform3DMakeScale(1, peak / owf_bar_max_height, 1);
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
}

// Restart each recording so a previous processing state cannot leave motion stopped.
static void owf_start_motion(void) {
    if (owf_reduce_motion()) return;
    CABasicAnimation *rotate = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    rotate.fromValue = @0;
    rotate.toValue = @(-2 * M_PI);
    rotate.duration = owf_glow_period;
    rotate.repeatCount = HUGE_VALF;
    [owf_spin addAnimation:rotate forKey:@"spin"];
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    pulse.fromValue = @1.0;
    pulse.toValue = @0.7;
    pulse.duration = 0.8;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [owf_dot addAnimation:pulse forKey:@"pulse"];
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

    // A restrained reflection at the lower edge keeps the camera area truly black.
    owf_sheen = [[CAGradientLayer alloc] init];
    owf_sheen.colors = @[(id)[NSColor colorWithWhite:0.18 alpha:0.35].CGColor,
                         (id)CGColorGetConstantColor(kCGColorClear)];
    owf_sheen.startPoint = CGPointMake(0.5, 0);
    owf_sheen.endPoint = CGPointMake(0.5, 1);
    [owf_island addSublayer:owf_sheen];
    owf_edge = owf_stroke(0.75);
    owf_edge.strokeColor = [NSColor colorWithWhite:1 alpha:0.10].CGColor;
    [owf_island addSublayer:owf_edge];

    owf_content = [[CALayer alloc] init];
    [owf_island addSublayer:owf_content];

    owf_indicator_setup();
    owf_wave_setup();
    owf_correction_setup();
    // Respond immediately if Reduce Motion is enabled while dictating.
    [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                                                               object:nil queue:NSOperationQueue.mainQueue
                                                           usingBlock:^(NSNotification *note) {
        if (owf_reduce_motion()) {
            for (CALayer *layer in @[owf_spin, owf_dot, owf_bloom, owf_mask, owf_bloom_mask, owf_edge, owf_content, owf_glow]) {
                [layer removeAllAnimations];
            }
            for (int i = 0; i < owf_bar_count; i++) [owf_bars[i] removeAllAnimations];
            if (!owf_expanded) [owf_panel orderOut:nil];
        }
    }];
}

void owf_ui_show(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // A correction result gives way to a new recording at once.
        if (owf_expanded && !owf_correcting) {
            return;
        }

        // Mid-collapse the geometry is still valid; morph back from the current outline.
        if (!owf_panel.visible) {
            owf_layout();
        }

        // Resume ambient animations only while the indicator is visible.
        owf_reset_state();
        owf_start_motion();
        [owf_panel.contentView setAccessibilityElement:YES];
        [owf_panel.contentView setAccessibilityRole:NSAccessibilityStaticTextRole];
        [owf_panel.contentView setAccessibilityLabel:owf_text(@"Recording")];
        owf_started_at = CACurrentMediaTime();
        owf_expanded = YES;
        [owf_panel orderFrontRegardless];
        owf_morph(owf_expanded_path, YES);
    });
}

// Recording has stopped and transcription runs: the light turns silver, the timer stops
// and dims, the wave rolls on its own, and the glow breathes until owf_ui_hide.
void owf_ui_processing(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!owf_expanded) {
            return;
        }

        owf_processing = YES;

        [CATransaction begin];
        [CATransaction setAnimationDuration:owf_reduce_motion() ? 0 : 0.25];
        [owf_dot removeAnimationForKey:@"pulse"];
        owf_dot.opacity = 1;
        owf_dot.backgroundColor = [NSColor colorWithWhite:0.78 alpha:1].CGColor;
        // A dimmed final time reads as done; an ellipsis next to the dot read as four dots.
        owf_timer.opacity = 0.5;
        [owf_panel.contentView setAccessibilityLabel:owf_text(@"Transcribing")];
        owf_think();
        [CATransaction commit];
    });
}

void owf_ui_correcting(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (owf_expanded && !owf_correcting) {
            return;
        }

        if (!owf_panel.visible) {
            owf_layout();
        }

        owf_reset_state();
        owf_correcting = YES;
        owf_fix_count++;

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        owf_dot.hidden = YES;
        owf_timer.hidden = YES;
        owf_wave.hidden = YES;
        owf_rich_set(owf_fix_label, owf_words(owf_text(@"Correction"), 0.92, NO), CGFLOAT_MAX);
        owf_rich_set(owf_fix_status, owf_words(owf_text(@"Saving…"), 0.92, NO), CGFLOAT_MAX);
        owf_rich_set(
            owf_fix_row, owf_words(owf_text(@"Comparing with dictation"), 0.5, NO), owf_fix_row_width
        );

        for (CALayer *layer in @[owf_fix_label, owf_fix_status, owf_fix_row]) {
            layer.hidden = NO;
        }

        owf_fix_place();
        owf_think();
        [CATransaction commit];

        // A fade, so it stays under Reduce Motion.
        CABasicAnimation *shimmer = [CABasicAnimation animationWithKeyPath:@"opacity"];
        shimmer.fromValue = @0.35;
        shimmer.toValue = @1.0;
        shimmer.duration = 0.8;
        shimmer.autoreverses = YES;
        shimmer.repeatCount = HUGE_VALF;
        shimmer.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [owf_fix_status addAnimation:shimmer forKey:@"shimmer"];
        [owf_fix_row addAnimation:shimmer forKey:@"shimmer"];

        owf_start_motion();
        [owf_panel.contentView setAccessibilityElement:YES];
        [owf_panel.contentView setAccessibilityRole:NSAccessibilityStaticTextRole];
        [owf_panel.contentView setAccessibilityLabel:owf_text(@"Saving correction")];

        if (!owf_expanded) {
            owf_expanded = YES;
            [owf_panel orderFrontRegardless];
            owf_morph(owf_correction_path, YES);
        }
    });
}

// Replaces the saving state with the outcome: number, if not nil, after
// "Correction", the status, and row under the notch; then folds the island away.
static void owf_fix_result(BOOL saved, NSString *number, NSAttributedString *row) {
    unsigned correction = owf_fix_count;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [owf_bloom removeAnimationForKey:@"think"];
    [owf_fix_status removeAnimationForKey:@"shimmer"];
    [owf_fix_row removeAnimationForKey:@"shimmer"];
    owf_fix_number.hidden = number == nil;

    if (number != nil) {
        owf_rich_set(owf_fix_number, owf_words(number, 0.92, NO), CGFLOAT_MAX);
    }

    owf_rich_set(
        owf_fix_status,
        saved ? owf_words(owf_text(@"Saved"), 1, YES)
              : owf_words(owf_text(@"Not saved"), 0.5, NO),
        CGFLOAT_MAX
    );
    owf_rich_set(owf_fix_row, row, owf_fix_row_width);
    owf_fix_place();
    [CATransaction commit];

    [owf_panel.contentView setAccessibilityLabel:owf_text(saved ? @"Correction saved" : @"Correction not saved")];

    if (!owf_reduce_motion()) {
        if (saved) {
            CASpringAnimation *pop = [CASpringAnimation animationWithKeyPath:@"transform.scale"];
            pop.fromValue = @0.4;
            pop.toValue = @1.0;
            pop.stiffness = 300;
            pop.damping = 15;
            pop.duration = pop.settlingDuration;
            [owf_fix_number addAnimation:pop forKey:@"pop"];
            [owf_fix_status addAnimation:pop forKey:@"pop"];
        } else {
            CAKeyframeAnimation *shake = [CAKeyframeAnimation animationWithKeyPath:@"position.x"];
            shake.values = @[@0, @-4, @4, @-4, @4, @0];
            shake.additive = YES;
            shake.duration = 0.35;
            [owf_fix_status addAnimation:shake forKey:@"shake"];
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, owf_result_time), dispatch_get_main_queue(), ^{
        // A later correction or a recording owns the island by now.
        if (owf_correcting && owf_fix_count == correction) {
            owf_correcting = NO;
            owf_expanded = NO;
            owf_morph(owf_collapsed_path, NO);
        }
    });
}

void owf_ui_corrected(int number, const char *segments) {
    NSData *json = [NSData dataWithBytes:segments length:strlen(segments)];
    NSArray *parts = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!owf_correcting) {
            return;
        }

        NSMutableAttributedString *row = [[[NSMutableAttributedString alloc] init] autorelease];

        for (NSDictionary *part in parts) {
            int kind = [part[@"kind"] intValue];

            if (row.length > 0) {
                [row appendAttributedString:owf_words(@" ", 1, NO)];
            }

            // Kept words stay quiet, removed ones are struck through, added ones glow.
            NSMutableAttributedString *words = [[owf_words(
                part[@"text"], kind == 0 ? 0.75 : kind == 1 ? 0.4 : 1, kind == 2
            ) mutableCopy] autorelease];

            if (kind == 1) {
                NSRange all = NSMakeRange(0, words.length);
                [words addAttribute:NSStrikethroughStyleAttributeName value:@(NSUnderlineStyleSingle) range:all];
                [words addAttribute:NSStrikethroughColorAttributeName value:[NSColor colorWithWhite:1 alpha:0.4] range:all];
            }

            [row appendAttributedString:words];
        }

        owf_fix_result(YES, number > 0 ? owf_number(number) : nil, row);
    });
}

void owf_ui_not_corrected(const char *reason) {
    NSString *english = @(reason);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (owf_correcting) {
            owf_fix_result(NO, nil, owf_words(owf_text(english), 0.5, NO));
        }
    });
}

void owf_ui_hide(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!owf_expanded) {
            return;
        }

        owf_expanded = NO;
        owf_processing = NO;
        owf_morph(owf_collapsed_path, NO);
    });
}

void owf_ui_set_level(double level) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!owf_expanded) {
            return;
        }

        if (owf_processing) return;
        double input = fmin(1, fmax(0, level));

        // Fast attack, slow release keeps the bars from flickering.
        owf_level = fmax(input, owf_level * 0.85);

        [CATransaction begin];
        [CATransaction setAnimationDuration:owf_reduce_motion() ? 0 : 0.08];
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
