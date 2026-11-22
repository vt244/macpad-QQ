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

#ifdef __cplusplus
}
#endif
#endif
