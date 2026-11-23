// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

#include <optional>
#include <string>
#include <vector>
#include "Scintilla.h"

struct MacroStep
{
	unsigned int message;
	uptr_t wParam;
	sptr_t lParam;
	std::optional<std::string> text;
};

bool IsMacroMenuCommand(uptr_t command);
enum class MacroMenuAction { Unsupported, Save, Whitespace, Comment, Reorder, Case, Bookmarks };
MacroMenuAction MacroMenuActionForCommand(uptr_t command);
bool IsMacroSearchStep(unsigned int message);
extern NSNotificationName const EditorMacroLibraryDidChange;

@interface EditorMacro : NSObject
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSString *folder;
- (const std::vector<MacroStep> &)steps;
@end

@interface EditorMacroLibrary : NSObject
@property(nonatomic, readonly) NSArray<EditorMacro *> *macros;
+ (instancetype)shared;
- (instancetype)initWithDirectory:(NSURL *)directory;
- (BOOL)saveSteps:(const std::vector<MacroStep> &)steps name:(NSString *)name replacing:(BOOL)replacing error:(NSError **)error;
- (BOOL)removeMacro:(EditorMacro *)macro error:(NSError **)error;
- (NSInteger)importShortcuts:(NSURL *)url skipped:(NSUInteger *)skipped error:(NSError **)error;
@end
