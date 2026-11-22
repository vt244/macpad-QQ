// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class ScintillaView;
@class EditorDocument;

@interface EditorSearchSource : NSObject
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSURL *url;
@property(nonatomic, readonly, weak) EditorDocument *document;
@property(nonatomic, readonly) NSData *utf8;
@property(nonatomic, readonly) NSRange range;
@property(nonatomic, copy) NSIndexSet *lines;
- (instancetype)initWithName:(NSString *)name url:(NSURL *)url document:(EditorDocument *)document utf8:(NSData *)utf8
	range:(NSRange)range;
@end

@interface EditorSearchMatch : NSObject
@property(nonatomic, readonly) NSURL *url;
@property(nonatomic, readonly, weak) EditorDocument *document;
@property(nonatomic, readonly) NSUInteger line;
@property(nonatomic, readonly) NSRange byteRange;
@property(nonatomic, readonly) NSString *lineText;
@property(nonatomic, readonly) NSRange highlight;
@property(nonatomic, readonly) NSData *matchedBytes;
@property(nonatomic, readonly) NSData *replacementBytes;
@end

@interface EditorSearchFile : NSObject
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSURL *url;
@property(nonatomic, readonly, weak) EditorDocument *document;
@property(nonatomic, readonly) NSArray<EditorSearchMatch *> *matches;
@property(nonatomic, readonly) BOOL fromOpenBuffer;
@property(nonatomic, readonly) NSData *originalUTF8;
- (BOOL)replaceOnDisk:(NSError **)error;
@end

@interface EditorSearchReport : NSObject
@property(nonatomic, readonly) NSString *query;
@property(nonatomic, readonly) NSArray<EditorSearchFile *> *files;
@property(nonatomic, readonly) NSUInteger searchedFiles;
@property(nonatomic, readonly) NSUInteger skippedFiles;
@property(nonatomic, readonly) NSUInteger hits;
- (void)discardReplacementSnapshots;
@end

// Accept snapshots of open documents so results reflect unsaved edits.
EditorSearchReport *SearchDirectory(NSURL *directory, NSString *query, NSString *filters, NSUInteger flags,
	BOOL recursive, BOOL includeHidden, NSDictionary<NSURL *, NSData *> *openFiles, NSString *replacement, NSProgress *progress, NSError **error);
EditorSearchReport *SearchSources(NSArray<EditorSearchSource *> *sources, NSString *query, NSString *filters,
	NSUInteger flags, NSString *replacement, NSProgress *progress, NSError **error);
NSInteger SearchEditorTarget(ScintillaView *editor, NSString *query, NSUInteger flags);
NSInteger SearchEditorFromAnchor(ScintillaView *editor, unsigned int message, NSUInteger flags, NSInteger text);
NSArray<EditorSearchReport *> *SearchReportsRemovingRows(NSArray<EditorSearchReport *> *reports, NSSet *rows);

@interface EditorSearchResultsView : NSView
@property(nonatomic, copy) NSArray<EditorSearchReport *> *reports;
@property(nonatomic) BOOL purgeForEachSearch;
@property(nonatomic, copy) void (^reportsChanged)(NSArray<EditorSearchReport *> *);
@property(nonatomic, copy) void (^purgeChanged)(BOOL);
@property(nonatomic, copy) void (^refine)(NSArray<EditorSearchReport *> *);
- (instancetype)initWithOpenMatch:(void (^)(EditorSearchMatch *))openMatch dismiss:(void (^)(void))dismiss;
- (void)selectMatch:(EditorSearchMatch *)match;
- (void)refreshTheme;
@end
