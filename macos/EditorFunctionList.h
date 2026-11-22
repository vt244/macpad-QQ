// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@interface EditorFunction : NSObject
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSString *group;
@property(nonatomic, readonly) NSUInteger bytePosition;
@end

NSArray<EditorFunction *> *EditorReadFunctions(NSData *utf8, NSURL *rules, NSProgress *progress);

@interface EditorFunctionList : NSView
- (instancetype)initWithNavigate:(void (^)(NSUInteger))navigate dismiss:(void (^)(void))dismiss;
- (void)refresh:(NSData *)utf8 language:(NSString *)language;
- (void)cancel;
@end
