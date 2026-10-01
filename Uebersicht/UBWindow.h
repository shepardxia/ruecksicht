//
//  UBWindow.h
//  Übersicht
//
//  Created by Felix Hageloh on 20/9/13.
//  Copyright (c) 2013 Felix Hageloh.
//
//  Released under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version. See <http://www.gnu.org/licenses/> for
//  details.

#import <Cocoa/Cocoa.h>


typedef NS_ENUM(NSInteger, UBWindowType) {
    UBWindowTypeAgnostic,
    UBWindowTypeBackground,
    UBWindowTypeForeground
};


@interface UBWindow : NSWindow

- (id)initWithWindowType:(UBWindowType)type;
/// Loads this window's layer of the page for a screen. The window stays
/// invisible until `reveal`; `ready` runs once, when the page reports its
/// widgets drawn.
- (void)loadUrl:(NSURL*)screenUrl onReady:(void (^)(void))ready;
- (void)pageDidBecomeReady;
- (void)reveal;
- (void)redraw;
/// Runs `stalled` when the window is in view and its page renders no frame
/// within `timeout`. A covered window's page is paused by WebKit and owes no
/// frame.
- (void)expectFrameWithin:(NSTimeInterval)timeout
                   orElse:(void (^)(void))stalled;

@end
