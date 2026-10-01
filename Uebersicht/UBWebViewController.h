//
//  UBWebViewController.h
//  Uebersicht
//
//  Created by Felix Hageloh on 2/7/16.
//  Copyright © 2016 tracesOf. All rights reserved.
//

#import <Foundation/Foundation.h>
@import WebKit;

@interface UBWebViewController : NSObject<WKNavigationDelegate>

@property (strong, readonly) NSView* view;

+ (NSString*)sessionToken;
- (id)initWithFrame:(NSRect)frame;
- (void)load:(NSURL*)url;
- (void)redraw;
- (void)destroy;
/// Runs `stalled` when the page renders no frame within `timeout`.
- (void)expectFrameWithin:(NSTimeInterval)timeout
                   orElse:(void (^)(void))stalled;

@end
