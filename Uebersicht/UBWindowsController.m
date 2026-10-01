//
//  UBWindowsController.m
//  Uebersicht
//
//  Created by Felix Hageloh on 30/09/2020.
//  Copyright © 2020 tracesOf. All rights reserved.
//

#import "UBWindowsController.h"
#import "UBWindow.h"
#import "WKInspector.h"
#import "WKView.h"
#import "WKPage.h"
#import "WKWebViewInternal.h"

@import WebKit;

// The windows of every screen, by screen id.
typedef NSDictionary<NSNumber*, NSArray<UBWindow*>*> UBWindowSet;

// A display change arrives as a burst of notifications, and docking or waking
// sets off several causes at once. A rebuild waits until they stop coming.
static const NSTimeInterval SETTLE_DELAY = 0.5;
// How long new pages get to draw before they are shown regardless.
static const NSTimeInterval DRAW_TIMEOUT = 5;
// A page in view renders a frame within FRAME_TIMEOUT of being asked. The
// interval is the longer of the two, so one check ends before the next.
static const NSTimeInterval RENDER_CHECK_INTERVAL = 10;
static const NSTimeInterval FRAME_TIMEOUT = 5;

@implementation UBWindowsController {
    // On screen.
    UBWindowSet* shown;
    // Drawing out of sight, to take the place of `shown`.
    UBWindowSet* staged;
}

- (id)init
{
    self = [super init];
    if (self) {
        NSNotificationCenter* workspace =
            [[NSWorkspace sharedWorkspace] notificationCenter];

        // Windows are built for the displays as they stand.
        [[NSNotificationCenter defaultCenter]
            addObserver: self
            selector: @selector(rebuild)
            name: NSApplicationDidChangeScreenParametersNotification
            object: nil
        ];
        [workspace
            addObserver: self
            selector: @selector(rebuild)
            name: NSWorkspaceDidWakeNotification
            object: nil
        ];
        [workspace
            addObserver: self
            selector: @selector(redraw)
            name: NSWorkspaceActiveSpaceDidChangeNotification
            object: nil
        ];

        __weak UBWindowsController* weakSelf = self;
        [NSTimer
            scheduledTimerWithTimeInterval: RENDER_CHECK_INTERVAL
            repeats: YES
            block: ^(NSTimer* timer) { [weakSelf checkRendering]; }
        ];
    }
    return self;
}

- (void)setBaseUrl:(NSURL*)baseUrl
{
    _baseUrl = [baseUrl copy];
    [self rebuild];
}

- (void)setInteractionEnabled:(BOOL)interactionEnabled
{
    _interactionEnabled = interactionEnabled;
    [self rebuild];
}

- (void)rebuild
{
    [NSObject
        cancelPreviousPerformRequestsWithTarget: self
        selector: @selector(stage)
        object: nil
    ];
    [self performSelector:@selector(stage) withObject:nil afterDelay:SETTLE_DELAY];
}

// The new set is built invisible and takes over once every page in it has
// drawn, so a rebuild never bares the desktop.
- (void)stage
{
    [self makeWindowsIn:staged perform:@selector(close)];

    NSMutableDictionary<NSNumber*, NSArray<UBWindow*>*>* set =
        [NSMutableDictionary dictionary];
    for (NSScreen* screen in _baseUrl ? [NSScreen screens] : @[]) {
        set[[screen deviceDescription][@"NSScreenNumber"]] =
            [self windowsForScreen:screen];
    }
    staged = set;
    NSLog(@"using %lu screens", (unsigned long)[set count]);

    __block NSUInteger drawing = 0;
    for (NSNumber* screenId in set) {
        NSURL* url = [_baseUrl URLByAppendingPathComponent:[screenId stringValue]];
        for (UBWindow* window in set[screenId]) {
            drawing++;
            [window loadUrl:url onReady:^{
                if (--drawing == 0) [self promote:set];
            }];
        }
    }
    if (drawing == 0) [self promote:set];

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, DRAW_TIMEOUT * NSEC_PER_SEC),
        dispatch_get_main_queue(),
        ^{ [self promote:set]; }
    );
}

- (void)promote:(UBWindowSet*)set
{
    // Replaced by a later set before it drew, or on screen already.
    if (set != staged) return;

    staged = nil;
    [self makeWindowsIn:set perform:@selector(reveal)];
    [self makeWindowsIn:shown perform:@selector(close)];
    shown = set;
}

- (void)makeWindowsIn:(UBWindowSet*)set perform:(SEL)action
{
    for (NSArray<UBWindow*>* windows in [set allValues]) {
        [windows makeObjectsPerformSelector:action];
    }
}

// With interaction, a screen's widgets are split over a window above the
// desktop icons, which takes the mouse, and one below them.
- (NSArray<UBWindow*>*)windowsForScreen:(NSScreen*)screen
{
    NSArray<UBWindow*>* windows = _interactionEnabled
        ? @[
            [[UBWindow alloc] initWithWindowType:UBWindowTypeForeground],
            [[UBWindow alloc] initWithWindowType:UBWindowTypeBackground],
        ]
        : @[[[UBWindow alloc] initWithWindowType:UBWindowTypeAgnostic]];

    for (UBWindow* window in windows) {
        [window setFrame:[self frameForScreen:screen] display:YES];
        [window orderFront:self];
    }
    return windows;
}

- (NSRect)frameForScreen:(NSScreen*)screen
{
    CGFloat auxiliaryHeight = screen.auxiliaryTopLeftArea.size.height;
    CGFloat windowHeight = screen.visibleFrame.size.height +
        (screen.visibleFrame.origin.y - screen.frame.origin.y);

    // If the remaining visible height is exactly the auxiliaryHeight, the menu
    // bar is hidden. There seems to be no other way to dedect this reliably
    if (screen.frame.size.height - windowHeight == auxiliaryHeight) {
        windowHeight = windowHeight + auxiliaryHeight;
    }

    return NSMakeRect(
        screen.frame.origin.x,
        screen.frame.origin.y,
        screen.frame.size.width,
        windowHeight
    );
}

// A page can stop rendering while its scripts run on. Nothing reports that
// and no reload revives it; only a new view does.
- (void)checkRendering
{
    UBWindowSet* set = shown;
    for (NSNumber* screenId in set) {
        for (UBWindow* window in set[screenId]) {
            [window expectFrameWithin:FRAME_TIMEOUT orElse:^{
                if (set != self->shown) return;
                NSLog(@"screen %@ stopped rendering, rebuilding windows", screenId);
                [self rebuild];
            }];
        }
    }
}

- (void)redraw
{
    [self makeWindowsIn:shown perform:@selector(redraw)];
}

- (void)showDebugConsolesForScreen:(NSNumber*)screenId
{
    for (UBWindow* window in shown[screenId]) {
        [self showDebugConsoleForWindow:window];
    }
}

- (void)showDebugConsoleForWindow:(NSWindow*)window
{
    WKPageRef page = NULL;
    SEL pageForTesting = @selector(_pageForTesting);

    if ([window.contentView.subviews[0] isKindOfClass:[WKView class]]) {
        WKView* webview = window.contentView.subviews[0];
        page = webview.pageRef;
    } else if ([window.contentView respondsToSelector:pageForTesting]) {
        page = (__bridge WKPageRef)([window.contentView
            performSelector: pageForTesting
        ]);
    }

    if (page) {
        WKInspectorRef inspector = WKPageGetInspector(page);

        [NSApp activateIgnoringOtherApps:YES];

        WKInspectorShowConsole(inspector);
        [self
            performSelector: @selector(detachInspector:)
            withObject: (__bridge id)(inspector)
            afterDelay: 0
        ];
    }
}

- (void)detachInspector:(WKInspectorRef)inspector
{
     WKInspectorDetach(inspector);
}

@end
