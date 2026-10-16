#import "NativeEditorController+Private.h"

// Menu bar, tab context menu and editor context menu, laid out like the latest
// Notepad++ (PowerEditor/src/Notepad_plus.rc). Windows shortcuts are mapped to
// their closest macOS equivalents (Ctrl -> Cmd where it doesn't clash).

static const NSEventModifierFlags kCmd = NSEventModifierFlagCommand;
static const NSEventModifierFlags kCmdShift = NSEventModifierFlagCommand | NSEventModifierFlagShift;
static const NSEventModifierFlags kCmdOption = NSEventModifierFlagCommand | NSEventModifierFlagOption;
static const NSEventModifierFlags kCmdOptionShift = NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagShift;
static const NSEventModifierFlags kCtrl = NSEventModifierFlagControl;
static const NSEventModifierFlags kCtrlShift = NSEventModifierFlagControl | NSEventModifierFlagShift;
static const NSEventModifierFlags kCtrlCmd = NSEventModifierFlagControl | NSEventModifierFlagCommand;
static const NSEventModifierFlags kOption = NSEventModifierFlagOption;

static NSString *Key(unichar character) {
  return [NSString stringWithFormat:@"%C", character];
}

@implementation NativeEditorController (Menus)

- (NSMenuItem *)item:(NSString *)title action:(SEL)action menu:(NSMenu *)menu {
  return [self addMenuItem:title action:action key:@"" toMenu:menu];
}

- (NSMenuItem *)item:(NSString *)title action:(SEL)action key:(NSString *)key mods:(NSEventModifierFlags)mods menu:(NSMenu *)menu {
  return [self addMenuItem:title action:action key:key modifiers:mods toMenu:menu];
}

- (NSMenuItem *)item:(NSString *)title action:(SEL)action tag:(NSInteger)tag menu:(NSMenu *)menu {
  NSMenuItem *item = [self addMenuItem:title action:action key:@"" toMenu:menu];
  item.tag = tag;
  return item;
}

- (void)separator:(NSMenu *)menu {
  [menu addItem:NSMenuItem.separatorItem];
}

- (void)addStyleMenus:(NSMenu *)menu {
  NSArray *ordinals = @[@"Using 1st Style", @"Using 2nd Style", @"Using 3rd Style", @"Using 4th Style", @"Using 5th Style"];
  NSMenu *all = [self submenu:@"Style All Occurrences of Token" inMenu:menu];
  NSMenu *one = [self submenu:@"Style One Token" inMenu:menu];
  for (NSInteger index = 0; index < 5; index += 1) {
    [self item:ordinals[index] action:@selector(styleAllOccurrences:) tag:index + 1 menu:all];
    [self item:ordinals[index] action:@selector(styleOneToken:) tag:index + 1 menu:one];
  }
  NSMenu *clear = [self submenu:@"Clear Style" inMenu:menu];
  for (NSInteger index = 0; index < 5; index += 1) {
    [self item:[NSString stringWithFormat:@"Clear %@ Style", @[@"1st", @"2nd", @"3rd", @"4th", @"5th"][index]] action:@selector(clearStyle:) tag:index + 1 menu:clear];
  }
  [self item:@"Clear all Styles" action:@selector(clearStyle:) tag:0 menu:clear];
}

- (void)buildMainMenu {
  NSMenu *main = [[NSMenu alloc] initWithTitle:@"Main Menu"];
  NSString *appName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"Editor";
  NSString *up = Key(NSUpArrowFunctionKey), *down = Key(NSDownArrowFunctionKey);
  NSString *f2 = Key(NSF2FunctionKey), *f4 = Key(NSF4FunctionKey), *f12 = Key(NSF12FunctionKey);
  NSString *pageUp = Key(NSPageUpFunctionKey), *pageDown = Key(NSPageDownFunctionKey);

  // App menu (macOS).
  NSMenu *app = [self submenu:appName inMenu:main];
  [app addItemWithTitle:[@"About " stringByAppendingString:appName] action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
  [self separator:app];
  [self item:@"Settings…" action:@selector(showPreferences:) key:@"," mods:kCmd menu:app];
  [self separator:app];
  NSMenuItem *services = [[NSMenuItem alloc] initWithTitle:@"Services" action:nil keyEquivalent:@""];
  services.submenu = [[NSMenu alloc] initWithTitle:@"Services"];
  NSApp.servicesMenu = services.submenu;
  [app addItem:services];
  [self separator:app];
  [app addItemWithTitle:[@"Hide " stringByAppendingString:appName] action:@selector(hide:) keyEquivalent:@"h"];
  NSMenuItem *hideOthers = [app addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
  hideOthers.keyEquivalentModifierMask = kCmdOption;
  [app addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
  [self separator:app];
  [app addItemWithTitle:[@"Quit " stringByAppendingString:appName] action:@selector(terminate:) keyEquivalent:@"q"];

  // File
  NSMenu *file = [self submenu:@"File" inMenu:main];
  [self item:@"New" action:@selector(newDocument:) key:@"n" mods:kCmd menu:file];
  [self item:@"Open…" action:@selector(openFiles:) key:@"o" mods:kCmd menu:file];
  NSMenu *containing = [self submenu:@"Open Containing Folder" inMenu:file];
  [self item:@"Finder" action:@selector(revealInFinder:) menu:containing];
  [self item:@"Terminal" action:@selector(openInTerminal:) menu:containing];
  [self item:@"Folder as Workspace" action:@selector(openContainingFolderAsWorkspace:) menu:containing];
  [self item:@"Open in Default Viewer" action:@selector(openInDefaultViewer:) menu:file];
  [self item:@"Open Folder as Workspace…" action:@selector(openProjectFolder:) key:@"o" mods:kCmdShift menu:file];
  [self item:@"Reload from Disk" action:@selector(reloadDocument:) key:@"r" mods:kCmdOption menu:file];
  [self separator:file];
  [self item:@"Save" action:@selector(saveDocument:) key:@"s" mods:kCmd menu:file];
  [self item:@"Save As…" action:@selector(saveDocumentAs:) key:@"s" mods:kCmdShift menu:file];
  [self item:@"Save a Copy As…" action:@selector(saveCopyAs:) menu:file];
  [self item:@"Save All" action:@selector(saveAll:) key:@"s" mods:kCmdOption menu:file];
  [self item:@"Rename…" action:@selector(renameDocument:) menu:file];
  [self item:@"Close" action:@selector(closeCurrentTab:) key:@"w" mods:kCmd menu:file];
  [self item:@"Close All" action:@selector(closeAllTabs:) key:@"w" mods:kCmdShift menu:file];
  NSMenu *closeMultiple = [self submenu:@"Close Multiple Documents" inMenu:file];
  [self item:@"Close All but Active Document" action:@selector(closeOtherTabs:) menu:closeMultiple];
  [self item:@"Close All but Pinned Documents" action:@selector(closeAllButPinned:) menu:closeMultiple];
  [self item:@"Close All to the Left" action:@selector(closeAllToTheLeft:) menu:closeMultiple];
  [self item:@"Close All to the Right" action:@selector(closeAllToTheRight:) menu:closeMultiple];
  [self item:@"Close All Unchanged" action:@selector(closeUnchangedTabs:) menu:closeMultiple];
  [self item:@"Move to Trash" action:@selector(moveToTrash:) menu:file];
  [self separator:file];
  [self item:@"Load Session…" action:@selector(loadSession:) menu:file];
  [self item:@"Save Session…" action:@selector(saveSession:) menu:file];
  [self separator:file];
  [self item:@"Print…" action:@selector(printDocument:) key:@"p" mods:kCmd menu:file];
  [self item:@"Print Now" action:@selector(printNow:) menu:file];
  [self separator:file];
  self.recentMenu = [self submenu:@"Recent Files" inMenu:file];
  [self rebuildRecentMenu];
  [self separator:file];
  [self item:@"Exit" action:@selector(terminate:) menu:file].target = NSApp;

  // Edit
  NSMenu *edit = [self submenu:@"Edit" inMenu:main];
  [self item:@"Undo" action:@selector(undo:) key:@"z" mods:kCmd menu:edit];
  [self item:@"Redo" action:@selector(redo:) key:@"z" mods:kCmdShift menu:edit];
  [self separator:edit];
  [self item:@"Cut" action:@selector(cut:) key:@"x" mods:kCmd menu:edit];
  [self item:@"Copy" action:@selector(copy:) key:@"c" mods:kCmd menu:edit];
  [self item:@"Paste" action:@selector(paste:) key:@"v" mods:kCmd menu:edit];
  [self item:@"Delete" action:@selector(deleteSelection:) menu:edit];
  [self item:@"Select All" action:@selector(selectAll:) key:@"a" mods:kCmd menu:edit];
  [self item:@"Begin/End Select" action:@selector(beginEndSelect:) menu:edit];
  [self item:@"Begin/End Select in Column Mode" action:@selector(beginEndSelectColumn:) menu:edit];
  [self separator:edit];
  NSMenu *insert = [self submenu:@"Insert" inMenu:edit];
  [self item:@"Date Time (short)" action:@selector(insertShortDateTime:) menu:insert];
  [self item:@"Date Time (long)" action:@selector(insertLongDateTime:) menu:insert];
  [self item:@"Date Time (customized)" action:@selector(insertCustomDateTime:) menu:insert];
  NSMenu *copyMenu = [self submenu:@"Copy to Clipboard" inMenu:edit];
  [self item:@"Copy Current Full File path" action:@selector(copyFullPath:) menu:copyMenu];
  [self item:@"Copy Current Filename" action:@selector(copyFileName:) menu:copyMenu];
  [self item:@"Copy Current Dir. Path" action:@selector(copyDirectoryPath:) menu:copyMenu];
  [self item:@"Copy All Filenames" action:@selector(copyAllFileNames:) menu:copyMenu];
  [self item:@"Copy All File Paths" action:@selector(copyAllFilePaths:) menu:copyMenu];
  NSMenu *indent = [self submenu:@"Indent" inMenu:edit];
  [self item:@"Increase Line Indent" action:@selector(indentLines:) key:@"]" mods:kCmd menu:indent];
  [self item:@"Decrease Line Indent" action:@selector(outdentLines:) key:@"[" mods:kCmd menu:indent];
  NSMenu *caseMenu = [self submenu:@"Convert Case to" inMenu:edit];
  [self item:@"UPPERCASE" action:@selector(uppercaseSelection:) key:@"u" mods:kCmdShift menu:caseMenu];
  [self item:@"lowercase" action:@selector(lowercaseSelection:) key:@"u" mods:kCmd menu:caseMenu];
  [self item:@"Proper Case" action:@selector(properCaseSelection:) key:@"u" mods:kCmdOption menu:caseMenu];
  [self item:@"Proper Case (blend)" action:@selector(properCaseBlend:) menu:caseMenu];
  [self item:@"Sentence case" action:@selector(sentenceCaseSelection:) key:@"u" mods:kCtrlCmd menu:caseMenu];
  [self item:@"Sentence case (blend)" action:@selector(sentenceCaseBlend:) menu:caseMenu];
  [self item:@"iNVERT cASE" action:@selector(invertCaseSelection:) key:@"u" mods:kCmdOptionShift menu:caseMenu];
  [self item:@"ranDOm CasE" action:@selector(randomCaseSelection:) menu:caseMenu];
  NSMenu *lines = [self submenu:@"Line Operations" inMenu:edit];
  [self item:@"Duplicate Current Line" action:@selector(duplicateLine:) key:@"d" mods:kCmd menu:lines];
  [self item:@"Remove Duplicate Lines" action:@selector(removeDuplicateLines:) menu:lines];
  [self item:@"Remove Consecutive Duplicate Lines" action:@selector(removeConsecutiveDuplicateLines:) menu:lines];
  [self item:@"Split Lines" action:@selector(splitLines:) key:@"i" mods:kCmd menu:lines];
  [self item:@"Join Lines" action:@selector(joinLines:) key:@"j" mods:kCmd menu:lines];
  [self item:@"Move Up Current Line" action:@selector(moveLineUp:) key:up mods:kCmdOption menu:lines];
  [self item:@"Move Down Current Line" action:@selector(moveLineDown:) key:down mods:kCmdOption menu:lines];
  [self item:@"Remove Empty Lines" action:@selector(removeEmptyLines:) menu:lines];
  [self item:@"Remove Empty Lines (Containing Blank characters)" action:@selector(removeBlankLines:) menu:lines];
  [self item:@"Insert Blank Line Above Current" action:@selector(insertLineAbove:) key:@"\r" mods:kCmdOption menu:lines];
  [self item:@"Insert Blank Line Below Current" action:@selector(insertLineBelow:) key:@"\r" mods:kCmdOptionShift menu:lines];
  [self item:@"Delete Current Line" action:@selector(deleteLine:) key:@"l" mods:kCmdShift menu:lines];
  [self item:@"Transpose Current Line" action:@selector(transposeLine:) menu:lines];
  [self item:@"Reverse Line Order" action:@selector(reverseLines:) menu:lines];
  [self item:@"Randomize Line Order" action:@selector(shuffleLines:) menu:lines];
  [self separator:lines];
  NSArray *sorts = @[
    @[@"Sort Lines Lexicographically Ascending", @"lex", @YES], @[@"Sort Lines Lex. Ascending Ignoring Case", @"lexi", @YES],
    @[@"Sort Lines In Locale Order Ascending", @"locale", @YES], @[@"Sort Lines As Integers Ascending", @"int", @YES],
    @[@"Sort Lines As Decimals (Comma) Ascending", @"comma", @YES], @[@"Sort Lines As Decimals (Dot) Ascending", @"dot", @YES],
    @[@"Sort Lines By Length Ascending", @"length", @YES],
    @[@"Sort Lines Lexicographically Descending", @"lex", @NO], @[@"Sort Lines Lex. Descending Ignoring Case", @"lexi", @NO],
    @[@"Sort Lines In Locale Order Descending", @"locale", @NO], @[@"Sort Lines As Integers Descending", @"int", @NO],
    @[@"Sort Lines As Decimals (Comma) Descending", @"comma", @NO], @[@"Sort Lines As Decimals (Dot) Descending", @"dot", @NO],
    @[@"Sort Lines By Length Descending", @"length", @NO],
  ];
  for (NSArray *sort in sorts) {
    NSMenuItem *item = [self item:sort[0] action:@selector(sortLinesBy:) menu:lines];
    item.representedObject = @{@"kind": sort[1], @"ascending": sort[2]};
  }
  NSMenu *comment = [self submenu:@"Comment/Uncomment" inMenu:edit];
  [self item:@"Toggle Single Line Comment" action:@selector(toggleComment:) key:@"/" mods:kCmd menu:comment];
  [self item:@"Single Line Comment" action:@selector(singleLineComment:) key:@"k" mods:kCmd menu:comment];
  [self item:@"Single Line Uncomment" action:@selector(singleLineUncomment:) key:@"k" mods:kCmdShift menu:comment];
  [self item:@"Block Comment" action:@selector(blockComment:) key:@"/" mods:kCmdOption menu:comment];
  [self item:@"Block Uncomment" action:@selector(blockUncomment:) key:@"/" mods:kCmdOptionShift menu:comment];
  NSMenu *completion = [self submenu:@"Auto-Completion" inMenu:edit];
  [self item:@"Function Completion" action:@selector(functionCompletion:) key:@" " mods:kCtrl menu:completion];
  [self item:@"Word Completion" action:@selector(wordCompletion:) key:@"\r" mods:kCtrl menu:completion];
  [self item:@"Function Parameters Hint" action:@selector(functionParametersHint:) key:@" " mods:kCtrlShift menu:completion];
  [self item:@"Function Parameters Previous Hint" action:@selector(functionParametersHint:) menu:completion];
  [self item:@"Function Parameters Next Hint" action:@selector(functionParametersHint:) menu:completion];
  [self item:@"Path Completion" action:@selector(pathCompletion:) key:@" " mods:kCtrl | kOption menu:completion];
  NSMenu *eol = [self submenu:@"EOL Conversion" inMenu:edit];
  for (NSArray *ending in @[@[@"Windows (CR LF)", @"CRLF"], @[@"Unix (LF)", @"LF"], @[@"Macintosh (CR)", @"CR"]]) {
    [self item:ending[0] action:@selector(selectLineEnding:) menu:eol].representedObject = ending[1];
  }
  NSMenu *blank = [self submenu:@"Blank Operations" inMenu:edit];
  [self item:@"Trim Trailing Space" action:@selector(trimWhitespace:) menu:blank];
  [self item:@"Trim Leading Space" action:@selector(trimLeadingWhitespace:) menu:blank];
  [self item:@"Trim Leading and Trailing Space" action:@selector(trimBothWhitespace:) menu:blank];
  [self item:@"EOL to Space" action:@selector(eolToSpace:) menu:blank];
  [self item:@"Trim both and EOL to Space" action:@selector(trimBothAndEolToSpace:) menu:blank];
  [self separator:blank];
  [self item:@"TAB to Space" action:@selector(tabsToSpaces:) menu:blank];
  [self item:@"Space to TAB (All)" action:@selector(spacesToTabsAll:) menu:blank];
  [self item:@"Space to TAB (Leading)" action:@selector(spacesToTabsLeading:) menu:blank];
  NSMenu *pasteSpecial = [self submenu:@"Paste Special" inMenu:edit];
  [self item:@"Paste HTML Content" action:@selector(pasteHTMLContent:) menu:pasteSpecial];
  [self item:@"Paste RTF Content" action:@selector(pasteRTFContent:) menu:pasteSpecial];
  [self separator:pasteSpecial];
  [self item:@"Copy Binary Content" action:@selector(copy:) menu:pasteSpecial];
  [self item:@"Cut Binary Content" action:@selector(cut:) menu:pasteSpecial];
  [self item:@"Paste Binary Content" action:@selector(paste:) menu:pasteSpecial];
  NSMenu *onSelection = [self submenu:@"On Selection" inMenu:edit];
  [self item:@"Open File" action:@selector(openFileFromSelection:) menu:onSelection];
  [self item:@"Open Containing Folder in Finder" action:@selector(openContainingFolderOfSelection:) menu:onSelection];
  [self item:@"Redact Selection █" action:@selector(redactSelection:) menu:onSelection];
  [self item:@"Search on Internet" action:@selector(searchOnInternet:) menu:onSelection];
  [self item:@"Change Search Engine…" action:@selector(changeSearchEngine:) menu:onSelection];
  [self separator:edit];
  NSArray *multiTitles = @[@"Ignore Case & Whole Word", @"Match Case Only", @"Match Whole Word Only", @"Match Case & Whole Word"];
  NSMenu *multiAll = [self submenu:@"Multi-select All" inMenu:edit];
  NSMenu *multiNext = [self submenu:@"Multi-select Next" inMenu:edit];
  for (NSInteger index = 0; index < 4; index += 1) {
    [self item:multiTitles[index] action:@selector(multiSelectAll:) tag:index menu:multiAll];
    [self item:multiTitles[index] action:@selector(multiSelectNext:) tag:index menu:multiNext];
  }
  [[multiNext itemAtIndex:1] setKeyEquivalent:@"d"];
  [[multiNext itemAtIndex:1] setKeyEquivalentModifierMask:kCmdOption];
  [self item:@"Undo the Latest Added Multi-Select" action:@selector(undoLatestMultiSelect:) menu:edit];
  [self item:@"Skip Current & Go to Next Multi-select" action:@selector(skipCurrentMultiSelect:) menu:edit];
  [self separator:edit];
  [self item:@"Column Mode…" action:@selector(showColumnModeInfo:) menu:edit];
  [self item:@"Column Editor…" action:@selector(showColumnEditor:) key:@"c" mods:kCmdOption menu:edit];
  [self item:@"Character Panel" action:@selector(toggleCharacterPanel:) menu:edit];
  [self item:@"Clipboard History" action:@selector(toggleClipboardHistory:) menu:edit];
  [self separator:edit];
  NSMenu *readOnly = [self submenu:@"Read-Only in Notepad++" inMenu:edit];
  [self item:@"Read-Only on Current Document" action:@selector(toggleReadOnly:) menu:readOnly];
  [self item:@"Read-Only for All Documents" action:@selector(readOnlyAllDocuments:) menu:readOnly];
  [self item:@"Clear Read-Only for All Documents" action:@selector(clearReadOnlyAllDocuments:) menu:readOnly];
  [self item:@"Read-Only Attribute in Finder" action:@selector(toggleReadOnlyAttribute:) menu:edit];

  // Search
  NSMenu *search = [self submenu:@"Search" inMenu:main];
  [self item:@"Find…" action:@selector(focusFind:) key:@"f" mods:kCmd menu:search];
  [self item:@"Find in Files…" action:@selector(findInProject:) key:@"f" mods:kCmdShift menu:search];
  [self item:@"Find Next" action:@selector(findNext:) key:@"g" mods:kCmd menu:search];
  [self item:@"Find Previous" action:@selector(findPrevious:) key:@"g" mods:kCmdShift menu:search];
  [self item:@"Select and Find Next" action:@selector(selectAndFindNext:) key:@"e" mods:kCmd menu:search];
  [self item:@"Select and Find Previous" action:@selector(selectAndFindPrevious:) key:@"e" mods:kCmdShift menu:search];
  [self item:@"Find (Volatile) Next" action:@selector(volatileFindNext:) key:@"g" mods:kCmdOption menu:search];
  [self item:@"Find (Volatile) Previous" action:@selector(volatileFindPrevious:) key:@"g" mods:kCmdOptionShift menu:search];
  [self item:@"Replace…" action:@selector(focusReplace:) key:@"f" mods:kCmdOption menu:search];
  [self item:@"Incremental Search" action:@selector(toggleIncrementalSearch:) key:@"i" mods:kCmdOption menu:search];
  [self item:@"Search Results Window" action:@selector(toggleResultsPane:) menu:search];
  [self item:@"Next Search Result" action:@selector(nextSearchResult:) key:f4 mods:0 menu:search];
  [self item:@"Previous Search Result" action:@selector(previousSearchResult:) key:f4 mods:NSEventModifierFlagShift menu:search];
  [self item:@"Go to…" action:@selector(goToLine:) key:@"l" mods:kCmd menu:search];
  [self item:@"Go to Matching Brace" action:@selector(goToMatchingBrace:) key:@"b" mods:kCmd menu:search];
  [self item:@"Select All In-between {} [] or ()" action:@selector(selectToMatchingBrace:) key:@"b" mods:kCmdOption menu:search];
  [self item:@"Mark…" action:@selector(showMarkPanel:) key:@"m" mods:kCmdShift menu:search];
  [self separator:search];
  NSMenu *history = [self submenu:@"Change History" inMenu:search];
  [self item:@"Go to Next Change" action:@selector(goToNextChange:) menu:history];
  [self item:@"Go to Previous Change" action:@selector(goToPreviousChange:) menu:history];
  [self item:@"Clear Change History" action:@selector(clearChangeHistory:) menu:history];
  [self separator:search];
  [self addStyleMenus:search];
  NSArray *styleNames = @[@"1st Style", @"2nd Style", @"3rd Style", @"4th Style", @"5th Style"];
  NSMenu *jumpUp = [self submenu:@"Jump Up" inMenu:search];
  NSMenu *jumpDown = [self submenu:@"Jump Down" inMenu:search];
  NSMenu *copyStyled = [self submenu:@"Copy Styled Text" inMenu:search];
  for (NSInteger index = 0; index < 5; index += 1) {
    [self item:styleNames[index] action:@selector(jumpUpToStyle:) tag:index + 1 menu:jumpUp];
    [self item:styleNames[index] action:@selector(jumpDownToStyle:) tag:index + 1 menu:jumpDown];
    [self item:styleNames[index] action:@selector(copyStyledText:) tag:index + 1 menu:copyStyled];
  }
  [self item:@"Find Mark Style" action:@selector(jumpUpToStyle:) tag:6 menu:jumpUp];
  [self item:@"Find Mark Style" action:@selector(jumpDownToStyle:) tag:6 menu:jumpDown];
  [self item:@"All Styles" action:@selector(copyStyledText:) tag:0 menu:copyStyled];
  [self item:@"Find Mark Style" action:@selector(copyStyledText:) tag:6 menu:copyStyled];
  [self separator:search];
  NSMenu *bookmarks = [self submenu:@"Bookmark" inMenu:search];
  [self item:@"Toggle Bookmark" action:@selector(toggleBookmark:) key:f2 mods:kCmd menu:bookmarks];
  [self item:@"Next Bookmark" action:@selector(nextBookmark:) key:f2 mods:0 menu:bookmarks];
  [self item:@"Previous Bookmark" action:@selector(previousBookmark:) key:f2 mods:NSEventModifierFlagShift menu:bookmarks];
  [self item:@"Clear All Bookmarks" action:@selector(clearBookmarks:) menu:bookmarks];
  [self item:@"Cut Bookmarked Lines" action:@selector(cutBookmarkedLines:) menu:bookmarks];
  [self item:@"Copy Bookmarked Lines" action:@selector(copyBookmarkedLines:) menu:bookmarks];
  [self item:@"Paste to (Replace) Bookmarked Lines" action:@selector(pasteToBookmarkedLines:) menu:bookmarks];
  [self item:@"Remove Bookmarked Lines" action:@selector(removeBookmarkedLines:) menu:bookmarks];
  [self item:@"Remove Non-Bookmarked Lines" action:@selector(removeUnbookmarkedLines:) menu:bookmarks];
  [self item:@"Inverse Bookmarks" action:@selector(inverseBookmarks:) menu:bookmarks];
  [self separator:search];
  [self item:@"Find characters in range…" action:@selector(findCharactersInRange:) menu:search];

  // View
  NSMenu *view = [self submenu:@"View" inMenu:main];
  [self item:@"Always on Top" action:@selector(toggleAlwaysOnTop:) menu:view];
  [self item:@"Toggle Full Screen Mode" action:@selector(toggleFullScreenMode:) key:@"f" mods:kCtrlCmd menu:view];
  [self item:@"Post-It" action:@selector(togglePostIt:) key:f12 mods:0 menu:view];
  [self item:@"Distraction Free Mode" action:@selector(toggleDistractionFree:) menu:view];
  [self separator:view];
  NSMenu *viewIn = [self submenu:@"View Current File in" inMenu:view];
  for (NSArray *browser in @[@[@"Safari", @"com.apple.Safari"], @[@"Chrome", @"com.google.Chrome"],
                             @[@"Firefox", @"org.mozilla.firefox"], @[@"Edge", @"com.microsoft.edgemac"]]) {
    [self item:browser[0] action:@selector(viewInBrowser:) menu:viewIn].representedObject = browser[1];
  }
  [self separator:view];
  NSMenu *symbols = [self submenu:@"Show Symbol" inMenu:view];
  [self addMenuItem:@"Show Space and Tab" action:@selector(toggleViewOption:) key:@"" toMenu:symbols].representedObject = NativeViewWhitespace;
  [self addMenuItem:@"Show End of Line" action:@selector(toggleViewOption:) key:@"" toMenu:symbols].representedObject = NativeViewEndOfLine;
  [self addMenuItem:@"Show Non-Printing Characters" action:@selector(toggleViewOption:) key:@"" toMenu:symbols].representedObject = @"nonPrinting";
  [self addMenuItem:@"Show Control Characters & Unicode EOL" action:@selector(toggleViewOption:) key:@"" toMenu:symbols].representedObject = @"controlChars";
  [self item:@"Show All Characters" action:@selector(toggleAllCharacters:) menu:symbols];
  [self separator:symbols];
  [self addMenuItem:@"Show Indent Guide" action:@selector(toggleViewOption:) key:@"" toMenu:symbols].representedObject = NativeViewIndentGuides;
  [self addMenuItem:@"Show Wrap Symbol" action:@selector(toggleViewOption:) key:@"" toMenu:symbols].representedObject = @"wrapSymbol";
  NSMenu *zoom = [self submenu:@"Zoom" inMenu:view];
  [self item:@"Zoom In" action:@selector(zoomIn:) key:@"=" mods:kCmd menu:zoom];
  [self item:@"Zoom Out" action:@selector(zoomOut:) key:@"-" mods:kCmd menu:zoom];
  [self item:@"Restore Default Zoom" action:@selector(zoomReset:) key:@"0" mods:kCmd menu:zoom];
  [self addMenuItem:@"Synchronize Across Views" action:@selector(toggleViewOption:) key:@"" toMenu:zoom].representedObject = @"syncZoom";
  NSMenu *moveClone = [self submenu:@"Move/Clone Current Document" inMenu:view];
  [self item:@"Move to Other View" action:@selector(moveToOtherView:) menu:moveClone];
  [self item:@"Clone to Other View" action:@selector(toggleSplitView:) menu:moveClone];
  [self item:@"Move to New Instance" action:@selector(moveToNewInstance:) menu:moveClone];
  [self item:@"Open in New Instance" action:@selector(openInNewInstance:) menu:moveClone];
  NSMenu *tabMenu = [self submenu:@"Tab" inMenu:view];
  NSArray *ordinals = @[@"1st", @"2nd", @"3rd", @"4th", @"5th", @"6th", @"7th", @"8th", @"9th"];
  for (NSInteger index = 0; index < 9; index += 1) {
    NSMenuItem *item = [self item:[ordinals[index] stringByAppendingString:@" Tab"] action:@selector(selectTabNumber:)
                              key:[NSString stringWithFormat:@"%ld", (long)index + 1] mods:kCmd menu:tabMenu];
    item.tag = index;
  }
  [self item:@"First Tab" action:@selector(selectFirstTab:) menu:tabMenu];
  [self item:@"Last Tab" action:@selector(selectLastTab:) menu:tabMenu];
  [self item:@"Next Tab" action:@selector(selectNextTab:) key:@"\t" mods:kCtrl menu:tabMenu];
  [self item:@"Previous Tab" action:@selector(selectPreviousTab:) key:@"\t" mods:kCtrlShift menu:tabMenu];
  [self item:@"Move to Start" action:@selector(moveTabToStart:) menu:tabMenu];
  [self item:@"Move to End" action:@selector(moveTabToEnd:) menu:tabMenu];
  [self item:@"Move Tab Forward" action:@selector(moveTabForward:) key:pageDown mods:kCtrlShift menu:tabMenu];
  [self item:@"Move Tab Backward" action:@selector(moveTabBackward:) key:pageUp mods:kCtrlShift menu:tabMenu];
  [self separator:tabMenu];
  for (NSInteger index = 1; index <= 5; index += 1) {
    [self item:[NSString stringWithFormat:@"Apply Color %ld", (long)index] action:@selector(applyTabColor:) tag:index menu:tabMenu];
  }
  [self item:@"Remove Color" action:@selector(applyTabColor:) tag:0 menu:tabMenu];
  [self separator:view];
  [self item:@"Word wrap" action:@selector(toggleWordWrap:) menu:view];
  [self item:@"Focus on Another View" action:@selector(focusOnAnotherView:) menu:view];
  [self item:@"Hide Lines" action:@selector(hideLines:) menu:view];
  [self item:@"Show Hidden Lines" action:@selector(showHiddenLines:) menu:view];
  [self separator:view];
  [self item:@"Fold All" action:@selector(foldAll:) key:@"0" mods:kCmdOption menu:view];
  [self item:@"Unfold All" action:@selector(unfoldAll:) key:@"0" mods:kCmdOptionShift menu:view];
  [self item:@"Fold Current Level" action:@selector(foldCurrentLevel:) menu:view];
  [self item:@"Unfold Current Level" action:@selector(unfoldCurrentLevel:) menu:view];
  NSMenu *foldLevel = [self submenu:@"Fold Level" inMenu:view];
  NSMenu *unfoldLevel = [self submenu:@"Unfold Level" inMenu:view];
  for (NSInteger level = 1; level <= 8; level += 1) {
    NSString *title = [NSString stringWithFormat:@"%ld", (long)level];
    NSMenuItem *fold = [self item:title action:@selector(foldLevel:) key:title mods:kCmdOption menu:foldLevel];
    fold.tag = level;
    NSMenuItem *unfold = [self item:title action:@selector(unfoldLevel:) key:title mods:kCmdOptionShift menu:unfoldLevel];
    unfold.tag = level;
  }
  [self separator:view];
  [self item:@"Summary…" action:@selector(showSummary:) menu:view];
  [self separator:view];
  NSMenu *projects = [self submenu:@"Project Panels" inMenu:view];
  for (NSInteger index = 1; index <= 3; index += 1) {
    [self item:[NSString stringWithFormat:@"Project Panel %ld", (long)index] action:@selector(toggleProjectPanel:) tag:index menu:projects];
  }
  [self item:@"Folder as Workspace" action:@selector(toggleProjectPane:) menu:view];
  [self item:@"Document Map" action:@selector(toggleDocumentMap:) menu:view];
  [self item:@"Document List" action:@selector(toggleDocumentList:) menu:view];
  [self item:@"Function List" action:@selector(toggleFunctionList:) menu:view];
  [self separator:view];
  [self item:@"Synchronize Vertical Scrolling" action:@selector(toggleSyncVerticalScrolling:) menu:view];
  [self item:@"Synchronize Horizontal Scrolling" action:@selector(toggleSyncHorizontalScrolling:) menu:view];
  [self separator:view];
  [self item:@"Text Direction RTL" action:@selector(textDirectionRTL:) menu:view];
  [self item:@"Text Direction LTR" action:@selector(textDirectionLTR:) menu:view];
  [self separator:view];
  [self item:@"Monitoring (tail -f)" action:@selector(toggleMonitoring:) menu:view];

  // Encoding: the first group reinterprets the file, "Convert to" re-encodes it.
  NSMenu *encoding = [self submenu:@"Encoding" inMenu:main];
  NSArray *unicode = @[
    @[@"ANSI", @(NSWindowsCP1252StringEncoding), @NO], @[@"UTF-8", @(NSUTF8StringEncoding), @NO],
    @[@"UTF-8-BOM", @(NSUTF8StringEncoding), @YES], @[@"UTF-16 BE BOM", @(NSUTF16BigEndianStringEncoding), @YES],
    @[@"UTF-16 LE BOM", @(NSUTF16LittleEndianStringEncoding), @YES]
  ];
  for (NSArray *entry in unicode) {
    [self item:entry[0] action:@selector(encodeIn:) menu:encoding].representedObject = @{@"encoding": entry[1], @"bom": entry[2]};
  }
  [self separator:encoding];
  for (NSArray *entry in unicode) {
    NSString *title = [@"Convert to " stringByAppendingString:entry[0]];
    [self item:title action:@selector(selectEncoding:) menu:encoding].representedObject = @{@"encoding": entry[1], @"bom": entry[2]};
  }

  // Language: compact, grouped by first letter as in Notepad++.
  NSMenu *language = [self submenu:@"Language" inMenu:main];
  NSArray<NativeLanguage *> *sorted = [[NativeLanguage allLanguages] sortedArrayUsingComparator:^NSComparisonResult(NativeLanguage *left, NativeLanguage *right) {
    return [left.name localizedCaseInsensitiveCompare:right.name];
  }];
  [self item:@"None (Normal Text)" action:@selector(selectLanguage:) menu:language].representedObject = @"text";
  NSMutableDictionary<NSString *, NSMutableArray<NativeLanguage *> *> *byLetter = [NSMutableDictionary dictionary];
  for (NativeLanguage *entry in sorted) {
    if ([entry.identifier isEqualToString:@"text"]) continue;
    NSString *letter = [entry.name substringToIndex:1].uppercaseString;
    if (!byLetter[letter]) byLetter[letter] = [NSMutableArray array];
    [byLetter[letter] addObject:entry];
  }
  for (NSString *letter in [byLetter.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSArray *entries = byLetter[letter];
    NSMenu *target = language;
    if (entries.count > 1) target = [self submenu:letter inMenu:language];
    for (NativeLanguage *entry in entries) {
      [self item:entry.name action:@selector(selectLanguage:) menu:target].representedObject = entry.identifier;
    }
  }
  [self separator:language];
  NSMenu *udl = [self submenu:@"User Defined Language" inMenu:language];
  [self item:@"Define your language…" action:@selector(defineCustomLanguage:) menu:udl];
  [self item:@"Open User Defined Language folder…" action:@selector(openUserLanguageFolder:) menu:udl];
  [self separator:language];
  self.languageMenu = language;

  // Settings
  NSMenu *settings = [self submenu:@"Settings" inMenu:main];
  [self item:@"Preferences…" action:@selector(showPreferences:) menu:settings];
  [self item:@"Style Configurator…" action:@selector(showStyleConfigurator:) menu:settings];
  [self item:@"Shortcut Mapper…" action:@selector(showShortcutMapper:) menu:settings];
  [self separator:settings];
  NSMenu *import = [self submenu:@"Import" inMenu:settings];
  [self item:@"Import plugin(s)…" action:@selector(importPluginPack:) menu:import];
  [self item:@"Import style theme(s)…" action:@selector(importStyleTheme:) menu:import];
  [self separator:settings];
  [self item:@"Dark Mode" action:@selector(toggleTheme:) menu:settings];

  // Tools
  NSMenu *tools = [self submenu:@"Tools" inMenu:main];
  for (NSString *algorithm in @[@"MD5", @"SHA-1", @"SHA-256", @"SHA-512"]) {
    NSMenu *hash = [self submenu:algorithm inMenu:tools];
    [self item:@"Generate…" action:@selector(hashGenerate:) menu:hash].representedObject = algorithm;
    [self item:@"Generate from files…" action:@selector(hashFromFiles:) menu:hash].representedObject = algorithm;
    [self item:@"Generate from selection into clipboard" action:@selector(hashSelectionToClipboard:) menu:hash].representedObject = algorithm;
  }

  // Macro
  self.macroMenu = [self submenu:@"Macro" inMenu:main];
  [self buildMacroMenu:self.macroMenu];

  // Run
  NSMenu *run = [self submenu:@"Run" inMenu:main];
  [self buildRunMenu:run];

  // Plugins: the plugins Notepad++ ships by default, plus data-only packs.
  NSMenu *plugins = [self submenu:@"Plugins" inMenu:main];
  NSMenu *mime = [self submenu:@"MIME Tools" inMenu:plugins];
  [self item:@"Base64 Encode" action:@selector(base64Encode:) menu:mime];
  [self item:@"Base64 Decode" action:@selector(base64Decode:) menu:mime];
  [self item:@"URL Encode" action:@selector(urlEncode:) menu:mime];
  [self item:@"URL Decode" action:@selector(urlDecode:) menu:mime];
  NSMenu *converter = [self submenu:@"Converter" inMenu:plugins];
  [self item:@"ASCII -> HEX" action:@selector(asciiToHex:) menu:converter];
  [self item:@"HEX -> ASCII" action:@selector(hexToAscii:) menu:converter];
  NSMenu *exportMenu = [self submenu:@"NppExport" inMenu:plugins];
  [self item:@"Export to RTF…" action:@selector(exportToRTF:) menu:exportMenu];
  [self item:@"Export to HTML…" action:@selector(exportToHTML:) menu:exportMenu];
  [self item:@"Copy RTF to clipboard" action:@selector(copyRTFToClipboard:) menu:exportMenu];
  [self item:@"Copy HTML to clipboard" action:@selector(copyHTMLToClipboard:) menu:exportMenu];
  [self separator:plugins];
  [self item:@"Insert Snippet…" action:@selector(insertSnippet:) menu:plugins];
  [self item:@"Run Text Action…" action:@selector(runPluginAction:) menu:plugins];
  [self item:@"Plugins Admin…" action:@selector(managePluginPacks:) menu:plugins];
  [self item:@"Open Plugins Folder…" action:@selector(openPluginsFolder:) menu:plugins];

  // Window: sort options, Windows… dialog, recent window and the open documents.
  NSMenu *window = [self submenu:@"Window" inMenu:main];
  window.delegate = (id<NSMenuDelegate>)self;
  NSApp.windowsMenu = window;

  // ?
  NSMenu *help = [self submenu:@"?" inMenu:main];
  [self item:@"Command Line Arguments…" action:@selector(showCommandLineArguments:) menu:help];
  [self item:@"Debug Info…" action:@selector(showDebugInfo:) menu:help];
  [help addItemWithTitle:[@"About " stringByAppendingString:appName] action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
  NSApp.helpMenu = help;

  [NSApp setMainMenu:main];
  [self applyShortcutOverrides];
}

// Rebuilt each time it opens so the document list is current.
- (void)menuNeedsUpdate:(NSMenu *)menu {
  if (menu != NSApp.windowsMenu) return;
  [menu removeAllItems];
  NSMenu *sortMenu = [self submenu:@"Sort By" inMenu:menu];
  NSArray *sorts = @[@"Name A to Z", @"Name Z to A", @"Path A to Z", @"Path Z to A", @"Type A to Z", @"Type Z to A",
                     @"Content Length Ascending", @"Content Length Descending", @"Modified Time Ascending", @"Modified Time Descending"];
  [sorts enumerateObjectsUsingBlock:^(NSString *title, NSUInteger index, BOOL *stop) {
    (void)stop;
    [self item:title action:@selector(sortTabsBy:) tag:(NSInteger)index menu:sortMenu];
  }];
  [self item:@"Windows…" action:@selector(showDocumentList:) menu:menu];
  [self item:@"Recent Window" action:@selector(recentWindow:) key:@"`" mods:kCtrl menu:menu];
  [self separator:menu];
  [menu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
  [menu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
  [self separator:menu];
  NativeDocument *active = self.activeDocument;
  NSInteger number = 1;
  for (NSTabViewItem *tabItem in self.tabView.tabViewItems) {
    NativeDocument *document = [self documentWithIdentifier:tabItem.identifier];
    if (!document) continue;
    NSString *title = [NSString stringWithFormat:@"%ld: %@%@", (long)number, document.fileURL.path ?: document.name, document.isDirty ? @" *" : @""];
    NSMenuItem *item = [self item:title action:@selector(activateDocumentFromMenu:) menu:menu];
    item.representedObject = document.identifier;
    item.state = document == active ? NSControlStateValueOn : NSControlStateValueOff;
    number += 1;
  }
}

#pragma mark - Context menus

// Same structure as Notepad++'s default tab context menu (tabContextMenu.xml).
- (NSMenu *)tabContextMenu {
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Tab"];
  [self item:@"Close" action:@selector(closeCurrentTab:) menu:menu];
  NSMenu *closeMultiple = [self submenu:@"Close Multiple Tabs" inMenu:menu];
  [self item:@"Close All BUT This" action:@selector(closeOtherTabs:) menu:closeMultiple];
  [self item:@"Close All BUT Pinned" action:@selector(closeAllButPinned:) menu:closeMultiple];
  [self item:@"Close All to the Left" action:@selector(closeAllToTheLeft:) menu:closeMultiple];
  [self item:@"Close All to the Right" action:@selector(closeAllToTheRight:) menu:closeMultiple];
  [self item:@"Close All Unchanged" action:@selector(closeUnchangedTabs:) menu:closeMultiple];
  [self item:[self.pinnedDocuments containsObject:self.activeDocument.identifier] ? @"Unpin Tab" : @"Pin Tab"
      action:@selector(togglePinTab:) menu:menu];
  [self separator:menu];
  [self item:@"Save" action:@selector(saveDocument:) menu:menu];
  [self item:@"Save As…" action:@selector(saveDocumentAs:) menu:menu];
  NSMenu *openInto = [self submenu:@"Open Into" inMenu:menu];
  [self item:@"Open Containing Folder in Finder" action:@selector(revealInFinder:) menu:openInto];
  [self item:@"Open Containing Folder in Terminal" action:@selector(openInTerminal:) menu:openInto];
  [self item:@"Open Containing Folder as Workspace" action:@selector(openContainingFolderAsWorkspace:) menu:openInto];
  [self item:@"Open in Default Viewer" action:@selector(openInDefaultViewer:) menu:openInto];
  [self item:@"Rename" action:@selector(renameDocument:) menu:menu];
  [self item:@"Move to Trash" action:@selector(moveToTrash:) menu:menu];
  [self item:@"Reload" action:@selector(reloadDocument:) menu:menu];
  [self item:@"Print" action:@selector(printDocument:) menu:menu];
  [self separator:menu];
  [self item:@"Read-Only in Notepad++" action:@selector(toggleReadOnly:) menu:menu];
  [self item:@"Read-Only Attribute in Finder" action:@selector(toggleReadOnlyAttribute:) menu:menu];
  [self separator:menu];
  NSMenu *copy = [self submenu:@"Copy to Clipboard" inMenu:menu];
  [self item:@"Copy Full File Path" action:@selector(copyFullPath:) menu:copy];
  [self item:@"Copy Filename" action:@selector(copyFileName:) menu:copy];
  [self item:@"Copy Current Dir. Path" action:@selector(copyDirectoryPath:) menu:copy];
  NSMenu *move = [self submenu:@"Move Document" inMenu:menu];
  [self item:@"Move to Start" action:@selector(moveTabToStart:) menu:move];
  [self item:@"Move to End" action:@selector(moveTabToEnd:) menu:move];
  [self separator:move];
  [self item:@"Move to Other View" action:@selector(moveToOtherView:) menu:move];
  [self item:@"Clone to Other View" action:@selector(toggleSplitView:) menu:move];
  [self item:@"Move to New Instance" action:@selector(moveToNewInstance:) menu:move];
  [self item:@"Open in New Instance" action:@selector(openInNewInstance:) menu:move];
  NSMenu *colors = [self submenu:@"Apply Color to Tab" inMenu:menu];
  for (NSInteger index = 1; index <= 5; index += 1) {
    NSMenuItem *item = [self item:[NSString stringWithFormat:@"Apply Color %ld", (long)index] action:@selector(applyTabColor:) tag:index menu:colors];
    NSImage *swatch = [NSImage imageWithSize:NSMakeSize(12, 12) flipped:NO drawingHandler:^BOOL(NSRect rect) {
      [NativeTabColor(index) setFill];
      NSRectFill(rect);
      return YES;
    }];
    item.image = swatch;
  }
  [self item:@"Remove Color" action:@selector(applyTabColor:) tag:0 menu:colors];
  return menu;
}

// Same structure as Notepad++'s default editor context menu (contextMenu.xml).
- (NSMenu *)editorContextMenu {
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Editor"];
  [self item:@"Cut" action:@selector(cut:) menu:menu];
  [self item:@"Copy" action:@selector(copy:) menu:menu];
  [self item:@"Paste" action:@selector(paste:) menu:menu];
  [self item:@"Delete" action:@selector(deleteSelection:) menu:menu];
  [self item:@"Select All" action:@selector(selectAll:) menu:menu];
  [self item:@"Begin/End Select" action:@selector(beginEndSelect:) menu:menu];
  [self separator:menu];
  [self addStyleMenus:menu];
  [self separator:menu];
  [self item:@"Base64 Encode" action:@selector(base64Encode:) menu:menu];
  [self item:@"Base64 Decode" action:@selector(base64Decode:) menu:menu];
  [self separator:menu];
  [self item:@"UPPERCASE" action:@selector(uppercaseSelection:) menu:menu];
  [self item:@"lowercase" action:@selector(lowercaseSelection:) menu:menu];
  [self separator:menu];
  [self item:@"Open File" action:@selector(openFileFromSelection:) menu:menu];
  [self item:@"Search on Internet" action:@selector(searchOnInternet:) menu:menu];
  [self separator:menu];
  [self item:@"Toggle Single Line Comment" action:@selector(toggleComment:) menu:menu];
  [self item:@"Block Comment" action:@selector(blockComment:) menu:menu];
  [self item:@"Block Uncomment" action:@selector(blockUncomment:) menu:menu];
  [self separator:menu];
  [self item:@"Hide Lines" action:@selector(hideLines:) menu:menu];
  return menu;
}

@end
