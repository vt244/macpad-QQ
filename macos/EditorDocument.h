// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

@class ScintillaView;
@class EditorChrome;

@interface EditorDocument : NSDocument
@property(nonatomic, readonly) ScintillaView *editor;
@property(nonatomic, readonly) EditorChrome *chrome;
@property(nonatomic, readonly, getter=isTabPinned) BOOL tabPinned;
@property(nonatomic, readonly, getter=isMonitoring) BOOL monitoring;
@property(nonatomic, readonly) NSInteger tabColorIndex;
- (void)changeTabPin;
- (void)changeTabColor:(NSInteger)index;
- (BOOL)isToolbarCommandEnabled:(NSToolbarItem *)command;
- (id)targetForToolbarCommand:(NSToolbarItem *)command;
- (IBAction)closeEditorTab:(id)sender;
- (void)refreshChromeMenus;
- (void)applyTheme;
- (void)applyPreferences;
- (IBAction)selectLanguage:(NSMenuItem *)sender;
- (IBAction)convertEncoding:(NSMenuItem *)sender;
- (IBAction)reinterpretEncoding:(NSMenuItem *)sender;
- (IBAction)toggleBookmark:(id)sender;
- (IBAction)navigateBookmark:(id)sender;
- (IBAction)clearBookmarks:(id)sender;
- (IBAction)findText:(id)sender;
- (IBAction)findNext:(id)sender;
- (IBAction)findPrevious:(id)sender;
- (IBAction)findSelectedText:(NSMenuItem *)sender;
- (IBAction)findMatchingBrace:(NSMenuItem *)sender;
- (IBAction)useMarkStyle:(NSMenuItem *)sender;
- (IBAction)specialClipboard:(NSMenuItem *)sender;
- (IBAction)findInFiles:(id)sender;
- (void)findInDirectory:(NSURL *)directory;
- (IBAction)findInProjects:(id)sender;
- (IBAction)incrementalSearch:(id)sender;
- (IBAction)markText:(id)sender;
- (IBAction)toggleSearchResults:(id)sender;
- (IBAction)toggleDocumentList:(id)sender;
- (IBAction)moveToOtherView:(id)sender;
- (IBAction)cloneToOtherView:(id)sender;
- (IBAction)closeOtherView:(id)sender;
- (IBAction)toggleVerticalScrollSync:(id)sender;
- (IBAction)toggleHorizontalScrollSync:(id)sender;
- (IBAction)toggleZoomSync:(id)sender;
- (IBAction)replaceText:(id)sender;
- (IBAction)goToLine:(id)sender;
- (IBAction)runEditorCommand:(id)sender;
- (IBAction)runWhitespaceCommand:(id)sender;
- (IBAction)beginOrEndSelection:(NSMenuItem *)sender;
- (IBAction)transformSelectionCase:(NSMenuItem *)sender;
- (IBAction)monitorFile:(id)sender;
- (IBAction)saveCopyAs:(id)sender;
- (IBAction)moveFileToTrash:(id)sender;
- (IBAction)showDocumentSummary:(id)sender;
- (IBAction)hideSelectedLines:(id)sender;
- (IBAction)showHiddenLines:(id)sender;
- (IBAction)foldAtLevel:(NSMenuItem *)sender;
- (IBAction)togglePresentationMode:(NSMenuItem *)sender;
- (IBAction)convertLineEndings:(id)sender;
- (IBAction)toggleInvisibles:(id)sender;
- (IBAction)toggleIndentGuides:(id)sender;
- (IBAction)toggleWrap:(id)sender;
- (IBAction)toggleLineNumbers:(id)sender;
- (IBAction)toggleDocumentReadOnly:(id)sender;
@end

@interface EditorDocumentController : NSDocumentController
@property(nonatomic, readonly) EditorDocument *focusedDocument;
@property(nonatomic, readonly) NSArray<EditorDocument *> *tabDocuments;
- (NSArray<EditorDocument *> *)tabsInOtherView:(BOOL)other;
- (EditorDocument *)selectedTabInOtherView:(BOOL)other;
- (void)activateTab:(EditorDocument *)document otherView:(BOOL)other;
- (void)dropTab:(EditorDocument *)document before:(EditorDocument *)anchor otherView:(BOOL)other;
- (void)moveTab:(EditorDocument *)document toEnd:(BOOL)toEnd;
- (BOOL)cycleRecentTabsBackwards:(BOOL)backwards;
- (BOOL)finishRecentTabSwitch:(BOOL)accept;
- (void)applyImportedDockLayout;
- (IBAction)chooseWorkspaceFolders:(id)sender;
- (IBAction)toggleFolderWorkspace:(id)sender;
- (IBAction)toggleProjectPanel:(NSMenuItem *)sender;
- (IBAction)toggleFunctionList:(id)sender;
- (IBAction)toggleDocumentMap:(id)sender;
- (IBAction)toggleInsertPanel:(NSMenuItem *)sender;
- (IBAction)stepSearchResult:(NSMenuItem *)sender;
- (void)addWorkspaceFolders:(NSArray<NSURL *> *)folders;
- (void)prepareToShowDocument:(EditorDocument *)document;
- (void)refreshDocumentTabs;
@end
