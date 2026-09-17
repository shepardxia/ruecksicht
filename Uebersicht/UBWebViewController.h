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
- (void)reload;
- (void)redraw;
- (void)destroy;
/// WebKit's GPU helper for this view, 0 when it has none.
- (pid_t)gpuProcessIdentifier;

@end
