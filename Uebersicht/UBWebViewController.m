//
//  UBWebViewController.m
//  Uebersicht
//
//  Created by Felix Hageloh on 2/7/16.
//  Copyright © 2016 tracesOf. All rights reserved.
//

#import "UBWebViewController.h"
#import "UBLocation.h"
#import "UBWebView.h"
#import "UBWindow.h"


// Owned by the shared configuration, which retains its message handlers for the
// lifetime of the app. It must therefore not be a web view controller, or that
// controller and its web view could never be released.
@interface UBWidgetInteraction : NSObject<WKScriptMessageHandler>
@end

@implementation UBWidgetInteraction

- (void)userContentController:(WKUserContentController *)controller
    didReceiveScriptMessage:(WKScriptMessage *)message
{
    if ([message.body isEqual: @"widgetEnter"]) {
        [message.webView.window setIgnoresMouseEvents: NO];
    } else if ([message.body isEqual:@"widgetLeave"]) {
        [message.webView.window setIgnoresMouseEvents: YES];
    } else if ([message.body isEqual:@"ready"]) {
        [(UBWindow*)message.webView.window pageDidBecomeReady];
    }
}

@end


@interface WKWebView (UBPageLifetime)
- (void)_close;
@end

@implementation UBWebViewController {
    NSURL* url;
}

// Minted once per launch and required by the widget server on /run/, so that
// another local process cannot reach an endpoint that runs shell commands.
+ (NSString*)sessionToken
{
    static NSString* token = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        token = [[NSUUID UUID] UUIDString];
    });
    return token;
}

@synthesize view;

- (id)initWithFrame:(NSRect)frame
{
     self = [super init];
    
     if (self) {
        view = [self buildWebView:frame];
     }
    
     return self;
}

- (void)load:(NSURL*)newUrl
{
    url = newUrl;
    [(WKWebView*)view loadRequest:[NSURLRequest requestWithURL: url]];
}

- (void)redraw
{
    [self forceRedraw:(WKWebView*)view];
}

- (void)expectFrameWithin:(NSTimeInterval)timeout
                   orElse:(void (^)(void))stalled
{
    __block BOOL rendered = NO;
    [(WKWebView*)view
        callAsyncJavaScript: @"return new Promise(resolve => requestAnimationFrame(resolve))"
        arguments: nil
        inFrame: nil
        inContentWorld: [WKContentWorld pageWorld]
        completionHandler: ^(id result, NSError* error) { rendered = !error; }
    ];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_SEC),
        dispatch_get_main_queue(),
        ^{ if (!rendered) stalled(); }
    );
}

- (void)destroy
{
    [self teardownWebview:(WKWebView *)view];
    view = nil;
}

- (WKWebView*)buildWebView:(NSRect)frame
{
    WKWebView* webView = [[UBWebView alloc]
        initWithFrame: frame
        configuration: [self sharedConfig]
    ];
    [webView setValue:@YES forKey:@"drawsTransparentBackground"];
    [webView.configuration.preferences
        setValue: @YES
        forKey: @"developerExtrasEnabled"
    ];
    webView.navigationDelegate = (id<WKNavigationDelegate>)self;
    
    return webView;
}

// A released view leaves its page and content process running. The page is
// closed first, as WebKit reloads an open page whose process dies; the process
// is then killed, as one that stopped rendering ignores being asked to exit.
- (void)teardownWebview:(WKWebView*)webView
{
    webView.navigationDelegate = nil;
    if ([webView respondsToSelector:@selector(_close)]) {
        pid_t contentProcess = [[webView valueForKey:@"_webProcessIdentifier"] intValue];
        [webView _close];
        if (contentProcess > 0) kill(contentProcess, SIGKILL);
    }
    [webView removeFromSuperview];
}

- (WKWebViewConfiguration*)sharedConfig {
    static WKWebViewConfiguration *sharedConfig = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedConfig = [self buildConfig];
    });
    return sharedConfig;
}

- (WKWebViewConfiguration*)buildConfig
{
    WKUserContentController* ucController = [
        [WKUserContentController alloc] init
    ];
    
    // geolocation
    [ucController
        addScriptMessageHandler: [[UBLocation alloc] init]
        name: @"geolocation"
    ];
    
    NSString* geolocationScript = [NSString
        stringWithContentsOfURL: [[NSBundle mainBundle]
            URLForResource: @"geolocation"
            withExtension: @"js"
        ]
        encoding: NSUTF8StringEncoding
        error: nil
    ];
    [ucController addUserScript:[[WKUserScript alloc]
        initWithSource: geolocationScript
        injectionTime: WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly: YES
    ]];
    
    [ucController
        addScriptMessageHandler: [[UBWidgetInteraction alloc] init]
        name: @"uebersicht"
    ];

    NSString* tokenScript = [NSString
        stringWithFormat: @"window.__ubToken = '%@';", [UBWebViewController sessionToken]
    ];
    [ucController addUserScript:[[WKUserScript alloc]
        initWithSource: tokenScript
        injectionTime: WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly: YES
    ]];
    
    WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
    config.userContentController = ucController;
    
    return config;
}

- (void)forceRedraw:(WKWebView*)webView
{
    [webView
         evaluateJavaScript:
             @"document.documentElement.style.transform = 'scale(1)';\
               requestAnimationFrame(function() {\
                 document.documentElement.style.transform = '';\
               });"
         completionHandler:NULL
     ];
}


- (void)webView:(WKWebView *)webView
    didFinishNavigation:(WKNavigation*)navigation
{
    NSLog(@"loaded %@", webView.URL);
}

// WebKit drops a page's content process on display and GPU changes, among
// other things, and a dropped process leaves a blank window until the page is
// loaded again.
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    NSLog(@"content process for %@ terminated, reloading", url);
    [webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)webView:(WKWebView *)sender
    didFailNavigation:(WKNavigation*)nav
    withError:(NSError *)error
{
    [self handleWebviewLoadError:error];
}

- (void)webView:(WKWebView *)sender
    didFailProvisionalNavigation:(WKNavigation *)nav
    withError:(NSError *)error
{
    [self handleWebviewLoadError:error];
}


- (void)webView: (WKWebView *)theWebView
    decidePolicyForNavigationAction: (WKNavigationAction*)action
    decisionHandler: (void (^)(WKNavigationActionPolicy))handler
{
    if (!action.targetFrame.mainFrame) {
        handler(WKNavigationActionPolicyAllow);
    } else if ([action.request.URL isEqual: url]) {
        handler(WKNavigationActionPolicyAllow);
    } else if (action.navigationType == WKNavigationTypeLinkActivated) {
        [[NSWorkspace sharedWorkspace] openURL:action.request.URL];
        handler(WKNavigationActionPolicyCancel);
    } else {
        handler(WKNavigationActionPolicyCancel);
    }

}

- (void)handleWebviewLoadError:(NSError *)error
{
    NSLog(@"Error loading webview: %@", error);
    [self
        performSelector: @selector(load:)
        withObject: url
        afterDelay: 5.0
    ];
}

@end
