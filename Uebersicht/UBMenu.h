//
//  UBMenu.h
//  Übersicht
//
//  Released under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version. See <http://www.gnu.org/licenses/> for
//  details.

#import <Cocoa/Cocoa.h>

/// The app name as shown in menus.
extern NSString * const UBAppName;

/// Identifier of the status bar item the widget section is inserted above.
extern NSString * const UBWidgetSectionAnchor;

@interface UBMenu : NSObject

/// Items acting on the app delegate are sent to `target`; About and Quit go to
/// NSApp. The item carrying UBWidgetSectionAnchor marks where widgets belong.
+ (NSMenu *)statusBarMenuWithTarget:(id)target;

/// Menu bar for an agent app: key equivalents for windows that do open, and
/// nothing that assumes documents.
+ (NSMenu *)mainMenu;

@end
