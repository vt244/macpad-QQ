// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, EditorDockEdge) {
	EditorDockLeft, EditorDockRight, EditorDockTop, EditorDockBottom, EditorDockFloating
};

@interface EditorDockPlacement : NSObject
- (instancetype)initWithEdge:(EditorDockEdge)edge;
- (NSDictionary *)snapshot;
- (void)restore:(NSDictionary *)snapshot;
@end

@class EditorDockArea;

@interface EditorDockPane : NSView
- (NSMenu *)placementMenu;
- (void)toggleFloating;
- (void)dropAtScreenPoint:(NSPoint)point;
@property(nonatomic, getter=isShown) BOOL shown;
@end

@interface EditorDockArea : NSView
- (instancetype)initWithEditor:(NSView *)editor;
- (EditorDockPane *)addPanel:(NSView *)panel title:(NSString *)title
	placement:(EditorDockPlacement *)placement dismiss:(void (^)(void))dismiss;
- (void)refreshPanelPlacements;
@property(nonatomic, copy) void (^placementChanged)(void);
@end
