// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>

void EditorShowPreferences(void);
BOOL EditorShowStyleConfigurator(void);
BOOL EditorShowShortcutMapper(NSMenu *menu);
void EditorApplyShortcuts(NSMenu *menu);
NSString *EditorShortcutIdentifier(NSMenuItem *item);
BOOL EditorShowUserLanguageEditor(void);
void EditorExportUserLanguage(void);
