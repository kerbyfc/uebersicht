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
#import "UBWindow.h"
#import "UBPreferencesController.m"
#import "UBScreensController.h"
#import "WebInspector.h"
#import "UBKeyHandler.h"
#import "UBWidgetsController.h"
#import "UBWidgetsStore.h"
#import "UBWebSocket.h"

int const PORT = 41416;

@implementation UBAppDelegate {
    NSStatusItem* statusBarItem;
    NSTask* widgetServer;
    UBPreferencesController* preferences;
    UBScreensController* screensController;
    BOOL keepServerAlive;
    int portOffset;
    UBKeyHandler* keyHandler;
    UBWidgetsStore* widgetsStore;
    UBWidgetsController* widgetsController;
    NSMutableDictionary* windows;
}

@synthesize statusBarMenu;

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    windows = [[NSMutableDictionary alloc] initWithCapacity:42];
    statusBarItem = [self addStatusItemToMenu: statusBarMenu];
    preferences = [[UBPreferencesController alloc]
        initWithWindowNibName:@"UBPreferencesController"
    ];
    
    // NSTask doesn't terminate when xcode stop is pressed. Other ways of
    // spawning the server, like system() or popen() have the same problem.
    // So, hit em with a hammer :(
    system("killall localnode");
    
    // start server and load webview
    portOffset = 0;
    keepServerAlive = YES;
    
    [self startServer: ^(NSString* output) {
        // note that these might be called several times
        if ([output rangeOfString:@"server started"].location != NSNotFound) {
            [widgetsStore reset];
            [[UBWebSocket sharedSocket] open:[self serverUrl:@"ws"]];
            // this will trigger a render
            [screensController screensChanged:self];

        } else if ([output rangeOfString:@"EADDRINUSE"].location != NSNotFound) {
            portOffset++;
            if (portOffset >= 20) {
                keepServerAlive = NO;
                NSLog(@"couldn't find an open port. Giving up...");
            }
        }
    }];
    
    // enable the web inspector
    [[NSUserDefaults standardUserDefaults]
        setBool: YES
        forKey: @"WebKitDeveloperExtras"
    ];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // listen for keyboard events
    keyHandler = [[UBKeyHandler alloc]
        initWithPreferences: preferences
        listener: self
    ];
    
    widgetsStore = [[UBWidgetsStore alloc] init];

    screensController = [[UBScreensController alloc]
        initWithChangeListener:self
    ];
    
    widgetsController = [[UBWidgetsController alloc]
        initWithMenu: statusBarMenu
        widgets: widgetsStore
        screens: screensController
    ];
    [widgetsStore onChange: ^(NSDictionary* widgets) {
        [widgetsController render];
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
    
    [self listenToWallpaperChanges];
}

- (void)startServer:(void (^)(NSString*))callback
{
    NSLog(@"starting server task");

    void (^keepAlive)(NSTask*) = ^(NSTask* theTask) {
        if (keepServerAlive) {
            [self performSelector:@selector(startServer:) withObject:callback afterDelay:5.0];
        }
    };

    widgetServer = [self launchWidgetServer:[preferences.widgetDir path]
                                     onData:callback
                                     onExit:keepAlive];
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
    [item setImage: image];
    [item setHighlightMode:YES];
    [item setMenu:aMenu];
    [item setEnabled:YES];

    return item;
}

- (NSTask*)launchWidgetServer:(NSString*)widgetPath
                       onData:(void (^)(NSString*))dataHandler
                       onExit:(void (^)(NSTask*))exitHandler
{
    NSBundle* bundle     = [NSBundle mainBundle];
    NSString* nodePath   = [bundle pathForResource:@"localnode" ofType:nil];
    NSString* serverPath = [bundle pathForResource:@"server" ofType:@"js"];

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
    
    [task setLaunchPath:nodePath];
    [task setArguments:@[
        serverPath,
        @"-d", widgetPath,
        @"-p", [NSString stringWithFormat:@"%d", PORT + portOffset],
        @"-s", [[self getPreferencesDir] path]
        
    ]];
    
    [task launch];
    return task;
}


- (NSURL*)getPreferencesDir
{
    NSArray* urls = [[NSFileManager defaultManager]
        URLsForDirectory:NSApplicationSupportDirectory
               inDomains:NSUserDomainMask
    ];
    
    return [urls[0]
        URLByAppendingPathComponent:[[NSBundle mainBundle] bundleIdentifier]
                        isDirectory:YES
    ];
}

- (NSURL*)serverUrl:(NSString*)protocol
{
    // trailing slash required for load policy in UBWindow
    return [NSURL
        URLWithString:[NSString
            stringWithFormat:@"%@://127.0.0.1:%d/", protocol, PORT+portOffset
        ]
    ];
}

#
#pragma mark Screen Handling
#

- (void)screensChanged:(NSDictionary*)screens
{
    if (widgetsController) {
        [self renderOnScreens:screens];
    }
}

- (void)renderOnScreens:(NSDictionary*)screens
{
    NSMutableArray* obsoleteScreens = [[windows allKeys] mutableCopy];
    UBWindow* window;
    
    for(NSNumber* screenId in screens) {
        if (![windows objectForKey:screenId]) {
            window = [[UBWindow alloc] init];
            [windows setObject:window forKey:screenId];
            
            [window loadUrl:[
                [self serverUrl:@"http"]
                    URLByAppendingPathComponent:[NSString
                        stringWithFormat:@"%@",
                        screenId
                    ]
                ]
            ];
        } else {
            window = windows[screenId];
        }
        
        [window setFrame:[screensController screenRect:screenId] display:YES];
        [window makeKeyAndOrderFront:self];
        
        [obsoleteScreens removeObject:screenId];
    }
    
    for (NSNumber* screenId in obsoleteScreens) {
        [windows[screenId] close];
        [windows removeObjectForKey:screenId];
    }
    
    NSLog(@"using %lu screens", (unsigned long)[windows count]);
}

#
# pragma mark received actions
#

- (void)modifierKeyReleased
{
    for (NSNumber* screenId in windows) {
        [windows[screenId] sendToDesktop];
    }
}


- (void)modifierKeyPressed
{
   for (NSNumber* screenId in windows) {
        [windows[screenId] comeToFront];
    }
}

- (void)widgetDirDidChange
{
    for (NSNumber* screenId in screensController.screens) {
        [windows[screenId] close];
        [windows removeAllObjects];
    }
    
    [[UBWebSocket sharedSocket] close];
    
    if (widgetServer){
        // server will restart by itself
        [widgetServer terminate];
    }
}

- (IBAction)showPreferences:(id)sender
{
    [preferences showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [preferences.window makeKeyAndOrderFront:self];
}

- (IBAction)openWidgetDir:(id)sender
{
    [[NSWorkspace sharedWorkspace]openURL:preferences.widgetDir];
}

- (IBAction)visitWidgetGallery:(id)sender
{
    [[NSWorkspace sharedWorkspace]
        openURL:[NSURL URLWithString:@"http://tracesof.net/uebersicht-widgets/"]
    ];
}

- (IBAction)refreshWidgets:(id)sender
{
    for (NSNumber* screenId in windows) {
        [windows[screenId] reload];
    }
}

- (IBAction)showDebugConsole:(id)sender
{

    NSNumber* currentScreen = [[NSScreen mainScreen]
        deviceDescription
    ][@"NSScreenNumber"];
    
    NSWindow* window = windows[currentScreen];
    WebInspector *inspector= [WebInspector.alloc
        initWithWebView: window.contentView
    ];

    [[NSUserDefaults standardUserDefaults]
        setBool: NO
        forKey: @"WebKit Web Inspector Setting - inspectorStartsAttached"
    ];
    
    [NSApp activateIgnoringOtherApps:YES];
    [inspector show:self];
}

- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center
     shouldPresentNotification:(NSUserNotification *)notification
{
    return YES;
}

- (void)wakeFromSleep:(NSNotification *)notification
{
    for (NSNumber* screenId in windows) {
        [windows[screenId] reload];
    }
}

- (void)workspaceChanged:(NSNotification *)notification
{
    for (NSNumber* screenId in windows) {
        [windows[screenId] workspaceChanged];
    }
}

- (void)wallpaperChanged:(NSNotification *)notification
{
    for (NSNumber* screenId in windows) {
        [windows[screenId] wallpaperChanged];
    }
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

    //printf("Callback called\n");
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

@end
