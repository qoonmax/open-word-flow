#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>

#include <math.h>

#include "native_darwin.h"

// Layout in points. The black island grows out of the notch into two ears: a
// recording dot with a timer left of the camera, the voice wave right of it.
// A soft spectrum of light traces the silhouette and swells with the voice.
// A theme may instead hang a floating card under the notch; see OWFIsland.
static const CGFloat owf_ear_width = 76;
static const CGFloat owf_notchless_gap = 12;
static const CGFloat owf_notchless_height = 38;
static const CGFloat owf_notch_radius = 8;
static const CGFloat owf_shoulder_radius = 6;
static const CGFloat owf_margin = 56;
static const CGFloat owf_glow_bloom_width = 16;
static const CGFloat owf_glow_blur = 12;
static const CFTimeInterval owf_glow_period = 5;
// Glow opacity in silence and at full voice.
static const float owf_glow_rest = 0.50;
static const float owf_glow_peak = 0.80;
// One size and weight for every word on the island but the timer.
static const CGFloat owf_font_size = 13;
static const CGFloat owf_bar_min_height = 3;
// A floating card's bars stand at full height; a voice shrinks one of them
// toward rest, from quiet, an input level above the room's hum, to loud, and
// the small one runs left and right, so many bars a second. It moves only
// with a voice, so it keeps moving under Reduce Motion.
static const CGFloat owf_card_bar_rest = 0.35;
static const CGFloat owf_card_dip_quiet = 0.15;
static const CGFloat owf_card_dip_loud = 0.5;
static const CGFloat owf_card_dip_speed = 10;
// A card's word while transcribing, the room between it and the beads and
// between beads, and how high the beads bounce.
static const CGFloat owf_busy_font_size = 18;
static const CGFloat owf_busy_gap = 14;
static const CGFloat owf_bead_size = 12;
static const CGFloat owf_bead_gap = 6;
static const CGFloat owf_bead_bounce = 7;
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
// A floating card overlaps the notch's bottom edge by overlap. Recording, it
// is a capsule of card width and height with its content padded from the
// ends; the correction look is fix width and height, with the words' row
// centered row below its top and the header above them. Its outline and hard
// shadow are in points.
static const CGFloat owf_card_overlap = 7;
static const CGFloat owf_card_width = 300;
static const CGFloat owf_card_height = 58;
static const CGFloat owf_card_padding = 20;
static const CGFloat owf_card_fix_width = 400;
static const CGFloat owf_card_fix_height = 90;
static const CGFloat owf_card_header = 28;
static const CGFloat owf_card_row = 62;
static const CGFloat owf_card_outline = 2.5;
static const CGSize owf_card_shadow = {4, -5};
// How long a correction result stays in view before the island folds away.
static const int64_t owf_result_time = 1200 * NSEC_PER_MSEC;

enum {
    owf_bar_max = 12,
    owf_card_bar_count = 7,
    owf_bead_count = 3,
};

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
static CAShapeLayer *owf_shadow;
static CAGradientLayer *owf_sheen;
static CALayer *owf_content;
static CALayer *owf_glow;
static CALayer *owf_bloom;
static CAShapeLayer *owf_bloom_mask;
static CALayer *owf_ring;
static CAGradientLayer *owf_spin;
static CALayer *owf_dot;
static CATextLayer *owf_timer;
static CALayer *owf_wave;
static CALayer *owf_bars[owf_bar_max];
static CALayer *owf_busy;
static CATextLayer *owf_busy_word;
static CALayer *owf_beads[owf_bead_count];
// Layout A+'s: soft lights behind the island, and while transcribing a
// spinning ring beside a word.
static CALayer *owf_lights;
static CALayer *owf_spinner;
static CATextLayer *owf_spin_word;
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
// A floating card's center, top, and width in its correction look.
static CGFloat owf_card_cx, owf_card_top, owf_card_fix_w;
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

// How many bars the wave shows.
static int owf_bar_count(void) {
    const OWFIsland *style = &owf_theme()->island;
    return style->floating ? owf_card_bar_count : style->bars > 0 ? style->bars : 9;
}

// How tall bar i of n rises at full voice: most in the middle, least at the ends.
static CGFloat owf_bar_weight(int i, int n) {
    return 0.3 + 0.7 * sin(M_PI * i / (n - 1));
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
    // Quarter circles as cubic curves, their control points this far in.
    CGFloat s = shoulder * 0.448, r = radius * 0.448;
    CGMutablePathRef path = CGPathCreateMutable();

    CGPathMoveToPoint(path, NULL, left - shoulder, top);
    CGPathAddCurveToPoint(path, NULL, left - s, top, left, top - s, left, top - shoulder);
    CGPathAddLineToPoint(path, NULL, left, bottom + radius);
    CGPathAddCurveToPoint(path, NULL, left, bottom + r, left + r, bottom, left + radius, bottom);
    CGPathAddLineToPoint(path, NULL, right - radius, bottom);
    CGPathAddCurveToPoint(path, NULL, right - r, bottom, right, bottom + r, right, bottom + radius);
    CGPathAddLineToPoint(path, NULL, right, top - shoulder);
    CGPathAddCurveToPoint(path, NULL, right, top - s, right + s, top, right + shoulder, top);

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
    const OWFTheme *theme = owf_theme();
    CGFloat size = theme->island.timer_size;

    if (theme->island.floating) {
        return owf_display_font(size);
    }

    if (theme->island.mono != nil) {
        return owf_family(theme->island.mono, NSFontWeightMedium, size);
    }

    // A themed design such as monospaced has fixed-width digits of its own.
    return theme->font == nil ? [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightRegular]
                              : owf_font(size, NSFontWeightRegular);
}

// Marks words that owf_rich_set draws in the glow's colors.
static NSString *const owf_gradient_key = @"OWFGradient";

// Words of the correction look in ink at alpha, or in the marks' colors when gradient.
static NSAttributedString *owf_words(NSString *text, CGFloat alpha, BOOL gradient) {
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    attributes[NSFontAttributeName] = owf_font(owf_font_size, NSFontWeightRegular);
    attributes[NSForegroundColorAttributeName] = [owf_theme()->island.ink colorWithAlphaComponent:alpha];

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
    const OWFIsland *style = &owf_theme()->island;
    CGFloat max = style->bar_height;

    if (style->floating) {
        // Steps from the first bar to the last and back.
        int span = owf_card_bar_count - 1;
        long dip = span - labs((long)(now * owf_card_dip_speed) % (2 * span) - span);
        CGFloat voice = fmin(1, fmax(0, (level - owf_card_dip_quiet) / (owf_card_dip_loud - owf_card_dip_quiet)));

        for (int i = 0; i < owf_card_bar_count; i++) {
            CGFloat scale = i == dip ? 1 - (1 - owf_card_bar_rest) * voice : 1;
            owf_bars[i].transform = CATransform3DMakeScale(1, scale, 1);
        }

        return;
    }

    int bars = owf_bar_count();
    for (int i = 0; i < bars; i++) {
        // A ripple travels across the bars: it shapes the voice level and keeps
        // a faint breathing motion in silence, so the wave never looks frozen.
        CGFloat ripple = owf_reduce_motion() ? 0.5 : 0.5 + 0.5 * sin(now * 7 + i * 0.9);
        // The square root lifts ordinary speech, which sits mid-scale, toward the full height.
        CGFloat voice = sqrt(level) * owf_bar_weight(i, bars) * (0.65 + 0.35 * ripple);
        CGFloat scale = fmin(1, fmax(voice, 0.12 * ripple));
        CGFloat height = owf_bar_min_height + (max - owf_bar_min_height) * scale;
        owf_bars[i].transform = CATransform3DMakeScale(1, height / max, 1);
    }
}

static void owf_set_timer(int seconds) {
    owf_timer_seconds = seconds;
    owf_timer.string = [NSString stringWithFormat:@"%d:%02d", seconds / 60, seconds % 60];
}

// Paints the island for state: 0 recording, 1 transcribing, 2 correction. A
// floating card also casts its shadow, or the alert one, and tilts by degrees
// clockwise, as CSS rotates in the design.
static void owf_paint(int state, BOOL alert, CGFloat degrees) {
    const OWFIsland *style = &owf_theme()->island;
    owf_island.backgroundColor = style->fill[state].CGColor;
    owf_shadow.fillColor = (alert ? style->alert : style->shadow).CGColor;
    owf_panel.contentView.layer.sublayerTransform =
        style->floating ? CATransform3DMakeRotation(-degrees * M_PI / 180, 0, 0, 1) : CATransform3DIdentity;
}

static BOOL owf_halo(void) {
    return owf_theme()->island.halo[0] != nil;
}

// Layout A+'s lights for state: 0 recording, 1 transcribing, 2 a correction,
// 3 one not saved. Each is a color of the halo, its alpha, offset, and blur,
// as CSS box-shadow casts them from the island's outline. They are drawn,
// blurred by Core Image, so snapshots hold them as the screen does.
static void owf_halo_paint(int state) {
    const OWFIsland *style = &owf_theme()->island;
    const struct { int color; CGFloat alpha, x, y; } lights[4][2] = {
        {{0, 0.45, -36, 10}, {1, 0.38, 36, 10}},
        {{0, 0.40, 0, 10}, {-1}},
        {{0, 0.42, -40, 12}, {1, 0.34, 40, 12}},
        {{1, 0.22, 0, 12}, {-1}},
    };
    const CGFloat blurs[4] = {48, 44, 52, 44};

    owf_lights.hidden = !owf_halo();
    if (owf_lights.hidden) {
        return;
    }

    CGPathRef shape = state < 2 ? owf_expanded_path : owf_correction_path;
    CGSize size = owf_lights.bounds.size;
    size_t width = ceil(size.width * owf_scale), height = ceil(size.height * owf_scale);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextScaleCTM(bitmap, owf_scale, owf_scale);

    for (int i = 0; i < 2; i++) {
        if (lights[state][i].color < 0) continue;
        CGContextSaveGState(bitmap);
        // Down is negative on the panel.
        CGContextTranslateCTM(bitmap, lights[state][i].x, -lights[state][i].y);
        CGContextAddPath(bitmap, shape);
        CGContextSetFillColorWithColor(bitmap, [style->halo[lights[state][i].color]
                                                colorWithAlphaComponent:lights[state][i].alpha].CGColor);
        CGContextFillPath(bitmap);
        CGContextRestoreGState(bitmap);
    }

    CGImageRef lit = CGBitmapContextCreateImage(bitmap);
    // CSS blurs with a standard deviation of half the blur radius.
    CIImage *blurred = [[CIImage imageWithCGImage:lit] imageByApplyingGaussianBlurWithSigma:blurs[state] / 2 * owf_scale];
    CIContext *context = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: (id)space}];
    CGImageRef image = [context createCGImage:blurred fromRect:CGRectMake(0, 0, width, height)];
    owf_lights.contents = (id)image;
    CGImageRelease(image);
    CGImageRelease(lit);
    CGContextRelease(bitmap);
    CGColorSpaceRelease(space);
}

// Returns the island to its recording look after a previous transcription.
static void owf_reset_state(void) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    for (int i = 0; i < owf_bar_max; i++) {
        [owf_bars[i] removeAnimationForKey:@"think"];
        owf_bars[i].opacity = 1;
        owf_bars[i].bounds = CGRectMake(0, 0, owf_bars[i].bounds.size.width, owf_theme()->island.bar_height);
    }

    for (int i = 0; i < owf_bead_count; i++) {
        [owf_beads[i] removeAnimationForKey:@"think"];
    }

    [owf_bloom removeAnimationForKey:@"think"];
    owf_processing = NO;
    owf_correcting = NO;
    owf_dot.hidden = NO;
    owf_timer.hidden = NO;
    owf_wave.hidden = NO;
    owf_busy.hidden = YES;
    owf_spinner.hidden = YES;
    owf_spin_word.hidden = YES;
    [owf_spinner removeAllAnimations];
    for (CALayer *layer in @[owf_fix_label, owf_fix_number, owf_fix_status, owf_fix_row]) {
        layer.hidden = YES;
        [layer removeAllAnimations];
    }

    owf_dot.opacity = 1;
    owf_timer.opacity = 1;
    owf_dot.backgroundColor = owf_theme()->island.dot.CGColor;
    owf_paint(0, NO, -1.5);
    owf_halo_paint(0);
    owf_bloom.opacity = owf_glow_rest;
    owf_level = 0;
    owf_set_bar_heights(0);
    owf_set_timer(0);

    [CATransaction commit];
}

static NSImage *owf_pieces_image(NSArray *pieces, CGFloat gap, CGFloat max);
static NSArray *owf_halo_reason(NSString *english);

// Places the panel around the notch of the current screen; displays may change between recordings.
static void owf_layout(void) {
    const OWFIsland *style = &owf_theme()->island;
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

    BOOL halo = owf_halo();
    CGFloat ear = style->ear > 0 ? style->ear : owf_ear_width;
    CGFloat shoulder = style->shoulder > 0 ? style->shoulder : owf_shoulder_radius;
    CGFloat gap = notchHeight > 0 ? notchWidth : owf_notchless_gap;
    CGFloat width = gap + 2 * ear;

    // The correction look widens the ears to fit its words in the chosen
    // language and adds a row under the notch.
    CGFloat leftWords = owf_words(owf_text(@"Correction"), 1, NO).size.width + owf_fix_gap +
                        owf_words(owf_number(9999), 1, NO).size.width;
    CGFloat rightWords = fmax(
        owf_words(owf_text(@"Saving…"), 1, NO).size.width,
        fmax(owf_words(owf_text(@"Saved"), 1, NO).size.width, owf_words(owf_text(@"Not saved"), 1, NO).size.width)
    );
    CGFloat fixEar = fmax(ear, ceil(fmax(leftWords, rightWords)) + owf_fix_padding + owf_fix_notch_gap);
    CGFloat fixWidth = gap + 2 * fixEar;
    CGFloat fixHeight = height + owf_fix_row_height;
    // A+ widens the island by 40 points, or to fit why nothing was saved in the
    // chosen language, and adds 37 points under the notch for a correction.
    if (halo) {
        CGFloat reason = owf_pieces_image(owf_halo_reason(@"Nothing selected"), 8, CGFLOAT_MAX).size.width;
        fixWidth = fmax(fmax(width + 40, fixWidth), ceil(reason) + 2 * 18);
        fixHeight = height + 37;
    }
    // How far below the top of the screen the island reaches.
    CGFloat depth = fixHeight;

    // A floating card clears the notch, so its words need no ears around it.
    if (style->floating) {
        width = owf_card_width;
        fixWidth = fmax(owf_card_fix_width, ceil(leftWords + rightWords) + 2 * owf_fix_padding + owf_fix_notch_gap);
        fixHeight = owf_card_fix_height;
        // Room for the tallest correction look, two lines under its header.
        depth = height - owf_card_overlap + 140 - owf_card_shadow.height;
    }

    // The panel fits the larger of both looks.
    CGFloat panelWidth = fmax(width, fixWidth);
    CGFloat inset = shoulder + owf_margin;
    NSRect panelFrame = NSMakeRect(
        notchCenter - panelWidth / 2 - inset,
        NSMaxY(frame) - depth - owf_margin,
        panelWidth + 2 * inset,
        depth + owf_margin
    );
    [owf_panel setFrame:panelFrame display:NO];

    CGRect bounds = CGRectMake(0, 0, panelFrame.size.width, panelFrame.size.height);
    CGFloat cx = bounds.size.width / 2;
    CGFloat top = bounds.size.height;
    CGFloat middle = top - height / 2;
    // Where the correction look's words sit, below the top of its shape.
    CGFloat fixTop = top;
    CGFloat fixHeader = height / 2;
    CGFloat fixRow = height + owf_fix_row_middle;
    CGFloat scale = screen.backingScaleFactor;

    CGPathRelease(owf_collapsed_path);
    CGPathRelease(owf_expanded_path);
    CGPathRelease(owf_correction_path);
    owf_collapsed_path = owf_island_path(
        cx, top, notchWidth, notchHeight, notchHeight > 0 ? owf_notch_radius : 0, 0
    );
    if (style->floating) {
        // Tucked into the notch, the card drops out of it and hangs below.
        CGFloat cardTop = top - height + owf_card_overlap;
        middle = cardTop - owf_card_height / 2;
        fixTop = cardTop;
        fixHeader = owf_card_header;
        fixRow = owf_card_row;
        CGPathRelease(owf_collapsed_path);
        owf_collapsed_path = CGPathCreateWithRoundedRect(CGRectMake(cx - 24, top - height, 48, height), height / 2, height / 2, NULL);
        owf_expanded_path = CGPathCreateWithRoundedRect(
            CGRectMake(cx - width / 2, cardTop - owf_card_height, width, owf_card_height),
            owf_card_height / 2, owf_card_height / 2, NULL
        );
        owf_correction_path = CGPathCreateWithRoundedRect(
            CGRectMake(cx - fixWidth / 2, cardTop - fixHeight, fixWidth, fixHeight), 24, 24, NULL
        );
        owf_card_cx = cx;
        owf_card_top = cardTop;
        owf_card_fix_w = fixWidth;
    } else if (notchHeight > 0) {
        owf_expanded_path = owf_island_path(cx, top, width, height, style->radius, shoulder);
        owf_correction_path = owf_island_path(cx, top, fixWidth, fixHeight, halo ? 18 : owf_fix_radius, shoulder);
    } else {
        // An independent floating capsule on external displays, with room above its rim.
        top -= 8;
        middle -= 8;
        fixTop -= 8;
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

    // The theme may have changed since the island last showed.
    owf_spin.colors = owf_palette(YES);
    owf_glow.hidden = style->floating || halo;
    owf_sheen.hidden = style->floating || halo;
    // The mask clips half the edge's stroke.
    owf_edge.lineWidth = style->floating ? 2 * owf_card_outline : 0.75;
    owf_edge.strokeColor = style->floating ? style->ink.CGColor
                         : halo ? NULL : [NSColor colorWithWhite:1 alpha:0.10].CGColor;
    owf_timer.font = (CFTypeRef)owf_timer_font();
    owf_timer.fontSize = style->timer_size;
    owf_timer.foregroundColor = [style->ink colorWithAlphaComponent:halo ? 1 : 0.92].CGColor;
    owf_dot.bounds = CGRectMake(0, 0, style->dot_size, style->dot_size);
    owf_dot.cornerRadius = style->dot_size / 2;
    owf_dot.borderWidth = style->floating ? 2 : 0;
    owf_dot.borderColor = style->ink.CGColor;

    NSArray *marks = style->mark == nil ? owf_palette(NO) : @[(id)style->mark.CGColor, (id)style->mark.CGColor];
    for (CALayer *rich in @[owf_fix_label, owf_fix_number, owf_fix_status, owf_fix_row]) {
        ((CAGradientLayer *)rich.sublayers[1]).colors = marks;
    }

    for (CAShapeLayer *shape in @[owf_mask, owf_bloom_mask, owf_edge, owf_shadow]) {
        shape.frame = bounds;
        shape.contentsScale = scale;
        shape.path = owf_collapsed_path;
    }

    owf_lights.frame = bounds;
    owf_lights.opacity = 0;

    owf_shadow.frame = CGRectOffset(bounds, owf_card_shadow.width, owf_card_shadow.height);

    // The spinning gradient covers the panel at any angle.
    CGFloat diagonal = hypot(bounds.size.width, bounds.size.height);
    owf_spin.bounds = CGRectMake(0, 0, diagonal, diagonal);
    owf_spin.position = CGPointMake(cx, middle);

    owf_content.opacity = 0;
    owf_glow.opacity = 0;
    owf_shadow.opacity = 0;

    // Dot and timer as one group, centered in the left ear or at the card's
    // start; the gap grows with the dot.
    NSSize timerSize = [@"0:00" sizeWithAttributes:@{NSFontAttributeName: owf_timer_font()}];
    CGFloat timerWidth = [@"00:00" sizeWithAttributes:@{NSFontAttributeName: owf_timer_font()}].width;
    CGFloat dotGap = style->dot_size / 2 + 3;
    CGFloat groupWidth = style->dot_size + dotGap + timerWidth;
    CGFloat groupLeft = style->floating ? cx - width / 2 + owf_card_padding
                      : halo ? cx - width / 2 + style->inset
                             : cx - gap / 2 - ear / 2 - groupWidth / 2;
    owf_dot.position = CGPointMake(groupLeft + style->dot_size / 2, middle);
    owf_timer.frame = CGRectMake(
        groupLeft + style->dot_size + dotGap,
        middle - timerSize.height / 2,
        timerWidth + 8,
        timerSize.height
    );
    owf_timer.contentsScale = scale;

    // A+'s ring and word while transcribing, where the light and timer were.
    NSFont *spinFont = owf_font(13, NSFontWeightMedium);
    NSString *spinWord = owf_text(@"Recognizing");
    NSSize spinSize = [spinWord sizeWithAttributes:@{NSFontAttributeName: spinFont}];
    owf_spinner.position = CGPointMake(groupLeft + 6, middle);
    owf_spin_word.string = spinWord;
    owf_spin_word.font = (CFTypeRef)spinFont;
    owf_spin_word.fontSize = 13;
    owf_spin_word.foregroundColor = style->ink.CGColor;
    owf_spin_word.frame = CGRectMake(groupLeft + 20, middle - spinSize.height / 2, ceil(spinSize.width) + 4, spinSize.height);
    owf_spin_word.contentsScale = scale;
    for (CAShapeLayer *arc in owf_spinner.sublayers) {
        arc.strokeColor = [style->halo[0] ?: style->ink colorWithAlphaComponent:arc == owf_spinner.sublayers.firstObject ? 0.25 : 1].CGColor;
        arc.contentsScale = scale;
    }

    // The wave, centered in the right ear, at the card's end, or inset from
    // the island's end, in the spectrum's colors left to right; a card's bars
    // take them one by one.
    int bars = owf_bar_count();
    NSArray<NSColor *> *spectrum = owf_theme()->spectrum;
    CGFloat waveWidth = bars * style->bar_width + (bars - 1) * style->bar_gap;
    owf_wave.frame = CGRectMake(
        style->floating ? cx + width / 2 - owf_card_padding - waveWidth
        : halo ? cx + width / 2 - style->inset - waveWidth : cx + gap / 2 + ear / 2 - waveWidth / 2,
        middle - style->bar_height / 2,
        waveWidth,
        style->bar_height
    );

    for (int i = 0; i < owf_bar_max; i++) {
        owf_bars[i].hidden = i >= bars;
        owf_bars[i].bounds = CGRectMake(0, 0, style->bar_width, style->bar_height);
        owf_bars[i].cornerRadius = style->bar_width / 2;
        owf_bars[i].backgroundColor = (style->floating ? spectrum[i % spectrum.count]
                                                       : owf_spectrum_at((CGFloat)i / (bars - 1))).CGColor;
        owf_bars[i].borderWidth = style->floating ? 1.5 : 0;
        owf_bars[i].borderColor = style->ink.CGColor;
        owf_bars[i].position = CGPointMake(
            style->bar_width / 2 + i * (style->bar_width + style->bar_gap), style->bar_height / 2
        );
    }

    // The word and the beads while transcribing, centered as one group.
    if (style->beads != nil) {
        NSFont *font = owf_display_font(owf_busy_font_size);
        NSString *word = owf_text(@"Recognizing");
        NSSize wordSize = [word sizeWithAttributes:@{NSFontAttributeName: font}];
        CGFloat beadsWidth = owf_bead_count * owf_bead_size + (owf_bead_count - 1) * owf_bead_gap;
        CGFloat busyWidth = ceil(wordSize.width) + owf_busy_gap + beadsWidth;
        owf_busy.frame = CGRectMake(cx - busyWidth / 2, middle - style->bar_height / 2, busyWidth, style->bar_height);
        owf_busy_word.frame = CGRectMake(0, (style->bar_height - wordSize.height) / 2, ceil(wordSize.width), wordSize.height);
        owf_busy_word.string = word;
        owf_busy_word.font = (CFTypeRef)font;
        owf_busy_word.fontSize = owf_busy_font_size;
        owf_busy_word.foregroundColor = style->ink.CGColor;
        owf_busy_word.contentsScale = scale;

        for (int i = 0; i < owf_bead_count; i++) {
            owf_beads[i].bounds = CGRectMake(0, 0, owf_bead_size, owf_bead_size);
            owf_beads[i].cornerRadius = owf_bead_size / 2;
            owf_beads[i].backgroundColor = style->beads[i].CGColor;
            owf_beads[i].borderWidth = 2;
            owf_beads[i].borderColor = style->ink.CGColor;
            owf_beads[i].position = CGPointMake(
                busyWidth - beadsWidth + owf_bead_size / 2 + i * (owf_bead_size + owf_bead_gap), style->bar_height / 2
            );
        }
    }

    // The correction look; owf_fix_place arranges it around these points.
    // The ears' content keeps to the island's sides, so both stay the same
    // distance from them whatever their width in each state and language.
    CGFloat fixSide = style->floating || halo ? fixWidth / 2 : gap / 2 + fixEar;
    // A+ keeps 18 points from the island's sides and centers its row in the
    // 34 points under the notch.
    CGFloat padding = halo ? 18 : owf_fix_padding;
    owf_fix_left = CGPointMake(cx - fixSide + padding, fixTop - fixHeader);
    owf_fix_right = CGPointMake(cx + fixSide - padding, fixTop - fixHeader);
    owf_fix_row_center = CGPointMake(cx, fixTop - (halo ? height + 17 : fixRow));
    owf_fix_row_width = halo ? fixWidth - 2 * padding
                      : style->floating ? fixWidth - 5 - 36 : fixWidth - 2 * (owf_fix_radius + 4);
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
                for (int i = 0; i < owf_bar_max; i++) [owf_bars[i] removeAllAnimations];
                for (int i = 0; i < owf_bead_count; i++) [owf_beads[i] removeAllAnimations];
            }
        }];
    }

    for (CAShapeLayer *shape in @[owf_mask, owf_bloom_mask, owf_edge, owf_shadow]) {
        shape.path = target;
        [shape addAnimation:morph forKey:@"path"];
    }

    for (CALayer *layer in @[owf_content, owf_glow, owf_shadow, owf_lights]) {
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
    [owf_content addSublayer:owf_dot];

    owf_timer = [[CATextLayer alloc] init];
    [owf_content addSublayer:owf_timer];

    // A ring with its top quarter lit, as CSS draws a round border with one colored side.
    owf_spinner = [[CALayer alloc] init];
    owf_spinner.bounds = CGRectMake(0, 0, 12, 12);
    owf_spinner.hidden = YES;
    CGPathRef ring = CGPathCreateWithEllipseInRect(CGRectMake(1, 1, 10, 10), NULL);
    for (int i = 0; i < 2; i++) {
        CAShapeLayer *arc = owf_stroke(2);
        arc.frame = owf_spinner.bounds;
        arc.path = ring;
        arc.lineCap = kCALineCapButt;
        if (i == 1) {
            arc.strokeStart = 0.125;
            arc.strokeEnd = 0.375;
        }
        [owf_spinner addSublayer:arc];
    }
    CGPathRelease(ring);
    [owf_content addSublayer:owf_spinner];
    owf_spin_word = [[CATextLayer alloc] init];
    owf_spin_word.hidden = YES;
    [owf_content addSublayer:owf_spin_word];
}

static void owf_wave_setup(void) {
    owf_wave = [[CALayer alloc] init];
    [owf_content addSublayer:owf_wave];

    for (int i = 0; i < owf_bar_max; i++) {
        owf_bars[i] = [[CALayer alloc] init];
        [owf_wave addSublayer:owf_bars[i]];
    }

    owf_busy = [[CALayer alloc] init];
    owf_busy.hidden = YES;
    [owf_content addSublayer:owf_busy];
    owf_busy_word = [[CATextLayer alloc] init];
    [owf_busy addSublayer:owf_busy_word];

    for (int i = 0; i < owf_bead_count; i++) {
        owf_beads[i] = [[CALayer alloc] init];
        [owf_busy addSublayer:owf_beads[i]];
    }
}

// A line of text: its plain words, and the glow's gradient seen through the
// words marked with owf_gradient_key, both drawn by owf_rich_set.
static CALayer *owf_rich_layer(void) {
    CALayer *rich = [[CALayer alloc] init];
    CAGradientLayer *gradient = [[CAGradientLayer alloc] init];
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

// The canvas's correction looks, drawn as their boards draw them: pieces of
// words, icons, struck-through words, and chips, gap apart and centered on
// one line. A chip pads its words by pad (x, y), and may have a border, a
// radius, a tilt in degrees, a hard shadow 2 points down and right, a line
// height of its own as an inline block, and an icon before its words.
static NSDictionary *owf_piece(NSString *text, NSFont *font, NSColor *color) {
    return @{@"text": [[[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: font, NSForegroundColorAttributeName: color}] autorelease]};
}

static NSDictionary *owf_icon_piece(NSString *name, CGFloat size, NSColor *color) {
    return @{@"icon": name, @"size": @(size), @"color": color};
}

// Font metrics as Blink holds them on a 2x display.
static CGFloat owf_piece_ascent(NSFont *font) {
    return round(font.ascender * 2) / 2;
}

static CGFloat owf_piece_line(NSFont *font) {
    return round(font.ascender * 2) / 2 + round(-font.descender * 2) / 2;
}

static NSFont *owf_piece_font(NSDictionary *piece) {
    return [piece[@"text"] attributesAtIndex:0 effectiveRange:NULL][NSFontAttributeName];
}

static CGFloat owf_piece_width(NSDictionary *piece) {
    if (piece[@"text"] == nil) return [piece[@"size"] doubleValue];
    CGFloat width = [piece[@"text"] size].width;
    if (piece[@"chip"] != nil) {
        width += 2 * [piece[@"padX"] ?: @7 doubleValue] + 2 * [piece[@"border"] ?: @0 doubleValue];
        if (piece[@"icon"] != nil) width += [piece[@"size"] doubleValue] + 6;
    }
    return width;
}

static CGFloat owf_piece_height(NSDictionary *piece) {
    if (piece[@"text"] == nil) return [piece[@"size"] doubleValue];
    NSFont *font = owf_piece_font(piece);
    CGFloat line = piece[@"lineHeight"] != nil ? [piece[@"lineHeight"] doubleValue] : owf_piece_line(font);
    if (piece[@"chip"] == nil) return line;
    return line + 2 * [piece[@"padY"] ?: @1 doubleValue] + 2 * [piece[@"border"] ?: @0 doubleValue];
}

// Draws pieces into an image as wide as they are, at most max wide: past it,
// the first piece, the words before a change, loses words from its start.
// The image is as high as the tallest piece and room for chips' shadows.
static NSImage *owf_pieces_image(NSArray *pieces, CGFloat gap, CGFloat max) {
    NSMutableArray *shown = [[pieces mutableCopy] autorelease];
    CGFloat (^width)(void) = ^{
        CGFloat total = gap * (shown.count - 1);
        for (NSDictionary *piece in shown) total += owf_piece_width(piece);
        return total;
    };

    while (width() > max && shown.count > 1 && [shown[0] objectForKey:@"lead"] != nil) {
        NSAttributedString *lead = shown[0][@"text"];
        NSMutableArray *words = [[[lead.string componentsSeparatedByString:@" "] mutableCopy] autorelease];
        [words removeObject:@"…"];
        if (words.count <= 1) {
            [shown removeObjectAtIndex:0];
            break;
        }
        [words removeObjectAtIndex:0];
        NSDictionary *attributes = [lead attributesAtIndex:0 effectiveRange:NULL];
        NSString *text = [@"… " stringByAppendingString:[words componentsJoinedByString:@" "]];
        shown[0] = @{@"text": [[[NSAttributedString alloc] initWithString:text attributes:attributes] autorelease], @"lead": @YES};
    }

    CGFloat height = 0;
    for (NSDictionary *piece in shown) height = fmax(height, owf_piece_height(piece));
    // Room for tilted chips and their shadows: above and below alike, so the
    // line stays centered, and right of a last chip's shadow.
    CGFloat margin = 4, right = shown.lastObject[@"shade"] != nil ? 3 : 0;
    NSSize size = NSMakeSize(ceil(fmin(width(), max)) + right, ceil(height) + 2 * margin);

    return [NSImage imageWithSize:size flipped:YES drawingHandler:^BOOL(NSRect rect) {
        CGFloat x = 0, middle = size.height / 2;
        for (NSDictionary *piece in shown) {
            CGFloat wide = owf_piece_width(piece), high = owf_piece_height(piece);
            NSRect box = NSMakeRect(x, round((middle - high / 2) * 2) / 2, wide, high);
            [NSGraphicsContext saveGraphicsState];

            if (piece[@"tilt"] != nil) {
                NSAffineTransform *tilt = [NSAffineTransform transform];
                [tilt translateXBy:NSMidX(box) yBy:NSMidY(box)];
                // Clockwise, as CSS rotates, on a flipped canvas.
                [tilt rotateByDegrees:[piece[@"tilt"] doubleValue]];
                [tilt translateXBy:-NSMidX(box) yBy:-NSMidY(box)];
                [tilt concat];
            }

            CGFloat contentX = x;
            if (piece[@"chip"] != nil) {
                CGFloat border = [piece[@"border"] ?: @0 doubleValue];
                CGFloat radius = fmin([piece[@"radius"] ?: @6 doubleValue], high / 2);
                if (piece[@"shade"] != nil) {
                    [piece[@"shade"] setFill];
                    [[NSBezierPath bezierPathWithRoundedRect:NSOffsetRect(box, 2, 2) xRadius:radius yRadius:radius] fill];
                }
                NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:box xRadius:radius yRadius:radius];
                [piece[@"chip"] setFill];
                [body fill];
                if (border > 0) {
                    NSBezierPath *edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, border / 2, border / 2)
                                                                         xRadius:radius - border / 2
                                                                         yRadius:radius - border / 2];
                    edge.lineWidth = border;
                    [piece[@"edge"] setStroke];
                    [edge stroke];
                }
                contentX += border + [piece[@"padX"] ?: @7 doubleValue];
            }

            if (piece[@"icon"] != nil) {
                CGFloat side = [piece[@"size"] doubleValue];
                NSBezierPath *path = owf_icon_path(piece[@"icon"]);
                NSAffineTransform *place = [NSAffineTransform transform];
                [place translateXBy:contentX yBy:round((middle - side / 2) * 2) / 2];
                [place scaleBy:side / 24];
                [path transformUsingAffineTransform:place];
                path.lineWidth = [piece[@"stroke"] ?: @2 doubleValue] * side / 24;
                path.lineCapStyle = NSLineCapStyleRound;
                path.lineJoinStyle = NSLineJoinStyleRound;
                [piece[@"color"] setStroke];
                [path stroke];
                contentX += side + 6;
            }

            if (piece[@"text"] != nil) {
                NSAttributedString *text = piece[@"text"];
                NSFont *font = owf_piece_font(piece);
                CGFloat line = piece[@"lineHeight"] != nil ? [piece[@"lineHeight"] doubleValue] : owf_piece_line(font);
                CGFloat top = middle - line / 2;
                CGFloat baseline = round((top + (line - owf_piece_line(font)) / 2 + owf_piece_ascent(font)) * 2) / 2;
                [text drawAtPoint:NSMakePoint(contentX, baseline - font.ascender)];
                if (piece[@"strike"] != nil) {
                    CGFloat thickness = [piece[@"thickness"] ?: @1.5 doubleValue];
                    [piece[@"strike"] setFill];
                    NSRectFillUsingOperation(NSMakeRect(x, baseline - font.xHeight / 2 - thickness / 2, wide, thickness),
                                             NSCompositingOperationSourceOver);
                }
            }

            [NSGraphicsContext restoreGraphicsState];
            x += wide + gap;
        }
        return YES;
    }];
}

// Draws images one under another, centered, gap apart.
static NSImage *owf_stack_image(NSArray<NSImage *> *images, CGFloat gap) {
    CGFloat width = 0, height = gap * (images.count - 1);
    for (NSImage *image in images) {
        width = fmax(width, image.size.width);
        height += image.size.height;
    }
    return [NSImage imageWithSize:NSMakeSize(width, height) flipped:YES drawingHandler:^BOOL(NSRect rect) {
        CGFloat y = 0;
        for (NSImage *image in images) {
            [image drawInRect:NSMakeRect((width - image.size.width) / 2, y, image.size.width, image.size.height)];
            y += image.size.height + gap;
        }
        return YES;
    }];
}

// Shows image in a rich layer in place of text.
static void owf_rich_image(CALayer *rich, NSImage *image) {
    CALayer *plain = rich.sublayers[0];
    CAGradientLayer *gradient = (CAGradientLayer *)rich.sublayers[1];
    CGFloat scale = [image recommendedLayerContentsScale:owf_scale];
    CGRect bounds = CGRectMake(0, 0, image.size.width, image.size.height);
    plain.contents = [image layerContentsForContentsScale:scale];
    plain.contentsScale = scale;
    plain.frame = bounds;
    gradient.mask.contents = nil;
    gradient.frame = bounds;
    rich.bounds = bounds;
}

// Layout A+'s colors of words by their role.
static NSColor *owf_halo_muted(void) {
    return owf_hex(0xA8A2B3);
}

static NSImage *owf_halo_label(void) {
    return owf_pieces_image(@[owf_icon_piece(@"pencil", 14, owf_halo_muted()),
                              owf_piece(owf_text(@"Correction"), owf_font(13.5, NSFontWeightMedium),
                                        owf_theme()->island.ink)], 7, CGFLOAT_MAX);
}

// The status: 0 saving, 1 saved, 2 not saved.
static NSImage *owf_halo_status(int status) {
    const OWFIsland *style = &owf_theme()->island;
    if (status == 0) {
        return owf_pieces_image(@[owf_piece(owf_text(@"Saving…"), owf_font(13.5, NSFontWeightMedium), owf_halo_muted())],
                                0, CGFLOAT_MAX);
    }
    NSColor *color = status == 1 ? style->mark : style->dot;
    return owf_pieces_image(@[owf_icon_piece(status == 1 ? @"check" : @"x", status == 1 ? 14 : 13, color),
                              owf_piece(owf_text(status == 1 ? @"Saved" : @"Not saved"),
                                        owf_font(status == 1 ? 13.5 : 13, NSFontWeightSemibold), color)], 6, CGFLOAT_MAX);
}

// Why no correction was saved, and for nothing selected, what to do: A+'s boards show both.
static NSArray *owf_halo_reason(NSString *english) {
    NSFont *font = owf_font(13.5, NSFontWeightMedium);
    NSMutableArray *pieces = [NSMutableArray arrayWithObject:owf_piece(owf_text(english), font, owf_theme()->island.ink)];
    if ([english isEqualToString:@"Nothing selected"]) {
        [pieces addObject:owf_piece(@"·", font, owf_halo_muted())];
        NSArray *hint = [owf_text(@"select text and press %@") componentsSeparatedByString:@"%@"];
        NSMutableAttributedString *text = [[[NSMutableAttributedString alloc] init] autorelease];
        NSDictionary *muted = @{NSFontAttributeName: font, NSForegroundColorAttributeName: owf_halo_muted()};
        [text appendAttributedString:[[[NSAttributedString alloc] initWithString:hint.firstObject attributes:muted] autorelease]];
        [text appendAttributedString:[[[NSAttributedString alloc] initWithString:@"Ctrl+Fn" attributes:@{
            NSFontAttributeName: owf_family(owf_theme()->island.mono, NSFontWeightMedium, 12),
            NSForegroundColorAttributeName: owf_theme()->island.ink}] autorelease]];
        if (hint.count > 1) {
            [text appendAttributedString:[[[NSAttributedString alloc] initWithString:hint[1] attributes:muted] autorelease]];
        }
        [pieces addObject:@{@"text": text}];
    }
    return pieces;
}

// Layout F's correction look: ink words, a numbered sticker, a status pill,
// and added words on stickers, in a card outlined 2.5 points and padded 14,
// 18, and 16 points.
static NSDictionary *owf_chip(NSDictionary *piece, NSDictionary *chip) {
    NSMutableDictionary *merged = [[piece mutableCopy] autorelease];
    [merged addEntriesFromDictionary:chip];
    return merged;
}

static NSImage *owf_card_label(void) {
    NSColor *ink = owf_theme()->island.ink;
    return owf_pieces_image(@[owf_chip(owf_icon_piece(@"pencil", 16, ink), @{@"stroke": @2.4}),
                              owf_piece(owf_text(@"Correction"), owf_font(15, NSFontWeightHeavy), ink)], 8, CGFLOAT_MAX);
}

static NSImage *owf_card_number(NSString *number) {
    const OWFIsland *style = &owf_theme()->island;
    return owf_pieces_image(@[owf_chip(owf_piece(number, owf_display_font(13), style->ink), @{
        @"chip": style->fill[0], @"edge": style->ink, @"border": @2, @"padX": @9, @"padY": @2, @"radius": @99, @"tilt": @-4})],
        0, CGFLOAT_MAX);
}

// The status: 0 saving, 1 saved, 2 not saved.
static NSImage *owf_card_status(int status) {
    const OWFIsland *style = &owf_theme()->island;
    NSFont *font = owf_font(13, NSFontWeightHeavy);
    if (status == 0) {
        return owf_pieces_image(@[owf_piece(owf_text(@"Saving…"), font, owf_hex(0x4A4556))], 0, CGFLOAT_MAX);
    }
    NSColor *color = status == 1 ? NSColor.whiteColor : style->ink;
    NSDictionary *pill = owf_chip(owf_piece(owf_text(status == 1 ? @"Saved" : @"Not saved"), font, color), @{
        @"chip": status == 1 ? style->shadow : style->alert, @"edge": style->ink, @"border": @2, @"padX": @12, @"padY": @5,
        @"radius": @99, @"icon": status == 1 ? @"check" : @"x", @"size": @(status == 1 ? 13 : 12), @"color": color,
        @"stroke": @2.4});
    return owf_pieces_image(@[pill], 0, CGFLOAT_MAX);
}

// Shows image in rich layer, as owf_rich_image does, and returns its height without the image's margins.
static CGFloat owf_rich_card(CALayer *rich, NSImage *image) {
    owf_rich_image(rich, image);
    return image.size.height - 8;
}

// Sizes the floating card to its correction look: header and row heights,
// gap apart, inside its padding and outline; morphs to it when showing.
static void owf_card_fit(CGFloat header, CGFloat gap, CGFloat row) {
    CGFloat height = 2.5 + 14 + header + gap + row + 16 + 2.5, side = owf_card_fix_w / 2;
    CGPathRelease(owf_correction_path);
    owf_correction_path = CGPathCreateWithRoundedRect(
        CGRectMake(owf_card_cx - side, owf_card_top - height, owf_card_fix_w, height), 24, 24, NULL);
    owf_fix_left = CGPointMake(owf_card_cx - side + 2.5 + 18, owf_card_top - 2.5 - 14 - header / 2);
    owf_fix_right = CGPointMake(owf_card_cx + side - 2.5 - 18, owf_fix_left.y);
    owf_fix_row_center = CGPointMake(owf_card_cx, owf_card_top - 2.5 - 14 - header - gap - row / 2);

    if (owf_expanded) {
        owf_morph(owf_correction_path, YES);
    }
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
    CGFloat gap = owf_halo() ? 7 : owf_theme()->island.floating ? 8 : owf_fix_gap;
    owf_place(owf_fix_number, owf_fix_left.x + owf_fix_label.bounds.size.width + gap, owf_fix_left.y);
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
    CGFloat max = owf_theme()->island.bar_height;
    int bars = owf_bar_count();

    if (owf_halo()) {
        for (int i = 0; i < bars; i++) {
            owf_bars[i].transform = CATransform3DIdentity;
            owf_bars[i].bounds = CGRectMake(0, 0, owf_bars[i].bounds.size.width, 4);
            owf_bars[i].opacity = 0.2;
            CABasicAnimation *sweep = [CABasicAnimation animationWithKeyPath:@"opacity"];
            sweep.fromValue = @0.2;
            sweep.toValue = @1.0;
            sweep.duration = 0.6;
            sweep.autoreverses = YES;
            sweep.repeatCount = HUGE_VALF;
            sweep.beginTime = now + i * 0.1;
            sweep.fillMode = kCAFillModeBackwards;
            sweep.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [owf_bars[i] addAnimation:sweep forKey:@"think"];
        }

        // The ring holds still under Reduce Motion; the dots still show progress.
        if (!reduce) {
            CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
            spin.fromValue = @0;
            spin.toValue = @(-2 * M_PI);
            spin.duration = 0.8;
            spin.repeatCount = HUGE_VALF;
            [owf_spinner addAnimation:spin forKey:@"spin"];
        }
        return;
    }

    for (int i = 0; i < bars; i++) {
        CGFloat peak = owf_bar_min_height + (max - owf_bar_min_height) * 0.6 * owf_bar_weight(i, bars);
        CABasicAnimation *roll = [CABasicAnimation animationWithKeyPath:reduce ? @"opacity" : @"transform.scale.y"];
        roll.fromValue = reduce ? @0.25 : @(owf_bar_min_height / max);
        roll.toValue = reduce ? @1.0 : @(peak / max);
        roll.duration = 0.45;
        roll.autoreverses = YES;
        roll.repeatCount = HUGE_VALF;
        roll.beginTime = now + i * 0.08;
        roll.fillMode = kCAFillModeBackwards;
        roll.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        owf_bars[i].transform = CATransform3DMakeScale(1, peak / max, 1);
        [owf_bars[i] addAnimation:roll forKey:@"think"];
    }

    // A card's beads hop one after another, or light up in turn under Reduce Motion.
    for (int i = 0; i < owf_bead_count; i++) {
        CABasicAnimation *hop = [CABasicAnimation animationWithKeyPath:reduce ? @"opacity" : @"position.y"];
        hop.fromValue = reduce ? @0.25 : @0;
        hop.toValue = reduce ? @1.0 : @(owf_bead_bounce);
        hop.additive = !reduce;
        hop.duration = 0.45;
        hop.autoreverses = YES;
        hop.repeatCount = HUGE_VALF;
        hop.beginTime = now + i * 0.15;
        hop.fillMode = kCAFillModeBackwards;
        hop.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [owf_beads[i] addAnimation:hop forKey:@"think"];
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
    BOOL fade = owf_halo();
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:fade ? @"opacity" : @"transform.scale"];
    pulse.fromValue = @1.0;
    pulse.toValue = fade ? @0.3 : @0.7;
    pulse.duration = fade ? 0.7 : 0.8;
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

    // Layout A+'s lights, under the island.
    owf_lights = [[CALayer alloc] init];
    owf_lights.hidden = YES;
    [view.layer addSublayer:owf_lights];

    // A floating card's hard shadow, offset from its outline.
    owf_shadow = [[CAShapeLayer alloc] init];
    [view.layer addSublayer:owf_shadow];

    // The body, clipped by the animated outline; owf_paint colors it.
    owf_island = [[CALayer alloc] init];
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
            for (CALayer *layer in @[owf_spin, owf_dot, owf_bloom, owf_mask, owf_bloom_mask, owf_edge, owf_shadow, owf_content, owf_glow]) {
                [layer removeAllAnimations];
            }
            for (int i = 0; i < owf_bar_max; i++) [owf_bars[i] removeAllAnimations];
            for (int i = 0; i < owf_bead_count; i++) [owf_beads[i] removeAllAnimations];
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
        owf_paint(1, YES, 1.5);
        // A dimmed final time reads as done; an ellipsis next to the dot read as four dots.
        owf_timer.opacity = 0.5;
        // A+ spins a ring beside a word instead.
        if (owf_halo()) {
            owf_dot.hidden = YES;
            owf_timer.hidden = YES;
            owf_spinner.hidden = NO;
            owf_spin_word.hidden = NO;
            owf_halo_paint(1);
        }
        // A card says so in words with its beads instead.
        if (owf_theme()->island.beads != nil) {
            owf_dot.hidden = YES;
            owf_timer.hidden = YES;
            owf_wave.hidden = YES;
            owf_busy.hidden = NO;
        }
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
        owf_paint(2, NO, -1);
        owf_halo_paint(2);
        if (owf_halo()) {
            owf_rich_image(owf_fix_label, owf_halo_label());
            owf_rich_image(owf_fix_status, owf_halo_status(0));
            owf_rich_image(owf_fix_row, owf_pieces_image(@[owf_piece(owf_text(@"Comparing with dictation"),
                owf_font(13.5, NSFontWeightMedium), owf_halo_muted())], 0, owf_fix_row_width));
        } else if (owf_theme()->island.floating) {
            CGFloat header = fmax(owf_rich_card(owf_fix_label, owf_card_label()),
                                  owf_rich_card(owf_fix_status, owf_card_status(0)));
            CGFloat row = owf_rich_card(owf_fix_row, owf_pieces_image(@[owf_piece(owf_text(@"Comparing with dictation"),
                owf_font(16, NSFontWeightSemibold), owf_hex(0x4A4556))], 0, owf_fix_row_width));
            owf_card_fit(header, 12, row);
        } else {
            owf_rich_set(owf_fix_label, owf_words(owf_text(@"Correction"), 0.92, NO), CGFLOAT_MAX);
            owf_rich_set(owf_fix_status, owf_words(owf_text(@"Saving…"), 0.92, NO), CGFLOAT_MAX);
            owf_rich_set(
                owf_fix_row, owf_words(owf_text(@"Comparing with dictation"), 0.5, NO), owf_fix_row_width
            );
        }

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
// "Correction", the status, and row under the notch, or picture, A+'s row;
// then folds the island away.
static void owf_fix_result(BOOL saved, NSString *number, NSAttributedString *row, NSImage *picture) {
    unsigned correction = owf_fix_count;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [owf_bloom removeAnimationForKey:@"think"];
    [owf_fix_status removeAnimationForKey:@"shimmer"];
    [owf_fix_row removeAnimationForKey:@"shimmer"];
    owf_fix_number.hidden = number == nil;
    owf_paint(2, !saved, saved ? -1 : 1);
    owf_halo_paint(saved ? 2 : 3);

    if (picture != nil && owf_theme()->island.floating) {
        CGFloat header = owf_rich_card(owf_fix_label, owf_card_label());
        if (number != nil) {
            header = fmax(header, owf_rich_card(owf_fix_number, owf_card_number(number)));
        }
        header = fmax(header, owf_rich_card(owf_fix_status, owf_card_status(saved ? 1 : 2)));
        owf_card_fit(header, saved ? 12 : 10, owf_rich_card(owf_fix_row, picture));
    } else if (picture != nil) {
        if (number != nil) {
            const OWFIsland *style = &owf_theme()->island;
            owf_rich_image(owf_fix_number, owf_pieces_image(@[owf_piece(number, owf_family(style->mono, NSFontWeightMedium, 13),
                                                                        style->mark)], 0, CGFLOAT_MAX));
        }
        owf_rich_image(owf_fix_status, owf_halo_status(saved ? 1 : 2));
        owf_rich_image(owf_fix_row, picture);
    } else {
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
    }
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

        if (owf_theme()->island.floating) {
            // Kept words in ink, removed ones struck through, added ones on tilted yellow stickers.
            const OWFIsland *style = &owf_theme()->island;
            NSFont *font = owf_font(16, NSFontWeightSemibold), *bold = owf_font(16, NSFontWeightHeavy);
            NSMutableArray *pieces = [NSMutableArray array];
            for (NSDictionary *part in parts) {
                int kind = [part[@"kind"] intValue];
                NSString *text = [part[@"text"] isKindOfClass:NSString.class] ? part[@"text"] : @"";
                if (kind == 2) {
                    [pieces addObject:owf_chip(owf_piece(text, bold, style->ink), @{
                        @"chip": style->fill[0], @"edge": style->ink, @"border": @2, @"padX": @8, @"padY": @0,
                        @"lineHeight": @24, @"radius": @8, @"tilt": @-2, @"shade": style->ink})];
                    continue;
                }
                NSMutableDictionary *piece = [[owf_piece(text, font, kind == 0 ? style->ink : owf_hex(0x6B6578))
                                               mutableCopy] autorelease];
                if (kind == 0 && pieces.count == 0) piece[@"lead"] = @YES;
                if (kind == 1) {
                    piece[@"strike"] = style->ink;
                    piece[@"thickness"] = @2;
                }
                [pieces addObject:piece];
            }
            owf_fix_result(YES, number > 0 ? owf_number(number) : nil, nil, owf_pieces_image(pieces, 8, owf_fix_row_width));
            return;
        }

        if (owf_halo()) {
            // Kept words quiet, removed ones struck through in coral, added ones on violet chips.
            const OWFIsland *style = &owf_theme()->island;
            NSFont *font = owf_font(14, NSFontWeightMedium);
            NSMutableArray *pieces = [NSMutableArray array];
            for (NSDictionary *part in parts) {
                int kind = [part[@"kind"] intValue];
                NSString *text = [part[@"text"] isKindOfClass:NSString.class] ? part[@"text"] : @"";
                NSMutableDictionary *piece = [[owf_piece(text, font, owf_hex(kind == 0 ? 0xC9C3D4 : kind == 1 ? 0x6E6879 : 0xC4ADFF))
                                               mutableCopy] autorelease];
                if (kind == 0 && pieces.count == 0) piece[@"lead"] = @YES;
                if (kind == 1) piece[@"strike"] = style->dot;
                if (kind == 2) piece[@"chip"] = [style->mark colorWithAlphaComponent:0.16];
                [pieces addObject:piece];
            }
            owf_fix_result(YES, number > 0 ? owf_number(number) : nil, nil, owf_pieces_image(pieces, 6, owf_fix_row_width));
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
                [words addAttribute:NSStrikethroughColorAttributeName
                              value:[owf_theme()->island.ink colorWithAlphaComponent:0.4]
                              range:all];
            }

            [row appendAttributedString:words];
        }

        owf_fix_result(YES, number > 0 ? owf_number(number) : nil, row, nil);
    });
}

void owf_ui_not_corrected(const char *reason) {
    NSString *english = @(reason);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!owf_correcting) {
            return;
        }

        if (owf_theme()->island.floating) {
            // Why in display type, and for nothing selected, what to do with the keys on chips.
            const OWFIsland *style = &owf_theme()->island;
            NSMutableArray *lines = [NSMutableArray arrayWithObject:owf_pieces_image(@[owf_piece(owf_text(english),
                owf_display_font(17), style->ink)], 0, owf_fix_row_width)];
            if ([english isEqualToString:@"Nothing selected"]) {
                NSFont *font = owf_font(13, NSFontWeightSemibold);
                NSColor *muted = owf_hex(0x4A4556);
                NSDictionary *(^key)(NSString *) = ^NSDictionary *(NSString *name) {
                    return owf_chip(owf_piece(name, owf_font(12, NSFontWeightHeavy), style->ink), @{
                        @"chip": owf_hex(0xFFF6EC), @"edge": style->ink, @"border": @2, @"padX": @7, @"padY": @1, @"radius": @7});
                };
                [lines addObject:owf_pieces_image(@[owf_piece([owf_text(@"Select text and press") stringByAppendingString:@" "],
                                                              font, muted),
                                                    key(@"Ctrl"), owf_piece(@" + ", font, muted), key(@"Fn")],
                                                  0, owf_fix_row_width)];
            }
            // 4 points apart once each line's 4-point margins overlap.
            owf_fix_result(NO, nil, nil, owf_stack_image(lines, 4 - 8));
            return;
        }

        if (owf_halo()) {
            owf_fix_result(NO, nil, nil, owf_pieces_image(owf_halo_reason(english), 8, owf_fix_row_width));
            return;
        }

        owf_fix_result(NO, nil, owf_words(owf_text(english), 0.5, NO), nil);
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
        // A card's bars move only with the voice, so they ease even under Reduce Motion.
        [CATransaction setAnimationDuration:owf_reduce_motion() && !owf_theme()->island.floating ? 0 : 0.08];
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
