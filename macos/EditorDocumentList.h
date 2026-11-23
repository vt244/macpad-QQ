// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class EditorDocument;

@interface EditorDocumentList : NSView
- (instancetype)initWithSelect:(void (^)(EditorDocument *, BOOL otherView))select
	dismiss:(void (^)(void))dismiss groupingChanged:(void (^)(BOOL))groupingChanged;
- (void)reloadDocuments:(NSArray<EditorDocument *> *)documents otherView:(NSArray<EditorDocument *> *)other
	selected:(EditorDocument *)selected focusOther:(BOOL)focusOther groupByView:(BOOL)groupByView;
@end
