//
//  UBWindowsController.h
//  Uebersicht
//
//  Created by Felix Hageloh on 30/09/2020.
//  Copyright © 2020 tracesOf. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns the widget windows of every screen, showing the pages served at
/// `baseUrl`. Nothing else creates, replaces or closes them.
@interface UBWindowsController : NSObject

/// Where the pages are served. Nil while there is no server, and then there
/// are no windows.
@property (nonatomic, copy, nullable) NSURL* baseUrl;
@property (nonatomic) BOOL interactionEnabled;

/// Replaces every window with a newly built one.
- (void)rebuild;
/// Has every page paint again, for when what shows through the windows has
/// changed.
- (void)redraw;
- (void)showDebugConsolesForScreen:(NSNumber*)screenId;

@end

NS_ASSUME_NONNULL_END
