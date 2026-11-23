// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

@interface EditorLaunchOptions : NSObject
@property(nonatomic, readonly) NSArray<NSURL *> *paths;
@property(nonatomic, readonly) NSString *language;
@property(nonatomic, readonly) NSString *translation;
@property(nonatomic, readonly) NSString *settingsPath;
@property(nonatomic, readonly) NSInteger line;
@property(nonatomic, readonly) NSInteger column;
@property(nonatomic, readonly) NSInteger position;
@property(nonatomic, readonly) BOOL noSession;
@property(nonatomic, readonly) BOOL noPlugins;
@property(nonatomic, readonly) BOOL readOnly;
@property(nonatomic, readonly) BOOL monitor;
@property(nonatomic, readonly) BOOL fullReadOnly;
@property(nonatomic, readonly) BOOL savingForbidden;
@property(nonatomic, readonly) BOOL monitoringMode;
@property(nonatomic, readonly) NSNumber *leftPosition;
@property(nonatomic, readonly) NSNumber *topPosition;
@property(nonatomic, readonly) NSString *titleSuffix;
@property(nonatomic, readonly) BOOL openSession;
@property(nonatomic, readonly) BOOL openFoldersAsWorkspace;
@property(nonatomic, readonly) BOOL hideTabs;
@property(nonatomic, readonly) BOOL help;
@property(nonatomic, readonly) BOOL multiInstance;
@property(nonatomic, readonly) BOOL recursive;
@property(nonatomic, readonly) BOOL quickPrint;
@property(nonatomic, readonly) BOOL alwaysOnTop;
- (NSArray<NSURL *> *)expandedPaths;
- (instancetype)initWithArguments:(NSArray<NSString *> *)arguments;
@end
