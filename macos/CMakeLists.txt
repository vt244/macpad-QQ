# SPDX-License-Identifier: GPL-3.0-only
cmake_minimum_required(VERSION 3.20)
project(macpad LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD 20)
set(root "${CMAKE_CURRENT_LIST_DIR}/..")
set(sci "${root}/scintilla")
set(lex "${root}/lexilla")
file(GLOB scintilla_sources CONFIGURE_DEPENDS "${sci}/src/*.cxx" "${sci}/cocoa/*.mm")
file(GLOB lexilla_sources CONFIGURE_DEPENDS "${lex}/lexlib/*.cxx" "${lex}/lexers/Lex*.cxx")

# Use the standard headers on macOS and keep the vendored sources intact.
list(FILTER lexilla_sources EXCLUDE REGEX "/LexUser[.]cxx$")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${lex}/lexers/LexUser.cxx")
file(READ "${lex}/lexers/LexUser.cxx" user_lexer)
string(REPLACE "#include <windows.h>" "#include <cctype>\n#include <cstdio>\n#include <cstdlib>" user_lexer "${user_lexer}")
string(REGEX REPLACE "_itoa\\(([^,]+),[ ]*\\(nestingBuffer[+]([0-9]+)\\),[ ]*10\\)"
	"std::snprintf(nestingBuffer + \\2, sizeof(nestingBuffer) - \\2, \"%d\", \\1)" user_lexer "${user_lexer}")
file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/LexUser.cxx" CONTENT "${user_lexer}")

add_library(editor STATIC ${scintilla_sources} ${lexilla_sources} "${lex}/src/Lexilla.cxx"
	"${CMAKE_CURRENT_BINARY_DIR}/LexUser.cxx"
	"${root}/boostregex/BoostRegExSearch.cxx" "${root}/boostregex/UTF8DocumentIterator.cxx")
target_compile_definitions(editor PRIVATE SCI_OWNREGEX BOOST_REGEX_STANDALONE)
target_compile_options(editor PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_include_directories(editor PUBLIC "${sci}/include" "${sci}/cocoa" "${lex}/include")
target_include_directories(editor PRIVATE "${sci}/src" "${lex}/lexlib" "${root}/boostregex")

add_executable(macpad macos-main.mm EditorDocument.mm EditorChrome.mm EditorResources.mm EditorPlugins.mm EditorSmoke.mm
	EditorText.mm EditorFileSearch.mm EditorSearchResultsView.mm EditorWorkspace.mm EditorMacros.mm EditorHash.mm EditorRun.mm
	EditorDocumentList.mm EditorPanelChrome.mm EditorContextMenus.mm EditorDock.mm EditorFolderPanel.mm EditorProjectPanel.mm
	EditorFunctionList.mm EditorDocumentMap.mm EditorInsertPanels.mm EditorIncrementalSearch.mm EditorEditActions.mm
	EditorCompletion.mm EditorTabManager.mm EditorPrinting.mm EditorPreview.mm EditorShortcuts.mm EditorSettings.mm EditorLaunchOptions.mm EditorPluginCatalog.mm)
file(GLOB detector_sources CONFIGURE_DEPENDS "${root}/PowerEditor/src/uchardet/*.cpp")
target_sources(macpad PRIVATE ${detector_sources})
set_target_properties(macpad PROPERTIES OUTPUT_NAME "macpadqq")
target_compile_options(macpad PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_include_directories(macpad PRIVATE "${root}/PowerEditor/src/pugixml" "${root}/PowerEditor/src/uchardet" "${sci}/src")
target_link_libraries(macpad PRIVATE editor "-framework Cocoa" "-framework QuartzCore" "-framework CoreText"
	"-framework CoreGraphics" "-framework UniformTypeIdentifiers")

add_executable(TextPreview quick-look/TextPreview.mm EditorPreview.mm EditorResources.mm EditorText.mm ${detector_sources})
target_compile_options(TextPreview PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc;-fapplication-extension>)
target_include_directories(TextPreview PRIVATE "${root}/PowerEditor/src/pugixml" "${root}/PowerEditor/src/uchardet")
target_link_options(TextPreview PRIVATE "-Wl,-e,_NSExtensionMain" "-Wl,-application_extension")
target_link_libraries(TextPreview PRIVATE editor "-framework Cocoa" "-framework QuickLookUI" "-framework QuartzCore"
	"-framework CoreText" "-framework CoreGraphics")
