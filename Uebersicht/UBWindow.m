//
//  UBWindow.m
//  Übersicht
//
//  A window that sits on desktop level, is always fullscreen and doesn't show
//  up in Mission Control
//
//  Created by Felix Hageloh on 20/9/13.
//  Copyright (c) 2013 Felix Hageloh.
//  Released under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version. See <http://www.gnu.org/licenses/> for
//  details.
//

#import "UBWindow.h"
#import "UBWebViewController.h"

@implementation UBWindow {
    UBWebViewController* webViewController;
    NSTrackingArea* trackingArea;
    UBWindowType type;
    void (^onReady)(void);
}

- (id)initWithWindowType:(UBWindowType)windowType
{
    self = [super
        initWithContentRect: NSMakeRect(0, 0, 0, 0)
        styleMask: NSBorderlessWindowMask
        backing: NSBackingStoreBuffered
        defer: NO
    ];
    
    if (self) {
        type = windowType;
        [self setBackgroundColor:[NSColor clearColor]];
        [self setOpaque:NO];
        [self setCollectionBehavior:(
            NSWindowCollectionBehaviorStationary |
            NSWindowCollectionBehaviorCanJoinAllSpaces |
            NSWindowCollectionBehaviorIgnoresCycle
        )];

        [self setRestorable:NO];
        [self disableSnapshotRestoration];
        [self setDisplaysWhenScreenProfileChanges:YES];
        [self setReleasedWhenClosed:NO];
        [self setLevel: type == UBWindowTypeForeground
            ? kCGNormalWindowLevel - 1
            : kCGDesktopWindowLevel
        ];
        [self setIgnoresMouseEvents:YES];
        // Transparent rather than ordered out: the page of a window that is
        // ordered out counts as hidden and renders no frames.
        [self setAlphaValue:0];
        
        webViewController = [[UBWebViewController alloc]
            initWithFrame: [self frame]
        ];
        [self setContentView:webViewController.view];
    }

    return self;
}

- (void)loadUrl:(NSURL*)screenUrl onReady:(void (^)(void))ready
{
    onReady = [ready copy];

    NSURL* url = screenUrl;
    if (type == UBWindowTypeBackground) {
        url = [screenUrl URLByAppendingPathComponent:@"background"];
    } else if (type == UBWindowTypeForeground) {
        url = [screenUrl URLByAppendingPathComponent:@"foreground"];
    }
    [webViewController load:url];
}

- (void)pageDidBecomeReady
{
    void (^ready)(void) = onReady;
    onReady = nil;
    if (ready) ready();
}

- (void)reveal
{
    [self setAlphaValue:1];
}

// The web view is torn down with the window, not left to ARC: one that
// outlives its window keeps its page and content process running.
- (void)close
{
    if (trackingArea != nil) {
        [self.contentView removeTrackingArea:trackingArea];
        trackingArea = nil;
    }
    onReady = nil;
    [webViewController destroy];
    webViewController = nil;
    [self setContentView:nil];
    [super close];
}

#
#pragma mark tracking area
#


- (void)setupTrackingArea
{
    trackingArea = [[NSTrackingArea alloc]
        initWithRect: self.contentView.bounds
        options: NSTrackingMouseMoved
            | NSTrackingMouseEnteredAndExited
            | NSTrackingActiveAlways
        owner: nil
        userInfo: nil
    ];
    [self.contentView addTrackingArea:trackingArea];
}

- (void)setFrame:(NSRect)newFrame display:(BOOL)doDisplay
{
    [super setFrame:newFrame display:doDisplay];
    [self updateTrackingArea];
}

- (void)updateTrackingArea
{
    if (trackingArea != nil) {
        [self.contentView removeTrackingArea:trackingArea];
    }
    if (self.contentView) {
        [self setupTrackingArea];
    }
}

#
#pragma mark signals/events
#

- (void)redraw
{
    [webViewController redraw];
}

- (BOOL)isInView
{
    return (self.occlusionState & NSWindowOcclusionStateVisible) != 0;
}

- (void)expectFrameWithin:(NSTimeInterval)timeout
                   orElse:(void (^)(void))stalled
{
    if (![self isInView]) return;

    [webViewController expectFrameWithin:timeout orElse:^{
        if ([self isInView]) stalled();
    }];
}

#
#pragma mark flags
#

- (BOOL)isKeyWindow { return type == UBWindowTypeForeground; }
- (BOOL)canBecomeKeyWindow { return type == UBWindowTypeForeground; }
- (BOOL)canBecomeMainWindow { return type == UBWindowTypeForeground; }
- (BOOL)acceptsFirstResponder { return type == UBWindowTypeForeground; }
- (BOOL)acceptsMouseMovedEvents { return type == UBWindowTypeForeground;; }

@end
