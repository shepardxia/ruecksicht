//
//  UBPreferencesController.m
//  Übersicht
//
//  Created by Felix Hageloh on 20/3/14.
//  Copyright (c) 2014 Felix Hageloh.
//
//  Released under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version. See <http://www.gnu.org/licenses/> for
//  details.

#import "UBPreferencesController.h"
#import "UBAppDelegate.h"

// One label column of uniform width, one control column; hints sit under their
// control, indented to the checkbox title.
static const CGFloat UBPrefsMargin = 20;
static const CGFloat UBPrefsColumnGap = 8;
static const CGFloat UBPrefsRowGap = 12;
static const CGFloat UBPrefsHintGap = 4;
static const CGFloat UBPrefsHintIndent = 18;
static const CGFloat UBPrefsColumnWidth = 348;

@implementation UBPreferencesController {
    LSSharedFileListRef loginItems;
    NSPopUpButton* filePicker;
}

- (instancetype)init
{
    self = [super initWithWindow:nil];
    if (self) {

        NSData* defaultWidgetDir = [self ensureDefaultsWidgetDir];
        NSDictionary *appDefaults = @{
            @"widgetDirectory": defaultWidgetDir,
            @"enableInteraction": @YES
        };
        [[NSUserDefaults standardUserDefaults] registerDefaults:appDefaults];

        // watch for login item changes
        loginItems = LSSharedFileListCreate(NULL,
                                            kLSSharedFileListSessionLoginItems,
                                            NULL);

        LSSharedFileListAddObserver(loginItems,
                                    CFRunLoopGetMain(),
                                    kCFRunLoopCommonModes,
                                    loginItemsChanged,
                                    (__bridge void*)self);

        [self setWindow:[self buildWindow]];

        [[self.window standardWindowButton:NSWindowMiniaturizeButton] setEnabled:NO];
        [[self.window standardWindowButton:NSWindowZoomButton] setEnabled:NO];

        [self widgetDirChanged:self.widgetDir];
    }

    return self;
}

#
#pragma mark Window
#

// NSWindowController only loads a window lazily when it owns a nib, so the
// window is built here and handed to -setWindow: while the controller is built.
- (NSWindow*)buildWindow
{
    NSView* form = [self buildForm];
    NSView* content = [[NSView alloc] initWithFrame:NSZeroRect];

    [content addSubview:form];
    [NSLayoutConstraint activateConstraints:@[
        [form.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                           constant:UBPrefsMargin],
        [form.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                            constant:-UBPrefsMargin],
        [form.topAnchor constraintEqualToAnchor:content.topAnchor
                                       constant:UBPrefsMargin],
        [form.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                          constant:-UBPrefsMargin]
    ]];

    NSWindow* window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 500, 260)
                  styleMask:NSWindowStyleMaskTitled
                            | NSWindowStyleMaskClosable
                            | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:YES
    ];

    window.title = @"Rücksicht Preferences";
    window.releasedWhenClosed = NO;
    window.restorable = NO;
    window.contentView = content;
    [window setContentSize:content.fittingSize];
    [window center];

    return window;
}

- (NSView*)buildForm
{
    NSTextField* startupLabel = [self makeLabel:@"Startup:"];
    NSTextField* folderLabel = [self makeLabel:@"Widgets Folder:"];
    NSTextField* interactionLabel = [self makeLabel:@"Interaction:"];
    NSTextField* shellLabel = [self makeLabel:@"Shell Commands:"];

    CGFloat labelWidth = 0;
    for (NSTextField* label in @[startupLabel, folderLabel,
                                 interactionLabel, shellLabel]) {
        labelWidth = MAX(labelWidth, label.fittingSize.width);
    }
    CGFloat hintIndent = labelWidth + UBPrefsColumnGap + UBPrefsHintIndent;

    filePicker = [self makeFilePicker];

    NSStackView* form = [[NSStackView alloc] initWithFrame:NSZeroRect];
    form.translatesAutoresizingMaskIntoConstraints = NO;
    form.orientation = NSUserInterfaceLayoutOrientationVertical;
    form.alignment = NSLayoutAttributeLeading;
    form.spacing = UBPrefsRowGap;

    [form addArrangedSubview:
        [self rowWithLabel:startupLabel
                     width:labelWidth
                   control:[self makeCheckbox:@"Launch Rücksicht when I login"
                                     boundTo:@"startAtLogin"]]];

    [form addArrangedSubview:[self rowWithLabel:folderLabel
                                          width:labelWidth
                                        control:filePicker]];

    NSView* interactionRow =
        [self rowWithLabel:interactionLabel
                     width:labelWidth
                   control:[self makeCheckbox:@"Enable interaction"
                                     boundTo:@"enableInteraction"]];
    [form addArrangedSubview:interactionRow];
    [form addArrangedSubview:
        [self hintRow:@"Disable if you don't want widgets to be clickable and"
                       " always stay behind items on your desktop."
               indent:hintIndent]];
    [form setCustomSpacing:UBPrefsHintGap afterView:interactionRow];

    NSView* shellRow =
        [self rowWithLabel:shellLabel
                     width:labelWidth
                   control:[self makeCheckbox:@"Load Bash env"
                                     boundTo:@"loginShell"]];
    [form addArrangedSubview:shellRow];
    [form addArrangedSubview:
        [self hintRow:@"Loading Bash env will preserve your config, like locale"
                       " and PATH settings. However, if not set up correctly,"
                       " it can cause widgets to not function."
               indent:hintIndent]];
    [form setCustomSpacing:UBPrefsHintGap afterView:shellRow];

    return form;
}

- (NSStackView*)rowWithLabel:(NSTextField*)label
                       width:(CGFloat)width
                     control:(NSView*)control
{
    [[label.widthAnchor constraintEqualToConstant:width] setActive:YES];

    NSStackView* row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeFirstBaseline;
    row.spacing = UBPrefsColumnGap;
    [row addArrangedSubview:label];
    [row addArrangedSubview:control];

    return row;
}

- (NSView*)hintRow:(NSString*)text indent:(CGFloat)indent
{
    NSTextField* hint = [NSTextField wrappingLabelWithString:text];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.selectable = NO;
    hint.font = [NSFont labelFontOfSize:[NSFont smallSystemFontSize]];
    hint.textColor = [NSColor secondaryLabelColor];
    hint.preferredMaxLayoutWidth = UBPrefsColumnWidth - UBPrefsHintIndent;

    NSView* row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:hint];
    [NSLayoutConstraint activateConstraints:@[
        [hint.widthAnchor constraintEqualToConstant:
            UBPrefsColumnWidth - UBPrefsHintIndent],
        [hint.leadingAnchor constraintEqualToAnchor:row.leadingAnchor
                                           constant:indent],
        [hint.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [hint.topAnchor constraintEqualToAnchor:row.topAnchor],
        [hint.bottomAnchor constraintEqualToAnchor:row.bottomAnchor]
    ]];

    return row;
}

- (NSTextField*)makeLabel:(NSString*)text
{
    NSTextField* label = [NSTextField labelWithString:text];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.alignment = NSTextAlignmentRight;

    return label;
}

- (NSButton*)makeCheckbox:(NSString*)title boundTo:(NSString*)keyPath
{
    NSButton* checkbox = [NSButton checkboxWithTitle:title
                                              target:nil
                                              action:NULL];
    checkbox.translatesAutoresizingMaskIntoConstraints = NO;
    [checkbox bind:NSValueBinding
          toObject:self
       withKeyPath:keyPath
           options:nil];

    return checkbox;
}

// Item 0 stands for the current widget directory: -widgetDirChanged: keeps its
// title and icon current, so it must stay the first and selected item.
- (NSPopUpButton*)makeFilePicker
{
    NSPopUpButton* picker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect
                                                       pullsDown:NO];
    picker.translatesAutoresizingMaskIntoConstraints = NO;
    [[picker cell] setLineBreakMode:NSLineBreakByTruncatingTail];
    [picker.widthAnchor constraintEqualToConstant:UBPrefsColumnWidth].active = YES;
    [picker setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
    menu.autoenablesItems = NO;
    [menu addItemWithTitle:@"" action:NULL keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem* other = [menu addItemWithTitle:@"Other…"
                                        action:@selector(showFilePicker:)
                                 keyEquivalent:@""];
    other.target = self;

    picker.menu = menu;
    [picker selectItemAtIndex:0];

    return picker;
}

#
#pragma mark Widget Directory
#

- (void)showFilePicker:(id)sender
{
    NSOpenPanel* openPanel = [NSOpenPanel openPanel];

    [openPanel setCanChooseFiles:NO];
    [openPanel setCanChooseDirectories:YES];

    [openPanel beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            [self setWidgetDir:[openPanel URLs][0]];
        }

        [self->filePicker selectItemAtIndex:0];
    }];
}

- (NSURL*)widgetDir
{
    NSData* widgetDir = [[NSUserDefaults standardUserDefaults]
                         objectForKey:@"widgetDirectory"];

    return [NSKeyedUnarchiver unarchiveObjectWithData:widgetDir];
}

- (void)setWidgetDir:(NSURL*)newDir
{
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:[NSKeyedArchiver archivedDataWithRootObject:newDir]
                 forKey:@"widgetDirectory"];

    [self widgetDirChanged:newDir];
    [(UBAppDelegate *)[NSApp delegate] widgetDirDidChange];
}

- (void)widgetDirChanged:(NSURL*)url
{
    NSImage *iconImage = [[NSWorkspace sharedWorkspace] iconForFile:[url path]];
    [iconImage setSize:NSMakeSize(16,16)];

    [[filePicker itemAtIndex:0] setTitle: [url path]];
    [[filePicker itemAtIndex:0] setImage:iconImage];
}


- (NSData*)ensureDefaultsWidgetDir
{
    NSArray* urls = [[NSFileManager defaultManager]
        URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask
    ];

    NSURL* defaultDir = [urls[0]
        URLByAppendingPathComponent:@"Rücksicht/widgets"
        isDirectory:YES
    ];

    [self createIfNotExists:defaultDir];

    return [NSKeyedArchiver archivedDataWithRootObject:defaultDir];
}

- (void)createIfNotExists:(NSURL*)defaultWidgetDir
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    BOOL isDir;

    if ([fileManager fileExistsAtPath:[defaultWidgetDir path] isDirectory:&isDir] && isDir) {
        return;
    }

    NSError* error;
    [fileManager createDirectoryAtURL:defaultWidgetDir
          withIntermediateDirectories:YES
                           attributes:nil
                                error:&error];

    if (error) {
        NSLog(@"%@", error);
        return;
    }

    // A missing resource yields a nil URL, and copying from nil raises. An
    // empty widget folder is a far better first launch than a crash.
    [self seedResource:@"GettingStarted" extension:@"jsx"
                  into:defaultWidgetDir as:@"GettingStarted.jsx"];
    [self seedResource:@"ruecksicht-logo" extension:@"png"
                  into:defaultWidgetDir as:@"logo.png"];
}

- (void)seedResource:(NSString*)name
           extension:(NSString*)extension
                into:(NSURL*)directory
                  as:(NSString*)filename
{
    NSURL* source = [[NSBundle mainBundle] URLForResource:name withExtension:extension];

    if (!source) {
        NSLog(@"%@.%@ is missing from the app bundle", name, extension);
        return;
    }

    NSError* error;
    [[NSFileManager defaultManager]
        copyItemAtURL:source
                toURL:[directory URLByAppendingPathComponent:filename]
                error:&error];

    if (error) {
        NSLog(@"%@", error);
    }
}

#
#pragma mark Login Shell
#


- (BOOL)loginShell
{
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    return [defaults boolForKey:@"loginShell"];
}

- (void)setLoginShell:(BOOL)enabled
{
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:@"loginShell"];
    [(UBAppDelegate *)[NSApp delegate] loginShellDidChange];
}


#
#pragma mark Interaction
#


- (BOOL)enableInteraction
{
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    return [[defaults valueForKey:@"enableInteraction"] boolValue];
}

- (void)setEnableInteraction:(BOOL)enabled
{
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:@(enabled) forKey:@"enableInteraction"];
    [(UBAppDelegate *)[NSApp delegate] interactionDidChange];
}

#
#pragma mark Startup
#

- (BOOL)startAtLogin
{
    return [self getLoginItem] != NULL;
}

- (void)setStartAtLogin:(BOOL)doStart
{
    if (doStart) {
        NSURL *bundleURL = [NSURL fileURLWithPath:[[NSBundle mainBundle] bundlePath]];
        LSSharedFileListInsertItemURL(loginItems,
                                      kLSSharedFileListItemLast,
                                      NULL,
                                      NULL,
                                      (__bridge CFURLRef)bundleURL,
                                      NULL,
                                      NULL);
    } else {
        LSSharedFileListItemRef loginItemRef = [self getLoginItem];
        if (loginItemRef) {
            LSSharedFileListItemRemove(loginItems, loginItemRef);
            CFRelease(loginItemRef);
        }

    }
}

- (LSSharedFileListItemRef)getLoginItem
{
    CFArrayRef snapshotRef = LSSharedFileListCopySnapshot(loginItems, NULL);
    NSURL *bundleURL = [NSURL fileURLWithPath:[[NSBundle mainBundle] bundlePath]];

    LSSharedFileListItemRef itemRef = NULL;
    CFURLRef itemURLRef;

    for (id item in (__bridge NSArray*)snapshotRef) {
        itemRef = (__bridge LSSharedFileListItemRef)item;
        if (LSSharedFileListItemResolve(itemRef, 0, &itemURLRef, NULL) == noErr) {
            if ([bundleURL isEqual:((__bridge NSURL *)itemURLRef)]) {
                CFRetain(itemRef);
                break;
            }
        }
        itemRef = NULL;
    }

    CFRelease(snapshotRef);
    return itemRef;
}

// The checkbox reads -startAtLogin through a binding, so a login item added or
// removed behind our back only shows up if the change is announced by hand.
static void loginItemsChanged(LSSharedFileListRef listRef, void *context)
{
    UBPreferencesController *controller = (__bridge UBPreferencesController*)context;

    [controller willChangeValueForKey:@"startAtLogin"];
    [controller didChangeValueForKey:@"startAtLogin"];
}

#
#pragma mark Teardown
#

- (void)dealloc
{
    LSSharedFileListRemoveObserver(loginItems,
                                   CFRunLoopGetMain(),
                                   kCFRunLoopCommonModes,
                                   loginItemsChanged,
                                   (__bridge void*)self);
    CFRelease(loginItems);
}


@end
