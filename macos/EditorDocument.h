// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class ScintillaView;

@interface EditorDocument : NSDocument
@property(nonatomic, readonly) ScintillaView *editor;
- (void)applyTheme;
- (IBAction)findText:(id)sender;
- (IBAction)findNext:(id)sender;
- (IBAction)replaceText:(id)sender;
- (IBAction)toggleWrap:(id)sender;
- (IBAction)toggleLineNumbers:(id)sender;
@end

@interface EditorDocumentController : NSDocumentController
@end
