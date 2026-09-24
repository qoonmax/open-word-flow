#import <AppKit/AppKit.h>

#include <signal.h>
#include <unistd.h>

#include "native_darwin.h"

@interface OWFAppActions : NSObject
@end

@implementation OWFAppActions

- (void)openSettings:(id)sender {
    owf_settings_open();
}

// Quit through SIGTERM so Go runs the same graceful shutdown as Ctrl+C.
- (void)quit:(id)sender {
    kill(getpid(), SIGTERM);
}

@end

static OWFAppActions *owf_actions;
static NSStatusItem *owf_status_item;

static NSMenuItem *owf_menu_item(NSString *title, SEL action, NSString *key, id target) {
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key] autorelease];
    item.target = target;

    return item;
}

static void owf_add_submenu(NSMenu *menu, NSMenu *submenu) {
    NSMenuItem *holder = [[[NSMenuItem alloc] init] autorelease];
    holder.submenu = submenu;
    [menu addItem:holder];
}

// A menu bar app shows no main menu, but key equivalents such as Cmd+V in the
// Settings window still go through it.
static void owf_setup_main_menu(void) {
    NSMenu *app = [[[NSMenu alloc] initWithTitle:@"Open Word Flow"] autorelease];
    [app addItem:owf_menu_item(@"Settings…", @selector(openSettings:), @",", owf_actions)];
    [app addItem:owf_menu_item(@"Quit Open Word Flow", @selector(quit:), @"q", owf_actions)];

    NSMenu *edit = [[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];
    [edit addItem:owf_menu_item(@"Undo", @selector(undo:), @"z", nil)];
    NSMenuItem *redo = owf_menu_item(@"Redo", @selector(redo:), @"z", nil);
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [edit addItem:redo];
    [edit addItem:[NSMenuItem separatorItem]];
    [edit addItem:owf_menu_item(@"Cut", @selector(cut:), @"x", nil)];
    [edit addItem:owf_menu_item(@"Copy", @selector(copy:), @"c", nil)];
    [edit addItem:owf_menu_item(@"Paste", @selector(paste:), @"v", nil)];
    [edit addItem:owf_menu_item(@"Select All", @selector(selectAll:), @"a", nil)];

    NSMenu *window = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];
    [window addItem:owf_menu_item(@"Close", @selector(performClose:), @"w", nil)];

    NSMenu *main = [[[NSMenu alloc] init] autorelease];
    owf_add_submenu(main, app);
    owf_add_submenu(main, edit);
    owf_add_submenu(main, window);
    NSApp.mainMenu = main;
}

// Rebuilds the menu bar icon's menu in the current interface language.
void owf_status_menu_reload(void) {
    NSMenuItem *hint = [[[NSMenuItem alloc] initWithTitle:owf_text(@"Double-press Fn to dictate")
                                                   action:nil
                                            keyEquivalent:@""] autorelease];
    hint.enabled = NO;

    NSMenu *menu = [[[NSMenu alloc] init] autorelease];
    [menu addItem:hint];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:owf_menu_item(owf_text(@"Settings…"), @selector(openSettings:), @",", owf_actions)];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:owf_menu_item(owf_text(@"Quit Open Word Flow"), @selector(quit:), @"q", owf_actions)];
    owf_status_item.menu = menu;
}

static void owf_setup_status_item(void) {
    owf_status_item = [[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength] retain];
    owf_status_item.button.image = [NSImage imageWithSystemSymbolName:@"waveform"
                                             accessibilityDescription:@"Open Word Flow"];
    owf_status_menu_reload();
}

static void owf_init_app(void) {
    [NSApplication sharedApplication];
    // No Dock icon; the island never takes focus from the app that receives the paste.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

void owf_activate(void) {
    if (@available(macOS 14, *)) {
        [NSApp activate];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
    }
}

void owf_ui_run(void) {
    @autoreleasepool {
        owf_init_app();
        owf_actions = [[OWFAppActions alloc] init];
        owf_setup_main_menu();
        owf_setup_status_item();
        owf_island_setup();
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

void owf_ui_alert(const char *message) {
    @autoreleasepool {
        owf_init_app();
        owf_activate();

        NSAlert *alert = [[[NSAlert alloc] init] autorelease];
        alert.messageText = owf_text(@"Open Word Flow stopped");
        alert.informativeText = [NSString stringWithUTF8String:message] ?: @"";
        [alert runModal];
    }
}
