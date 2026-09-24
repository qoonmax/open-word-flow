#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

#include "native_darwin.h"

// Virtual key code of the V key (kVK_ANSI_V); Cmd+V resolves to Paste on any layout.
static const CGKeyCode owf_key_v = 9;

int owf_accessibility_trusted(int prompt) {
    @autoreleasepool {
        NSDictionary *options = @{(id)kAXTrustedCheckOptionPrompt: @(prompt != 0)};
        return AXIsProcessTrustedWithOptions((CFDictionaryRef)options) ? 1 : 0;
    }
}

// Returns the pasteboard change count after writing text, or -1 on failure.
long owf_clipboard_set(const char *text) {
    @autoreleasepool {
        NSString *value = [NSString stringWithUTF8String:text];
        if (value == nil) {
            return -1;
        }

        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];

        if (![pasteboard setString:value forType:NSPasteboardTypeString]) {
            return -1;
        }

        return (long)[pasteboard changeCount];
    }
}

long owf_clipboard_change_count(void) {
    return (long)[[NSPasteboard generalPasteboard] changeCount];
}

// Copies every item and type on the pasteboard; free with owf_clipboard_release.
void *owf_clipboard_save(void) {
    @autoreleasepool {
        NSMutableArray *snapshot = [[NSMutableArray alloc] init];

        for (NSPasteboardItem *item in [[NSPasteboard generalPasteboard] pasteboardItems]) {
            NSPasteboardItem *copy = [[NSPasteboardItem alloc] init];

            for (NSPasteboardType type in item.types) {
                NSData *data = [item dataForType:type];
                if (data != nil) {
                    [copy setData:data forType:type];
                }
            }

            [snapshot addObject:copy];
            [copy release];
        }

        return snapshot;
    }
}

void owf_clipboard_restore(void *snapshot) {
    @autoreleasepool {
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        [pasteboard writeObjects:(NSArray *)snapshot];
    }
}

void owf_clipboard_release(void *snapshot) {
    [(NSArray *)snapshot release];
}

int owf_send_paste(void) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    CGEventRef down = CGEventCreateKeyboardEvent(source, owf_key_v, true);
    CGEventRef up = CGEventCreateKeyboardEvent(source, owf_key_v, false);
    int ok = down != NULL && up != NULL;

    if (ok) {
        // Explicit flags also mask modifiers the user may still hold from the hotkey.
        CGEventSetFlags(down, kCGEventFlagMaskCommand);
        CGEventSetFlags(up, kCGEventFlagMaskCommand);
        CGEventPost(kCGAnnotatedSessionEventTap, down);
        CGEventPost(kCGAnnotatedSessionEventTap, up);
    }

    if (down != NULL) {
        CFRelease(down);
    }
    if (up != NULL) {
        CFRelease(up);
    }
    if (source != NULL) {
        CFRelease(source);
    }

    return ok;
}
