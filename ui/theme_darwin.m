#import <AppKit/AppKit.h>

#include "native_darwin.h"

NSString *const owf_theme_key = @"theme";

NSColor *owf_hex(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0
                               alpha:1];
}

// A new theme is one more entry here; they live as long as the app.
const OWFTheme *owf_themes(size_t *count) {
    static OWFTheme themes[4];
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSColor *black = [NSColor.blackColor retain];
        OWFIsland notch = {
            .fill = {black, black, black},
            .ink = [NSColor.whiteColor retain],
            .dot = [owf_hex(0xFA665C) retain],
            .radius = 14,
            .dot_size = 6,
            .bar_width = 2,
            .bar_gap = 2.5,
            .bar_height = 19,
            .timer_size = 13,
        };

        // Layout A+ of the design canvas: the brand's dark look, the default.
        OWFIsland brand = notch;
        brand.ink = [owf_hex(0xF3F0F7) retain];
        brand.dot = [owf_hex(0xF28A6C) retain];
        brand.mark = [owf_hex(0xAC8DFF) retain];
        brand.halo[0] = brand.mark;
        brand.halo[1] = brand.dot;
        brand.dot_size = 8;
        brand.bar_width = 3;
        brand.bar_gap = 3;
        brand.bar_height = 20;
        brand.timer_size = 14;
        brand.ear = 102;
        brand.inset = 16;
        brand.shoulder = 8;
        brand.bars = 12;
        brand.mono = @"JetBrains Mono";
        themes[0] = (OWFTheme){
            .id = @"classic",
            .name = @"Classic",
            .appearance = [[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua] retain],
            .layout = OWFLayoutBrand,
            .spectrum = [@[owf_hex(0x7C8CFF), owf_hex(0x8B89FF), owf_hex(0x9587FF), owf_hex(0xA386FB), owf_hex(0xAE84F7),
                           owf_hex(0xBA82EE), owf_hex(0xC680E6), owf_hex(0xD17FD9), owf_hex(0xDC7ECB), owf_hex(0xE480B8),
                           owf_hex(0xEB82A6), owf_hex(0xF28A6C)] retain],
            .accent = [owf_hex(0xAC8DFF) retain],
            .canvas = [owf_hex(0x121015) retain],
            .sidebar = [owf_hex(0x17131C) retain],
            .card = [owf_hex(0x1B1821) retain],
            .card_radius = 16,
            .family = @"Onest",
            .display_weight = NSFontWeightSemibold,
            .island = brand,
        };

        // Layout D of the design canvas.
        NSColor *lime = [owf_hex(0xC5F23E) retain];
        OWFIsland terminal = notch;
        terminal.radius = 8;
        terminal.dot = lime;
        themes[3] = (OWFTheme){
            .id = @"terminal",
            .name = @"Terminal",
            .appearance = [[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua] retain],
            .spectrum = [@[lime, lime] retain],
            .accent = lime,
            .canvas = [owf_hex(0x0E0F0E) retain],
            .sidebar = [owf_hex(0x121412) retain],
            .card = [owf_hex(0x121412) retain],
            .card_radius = 6,
            .font = NSFontDescriptorSystemDesignMonospaced,
            .display_weight = NSFontWeightSemibold,
            .island = terminal,
        };

        // Layout F3 of the design canvas: ink outlines, hard shadows, and
        // candy colors.
        NSColor *ink = [owf_hex(0x17141F) retain];
        NSColor *violet = [owf_hex(0x5B3DF5) retain];
        NSColor *sky = [owf_hex(0x8FDDFF) retain];
        NSColor *pink = [owf_hex(0xFF9ED2) retain];
        NSColor *coral = [owf_hex(0xFF7A59) retain];
        NSColor *yellow = [owf_hex(0xFFD84D) retain];
        OWFIsland floating = {
            .floating = YES,
            .fill = {yellow, sky, [NSColor.whiteColor retain]},
            .ink = ink,
            .shadow = violet,
            .alert = coral,
            .mark = violet,
            .dot = coral,
            .beads = [@[yellow, pink, coral] retain],
            .dot_size = 14,
            .bar_width = 7,
            .bar_gap = 4,
            .bar_height = 28,
            .timer_size = 22,
        };

        // Layout F4+ of the design canvas: soft pastels on white cards, the
        // island of F.
        themes[1] = (OWFTheme){
            .id = @"soft",
            .name = @"Soft Spectrum",
            .appearance = [[NSAppearance appearanceNamed:NSAppearanceNameAqua] retain],
            .layout = OWFLayoutSoft,
            .spectrum = [@[sky, violet, pink, coral, violet, sky, pink] retain],
            .accent = violet,
            .canvas = [owf_hex(0xF4F0FC) retain],
            .sidebar = [NSColor.whiteColor retain],
            .card = [NSColor.whiteColor retain],
            .card_radius = 24,
            .family = @"Manrope",
            .display = @"DelaGothicOne-Regular",
            .display_weight = NSFontWeightBlack,
            .island = floating,
        };

        themes[2] = (OWFTheme){
            .id = @"bento",
            .name = @"Bento",
            .appearance = [[NSAppearance appearanceNamed:NSAppearanceNameAqua] retain],
            .layout = OWFLayoutBento,
            .spectrum = [@[sky, violet, pink, coral, violet, sky, pink, coral, violet] retain],
            .accent = violet,
            .canvas = [owf_hex(0xFFF6EC) retain],
            .sidebar = violet,
            .card = [NSColor.whiteColor retain],
            .card_radius = 22,
            .outline = ink,
            .shadow = 4,
            .family = @"Manrope",
            .display = @"DelaGothicOne-Regular",
            .display_weight = NSFontWeightBlack,
            .island = floating,
        };
    });

    *count = sizeof(themes) / sizeof(themes[0]);
    return themes;
}

const OWFTheme *owf_theme(void) {
    size_t count;
    const OWFTheme *themes = owf_themes(&count);
    NSString *chosen = [NSUserDefaults.standardUserDefaults stringForKey:owf_theme_key];

    for (size_t i = 0; i < count; i++) {
        if ([themes[i].id isEqualToString:chosen]) {
            return &themes[i];
        }
    }

    return &themes[0];
}

NSFont *owf_font(CGFloat size, NSFontWeight weight) {
    NSString *family = owf_theme()->family;
    NSFont *bundled = family == nil ? nil : [NSFont fontWithDescriptor:[NSFontDescriptor fontDescriptorWithFontAttributes:@{
        NSFontFamilyAttribute: family,
        NSFontTraitsAttribute: @{NSFontWeightTrait: @(weight)},
    }] size:size];

    if (bundled != nil) {
        return bundled;
    }

    NSFont *font = [NSFont systemFontOfSize:size weight:weight];
    NSFontDescriptor *design = owf_theme()->font == nil ? nil
        : [font.fontDescriptor fontDescriptorWithDesign:owf_theme()->font];

    return design == nil ? font : [NSFont fontWithDescriptor:design size:size];
}

NSFont *owf_family(NSString *family, NSFontWeight weight, CGFloat size) {
    NSFont *font = [NSFont fontWithDescriptor:[NSFontDescriptor fontDescriptorWithFontAttributes:@{
        NSFontFamilyAttribute: family,
        NSFontTraitsAttribute: @{NSFontWeightTrait: @(weight)},
    }] size:size];

    return font ?: [NSFont systemFontOfSize:size weight:weight];
}

NSFont *owf_display_font(CGFloat size) {
    const OWFTheme *theme = owf_theme();

    return (theme->display == nil ? nil : [NSFont fontWithName:theme->display size:size])
        ?: owf_font(size, theme->display_weight);
}

NSArray *owf_palette(BOOL loop) {
    NSArray<NSColor *> *spectrum = owf_theme()->spectrum;
    NSMutableArray *colors = [NSMutableArray array];

    for (NSUInteger i = 0; i < spectrum.count + (loop ? 1 : 0); i++) {
        [colors addObject:(id)spectrum[i % spectrum.count].CGColor];
    }

    return colors;
}

NSColor *owf_spectrum_at(CGFloat t) {
    NSArray<NSColor *> *spectrum = owf_theme()->spectrum;
    CGFloat position = fmin(fmax(t, 0), 1) * (spectrum.count - 1);
    NSUInteger index = fmin(floor(position), spectrum.count - 2);
    CGFloat mix = position - index;
    NSColor *from = [spectrum[index] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor *to = [spectrum[index + 1] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];

    return [NSColor colorWithSRGBRed:from.redComponent + (to.redComponent - from.redComponent) * mix
                               green:from.greenComponent + (to.greenComponent - from.greenComponent) * mix
                                blue:from.blueComponent + (to.blueComponent - from.blueComponent) * mix
                               alpha:1];
}
