// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@interface EditorClipboardHistory : NSView
- (instancetype)initWithInsert:(void (^)(NSString *))insert dismiss:(void (^)(void))dismiss;
- (void)setEntries:(NSArray<NSString *> *)entries;
@end

@interface EditorCharacterPanel : NSView
- (instancetype)initWithInsert:(void (^)(NSString *))insert dismiss:(void (^)(void))dismiss;
- (void)useEncoding:(NSStringEncoding)encoding;
@end
