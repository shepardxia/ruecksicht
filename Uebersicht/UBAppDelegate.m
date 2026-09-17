//
//  UBAppDelegate.m
//  Übersicht
//
//  Created by Felix Hageloh on 20/9/13.
//  Copyright (c) 2013 Felix Hageloh.
//
//  Released under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version. See <http://www.gnu.org/licenses/> for
//  details.

#import "UBAppDelegate.h"
#import "UBWebViewController.h"
#import "UBPreferencesController.h"
#import "UBScreensController.h"
#import "UBWidgetsController.h"
#import "UBWidgetsStore.h"
#import "UBWebSocket.h"
#import "UBWindowsController.h"
#import "UBMenu.h"

int const PORT = 41416;

@implementation UBAppDelegate {
    NSMenu* statusBarMenu;
    NSStatusItem* statusBarItem;
    NSTask* widgetServer;
    UBPreferencesController* preferences;
    UBScreensController* screensController;
    UBWindowsController* windowsController;
    BOOL shuttingDown;
    BOOL keepServerAlive;
    int port;
    UBWidgetsStore* widgetsStore;
    UBWidgetsController* widgetsController;
    pid_t gpuProcess;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    statusBarMenu = [UBMenu statusBarMenuWithTarget:self];
    statusBarItem = [self addStatusItemToMenu: statusBarMenu];
    preferences = [[UBPreferencesController alloc] init];

    // A daemon left behind by an earlier launch would still hold the port.
    system("killall -m ubersichtd");
    
    widgetsStore = [[UBWidgetsStore alloc] init];

    screensController = [[UBScreensController alloc]
        initWithChangeListener:self
    ];
    
    windowsController = [[UBWindowsController alloc] init];
    
    widgetsController = [[UBWidgetsController alloc]
        initWithMenu: statusBarMenu
        widgets: widgetsStore
        screens: screensController
        preferences: preferences
    ];
    [widgetsStore onChange: ^(NSDictionary* widgets) {
        [self->widgetsController render];
    }];
    
    // make sure notifcations always show
    NSUserNotificationCenter* unc = [NSUserNotificationCenter
        defaultUserNotificationCenter
    ];
    unc.delegate = self;
    

    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver: self
        selector: @selector(wakeFromSleep:)
        name: NSWorkspaceDidWakeNotification
        object: nil
    ];
    
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver: self
        selector: @selector(workspaceChanged:)
        name: NSWorkspaceActiveSpaceDidChangeNotification
        object: nil
    ];
    
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver: self
        selector: @selector(loginSessionBecameActive:)
        name: NSWorkspaceSessionDidBecomeActiveNotification
        object: nil
    ];
 
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver: self
        selector: @selector(loginSessionResigned:)
        name: NSWorkspaceSessionDidResignActiveNotification
        object: nil
    ];
    
    // start server and load webview
    port = PORT;
    [self startUp];

    // When WebKit's GPU helper dies, every web view keeps its page but never
    // paints again, and no reload brings it back. Only new views do.
    [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer* timer) {
        pid_t current = [self->windowsController gpuProcessIdentifier];
        if (self->gpuProcess && current != self->gpuProcess) {
            NSLog(@"gpu process %d gone (now %d), rebuilding windows", self->gpuProcess, current);
            [self->screensController syncScreens];
        }
        self->gpuProcess = current;
    }];
    
    [self listenToWallpaperChanges];
}

- (NSDictionary*)fetchState
{
    NSURL *urlPath = [[self serverUrl:@"http"] URLByAppendingPathComponent: @"state/"];
    NSData *jsonData = [NSData dataWithContentsOfURL:urlPath];
    NSError *error = nil;
    NSDictionary *dataDictionary = [NSJSONSerialization
        JSONObjectWithData: jsonData
        options: NSJSONReadingMutableContainers
        error: &error
    ];
    if (error) NSLog(@"%@", error);
    return dataDictionary;
}

- (void)startUp
{

    NSLog(@"starting server task");
    
    void (^handleData)(NSString*) = ^(NSString* output) {
        // The daemon binds the first free port at or after PORT and says which.
        NSRange started = [output rangeOfString:@"server started on port "];
        if (started.location != NSNotFound) {
            self->port = [[output substringFromIndex:NSMaxRange(started)] intValue];
            [[UBWebSocket sharedSocket] open:[self serverUrl:@"ws"]];
            [self->widgetsStore reset: [self fetchState]];
            // this will trigger a render
            [self->screensController syncScreens];
        }
    };

    void (^handleExit)(NSTask*) = ^(NSTask* theTask) {
        if (!self->shuttingDown) {
            // The server crashed: tear down but stay alive for the relaunch.
            [self shutdown:YES];
        }
        if (self->keepServerAlive) {
            [self
                performSelector: @selector(startUp)
                withObject: nil
                afterDelay: 1.0
            ];
        }
    };
    
    shuttingDown = NO;
    keepServerAlive = YES;
    widgetServer = [self
        launchWidgetServer: [preferences.widgetDir path]
        onData: handleData
        onExit: handleExit
    ];
}

- (void)shutdown:(Boolean)keepAlive
{
    if (shuttingDown) {
        return;
    }
    shuttingDown = YES;

    keepServerAlive = keepAlive;
    [windowsController closeAll];
    [[UBWebSocket sharedSocket] close];
    if (widgetServer){
        [widgetServer terminate];
    }
}

- (void)shutdown
{
    [self shutdown:false];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    keepServerAlive = NO;
    [widgetServer terminate];
    [[NSStatusBar systemStatusBar] removeStatusItem:statusBarItem];
    
}

- (NSStatusItem*)addStatusItemToMenu:(NSMenu*)aMenu
{
    NSStatusBar*  bar = [NSStatusBar systemStatusBar];
    NSStatusItem* item;

    item = [bar statusItemWithLength: NSSquareStatusItemLength];
    
    NSImage *image = [[NSBundle mainBundle] imageForResource:@"status-icon"];
    [image setTemplate:YES];
    [item.button setImage: image];
    [item setMenu:aMenu];
    [item setEnabled:YES];

    return item;
}

- (NSTask*)launchWidgetServer:(NSString*)widgetPath
                       onData:(void (^)(NSString*))dataHandler
                       onExit:(void (^)(NSTask*))exitHandler
{
    NSBundle* bundle     = [NSBundle mainBundle];
    NSString* serverPath = [bundle pathForAuxiliaryExecutable:@"ubersichtd"];
    BOOL loginShell = [[NSUserDefaults standardUserDefaults]
        boolForKey:@"loginShell"
    ];

    NSTask *task = [[NSTask alloc] init];

    [task setStandardOutput:[NSPipe pipe]];
    [task.standardOutput fileHandleForReading].readabilityHandler = ^(NSFileHandle *handle) {
        NSData *output = [handle availableData];
        NSString *outStr = [[NSString alloc]
            initWithData:output
            encoding:NSUTF8StringEncoding
        ];
        
        NSLog(@"%@", outStr);
        dispatch_async(dispatch_get_main_queue(), ^{
            dataHandler(outStr);
        });
    };
    
    task.terminationHandler = ^(NSTask *theTask) {
        [theTask.standardOutput fileHandleForReading].readabilityHandler = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            exitHandler(theTask);
        });
    };
    
    NSMutableArray* arguments = [@[
        @"-d", widgetPath,
        @"-p", [NSString stringWithFormat:@"%d", PORT],
        @"--public", [bundle resourcePath],
        @"--token", [UBWebViewController sessionToken]
    ] mutableCopy];
    if (loginShell) [arguments addObject:@"--login-shell"];

    [task setLaunchPath:serverPath];
    [task setArguments:arguments];
    
    [task launch];
    return task;
}


- (NSURL*)serverUrl:(NSString*)protocol
{
    // trailing slash required for load policy in UBWindow
    return [NSURL
        URLWithString:[NSString
            stringWithFormat:@"%@://127.0.0.1:%d/", protocol, port
        ]
    ];
}


#
#pragma mark Screen Handling
#

- (void)screensChanged:(NSDictionary*)screens
{
    if (widgetsController) {
        [windowsController
            updateWindows:screens
            baseUrl: [self serverUrl: @"http"]
            interactionEnabled: preferences.enableInteraction
        ];
    }
}

#
# pragma mark received actions
#


- (void)widgetDirDidChange
{
    [self shutdown:true];
}

- (void)loginShellDidChange
{
    [self shutdown:true];
}

- (void)interactionDidChange
{
    [screensController syncScreens];
}

- (void)showPreferences:(id)sender
{
    [preferences showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [preferences.window makeKeyAndOrderFront:self];
}

- (void)openWidgetDir:(id)sender
{
    [[NSWorkspace sharedWorkspace]openURL:preferences.widgetDir];
}

// The widget format is Übersicht's, so its gallery is this app's gallery too.
- (void)visitWidgetGallery:(id)sender
{
    [[NSWorkspace sharedWorkspace]
        openURL:[NSURL URLWithString:@"http://tracesof.net/uebersicht-widgets/"]
    ];
}

- (void)refreshWidgets:(id)sender
{
    [screensController syncScreens];
}

- (void)showDebugConsole:(id)sender
{
    NSNumber* currentScreen = [[NSScreen mainScreen]
        deviceDescription
    ][@"NSScreenNumber"];
    
    [windowsController showDebugConsolesForScreen:currentScreen];
}

- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center
     shouldPresentNotification:(NSUserNotification *)notification
{
    return YES;
}

- (void)wakeFromSleep:(NSNotification *)notification
{
    [screensController syncScreens];
}

- (void)workspaceChanged:(NSNotification *)notification
{
    [windowsController workspaceChanged];
}

- (void)wallpaperChanged:(NSNotification *)notification
{
    [windowsController wallpaperChanged];
}

- (void)loginSessionBecameActive:(NSNotification *)notification
{
    [self startUp];
}

- (void)loginSessionResigned:(NSNotification *)notification
{
    [self shutdown];
}


- (void)listenToWallpaperChanges
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory,
        NSUserDomainMask,
        YES
    );
    
    CFStringRef path = (__bridge CFStringRef)[paths[0]
        stringByAppendingPathComponent:@"/Application Support/Dock/"
    ];
    
    FSEventStreamContext context = {
        0,
        (__bridge void *)(self), NULL, NULL, NULL
    };
    FSEventStreamRef stream;
    
    stream = FSEventStreamCreate(
        NULL,
        &wallpaperSettingsChanged,
        &context,
        CFArrayCreate(NULL, (const void **)&path, 1, NULL),
        kFSEventStreamEventIdSinceNow,
        0,
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
    );
    
    FSEventStreamScheduleWithRunLoop(
        stream,
        CFRunLoopGetCurrent(),
        kCFRunLoopDefaultMode
    );
    FSEventStreamStart(stream);

}

void wallpaperSettingsChanged(
    ConstFSEventStreamRef streamRef,
    void *this,
    size_t numEvents,
    void *eventPaths,
    const FSEventStreamEventFlags eventFlags[],
    const FSEventStreamEventId eventIds[]
)
{
    CFStringRef path;
    CFArrayRef  paths = eventPaths;

    for (int i=0; i < numEvents; i++) {
        path = CFArrayGetValueAtIndex(paths, i);
        if (CFStringFindWithOptions(path, CFSTR("desktoppicture.db"),
                                    CFRangeMake(0,CFStringGetLength(path)),
                                    kCFCompareCaseInsensitive,
                                    NULL) == true) {
            [(__bridge UBAppDelegate*)this
                performSelector:@selector(wallpaperChanged:)
                withObject:nil
                afterDelay:0.5
            ];
        }
    }
}

#
# pragma mark script support
#

- (NSArray*)getWidgets
{
   return [widgetsController widgetsForScripting];
}

- (BOOL)application:(NSApplication *)sender delegateHandlesKey:(NSString *)key
{
    return [key isEqualToString:@"widgets"];
}

- (void)reloadWidget:(NSString*)widgetId
{
    [widgetsController reloadWidget:widgetId];
}

@end
