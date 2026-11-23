// SPDX-License-Identifier: GPL-3.0-only
#ifndef MACPAD_PLUGIN_H
#define MACPAD_PLUGIN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MACPAD_PLUGIN_ABI_VERSION 1

typedef struct MacpadEditorV1
{
	void *context;
	// Returns the required byte count without a terminator and copies up to capacity bytes.
	size_t (*copySelection)(void *context, char *buffer, size_t capacity);
	// Returns 1 on success. Text must be valid UTF-8. Both callbacks are valid only during run().
	int (*replaceSelection)(void *context, const char *utf8, size_t length);
} MacpadEditorV1;

typedef struct MacpadPluginV1
{
	uint32_t version;
	const char *title;
	void (*run)(const MacpadEditorV1 *editor);
} MacpadPluginV1;

typedef const MacpadPluginV1 *(*MacpadPluginEntry)(void);

// Export this symbol from the macOS dylib.
const MacpadPluginV1 *macpad_plugin(void);

#define MACPAD_PLUGIN_ABI_V2 2

typedef uint64_t MacpadDocumentID;

typedef enum MacpadDocumentEventV2
{
	MACPAD_DOCUMENT_OPENED = 1,
	MACPAD_DOCUMENT_ACTIVATED = 2,
	MACPAD_DOCUMENT_CHANGED = 3,
	MACPAD_DOCUMENT_CLOSED = 4,
} MacpadDocumentEventV2;

typedef struct MacpadEditorV2
{
	void *context;
	MacpadDocumentID (*activeDocument)(void *context);
	size_t (*documentCount)(void *context);
	MacpadDocumentID (*documentAtIndex)(void *context, size_t index);
	// Copies up to capacity UTF-8 bytes and returns the required byte count without a terminator.
	size_t (*copyPath)(void *context, MacpadDocumentID document, char *buffer, size_t capacity);
	size_t (*copyText)(void *context, MacpadDocumentID document, char *buffer, size_t capacity);
	int (*replaceRange)(void *context, MacpadDocumentID document, size_t start, size_t end, const char *utf8, size_t length);
	// nativeView is an AppKit NSView pointer. The host retains the view while the panel is open.
	int (*showPanel)(void *context, const char *id, const char *title, void *nativeView);
	void (*closePanel)(void *context, const char *id);
} MacpadEditorV2;

typedef struct MacpadPluginCommandV2
{
	const char *title;
	void (*run)(const MacpadEditorV2 *editor);
} MacpadPluginCommandV2;

typedef struct MacpadPluginV2
{
	uint32_t version;
	size_t structSize;
	const char *title;
	size_t commandCount;
	const MacpadPluginCommandV2 *commands;
	// The editor and callbacks are valid only during synchronous main-thread calls.
	void (*onDocumentEvent)(const MacpadEditorV2 *editor, MacpadDocumentEventV2 event, MacpadDocumentID document);
} MacpadPluginV2;

typedef const MacpadPluginV2 *(*MacpadPluginEntryV2)(void);
const MacpadPluginV2 *macpad_plugin_v2(void);

#define MACPAD_PLUGIN_ABI_V3 3

typedef enum MacpadDocumentEventV3
{
	MACPAD_EVENT_OPENED = 1,
	MACPAD_EVENT_ACTIVATED = 2,
	MACPAD_EVENT_CHANGED = 3,
	MACPAD_EVENT_CLOSED = 4,
	MACPAD_EVENT_SAVED = 5,
	MACPAD_EVENT_PATH_CHANGED = 6,
	MACPAD_EVENT_SELECTION_CHANGED = 7,
	MACPAD_EVENT_LANGUAGE_CHANGED = 8,
} MacpadDocumentEventV3;

typedef enum MacpadDocumentFlagV3
{
	MACPAD_DOCUMENT_EDITED = 1,
	MACPAD_DOCUMENT_READ_ONLY = 2,
	MACPAD_DOCUMENT_MONITORED = 4,
	MACPAD_DOCUMENT_PINNED = 8,
} MacpadDocumentFlagV3;

typedef struct MacpadSelectionV3
{
	// UTF-8 offsets. The caret and anchor preserve the selection's direction.
	size_t anchor;
	size_t caret;
} MacpadSelectionV3;

typedef enum MacpadEditorNotificationKindV3
{
	MACPAD_NOTIFY_MODIFIED = 1,
	MACPAD_NOTIFY_UPDATE = 2,
	MACPAD_NOTIFY_CHARACTER = 4,
	MACPAD_NOTIFY_MARGIN = 8,
	MACPAD_NOTIFY_ZOOM = 16,
	MACPAD_NOTIFY_SAVEPOINT = 32,
} MacpadEditorNotificationKindV3;

typedef struct MacpadEditorNotificationV3
{
	uint32_t kind;
	uint32_t scintillaCode;
	int64_t position;
	int64_t length;
	uint32_t modificationFlags;
	uint32_t updateFlags;
	int32_t character;
	int32_t margin;
} MacpadEditorNotificationV3;

typedef struct MacpadEditorV3
{
	size_t structSize;
	MacpadEditorV2 v2;
	// Pass v2.context to all callbacks. Offset arguments must be UTF-8 boundaries.
	int (*documentFlags)(void *context, MacpadDocumentID document, uint32_t *flags);
	size_t (*copyLanguage)(void *context, MacpadDocumentID document, char *buffer, size_t capacity);
	size_t (*copyRange)(void *context, MacpadDocumentID document, size_t start, size_t end, char *buffer, size_t capacity);
	size_t (*selectionCount)(void *context, MacpadDocumentID document);
	int (*selectionAt)(void *context, MacpadDocumentID document, size_t index, MacpadSelectionV3 *selection);
	int (*setSelection)(void *context, MacpadDocumentID document, MacpadSelectionV3 selection);
	int (*activateDocument)(void *context, MacpadDocumentID document);
	// Optional v3 additions. Test structSize before reading these callbacks.
	int (*addToolbarButton)(void *context, const char *command, const char *systemSymbol);
	int (*reserveMarkers)(void *context, size_t count);
	int (*reserveIndicators)(void *context, size_t count);
	int (*subscribeToEditor)(void *context, uint32_t kinds);
	int (*setMarker)(void *context, MacpadDocumentID document, int marker, size_t line, int present);
	int (*markRange)(void *context, MacpadDocumentID document, int indicator, size_t start, size_t end, int present);
	int (*mapWindowsShortcut)(void *context, const char *command, const char *module, int internalID);
} MacpadEditorV3;

typedef struct MacpadPluginCommandV3
{
	// Stable and unique within this plugin. Titles may change independently.
	const char *identifier;
	const char *title;
	void (*run)(const MacpadEditorV3 *editor);
} MacpadPluginCommandV3;

typedef struct MacpadPluginV3
{
	uint32_t version;
	size_t structSize;
	const char *identifier;
	const char *title;
	size_t commandCount;
	const MacpadPluginCommandV3 *commands;
	// All callbacks are synchronous and main-thread only, as in v2.
	void (*onDocumentEvent)(const MacpadEditorV3 *editor, MacpadDocumentEventV3 event, MacpadDocumentID document);
	// Optional trailing fields. The host accepts the original v3 descriptor size.
	void (*onReady)(const MacpadEditorV3 *editor);
	void (*onEditorNotification)(const MacpadEditorV3 *editor, MacpadDocumentID document, const MacpadEditorNotificationV3 *event);
} MacpadPluginV3;

typedef const MacpadPluginV3 *(*MacpadPluginEntryV3)(void);
const MacpadPluginV3 *macpad_plugin_v3(void);

#ifdef __cplusplus
}
#endif
#endif
