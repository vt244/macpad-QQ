// SPDX-License-Identifier: GPL-3.0-only
#include "MacpadPlugin.h"
#include <string.h>

static int savedEvent;
static int editorEvent;
static int registered;
static int marker;
static int indicator;

static void Ready(const MacpadEditorV3 *editor)
{
	if (editor->structSize < sizeof(*editor))
		return;
	void *context = editor->v2.context;
	marker = editor->reserveMarkers(context, 1);
	indicator = editor->reserveIndicators(context, 2);
	registered = marker >= 0 && indicator >= 0 && editor->reserveMarkers(context, 100) == -1 &&
		editor->addToolbarButton(context, "verify", "doc") &&
		editor->mapWindowsShortcut(context, "verify", "NativeFixture.dll", 7) &&
		editor->subscribeToEditor(context, MACPAD_NOTIFY_UPDATE | MACPAD_NOTIFY_MODIFIED);
}

static void OnEditorEvent(const MacpadEditorV3 *editor, MacpadDocumentID document, const MacpadEditorNotificationV3 *event)
{
	if (document && (event->kind == MACPAD_NOTIFY_UPDATE || event->kind == MACPAD_NOTIFY_MODIFIED))
		editorEvent = 1;
}

static void Event(const MacpadEditorV3 *editor, MacpadDocumentEventV3 event, MacpadDocumentID document)
{
	uint32_t flags;
	if (event == MACPAD_EVENT_SAVED && editor->documentFlags(editor->v2.context, document, &flags))
		savedEvent = 1;
}

static void Verify(const MacpadEditorV3 *editor)
{
	void *context = editor->v2.context;
	MacpadDocumentID document = editor->v2.activeDocument(context);
	MacpadSelectionV3 selection = {3, 1};
	MacpadSelectionV3 actual;
	char text[3] = {0};
	char language[16] = {0};
	if (editor->structSize < sizeof(*editor) || !savedEvent || !registered || !editorEvent ||
		editor->copyRange(context, document, 1, 3, text, 2) != 2 || strcmp(text, "é") != 0 ||
		editor->copyRange(context, document, 1, 2, NULL, 0) != 0 ||
		editor->setSelection(context, document, (MacpadSelectionV3){2, 3}) ||
		!editor->setSelection(context, document, selection) ||
		editor->selectionCount(context, document) != 1 ||
		!editor->selectionAt(context, document, 0, &actual) ||
		actual.anchor != selection.anchor || actual.caret != selection.caret ||
		!editor->copyLanguage(context, document, language, sizeof(language) - 1) ||
		strcmp(language, "python") != 0 ||
		!editor->setMarker(context, document, marker, 0, 1) ||
		!editor->markRange(context, document, indicator, 1, 3, 1) ||
		editor->markRange(context, document, indicator, 1, 2, 1))
		return;
	editor->v2.replaceRange(context, document, 0, 1, "OK", 2);
}

const MacpadPluginV3 *macpad_plugin_v3(void)
{
	static const MacpadPluginCommandV3 commands[] = {{"verify", "Verify v3", Verify}};
#if defined(TEST_ORIGINAL_DESCRIPTOR)
	static const MacpadPluginV3 plugin = {MACPAD_PLUGIN_ABI_V3, offsetof(MacpadPluginV3, onReady),
		"test.original-v3", "Original ABI v3", 1, commands, Event, Ready, OnEditorEvent};
#else
	static const MacpadPluginV3 plugin = {MACPAD_PLUGIN_ABI_V3, sizeof(MacpadPluginV3),
		"test.native-plugin", "Native ABI v3", 1, commands, Event, Ready, OnEditorEvent};
#endif
	return &plugin;
}
