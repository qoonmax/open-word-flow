#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

#include <string.h>

#include "native_darwin.h"

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

// Returns the clipboard text as a malloc'd UTF-8 string, or NULL when it holds none.
char *owf_clipboard_text(void) {
    @autoreleasepool {
        NSString *value = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
        return value == nil ? NULL : strdup(value.UTF8String);
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

int owf_send_command(int key) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    CGEventRef down = CGEventCreateKeyboardEvent(source, (CGKeyCode)key, true);
    CGEventRef up = CGEventCreateKeyboardEvent(source, (CGKeyCode)key, false);
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
