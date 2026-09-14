//
//  UBMenu.m
//  Übersicht
//
//  Released under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version. See <http://www.gnu.org/licenses/> for
//  details.

#import "UBMenu.h"

NSString * const UBAppName = @"Rücksicht";
NSString * const UBWidgetSectionAnchor = @"widgetSectionAnchor";

@implementation UBMenu

+ (NSMenu *)statusBarMenuWithTarget:(id)target
{
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Status Bar Menu"];

    [self add:[NSString stringWithFormat:@"About %@", UBAppName]
            to:menu
        action:@selector(orderFrontStandardAboutPanel:)
        target:NSApp];

    // No separator before this item: UBWidgetsController inserts the widget
    // section at the anchor, and it opens with one of its own.
    NSMenuItem* widgetDir = [self add:@"Open Widgets Folder"
                                   to:menu
                               action:@selector(openWidgetDir:)
                               target:target];
    widgetDir.identifier = UBWidgetSectionAnchor;

    [self add:@"Visit Widget Gallery"
            to:menu
        action:@selector(visitWidgetGallery:)
        target:target];

    [menu addItem:[NSMenuItem separatorItem]];

    [self add:@"Show Debug Console"
            to:menu
        action:@selector(showDebugConsole:)
        target:target];

    [self add:@"Refresh All Widgets"
            to:menu
        action:@selector(refreshWidgets:)
        target:target];

    [menu addItem:[NSMenuItem separatorItem]];

    [self add:@"Preferences..."
            to:menu
        action:@selector(showPreferences:)
        target:target];

    [menu addItem:[NSMenuItem separatorItem]];

    [self add:[NSString stringWithFormat:@"Quit %@", UBAppName]
            to:menu
        action:@selector(terminate:)
        target:NSApp];

    return menu;
}

+ (NSMenu *)mainMenu
{
    NSMenu* mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    [mainMenu addItem:[self submenuNamed:UBAppName items:^(NSMenu* menu) {
        [menu addItemWithTitle:[NSString stringWithFormat:@"About %@", UBAppName]
                        action:@selector(orderFrontStandardAboutPanel:)
                 keyEquivalent:@""];
        [menu addItemWithTitle:@"Preferences…"
                        action:@selector(showPreferences:)
                 keyEquivalent:@","];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItemWithTitle:[NSString stringWithFormat:@"Hide %@", UBAppName]
                        action:@selector(hide:)
                 keyEquivalent:@"h"];
        NSMenuItem* hideOthers = [menu
            addItemWithTitle:@"Hide Others"
                      action:@selector(hideOtherApplications:)
               keyEquivalent:@"h"
        ];
        hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand
                                             | NSEventModifierFlagOption;
        [menu addItemWithTitle:@"Show All"
                        action:@selector(unhideAllApplications:)
                 keyEquivalent:@""];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", UBAppName]
                        action:@selector(terminate:)
                 keyEquivalent:@"q"];
    }]];

    [mainMenu addItem:[self submenuNamed:@"Edit" items:^(NSMenu* menu) {
        [menu addItemWithTitle:@"Undo"
                        action:@selector(undo:)
                 keyEquivalent:@"z"];
        [menu addItemWithTitle:@"Redo"
                        action:@selector(redo:)
                 keyEquivalent:@"Z"];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItemWithTitle:@"Cut"
                        action:@selector(cut:)
                 keyEquivalent:@"x"];
        [menu addItemWithTitle:@"Copy"
                        action:@selector(copy:)
                 keyEquivalent:@"c"];
        [menu addItemWithTitle:@"Paste"
                        action:@selector(paste:)
                 keyEquivalent:@"v"];
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItemWithTitle:@"Select All"
                        action:@selector(selectAll:)
                 keyEquivalent:@"a"];
    }]];

    return mainMenu;
}

#
#pragma mark building blocks
#

/// Menu bar items are dispatched through the responder chain, so they carry no
/// target; the submenu owns the items.
+ (NSMenuItem *)submenuNamed:(NSString *)name items:(void (^)(NSMenu *))build
{
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:name
                                                  action:NULL
                                           keyEquivalent:@""];
    NSMenu* submenu = [[NSMenu alloc] initWithTitle:name];
    build(submenu);
    item.submenu = submenu;
    return item;
}

+ (NSMenuItem *)add:(NSString *)title
                 to:(NSMenu *)menu
             action:(SEL)action
             target:(id)target
{
    NSMenuItem* item = [menu addItemWithTitle:title
                                       action:action
                                keyEquivalent:@""];
    item.target = target;
    return item;
}

@end
