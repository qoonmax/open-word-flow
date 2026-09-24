#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include <math.h>
#include <stdlib.h>

#include "native_darwin.h"

// Layout in points. The island grows sideways out of the notch; each side holds content.
static const CGFloat owf_side_width = 64;
static const CGFloat owf_notchless_gap = 16;
static const CGFloat owf_notchless_height = 32;
static const CGFloat owf_notch_radius = 8;
static const CGFloat owf_island_radius = 12;
static const CGFloat owf_shoulder_radius = 6;
static const CGFloat owf_overshoot_margin = 16;
static const CGFloat owf_dot_size = 8;
static const CGFloat owf_bar_width = 3;
static const CGFloat owf_bar_gap = 3;
static const CGFloat owf_bar_min_height = 4;
static const CGFloat owf_bar_padding = 16;
static const CGFloat owf_bar_weights[] = {0.55, 0.8, 1.0, 0.8, 0.55};

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
static CALayer *owf_dot;
static CALayer *owf_bars[owf_bar_count];
static CGPathRef owf_collapsed_path;
static CGPathRef owf_expanded_path;
static CGFloat owf_bar_max_height;
static double owf_level;
static BOOL owf_expanded;

// Island outline: flat top on the screen edge, concave shoulders, rounded bottom corners.
// Every outline has the same elements, so Core Animation can morph one into another.
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
    CGPathCloseSubpath(path);

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

static void owf_set_bar_heights(CGFloat level) {
    for (int i = 0; i < owf_bar_count; i++) {
        // Jitter keeps the bars lively while the level is steady.
        CGFloat jitter = 0.75 + 0.25 * arc4random_uniform(1001) / 1000.0;
        CGFloat scale = fmin(1, level * owf_bar_weights[i] * jitter);
        CGFloat height = owf_bar_min_height + (owf_bar_max_height - owf_bar_min_height) * scale;
        owf_bars[i].bounds = CGRectMake(0, 0, owf_bar_width, height);
    }
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

    CGFloat gap = notchHeight > 0 ? notchWidth : owf_notchless_gap;
    CGFloat height = notchHeight > 0 ? notchHeight : owf_notchless_height;
    CGFloat width = gap + 2 * owf_side_width;
    CGFloat inset = owf_shoulder_radius + owf_overshoot_margin;
    NSRect panelFrame = NSMakeRect(
        notchCenter - width / 2 - inset,
        NSMaxY(frame) - height - owf_overshoot_margin,
        width + 2 * inset,
        height + owf_overshoot_margin
    );
    [owf_panel setFrame:panelFrame display:NO];

    CGFloat cx = panelFrame.size.width / 2;
    CGFloat top = panelFrame.size.height;
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
    owf_bar_max_height = height - owf_bar_padding;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    owf_island.frame = CGRectMake(0, 0, panelFrame.size.width, panelFrame.size.height);
    owf_mask.frame = owf_island.bounds;
    owf_mask.contentsScale = scale;
    owf_mask.path = owf_collapsed_path;
    owf_dot.position = CGPointMake(cx - gap / 2 - owf_side_width / 2, middle);

    CGFloat barsWidth = owf_bar_count * owf_bar_width + (owf_bar_count - 1) * owf_bar_gap;
    CGFloat barX = cx + gap / 2 + owf_side_width / 2 - barsWidth / 2 + owf_bar_width / 2;

    for (int i = 0; i < owf_bar_count; i++) {
        owf_bars[i].position = CGPointMake(barX + i * (owf_bar_width + owf_bar_gap), middle);
    }

    owf_level = 0;
    owf_set_bar_heights(0);

    [CATransaction commit];
}

static void owf_morph(CGPathRef target, BOOL expand) {
    CAShapeLayer *presentation = owf_mask.presentationLayer;
    CGPathRef from = presentation != nil ? presentation.path : owf_mask.path;
    CABasicAnimation *animation;

    if (expand) {
        CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:@"path"];
        spring.mass = 1;
        spring.stiffness = 260;
        spring.damping = 22;
        spring.duration = spring.settlingDuration;
        animation = spring;
    } else {
        animation = [CABasicAnimation animationWithKeyPath:@"path"];
        animation.duration = 0.3;
        animation.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.4:0:0.2:1];
    }

    animation.fromValue = (id)from;
    animation.toValue = (id)target;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (!expand) {
        [CATransaction setCompletionBlock:^{
            if (!owf_expanded) {
                [owf_panel orderOut:nil];
            }
        }];
    }

    owf_mask.path = target;
    [owf_mask addAnimation:animation forKey:@"path"];

    [CATransaction commit];
}

static CALayer *owf_new_layer(CGColorRef color, CGFloat width, CGFloat height) {
    CALayer *layer = [[CALayer alloc] init];
    layer.backgroundColor = color;
    layer.bounds = CGRectMake(0, 0, width, height);
    layer.cornerRadius = width / 2;
    [owf_island addSublayer:layer];

    return layer;
}

static void owf_setup(void) {
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

    // A black layer clipped by the animated outline: content is revealed as the island grows.
    owf_island = [[CALayer alloc] init];
    owf_island.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    owf_mask = [[CAShapeLayer alloc] init];
    owf_mask.fillColor = CGColorGetConstantColor(kCGColorBlack);
    owf_island.mask = owf_mask;
    [view.layer addSublayer:owf_island];

    owf_dot = owf_new_layer(NSColor.systemRedColor.CGColor, owf_dot_size, owf_dot_size);

    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1.0;
    pulse.toValue = @0.35;
    pulse.duration = 0.8;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [owf_dot addAnimation:pulse forKey:@"pulse"];

    for (int i = 0; i < owf_bar_count; i++) {
        owf_bars[i] = owf_new_layer(
            CGColorGetConstantColor(kCGColorWhite), owf_bar_width, owf_bar_min_height
        );
    }
}

void owf_ui_run(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        // No Dock icon or menu bar, and never takes focus from the app that receives the paste.
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        owf_setup();
        [NSApp run];
    }
}

void owf_ui_stop(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp stop:nil];

        // stop: takes effect after the next event, so post one.
        NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                            location:NSZeroPoint
                                       modifierFlags:0
                                           timestamp:0
                                        windowNumber:0
                                             context:nil
                                             subtype:0
                                               data1:0
                                               data2:0];
        [NSApp postEvent:event atStart:YES];
    });
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

        owf_expanded = YES;
        [owf_panel orderFrontRegardless];
        owf_morph(owf_expanded_path, YES);
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
        [CATransaction commit];
    });
}
