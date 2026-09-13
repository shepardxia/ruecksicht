//
//  main.m
//  Übersicht
//
//  Created by Felix Hageloh on 20/9/13.
//  Copyright (c) 2013 Felix Hageloh.
//
//  Released under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version. See <http://www.gnu.org/licenses/> for
//  details.

#import <Cocoa/Cocoa.h>
#import "UBAppDelegate.h"
#import "UBApplication.h"
#import "UBMenu.h"

// NSApplication holds its delegate weakly, so the delegate needs an owner that
// outlives the run loop.
static UBAppDelegate* appDelegate;

int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSApplication* app = [UBApplication sharedApplication];
        appDelegate = [[UBAppDelegate alloc] init];
        app.delegate = appDelegate;
        app.mainMenu = [UBMenu mainMenu];
        [app run];
    }
    return 0;
}
