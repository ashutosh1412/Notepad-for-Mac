#import "NativeEditorController+Private.h"
#include "ILexer.h"
#include "Lexilla.h"

static NSString * const kSessionDefaultsKey = @"NativeEditor.Session.v1";
static NSString * const kPreferencesDefaultsKey = @"NativeEditor.Preferences.v1";
static NSString * const kRecentFilesKey = @"NativeEditor.RecentFiles.v1";
static NSString * const kCustomThemeKey = @"NativeEditor.CustomTheme.v1";
static NSString * const kCustomLanguagesKey = @"NativeEditor.CustomLanguages.v1";
static const NSUInteger kMaxRecentFiles = 15;
// Session content is only stored for unsaved buffers, and only up to this size.
static const NSUInteger kMaxSessionContentLength = 8 * 1024 * 1024;

// /tmp and /private/tmp (and other symlinked paths) name the same file.
static BOOL SameFile(NSURL *left, NSURL *right) {
  if (!left || !right) return NO;
  return [left.URLByResolvingSymlinksInPath.path isEqualToString:right.URLByResolvingSymlinksInPath.path];
}

static NSString *AppName(void) {
  return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"Editor";
}

@implementation NativeFileNode
- (instancetype)initWithURL:(NSURL *)url {
  self = [super init];
  if (self) {
    _url = url;
    _name = url.lastPathComponent;
    NSNumber *isDirectory = nil;
    [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
    _directory = isDirectory.boolValue;
  }
  return self;
}
- (void)loadChildren {
  if (_childrenLoaded || !_directory) return;
  _childrenLoaded = YES;
  NSArray<NSURL *> *urls = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:_url
      includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey]
      options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
  NSMutableArray *children = [NSMutableArray array];
  for (NSURL *url in urls) {
    NSNumber *isSymbolicLink = nil;
    [url getResourceValue:&isSymbolicLink forKey:NSURLIsSymbolicLinkKey error:nil];
    if (isSymbolicLink.boolValue) continue;
    [children addObject:[[NativeFileNode alloc] initWithURL:url]];
  }
  [children sortUsingComparator:^NSComparisonResult(NativeFileNode *left, NativeFileNode *right) {
    if (left.directory != right.directory) return left.directory ? NSOrderedAscending : NSOrderedDescending;
    return [left.name localizedCaseInsensitiveCompare:right.name];
  }];
  _children = children;
}
@end

@implementation NativeTabView
@end

@implementation NativeEditorController

- (instancetype)initWithLexerFactory:(void *)lexerFactory {
  self = [super init];
  if (!self) return nil;
  _lexerFactory = lexerFactory;
  _documents = [NSMutableArray array];
  _tabItems = [NSMutableDictionary dictionary];
  _searchResults = @[];
  _currentMacro = @[];
  _monitoredDocuments = [NSMutableSet set];
  _pinnedDocuments = [NSMutableArray array];
  _tabColors = [NSMutableDictionary dictionary];
  _viewOptions = [@{
    NativeViewWordWrap: @NO, NativeViewLineNumbers: @YES, NativeViewWhitespace: @NO, NativeViewEndOfLine: @NO,
    NativeViewIndentGuides: @YES, NativeViewCaretLine: @YES, NativeViewTabWidth: @4, NativeViewUseTabs: @YES,
    NativeViewAutoIndent: @YES, NativeViewAutoComplete: @YES, NativeViewSmartHighlight: @YES, NativeViewFontSize: @13,
    NativeViewFontName: @"Menlo", NativeViewAutoClose: @NO, NativeViewChangeHistory: @YES,
    @"defaultEOL": @"LF", @"defaultBOM": @NO, @"rememberSession": @YES
  } mutableCopy];
  return self;
}

#pragma mark - Application lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  [self restorePreferences];
  [self buildMainMenu];
  [self buildWindow];
  for (NSDictionary *definition in [[NSUserDefaults standardUserDefaults] arrayForKey:kCustomLanguagesKey]) {
    [self addCustomLanguageMenuItem:definition];
  }
  for (NSDictionary *definition in [self userLanguageFilesDefinitions]) [self addCustomLanguageMenuItem:definition];
  [self startClipboardMonitoring];
  // Show the window before reopening files: a macOS folder-access prompt for a
  // restored file then appears over the app instead of before it.
  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  [self.window displayIfNeeded];
  [self restoreSession];
  if (self.documents.count == 0) [self newDocument:nil];
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  BOOL showFunctionList = [defaults boolForKey:@"NativeEditor.FunctionListVisible.v1"];
  BOOL showDocumentMap = [defaults boolForKey:@"NativeEditor.DocumentMapVisible.v1"];
  if (showFunctionList) [self toggleFunctionList:nil];
  if (showDocumentMap) [self toggleDocumentMap:nil];
  NSArray<NSURL *> *pending = self.pendingOpenURLs;
  self.pendingOpenURLs = nil;
  for (NSURL *url in pending) [self openURL:url];
  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationBecameActive:)
                                               name:NSApplicationDidBecomeActiveNotification object:nil];
#if NATIVE_EDITOR_DEBUG_HOOKS
  // Test-only hooks; release builds compile them out (see build.sh DEBUG_HOOKS).
  NSString *selfTestPath = NSProcessInfo.processInfo.environment[@"NATIVE_EDITOR_SELFTEST"];
  if (selfTestPath.length) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [self runSelfTestWritingTo:selfTestPath];
    });
  }
  // Debug aid: NATIVE_EDITOR_DUMP_MENUS=/path/menus.txt writes the menu tree, marking
  // items whose action has no implementation with "!! MISSING".
  NSString *menuDumpPath = NSProcessInfo.processInfo.environment[@"NATIVE_EDITOR_DUMP_MENUS"];
  if (menuDumpPath.length) {
    NSMutableString *dump = [NSMutableString string];
    __block void (^walk)(NSMenu *, NSInteger) = nil;
    __block __weak void (^weakWalk)(NSMenu *, NSInteger) = nil;
    walk = ^(NSMenu *menu, NSInteger depth) {
      if (menu == NSApp.windowsMenu) [self menuNeedsUpdate:menu];
      for (NSMenuItem *item in menu.itemArray) {
        if (item.isSeparatorItem) continue;
        NSString *indent = [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0];
        if (item.submenu) {
          [dump appendFormat:@"%@▸ %@\n", indent, item.title];
          weakWalk(item.submenu, depth + 1);
          continue;
        }
        id target = item.target ?: [NSApp targetForAction:item.action];
        BOOL implemented = !item.action || (target && [target respondsToSelector:item.action]);
        [dump appendFormat:@"%@%@%@%@\n", indent, item.title, item.keyEquivalent.length ? @"  [key]" : @"", implemented ? @"" : @"  !! MISSING"];
      }
    };
    weakWalk = walk;
    walk(NSApp.mainMenu, 0);
    [dump appendString:@"--- tab context menu ---\n"];
    walk([self tabContextMenu], 1);
    [dump appendString:@"--- editor context menu ---\n"];
    walk([self editorContextMenu], 1);
    [dump writeToFile:menuDumpPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }
  // Debug aid for checking the UI without screen-recording access:
  // NATIVE_EDITOR_SNAPSHOT=/path/out.png writes the window contents after launch.
  NSString *snapshotPath = NSProcessInfo.processInfo.environment[@"NATIVE_EDITOR_SNAPSHOT"];
  if (snapshotPath.length) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      NSView *view = self.window.contentView;
      for (NSInteger index = 0; index < self.tabView.numberOfTabViewItems; index += 1) {
        [self.tabView selectTabViewItemAtIndex:index];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
        [view layoutSubtreeIfNeeded];
        NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
        NSString *path = [snapshotPath.stringByDeletingPathExtension stringByAppendingFormat:@"-%ld.png", (long)index];
        [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
      }
      [self showPreferences:nil];
      [self showStyleConfigurator:nil];
      [self focusReplace:nil];
      for (NSWindow *window in @[self.preferencesWindow, self.styleWindow, self.findPanel]) {
        NSView *windowView = window.contentView;
        [windowView layoutSubtreeIfNeeded];
        NSBitmapImageRep *bitmap = [windowView bitmapImageRepForCachingDisplayInRect:windowView.bounds];
        [windowView cacheDisplayInRect:windowView.bounds toBitmapImageRep:bitmap];
        NSString *path = [snapshotPath.stringByDeletingPathExtension stringByAppendingFormat:@"-%@.png", window.title];
        [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
        [window close];
      }
    });
  }
#endif
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  (void)sender;
  return YES;
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
  (void)application;
  for (NSURL *url in urls) [self openURL:url];
}

- (void)application:(NSApplication *)application openFiles:(NSArray<NSString *> *)filenames {
  for (NSString *filename in filenames) [self openURL:[NSURL fileURLWithPath:filename]];
  [application replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

// Finder's "Open in Notepad++" service (NSServices in Info.plist).
- (void)openFilesService:(NSPasteboard *)pasteboard userData:(NSString *)userData error:(NSString **)error {
  (void)userData;
  NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[NSURL.class]
                                                     options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
  if (!urls.count) {
    if (error) *error = @"No files were selected.";
    return;
  }
  for (NSURL *url in urls) [self openURL:url];
  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
  (void)sender;
  // Like Notepad++, unsaved buffers survive quitting through the session instead of prompting,
  // unless "Remember current session" is off in Preferences.
  [self.sessionSaveTimer invalidate];
  if (![self.viewOptions[@"rememberSession"] boolValue]) {
    for (NativeDocument *document in [self.documents copy]) {
      if (!self.skipTerminationConfirmation && ![self confirmCloseDocument:document]) return NSTerminateCancel;
    }
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kSessionDefaultsKey];
    return NSTerminateNow;
  }
  [self persistSession];
  return NSTerminateNow;
}

- (void)applicationBecameActive:(NSNotification *)notification {
  (void)notification;
  [self checkForExternalChanges];
}

- (void)checkForExternalChanges {
  if (self.checkingExternalChanges) return;
  self.checkingExternalChanges = YES;
  for (NativeDocument *document in [self.documents copy]) {
    if ([self.monitoredDocuments containsObject:document.identifier] || ![document fileChangedOnDisk]) continue;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:document.fileURL.path];
    NSAlert *alert = [[NSAlert alloc] init];
    if (!exists) {
      alert.messageText = [NSString stringWithFormat:@"\"%@\" no longer exists.", document.fileURL.path];
      alert.informativeText = @"Keep this file in the editor? It will be marked as modified.";
      [alert addButtonWithTitle:@"Keep"];
      [alert addButtonWithTitle:@"Close"];
      if ([alert runModal] == NSAlertFirstButtonReturn) {
        document.fileModificationDate = nil;
        document.dirty = YES;
        [self updateDocument:document];
      } else {
        [document.editor message:SCI_SETSAVEPOINT];
        [self closeDocument:document];
      }
      continue;
    }
    alert.messageText = [NSString stringWithFormat:@"\"%@\" was modified by another program.", document.fileURL.path];
    alert.informativeText = document.isDirty ? @"Reload it? Your unsaved changes in this editor will be lost." : @"Reload it?";
    [alert addButtonWithTitle:@"Reload"];
    [alert addButtonWithTitle:@"Keep Mine"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
      NSError *error = nil;
      if (![document reloadFromDisk:&error]) [self showError:error];
    } else {
      NSDate *date = nil;
      [document.fileURL getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
      document.fileModificationDate = date;
    }
  }
  self.checkingExternalChanges = NO;
}

#pragma mark - Menus

- (NSMenuItem *)addMenuItem:(NSString *)title action:(SEL)action key:(NSString *)key toMenu:(NSMenu *)menu {
  return [self addMenuItem:title action:action key:key modifiers:NSEventModifierFlagCommand toMenu:menu];
}

- (NSMenuItem *)addMenuItem:(NSString *)title action:(SEL)action key:(NSString *)key
                  modifiers:(NSEventModifierFlags)modifiers toMenu:(NSMenu *)menu {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
  item.target = self;
  item.keyEquivalentModifierMask = key.length ? modifiers : 0;
  [menu addItem:item];
  return item;
}

- (NSMenu *)submenu:(NSString *)title inMenu:(NSMenu *)menu {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
  NSMenu *submenu = [[NSMenu alloc] initWithTitle:title];
  item.submenu = submenu;
  [menu addItem:item];
  return submenu;
}

- (NSMenuItem *)addOption:(NSString *)title key:(NSString *)optionKey toMenu:(NSMenu *)menu {
  NSMenuItem *item = [self addMenuItem:title action:@selector(toggleViewOption:) key:@"" toMenu:menu];
  item.representedObject = optionKey;
  return item;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
  NativeDocument *document = self.activeDocument;
  SEL action = item.action;
  if (action == @selector(toggleViewOption:)) {
    item.state = [self.viewOptions[item.representedObject] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(toggleAllCharacters:)) {
    BOOL all = [self.viewOptions[NativeViewWhitespace] boolValue] && [self.viewOptions[NativeViewEndOfLine] boolValue];
    item.state = all ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(selectLanguage:)) {
    item.state = !document.userLanguageName && [document.language isEqualToString:item.representedObject] ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(selectUserLanguage:)) {
    item.state = [document.userLanguageName isEqualToString:[item.representedObject objectForKey:@"name"]] ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(selectEncoding:)) {
    NSDictionary *encoding = item.representedObject;
    item.state = document.encoding == [encoding[@"encoding"] unsignedIntegerValue] && document.writesBOM == [encoding[@"bom"] boolValue]
        ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(reopenWithEncoding:) || action == @selector(reloadDocument:) ||
             action == @selector(revealInFinder:) || action == @selector(copyFullPath:)) {
    return document.fileURL != nil;
  } else if (action == @selector(selectLineEnding:)) {
    item.state = [document.lineEnding isEqualToString:item.representedObject] ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(selectTabWidth:)) {
    item.state = [self.viewOptions[NativeViewTabWidth] isEqual:item.representedObject] ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(selectFontSize:)) {
    item.state = [self.viewOptions[NativeViewFontSize] isEqual:item.representedObject] ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(toggleUseSpaces:)) {
    item.state = [self.viewOptions[NativeViewUseTabs] boolValue] ? NSControlStateValueOff : NSControlStateValueOn;
  } else if (action == @selector(toggleTheme:)) {
    item.state = self.darkTheme ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(toggleAlwaysOnTop:)) {
    item.state = self.window.level == NSFloatingWindowLevel ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(toggleMonitoring:)) {
    item.state = document && [self.monitoredDocuments containsObject:document.identifier] ? NSControlStateValueOn : NSControlStateValueOff;
    return document.fileURL != nil;
  } else if (action == @selector(toggleProjectPane:)) {
    item.state = self.projectPane.hidden ? NSControlStateValueOff : NSControlStateValueOn;
  } else if (action == @selector(toggleResultsPane:)) {
    item.state = self.resultsPane.hidden ? NSControlStateValueOff : NSControlStateValueOn;
  } else if (action == @selector(toggleSplitView:)) {
    item.state = document.splitContainer && document.splitDocument == document ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(compareWithNextTab:)) {
    item.state = document.splitContainer && document.splitDocument != document ? NSControlStateValueOn : NSControlStateValueOff;
  }
  if (![self validatePanelMenuItem:item]) return NO;
  if (![self validateParityMenuItem:item]) return NO;
  return [self validateCommandMenuItem:item];
}

#pragma mark - Window

static NSColor *ToolbarColor(unsigned int rgb) {
  return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0 green:((rgb >> 8) & 0xff) / 255.0 blue:(rgb & 0xff) / 255.0 alpha:1];
}

- (NSButton *)toolbarButtonWithImage:(NSImage *)image title:(NSString *)title action:(SEL)action {
  NSButton *button = image ? [NSButton buttonWithImage:image target:self action:action]
                           : [NSButton buttonWithTitle:title target:self action:action];
  button.bordered = NO;
  button.imageScaling = NSImageScaleProportionallyDown;
  button.toolTip = title;
  button.wantsLayer = YES;
  button.layer.cornerRadius = 3;
  [button.widthAnchor constraintEqualToConstant:24].active = YES;
  [button.heightAnchor constraintEqualToConstant:22].active = YES;
  return button;
}

- (NSView *)toolbarSeparator {
  NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 1, 18)];
  separator.boxType = NSBoxSeparator;
  [separator.heightAnchor constraintEqualToConstant:18].active = YES;
  return separator;
}

// Toolbar in Notepad++'s order and grouping, with colored icons.
- (NSStackView *)buildToolbar {
  NSStackView *toolbar = [[NSStackView alloc] initWithFrame:NSZeroRect];
  toolbar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  toolbar.spacing = 1;
  toolbar.edgeInsets = NSEdgeInsetsMake(3, 4, 3, 4);
  toolbar.translatesAutoresizingMaskIntoConstraints = NO;
  self.toolbarToggles = [NSMutableDictionary dictionary];
  NSColor *gray = ToolbarColor(0x5A5A5A), *blue = ToolbarColor(0x2F6FD0), *green = ToolbarColor(0x2E9E48);
  NSColor *red = ToolbarColor(0xD9363E), *yellow = ToolbarColor(0xF2B33D), *orange = ToolbarColor(0xE8862A);
  NSColor *purple = ToolbarColor(0x8A4FD0), *teal = ToolbarColor(0x1F9AA8), *brown = ToolbarColor(0x9C6B30);
  NSImage *(^symbol)(NSString *, NSArray *) = ^NSImage *(NSString *name, NSArray *colors) {
    return NativeSymbolIcon(name, colors, 13);
  };
  NSArray *items = @[
    @[@"New", NSStringFromSelector(@selector(newDocument:)), symbol(@"doc.badge.plus", @[green, gray])],
    @[@"Open", NSStringFromSelector(@selector(openFiles:)), symbol(@"folder.fill", @[yellow])],
    @[@"Save", NSStringFromSelector(@selector(saveDocument:)), NativeFloppyIcon(blue, 17)],
    @[@"Save All", NSStringFromSelector(@selector(saveAll:)), NativeSaveAllIcon(18)],
    @[@"Close", NSStringFromSelector(@selector(closeCurrentTab:)), symbol(@"xmark.square.fill", @[NSColor.whiteColor, red])],
    @[@"Close All", NSStringFromSelector(@selector(closeAllTabs:)), symbol(@"xmark.rectangle.portrait.fill", @[NSColor.whiteColor, red])],
    @[@"Print", NSStringFromSelector(@selector(printDocument:)), symbol(@"printer.fill", @[gray])],
    @"|",
    @[@"Cut", NSStringFromSelector(@selector(cut:)), symbol(@"scissors", @[red])],
    @[@"Copy", NSStringFromSelector(@selector(copy:)), symbol(@"doc.on.doc.fill", @[blue])],
    @[@"Paste", NSStringFromSelector(@selector(paste:)), symbol(@"doc.on.clipboard.fill", @[brown])],
    @"|",
    @[@"Undo", NSStringFromSelector(@selector(undo:)), symbol(@"arrow.uturn.backward", @[green])],
    @[@"Redo", NSStringFromSelector(@selector(redo:)), symbol(@"arrow.uturn.forward", @[green])],
    @"|",
    @[@"Find", NSStringFromSelector(@selector(focusFind:)), symbol(@"binoculars.fill", @[gray])],
    @[@"Replace", NSStringFromSelector(@selector(focusReplace:)), symbol(@"arrow.triangle.2.circlepath", @[blue])],
    @"|",
    @[@"Zoom In", NSStringFromSelector(@selector(zoomIn:)), symbol(@"plus.magnifyingglass", @[blue])],
    @[@"Zoom Out", NSStringFromSelector(@selector(zoomOut:)), symbol(@"minus.magnifyingglass", @[red])],
    @"|",
    @[@"Split View", NSStringFromSelector(@selector(toggleSplitView:)), symbol(@"rectangle.split.2x1.fill", @[orange]), @"split"],
    @[@"Compare with Next Tab", NSStringFromSelector(@selector(compareWithNextTab:)), symbol(@"arrow.left.and.right.square.fill", @[orange]), @"compare"],
    @"|",
    @[@"Word Wrap", NSStringFromSelector(@selector(toggleWordWrap:)), symbol(@"arrow.turn.down.left", @[blue]), NativeViewWordWrap],
    @[@"Show All Characters", NSStringFromSelector(@selector(toggleAllCharacters:)), symbol(@"paragraphsign", @[blue]), @"allChars"],
    @[@"Indent Guide", NSStringFromSelector(@selector(toggleIndentGuides:)), symbol(@"increase.indent", @[blue]), NativeViewIndentGuides],
    @"|",
    @[@"Folder as Workspace", NSStringFromSelector(@selector(toggleProjectPane:)), symbol(@"folder.badge.gearshape", @[orange, gray]), @"workspace"],
    @[@"Document Map", NSStringFromSelector(@selector(toggleDocumentMap:)), symbol(@"map.fill", @[teal]), @"map"],
    @[@"Function List", NSStringFromSelector(@selector(toggleFunctionList:)), symbol(@"function", @[purple]), @"functions"],
    @"|",
    @[@"Monitoring (tail -f)", NSStringFromSelector(@selector(toggleMonitoring:)), symbol(@"eye.fill", @[gray]), @"monitoring"],
    @"|",
    @[@"Start Recording", NSStringFromSelector(@selector(toggleMacroRecording:)), symbol(@"circle.fill", @[red]), @"recording"],
    @[@"Stop Recording", NSStringFromSelector(@selector(toggleMacroRecording:)), symbol(@"stop.fill", @[gray])],
    @[@"Playback", NSStringFromSelector(@selector(playMacro:)), symbol(@"play.fill", @[gray])],
    @[@"Run a Macro Multiple Times", NSStringFromSelector(@selector(runMacroMultipleTimes:)), symbol(@"forward.fill", @[blue])],
    @[@"Save Current Recorded Macro", NSStringFromSelector(@selector(saveCurrentMacro:)), symbol(@"tray.and.arrow.down.fill", @[blue])],
  ];
  for (id entry in items) {
    if ([entry isKindOfClass:NSString.class]) {
      [toolbar addArrangedSubview:[self toolbarSeparator]];
      continue;
    }
    NSArray *item = entry;
    NSImage *image = item[2] == [NSNull null] ? nil : item[2];
    NSButton *button = [self toolbarButtonWithImage:image title:item[0] action:NSSelectorFromString(item[1])];
    if (item.count > 3) self.toolbarToggles[item[3]] = button;
    [toolbar addArrangedSubview:button];
  }
  [toolbar setHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
  return toolbar;
}

// Toggle buttons show a pressed (blue) state, like Notepad++'s toolbar.
- (void)syncToolbarToggles {
  NativeDocument *document = self.activeDocument;
  NSDictionary<NSString *, NSNumber *> *states = @{
    NativeViewWordWrap: self.viewOptions[NativeViewWordWrap] ?: @NO,
    NativeViewIndentGuides: self.viewOptions[NativeViewIndentGuides] ?: @NO,
    @"allChars": @([self.viewOptions[NativeViewWhitespace] boolValue] && [self.viewOptions[NativeViewEndOfLine] boolValue]),
    @"workspace": @(!self.projectPane.hidden),
    @"map": @(!self.documentMap.hidden),
    @"functions": @(!self.functionListPane.hidden),
    @"split": @(document.splitContainer != nil && document.splitDocument == document),
    @"compare": @(document.splitContainer != nil && document.splitDocument != document),
    @"monitoring": @(document && [self.monitoredDocuments containsObject:document.identifier]),
    @"recording": @(document.isRecordingMacro),
  };
  NSColor *on = [NSColor.controlAccentColor colorWithAlphaComponent:0.25];
  [states enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *value, BOOL *stop) {
    (void)stop;
    NSButton *button = self.toolbarToggles[key];
    button.layer.backgroundColor = value.boolValue ? on.CGColor : NSColor.clearColor.CGColor;
    button.layer.borderWidth = value.boolValue ? 1 : 0;
    button.layer.borderColor = [NSColor.controlAccentColor colorWithAlphaComponent:0.6].CGColor;
  }];
}

- (void)buildWindow {
  NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
  self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1120, 760) styleMask:style
                                              backing:NSBackingStoreBuffered defer:NO];
  self.window.title = AppName();
  self.window.minSize = NSMakeSize(640, 420);
  self.window.delegate = self;
  self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
  [self.window setFrameAutosaveName:@"NativeEditor.MainWindow"];
  if (!self.window.frameAutosaveName.length || NSIsEmptyRect(self.window.frame)) [self.window center];

  NSView *content = self.window.contentView;
  NSStackView *toolbar = [self buildToolbar];
  [content addSubview:toolbar];
  self.toolbarView = toolbar;
  NSBox *toolbarLine = [[NSBox alloc] initWithFrame:NSZeroRect];
  toolbarLine.boxType = NSBoxSeparator;
  toolbarLine.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:toolbarLine];
  self.toolbarLine = toolbarLine;
  [self buildFindPanel];

  self.tabView = [[NativeTabView alloc] initWithFrame:NSMakeRect(0, 0, 800, 500)];
  self.tabView.tabViewType = NSNoTabsNoBorder;
  self.tabView.delegate = self;
  self.tabView.translatesAutoresizingMaskIntoConstraints = NO;
  __weak NativeEditorController *weakSelf = self;
  self.tabBar = [[NativeTabBar alloc] initWithFrame:NSMakeRect(0, 0, 800, 28)];
  self.tabBar.translatesAutoresizingMaskIntoConstraints = NO;
  self.tabBar.tabView = self.tabView;
  self.tabBar.stateProvider = ^NativeTabState(NSTabViewItem *item) {
    NativeEditorController *strongSelf = weakSelf;
    NativeDocument *document = [strongSelf documentWithIdentifier:item.identifier];
    if ([strongSelf.monitoredDocuments containsObject:item.identifier]) return NativeTabStateMonitoring;
    if (document.isReadOnly) return NativeTabStateReadOnly;
    return document.isDirty ? NativeTabStateModified : NativeTabStateSaved;
  };
  self.tabBar.pinnedProvider = ^BOOL(NSTabViewItem *item) {
    return [weakSelf.pinnedDocuments containsObject:item.identifier];
  };
  self.tabBar.colorProvider = ^NSInteger(NSTabViewItem *item) {
    return [weakSelf.tabColors[item.identifier] integerValue];
  };
  self.tabBar.toolTipProvider = ^NSString *(NSTabViewItem *item) {
    NativeDocument *document = [weakSelf documentWithIdentifier:item.identifier];
    return document.fileURL.path ?: document.name;
  };
  self.tabBar.menuProvider = ^NSMenu *(NSTabViewItem *item) {
    (void)item;
    return [weakSelf tabContextMenu];
  };
  self.tabBar.closeHandler = ^(NSTabViewItem *item) {
    NativeDocument *document = [weakSelf documentWithIdentifier:item.identifier];
    if (document) [weakSelf closeDocument:document];
  };
  self.tabBar.newTabHandler = ^{ [weakSelf newDocument:nil]; };
  self.tabBar.reorderHandler = ^(NSInteger from, NSInteger to) {
    NativeEditorController *strongSelf = weakSelf;
    if (!strongSelf || from >= (NSInteger)strongSelf.documents.count || to >= (NSInteger)strongSelf.documents.count) return;
    NativeDocument *moved = strongSelf.documents[from];
    [strongSelf.documents removeObjectAtIndex:from];
    [strongSelf.documents insertObject:moved atIndex:to];
    [strongSelf scheduleSessionPersistence];
  };
  NSView *editorColumn = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 500)];
  [editorColumn addSubview:self.tabBar];
  [editorColumn addSubview:self.tabView];
  [NSLayoutConstraint activateConstraints:@[
    [self.tabBar.topAnchor constraintEqualToAnchor:editorColumn.topAnchor],
    [self.tabBar.leadingAnchor constraintEqualToAnchor:editorColumn.leadingAnchor],
    [self.tabBar.trailingAnchor constraintEqualToAnchor:editorColumn.trailingAnchor],
    (self.tabBarHeightConstraint = [self.tabBar.heightAnchor constraintEqualToConstant:28]),
    [self.tabView.topAnchor constraintEqualToAnchor:self.tabBar.bottomAnchor],
    [self.tabView.leadingAnchor constraintEqualToAnchor:editorColumn.leadingAnchor],
    [self.tabView.trailingAnchor constraintEqualToAnchor:editorColumn.trailingAnchor],
    [self.tabView.bottomAnchor constraintEqualToAnchor:editorColumn.bottomAnchor],
  ]];

  self.projectOutline = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
  self.projectOutline.dataSource = self;
  self.projectOutline.delegate = self;
  self.projectOutline.headerView = nil;
  self.projectOutline.target = self;
  self.projectOutline.doubleAction = @selector(openProjectItem:);
  NSTableColumn *projectColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
  projectColumn.resizingMask = NSTableColumnAutoresizingMask;
  [self.projectOutline addTableColumn:projectColumn];
  self.projectOutline.outlineTableColumn = projectColumn;
  self.projectOutline.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
  self.projectPane = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 240, 500)];
  self.projectPane.hasVerticalScroller = YES;
  self.projectPane.documentView = self.projectOutline;
  self.projectPane.hidden = YES;
  NSLayoutConstraint *projectWidth = [self.projectPane.widthAnchor constraintEqualToConstant:240];
  projectWidth.priority = 480;
  projectWidth.active = YES;

  self.resultsTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
  self.resultsTable.dataSource = self;
  self.resultsTable.delegate = self;
  self.resultsTable.target = self;
  self.resultsTable.doubleAction = @selector(openSelectedSearchResult:);
  self.resultsTable.usesAlternatingRowBackgroundColors = YES;
  for (NSArray *column in @[@[@"file", @"File", @220], @[@"line", @"Line", @56], @[@"text", @"Match", @700]]) {
    NSTableColumn *tableColumn = [[NSTableColumn alloc] initWithIdentifier:column[0]];
    tableColumn.title = column[1];
    tableColumn.width = [column[2] doubleValue];
    [self.resultsTable addTableColumn:tableColumn];
  }
  self.resultsPane = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 800, 180)];
  self.resultsPane.hasVerticalScroller = YES;
  self.resultsPane.documentView = self.resultsTable;
  self.resultsPane.hidden = YES;

  self.workspaceSplit = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 1100, 500)];
  self.workspaceSplit.vertical = YES;
  self.workspaceSplit.dividerStyle = NSSplitViewDividerStyleThin;
  [self.workspaceSplit addArrangedSubview:self.projectPane];
  [self.workspaceSplit addArrangedSubview:editorColumn];
  [self.workspaceSplit addArrangedSubview:[self buildSidePanel]];
  [self.workspaceSplit setHoldingPriority:NSLayoutPriorityDefaultLow + 10 forSubviewAtIndex:0];
  [self.workspaceSplit setHoldingPriority:NSLayoutPriorityDefaultLow + 10 forSubviewAtIndex:2];

  self.editorSplit = [[NSSplitView alloc] initWithFrame:NSZeroRect];
  self.editorSplit.vertical = NO;
  self.editorSplit.dividerStyle = NSSplitViewDividerStyleThin;
  self.editorSplit.translatesAutoresizingMaskIntoConstraints = NO;
  [self.editorSplit addArrangedSubview:self.workspaceSplit];
  [self.editorSplit addArrangedSubview:self.resultsPane];
  [self.editorSplit setHoldingPriority:NSLayoutPriorityDefaultLow + 10 forSubviewAtIndex:1];
  [content addSubview:self.editorSplit];

  self.statusBar = [[NativeStatusBar alloc] initWithFrame:NSMakeRect(0, 0, 1100, 22)];
  self.statusBar.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:self.statusBar];
  NSView *incrementalBar = [self buildIncrementalSearchBar];
  incrementalBar.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:incrementalBar];
  NSLayoutConstraint *incrementalHeight = [incrementalBar.heightAnchor constraintEqualToConstant:0];
  self.toolObjects[@"incHeight"] = incrementalHeight;
  self.editorTopConstraint = [self.editorSplit.topAnchor constraintEqualToAnchor:toolbarLine.bottomAnchor];
  self.editorTopCompactConstraint = [self.editorSplit.topAnchor constraintEqualToAnchor:content.topAnchor];
  self.statusBarHeightConstraint = [self.statusBar.heightAnchor constraintEqualToConstant:22];

  [NSLayoutConstraint activateConstraints:@[
    [toolbar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [toolbar.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor],
    [toolbar.topAnchor constraintEqualToAnchor:content.topAnchor],
    [toolbarLine.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [toolbarLine.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [toolbarLine.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor],
    [self.editorSplit.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [self.editorSplit.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    self.editorTopConstraint,
    [self.editorSplit.bottomAnchor constraintEqualToAnchor:incrementalBar.topAnchor],
    [incrementalBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [incrementalBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [incrementalBar.bottomAnchor constraintEqualToAnchor:self.statusBar.topAnchor],
    incrementalHeight,
    [self.statusBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [self.statusBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [self.statusBar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    self.statusBarHeightConstraint
  ]];
  [self applyWindowAppearance];
}

- (void)applyWindowAppearance {
  self.window.appearance = [NSAppearance appearanceNamed:self.darkTheme ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
  self.tabBar.dark = self.darkTheme;
  self.statusBar.dark = self.darkTheme;
  [self.tabBar reload];
  [self updateStatus];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
  (void)sender;
  if (![self.viewOptions[@"rememberSession"] boolValue]) {
    for (NativeDocument *document in [self.documents copy]) {
      if (![self confirmCloseDocument:document]) return NO;
    }
    self.skipTerminationConfirmation = YES;
    return YES;
  }
  [self persistSession];
  return YES;
}

#pragma mark - Documents

- (NativeDocument *)activeDocument {
  NSString *identifier = self.tabView.selectedTabViewItem.identifier;
  return [self documentWithIdentifier:identifier] ?: self.documents.firstObject;
}

- (NativeDocument *)documentWithIdentifier:(NSString *)identifier {
  for (NativeDocument *document in self.documents) {
    if ([document.identifier isEqual:identifier]) return document;
  }
  return nil;
}

- (ScintillaView *)activeEditor {
  NativeDocument *document = self.activeDocument;
  NSResponder *responder = self.window.firstResponder;
  if (document.secondaryEditor && [responder isKindOfClass:NSView.class] &&
      [(NSView *)responder isDescendantOf:document.secondaryEditor]) {
    return document.secondaryEditor;
  }
  return document.editor;
}

- (NativeTheme *)currentTheme {
  NSDictionary *custom = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kCustomThemeKey];
  NSColor *(^color)(NSArray *) = ^NSColor *(NSArray *components) {
    if (components.count != 3) return nil;
    return [NSColor colorWithSRGBRed:[components[0] doubleValue] green:[components[1] doubleValue]
                                blue:[components[2] doubleValue] alpha:1];
  };
  NativeTheme *theme = [NativeTheme themeDark:self.darkTheme customBackground:color(custom[@"background"]) foreground:color(custom[@"foreground"])];
  NSDictionary *overrides = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"NativeEditor.StyleOverrides.v1"];
  [theme applyOverrides:overrides[self.darkTheme ? @"dark" : @"light"]];
  return theme;
}

- (NSString *)nextUntitledName {
  NSMutableSet<NSString *> *used = [NSMutableSet set];
  for (NativeDocument *document in self.documents) if (!document.fileURL) [used addObject:document.name];
  NSInteger number = 1;
  while ([used containsObject:[NSString stringWithFormat:@"new %ld", (long)number]]) number += 1;
  return [NSString stringWithFormat:@"new %ld", (long)number];
}

- (NativeDocument *)createDocument {
  NativeDocument *document = [[NativeDocument alloc] initWithLexerFactory:self.lexerFactory];
  document.name = [self nextUntitledName];
  __weak NativeEditorController *weakSelf = self;
  document.changeHandler = ^(NativeDocument *changedDocument) { [weakSelf updateDocument:changedDocument]; };
  document.sessionHandler = ^(NativeDocument *changedDocument) {
    (void)changedDocument;
    [weakSelf scheduleSessionPersistence];
  };
  document.fileDropHandler = ^(NSURL *url) { [weakSelf openURL:url]; };
  if (!self.editorMenu) self.editorMenu = [self editorContextMenu];
  document.editor.menu = self.editorMenu;
  document.viewOptions = self.viewOptions;
  document.theme = [self currentTheme];
  NSString *defaultEOL = self.viewOptions[@"defaultEOL"];
  if ([defaultEOL isEqualToString:@"CRLF"] || [defaultEOL isEqualToString:@"CR"]) {
    document.lineEnding = defaultEOL;
    [document.editor setGeneralProperty:SCI_SETEOLMODE value:[defaultEOL isEqualToString:@"CRLF"] ? SC_EOL_CRLF : SC_EOL_CR];
  }
  document.writesBOM = [self.viewOptions[@"defaultBOM"] boolValue];
  [self.documents addObject:document];
  NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:document.identifier];
  item.label = document.name;
  item.view = document.editor;
  self.tabItems[document.identifier] = item;
  [self.tabView addTabViewItem:item];
  [self.tabView selectTabViewItem:item];
  [self updateDocument:document];
  return document;
}

- (void)selectDocument:(NativeDocument *)document {
  NSTabViewItem *item = self.tabItems[document.identifier];
  if (item) [self.tabView selectTabViewItem:item];
  [self.window makeFirstResponder:document.editor.content];
}

- (void)newDocument:(id)sender {
  (void)sender;
  NativeDocument *document = [self createDocument];
  [self.window makeFirstResponder:document.editor.content];
  [self scheduleSessionPersistence];
}

- (void)openFiles:(id)sender {
  (void)sender;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = YES;
  NSURL *directory = self.activeDocument.fileURL.URLByDeletingLastPathComponent;
  if (directory) panel.directoryURL = directory;
  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    if (response != NSModalResponseOK) return;
    for (NSURL *url in panel.URLs) [self openURL:url];
  }];
}

- (void)openURL:(NSURL *)url {
  if (!self.window) {
    if (!self.pendingOpenURLs) self.pendingOpenURLs = [NSMutableArray array];
    [self.pendingOpenURLs addObject:url];
    return;
  }
  url = url.URLByStandardizingPath;
  NSNumber *isDirectory = nil;
  [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
  if (isDirectory.boolValue) {
    [self openProjectAtURL:url];
    return;
  }
  for (NativeDocument *document in self.documents) {
    if (SameFile(document.fileURL, url)) {
      [self selectDocument:document];
      return;
    }
  }
  NSNumber *fileSize = nil;
  [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
  if (fileSize.unsignedLongLongValue > 1024ULL * 1024 * 1024) {
    [self showErrorMessage:[NSString stringWithFormat:@"%@ is larger than 1 GB and can't be opened.", url.lastPathComponent]];
    return;
  }

  // Opening a file replaces an untouched "new 1" tab, as in Notepad++.
  NativeDocument *pristine = self.documents.count == 1 && self.activeDocument.isPristine ? self.activeDocument : nil;
  NativeDocument *document = [self createDocument];
  NSError *error = nil;
  if (![document openURL:url error:&error]) {
    [self removeDocument:document];
    [self showError:error];
    return;
  }
  if (pristine) [self removeDocument:pristine];
  [self noteRecentURL:url];
  [self updateDocument:document];
  [self.window makeFirstResponder:document.editor.content];
  [self scheduleSessionPersistence];
}

- (void)removeDocument:(NativeDocument *)document {
  for (NativeDocument *other in self.documents) {
    if (other != document && other.splitDocument == document) {
      [other disableSplit];
      self.tabItems[other.identifier].view = other.editor;
    }
  }
  [document disableSplit];
  NSTabViewItem *item = self.tabItems[document.identifier];
  if (item) [self.tabView removeTabViewItem:item];
  [self.tabItems removeObjectForKey:document.identifier];
  [self.documents removeObject:document];
  [self.monitoredDocuments removeObject:document.identifier];
  [self.tabBar reload];
}

- (BOOL)closeDocument:(NativeDocument *)document {
  if (![self confirmCloseDocument:document]) return NO;
  [self removeDocument:document];
  if (self.documents.count == 0) [self createDocument];
  [self scheduleSessionPersistence];
  [self updateStatus];
  return YES;
}

- (BOOL)confirmCloseDocument:(NativeDocument *)document {
  if (!document.isDirty) return YES;
  [self selectDocument:document];
  NSAlert *alert = [[NSAlert alloc] init];
  alert.alertStyle = NSAlertStyleWarning;
  alert.messageText = [NSString stringWithFormat:@"Save file \"%@\"?", document.fileURL.path ?: document.name];
  alert.informativeText = @"Your changes will be lost if you close without saving.";
  [alert addButtonWithTitle:@"Save"];
  [alert addButtonWithTitle:@"Don't Save"];
  [alert addButtonWithTitle:@"Cancel"];
  NSModalResponse result = [alert runModal];
  if (result == NSAlertFirstButtonReturn) return [self saveDocumentSynchronously:document];
  return result == NSAlertSecondButtonReturn;
}

- (BOOL)saveDocumentSynchronously:(NativeDocument *)document {
  NSURL *url = document.fileURL;
  if (!url) {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = document.name;
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return NO;
    url = panel.URL;
  }
  NSError *error = nil;
  if (![document saveToURL:url error:&error]) {
    [self showError:error];
    return NO;
  }
  [self noteRecentURL:url];
  return YES;
}

- (void)saveDocument:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  if (!document) return;
  if (!document.fileURL) {
    [self saveDocumentAs:nil];
    return;
  }
  NSError *error = nil;
  if (![document saveToURL:document.fileURL error:&error]) [self showError:error];
  [self scheduleSessionPersistence];
}

- (void)saveDocumentAs:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  if (!document) return;
  NSSavePanel *panel = [NSSavePanel savePanel];
  panel.nameFieldStringValue = document.fileURL ? document.fileURL.lastPathComponent : document.name;
  if (document.fileURL) panel.directoryURL = document.fileURL.URLByDeletingLastPathComponent;
  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    if (response != NSModalResponseOK || !panel.URL) return;
    NSError *error = nil;
    if (![document saveToURL:panel.URL error:&error]) {
      [self showError:error];
      return;
    }
    [self noteRecentURL:panel.URL];
    [self scheduleSessionPersistence];
  }];
}

- (void)saveCopyAs:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  if (!document) return;
  NSSavePanel *panel = [NSSavePanel savePanel];
  panel.nameFieldStringValue = document.fileURL ? document.fileURL.lastPathComponent : document.name;
  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    if (response != NSModalResponseOK || !panel.URL) return;
    NSData *data = [document.editor.string dataUsingEncoding:document.encoding allowLossyConversion:NO];
    NSError *error = nil;
    if (!data || ![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) {
      [self showError:error ?: [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInapplicableStringEncodingError userInfo:nil]];
    }
  }];
}

- (void)saveAll:(id)sender {
  (void)sender;
  for (NativeDocument *document in [self.documents copy]) {
    if (!document.isDirty) continue;
    if (!document.fileURL) [self selectDocument:document];
    if (![self saveDocumentSynchronously:document]) break;
  }
  [self scheduleSessionPersistence];
}

- (void)renameDocument:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  if (!document) return;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Rename";
  alert.informativeText = document.fileURL ? @"The file on disk will be renamed." : @"New name for this tab.";
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
  field.stringValue = document.fileURL ? document.fileURL.lastPathComponent : document.name;
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Rename"];
  [alert addButtonWithTitle:@"Cancel"];
  alert.window.initialFirstResponder = field;
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  NSString *name = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if (!name.length || [name containsString:@"/"]) return;
  if (!document.fileURL) {
    document.name = name;
  } else {
    NSURL *destination = [document.fileURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:name];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] moveItemAtURL:document.fileURL toURL:destination error:&error]) {
      [self showError:error];
      return;
    }
    document.fileURL = destination;
    document.name = name;
    [self noteRecentURL:destination];
  }
  [self updateDocument:document];
  [self scheduleSessionPersistence];
}

- (void)reloadDocument:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  if (!document.fileURL) return;
  if (document.isDirty) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Reload \"%@\"?", document.name];
    alert.informativeText = @"Your unsaved changes will be lost.";
    [alert addButtonWithTitle:@"Reload"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
  }
  NSError *error = nil;
  if (![document reloadFromDisk:&error]) [self showError:error];
}

- (void)reopenWithEncoding:(NSMenuItem *)sender {
  NativeDocument *document = self.activeDocument;
  if (!document.fileURL) return;
  if (document.isDirty) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Reopen with a different encoding?";
    alert.informativeText = @"Your unsaved changes will be lost.";
    [alert addButtonWithTitle:@"Reopen"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
  }
  NSDictionary *choice = sender.representedObject;
  NSStringEncoding encoding = [choice[@"encoding"] unsignedIntegerValue];
  NSData *data = [NSData dataWithContentsOfURL:document.fileURL];
  NSUInteger skip = 0;
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  if (encoding == NSUTF8StringEncoding && data.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) skip = 3;
  if ((encoding == NSUTF16LittleEndianStringEncoding || encoding == NSUTF16BigEndianStringEncoding) && data.length >= 2 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) skip = 2;
  NSString *text = data ? [[NSString alloc] initWithBytes:bytes + skip length:data.length - skip encoding:encoding] : nil;
  if (!text) {
    [self showErrorMessage:[NSString stringWithFormat:@"This file isn't valid %@.", sender.title]];
    return;
  }
  [document setText:text];
  document.encoding = encoding;
  document.writesBOM = [choice[@"bom"] boolValue];
  [document.editor message:SCI_SETSAVEPOINT];
  [self updateDocument:document];
}

- (void)closeCurrentTab:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  if (document) [self closeDocument:document];
}

- (void)closeAllTabs:(id)sender {
  (void)sender;
  for (NativeDocument *document in [self.documents copy]) {
    if (![self closeDocument:document]) return;
  }
}

- (void)closeOtherTabs:(id)sender {
  (void)sender;
  NativeDocument *current = self.activeDocument;
  for (NativeDocument *document in [self.documents copy]) {
    if (document != current && ![self closeDocument:document]) return;
  }
  [self selectDocument:current];
}

- (void)closeUnchangedTabs:(id)sender {
  (void)sender;
  for (NativeDocument *document in [self.documents copy]) {
    if (!document.isDirty) [self closeDocument:document];
  }
}

- (void)revealInFinder:(id)sender {
  (void)sender;
  NSURL *url = self.activeDocument.fileURL;
  if (url) [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
}

- (void)copyToPasteboard:(NSString *)string {
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:string forType:NSPasteboardTypeString];
}

- (void)copyFullPath:(id)sender {
  (void)sender;
  NSString *path = self.activeDocument.fileURL.path;
  if (path) [self copyToPasteboard:path];
}

- (void)copyFileName:(id)sender {
  (void)sender;
  [self copyToPasteboard:self.activeDocument.fileURL.lastPathComponent ?: self.activeDocument.name];
}

#pragma mark - Recent files

- (NSArray<NSString *> *)recentPaths {
  return [[NSUserDefaults standardUserDefaults] arrayForKey:kRecentFilesKey] ?: @[];
}

- (void)noteRecentURL:(NSURL *)url {
  if (!url.path) return;
  NSMutableArray *paths = [[self recentPaths] mutableCopy];
  [paths removeObject:url.path];
  [paths insertObject:url.path atIndex:0];
  if (paths.count > kMaxRecentFiles) [paths removeObjectsInRange:NSMakeRange(kMaxRecentFiles, paths.count - kMaxRecentFiles)];
  [[NSUserDefaults standardUserDefaults] setObject:paths forKey:kRecentFilesKey];
  [self rebuildRecentMenu];
}

- (void)rebuildRecentMenu {
  [self.recentMenu removeAllItems];
  NSArray<NSString *> *paths = [self recentPaths];
  for (NSString *path in paths) {
    NSMenuItem *item = [self addMenuItem:path.lastPathComponent action:@selector(openRecent:) key:@"" toMenu:self.recentMenu];
    item.representedObject = path;
    item.toolTip = path;
  }
  if (paths.count) [self.recentMenu addItem:NSMenuItem.separatorItem];
  [self addMenuItem:@"Open All Recent Files" action:@selector(openAllRecent:) key:@"" toMenu:self.recentMenu];
  [self addMenuItem:@"Clear Recent Files List" action:@selector(clearRecent:) key:@"" toMenu:self.recentMenu];
}

- (void)openRecent:(NSMenuItem *)sender {
  NSString *path = sender.representedObject;
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    NSMutableArray *paths = [[self recentPaths] mutableCopy];
    [paths removeObject:path];
    [[NSUserDefaults standardUserDefaults] setObject:paths forKey:kRecentFilesKey];
    [self rebuildRecentMenu];
    [self showErrorMessage:[NSString stringWithFormat:@"\"%@\" no longer exists.", path]];
    return;
  }
  [self openURL:[NSURL fileURLWithPath:path]];
}

- (void)openAllRecent:(id)sender {
  (void)sender;
  for (NSString *path in [[self recentPaths] reverseObjectEnumerator]) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) [self openURL:[NSURL fileURLWithPath:path]];
  }
}

- (void)clearRecent:(id)sender {
  (void)sender;
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:kRecentFilesKey];
  [self rebuildRecentMenu];
}

#pragma mark - Tabs

- (void)selectNextTab:(id)sender {
  (void)sender;
  NSInteger count = self.tabView.numberOfTabViewItems;
  if (count < 2) return;
  NSInteger index = [self.tabView indexOfTabViewItem:self.tabView.selectedTabViewItem];
  [self.tabView selectTabViewItemAtIndex:(index + 1) % count];
}

- (void)selectPreviousTab:(id)sender {
  (void)sender;
  NSInteger count = self.tabView.numberOfTabViewItems;
  if (count < 2) return;
  NSInteger index = [self.tabView indexOfTabViewItem:self.tabView.selectedTabViewItem];
  [self.tabView selectTabViewItemAtIndex:(index + count - 1) % count];
}

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)tabViewItem {
  (void)tabView;
  NativeDocument *document = [self documentWithIdentifier:tabViewItem.identifier];
  if (!document) return;
  [self updateDocument:document];
  [self refreshPanelsForce:YES];
  [self noteActiveDocumentForRecentWindow];
  [self scheduleSessionPersistence];
}

- (void)updateDocument:(NativeDocument *)document {
  NSTabViewItem *item = self.tabItems[document.identifier];
  if (item && ![item.label isEqualToString:document.name]) item.label = document.name;
  [self.tabBar reload];
  if (document == self.activeDocument) {
    NSString *location = document.fileURL ? document.fileURL.path : document.name;
    self.window.title = [NSString stringWithFormat:@"%@%@ - %@", document.isDirty ? @"*" : @"", location, AppName()];
    self.window.representedURL = document.fileURL;
    self.window.documentEdited = document.isDirty;
    [self updateStatus];
    [self syncToolbarToggles];
    [self refreshPanelsForce:NO];
    [self refreshDocumentList];
    [self syncScrollingForDocument:document];
  }
}

// Messages go to the Find dialog when it is open, and briefly replace the
// file-type panel of the status bar.
- (void)setStatus:(NSString *)message {
  [self setFindPanelMessage:message];
  [self.statusMessageTimer invalidate];
  self.statusMessageTimer = [NSTimer scheduledTimerWithTimeInterval:4 repeats:NO block:^(NSTimer *timer) {
    (void)timer;
    self.statusMessageTimer = nil;
    [self updateStatus];
  }];
  [self updateStatus];
  [self.statusBar setFields:[@[message] arrayByAddingObjectsFromArray:[self statusFieldsForActiveDocument]]];
}

- (NSString *)statusNameForDocument:(NativeDocument *)document {
  if (document.userLanguageName) return [document.userLanguageName stringByAppendingString:@" file"];
  NSDictionary *names = @{
    @"text": @"Normal text file", @"bash": @"Unix script file", @"batch": @"Batch file", @"c": @"C source file",
    @"cpp": @"C++ source file", @"cs": @"C# source file", @"css": @"CSS (Cascading Style Sheets) file",
    @"dart": @"Dart file", @"diff": @"Diff file", @"go": @"Go source file", @"html": @"Hyper Text Markup Language file",
    @"ini": @"MS ini file", @"java": @"Java source file", @"javascript": @"JavaScript file", @"json": @"JSON file",
    @"kotlin": @"Kotlin file", @"lua": @"Lua source file", @"makefile": @"Makefile", @"markdown": @"Markdown file",
    @"objc": @"Objective-C source file", @"perl": @"Perl source file", @"php": @"PHP Hypertext Preprocessor file",
    @"powershell": @"PowerShell file", @"python": @"Python file", @"ruby": @"Ruby file", @"rust": @"Rust file",
    @"sql": @"Structured Query Language file", @"swift": @"Swift file", @"toml": @"TOML file",
    @"typescript": @"TypeScript file", @"xml": @"eXtensible Markup Language file", @"yaml": @"YAML Ain't Markup Language file"
  };
  return names[document.language] ?: [document.languageDefinition.name stringByAppendingString:@" file"];
}

- (NSArray<NSString *> *)statusFieldsForActiveDocument {
  NativeDocument *document = self.activeDocument;
  ScintillaView *editor = self.activeEditor;
  if (!document || !editor) return @[];
  NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
  formatter.numberStyle = NSNumberFormatterDecimalStyle;
  NSString *(^number)(long) = ^NSString *(long value) { return [formatter stringFromNumber:@(value)]; };
  long position = [editor getGeneralProperty:SCI_GETCURRENTPOS];
  long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:position];
  long column = [editor getGeneralProperty:SCI_GETCOLUMN parameter:position];
  long selectionStart = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long selectionEnd = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  NSString *place;
  if (selectionEnd > selectionStart) {
    long selected = selectionEnd - selectionStart < 1024 * 1024
        ? [editor getGeneralProperty:SCI_COUNTCHARACTERS parameter:selectionStart extra:selectionEnd] : selectionEnd - selectionStart;
    long selectedLines = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:selectionEnd] -
                         [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:selectionStart] + 1;
    place = [NSString stringWithFormat:@"Ln : %@    Col : %ld    Sel : %@ | %ld", number(line + 1), column + 1, number(selected), selectedLines];
  } else {
    place = [NSString stringWithFormat:@"Ln : %@    Col : %ld    Pos : %@", number(line + 1), column + 1, number(position + 1)];
  }
  return @[
    [NSString stringWithFormat:@"length : %@    lines : %@", number([editor getGeneralProperty:SCI_GETLENGTH]),
                                number([editor getGeneralProperty:SCI_GETLINECOUNT])],
    place,
    document.lineEndingDisplayName,
    document.encodingDisplayName,
    document.isReadOnly ? @"R/O" : ([editor getGeneralProperty:SCI_GETOVERTYPE] ? @"OVR" : @"INS"),
  ];
}

- (void)updateStatus {
  NativeDocument *document = self.activeDocument;
  if (!document || self.statusMessageTimer) return;
  [self.statusBar setFields:[@[[self statusNameForDocument:document]] arrayByAddingObjectsFromArray:[self statusFieldsForActiveDocument]]];
}

#pragma mark - Monitoring (tail -f)

- (void)toggleMonitoring:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  if (!document.fileURL) {
    [self setStatus:@"Monitoring needs a saved file"];
    return;
  }
  if ([self.monitoredDocuments containsObject:document.identifier]) {
    [self.monitoredDocuments removeObject:document.identifier];
    document.readOnly = NO;
  } else {
    if (document.isDirty && ![self saveDocumentSynchronously:document]) return;
    [self.monitoredDocuments addObject:document.identifier];
    document.readOnly = YES;
    [document.editor message:SCI_DOCUMENTEND];
  }
  if (self.monitoredDocuments.count && !self.monitorTimer) {
    __weak NativeEditorController *weakSelf = self;
    self.monitorTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
      (void)timer;
      [weakSelf pollMonitoredDocuments];
    }];
  } else if (!self.monitoredDocuments.count) {
    [self.monitorTimer invalidate];
    self.monitorTimer = nil;
  }
  [self updateDocument:document];
}

// Like Notepad++'s Monitoring: reload changed files silently and follow the end.
- (void)pollMonitoredDocuments {
  for (NSString *identifier in [self.monitoredDocuments copy]) {
    NativeDocument *document = [self documentWithIdentifier:identifier];
    if (!document) {
      [self.monitoredDocuments removeObject:identifier];
      continue;
    }
    if (![document fileChangedOnDisk] || ![[NSFileManager defaultManager] fileExistsAtPath:document.fileURL.path]) continue;
    [document reloadFromDisk:nil];
    document.readOnly = YES;
    [document.editor message:SCI_DOCUMENTEND];
  }
}

#pragma mark - Workspace and results panes

- (void)openProjectFolder:(id)sender {
  (void)sender;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = NO;
  panel.canChooseDirectories = YES;
  panel.allowsMultipleSelection = NO;
  panel.prompt = @"Open Folder";
  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    if (response == NSModalResponseOK && panel.URL) [self openProjectAtURL:panel.URL];
  }];
}

- (void)openProjectAtURL:(NSURL *)url {
  self.projectURL = url;
  [[NSUserDefaults standardUserDefaults] setURL:url forKey:@"NativeEditor.ProjectURL.v1"];
  self.projectRootNode = [[NativeFileNode alloc] initWithURL:url];
  [self.projectRootNode loadChildren];
  [self.projectOutline reloadData];
  [self setProjectPaneVisible:YES];
  [self setStatus:[NSString stringWithFormat:@"Workspace: %@", url.path]];
}

- (void)setProjectPaneVisible:(BOOL)visible {
  if (self.projectPane.hidden != visible) return;
  self.projectPane.hidden = !visible;
  [self.workspaceSplit adjustSubviews];
  if (visible) [self.workspaceSplit setPosition:240 ofDividerAtIndex:0];
}

- (void)toggleProjectPane:(id)sender {
  (void)sender;
  if (!self.projectURL) {
    [self openProjectFolder:nil];
    return;
  }
  if (!self.projectRootNode) [self openProjectAtURL:self.projectURL];
  else [self setProjectPaneVisible:self.projectPane.hidden];
}

- (void)showSearchResultsPane:(BOOL)visible {
  if (self.resultsPane.hidden != visible) return;
  self.resultsPane.hidden = !visible;
  [self.editorSplit adjustSubviews];
  if (visible) [self.editorSplit setPosition:self.editorSplit.bounds.size.height - 200 ofDividerAtIndex:0];
}

- (void)toggleResultsPane:(id)sender {
  (void)sender;
  [self showSearchResultsPane:self.resultsPane.hidden];
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
  (void)outlineView;
  NativeFileNode *node = item ?: self.projectRootNode;
  [node loadChildren];
  return (NSInteger)node.children.count;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
  (void)outlineView;
  NativeFileNode *node = item ?: self.projectRootNode;
  [node loadChildren];
  return node.children[index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
  (void)outlineView;
  return [(NativeFileNode *)item directory];
}

- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(id)item {
  (void)tableColumn;
  NativeFileNode *node = item;
  NSTableCellView *cell = [outlineView makeViewWithIdentifier:@"file" owner:self];
  if (!cell) {
    cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 20)];
    cell.identifier = @"file";
    NSImageView *imageView = [[NSImageView alloc] initWithFrame:NSMakeRect(2, 2, 16, 16)];
    NSTextField *text = [NSTextField labelWithString:@""];
    text.frame = NSMakeRect(22, 2, 180, 16);
    text.autoresizingMask = NSViewWidthSizable;
    text.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [cell addSubview:imageView];
    [cell addSubview:text];
    cell.imageView = imageView;
    cell.textField = text;
  }
  cell.textField.stringValue = node.name;
  cell.imageView.image = [[NSWorkspace sharedWorkspace] iconForFile:node.url.path];
  cell.toolTip = node.url.path;
  return cell;
}

- (void)openProjectItem:(id)sender {
  (void)sender;
  NativeFileNode *node = [self.projectOutline itemAtRow:self.projectOutline.clickedRow];
  if (!node) return;
  if (node.directory) {
    if ([self.projectOutline isItemExpanded:node]) [self.projectOutline collapseItem:node];
    else [self.projectOutline expandItem:node];
    return;
  }
  [self openURL:node.url];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
  (void)tableView;
  return (NSInteger)self.searchResults.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
  (void)tableView;
  NSDictionary *result = self.searchResults[row];
  if ([column.identifier isEqualToString:@"file"]) return result[@"name"];
  if ([column.identifier isEqualToString:@"line"]) return result[@"line"];
  return result[@"text"];
}

- (void)openSelectedSearchResult:(id)sender {
  (void)sender;
  NSInteger row = self.resultsTable.clickedRow >= 0 ? self.resultsTable.clickedRow : self.resultsTable.selectedRow;
  if (row < 0 || row >= (NSInteger)self.searchResults.count) return;
  NSDictionary *result = self.searchResults[row];
  NativeDocument *document = result[@"document"] ? [self documentWithIdentifier:result[@"document"]] : nil;
  if (!document && result[@"url"]) {
    [self openURL:result[@"url"]];
    document = self.activeDocument;
  }
  if (!document) return;
  [self selectDocument:document];
  ScintillaView *editor = document.editor;
  long line = [result[@"line"] integerValue] - 1;
  [editor setGeneralProperty:SCI_ENSUREVISIBLEENFORCEPOLICY value:line];
  [editor setGeneralProperty:SCI_GOTOLINE value:line];
  if (result[@"position"]) {
    long start = [result[@"position"] longValue];
    [editor setGeneralProperty:SCI_SETSEL parameter:start value:start + [result[@"length"] longValue]];
  }
  [self.window makeFirstResponder:editor.content];
}

#pragma mark - View options

- (void)applyViewOptions {
  for (NativeDocument *document in self.documents) document.viewOptions = self.viewOptions;
  self.tabBar.doubleClickCloses = [self.viewOptions[@"tabDoubleClickCloses"] boolValue];
  self.tabBar.locked = [self.viewOptions[@"tabBarLocked"] boolValue];
  [self savePreferences];
  [self syncToolbarToggles];
  [self refreshPanelsForce:YES];
}

- (void)toggleViewOption:(NSMenuItem *)sender {
  NSString *key = sender.representedObject;
  self.viewOptions[key] = @(![self.viewOptions[key] boolValue]);
  [self applyViewOptions];
}

- (void)toggleWordWrap:(id)sender {
  (void)sender;
  self.viewOptions[NativeViewWordWrap] = @(![self.viewOptions[NativeViewWordWrap] boolValue]);
  [self applyViewOptions];
}

- (void)toggleIndentGuides:(id)sender {
  (void)sender;
  self.viewOptions[NativeViewIndentGuides] = @(![self.viewOptions[NativeViewIndentGuides] boolValue]);
  [self applyViewOptions];
}

- (void)toggleAllCharacters:(id)sender {
  (void)sender;
  BOOL show = !([self.viewOptions[NativeViewWhitespace] boolValue] && [self.viewOptions[NativeViewEndOfLine] boolValue]);
  self.viewOptions[NativeViewWhitespace] = @(show);
  self.viewOptions[NativeViewEndOfLine] = @(show);
  [self applyViewOptions];
}

- (void)selectTabWidth:(NSMenuItem *)sender {
  self.viewOptions[NativeViewTabWidth] = sender.representedObject;
  [self applyViewOptions];
}

- (void)toggleUseSpaces:(id)sender {
  (void)sender;
  self.viewOptions[NativeViewUseTabs] = @(![self.viewOptions[NativeViewUseTabs] boolValue]);
  [self applyViewOptions];
}

- (void)selectFontSize:(NSMenuItem *)sender {
  self.viewOptions[NativeViewFontSize] = sender.representedObject;
  [self applyViewOptions];
}

- (void)zoomIn:(id)sender {
  (void)sender;
  [self.activeEditor message:SCI_ZOOMIN];
  [self synchronizeZoom];
}

- (void)zoomOut:(id)sender {
  (void)sender;
  [self.activeEditor message:SCI_ZOOMOUT];
  [self synchronizeZoom];
}

- (void)zoomReset:(id)sender {
  (void)sender;
  [self.activeEditor setGeneralProperty:SCI_SETZOOM value:0];
  [self synchronizeZoom];
}

// View > Zoom > Synchronize Across Views applies the zoom to every document.
- (void)synchronizeZoom {
  if (![self.viewOptions[@"syncZoom"] boolValue]) return;
  long zoom = [self.activeEditor getGeneralProperty:SCI_GETZOOM];
  for (NativeDocument *document in self.documents) {
    [document.editor setGeneralProperty:SCI_SETZOOM value:zoom];
    if (document.secondaryEditor) [document.secondaryEditor setGeneralProperty:SCI_SETZOOM value:zoom];
  }
}

- (void)foldAll:(id)sender {
  (void)sender;
  [self.activeEditor setGeneralProperty:SCI_COLOURISE parameter:0 value:-1];
  [self.activeEditor setGeneralProperty:SCI_FOLDALL value:SC_FOLDACTION_CONTRACT];
}

- (void)unfoldAll:(id)sender {
  (void)sender;
  [self.activeEditor setGeneralProperty:SCI_FOLDALL value:SC_FOLDACTION_EXPAND];
}

- (void)toggleCurrentFold:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:[editor getGeneralProperty:SCI_GETCURRENTPOS]];
  long level = [editor getGeneralProperty:SCI_GETFOLDLEVEL parameter:line];
  if (!(level & SC_FOLDLEVELHEADERFLAG)) line = [editor getGeneralProperty:SCI_GETFOLDPARENT parameter:line];
  if (line >= 0) [editor setGeneralProperty:SCI_TOGGLEFOLD value:line];
}

- (void)toggleAlwaysOnTop:(id)sender {
  (void)sender;
  self.window.level = self.window.level == NSFloatingWindowLevel ? NSNormalWindowLevel : NSFloatingWindowLevel;
}

- (void)toggleFullScreenMode:(id)sender {
  [self.window toggleFullScreen:sender];
}

- (void)toggleSplitView:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  if (!document) return;
  NSTabViewItem *item = self.tabItems[document.identifier];
  BOOL wasSelfSplit = document.splitContainer && document.splitDocument == document;
  [document disableSplit];
  item.view = wasSelfSplit ? document.editor : [document enableSplitWithDocument:document readOnly:NO];
  document.secondaryEditor.menu = self.editorMenu;
}

- (void)compareWithNextTab:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  if (!document || self.documents.count < 2) {
    [self setStatus:@"Open a second tab to compare side by side"];
    return;
  }
  NSUInteger index = [self.documents indexOfObjectIdenticalTo:document];
  NativeDocument *other = self.documents[(index + 1) % self.documents.count];
  NSTabViewItem *item = self.tabItems[document.identifier];
  BOOL wasComparing = document.splitDocument == other;
  [document disableSplit];
  item.view = wasComparing ? document.editor : [document enableSplitWithDocument:other readOnly:YES];
}

- (void)showSummary:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  ScintillaView *editor = self.activeEditor;
  NSString *text = editor.string ?: @"";
  __block NSUInteger words = 0;
  [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
                        usingBlock:^(NSString *substring, NSRange range, NSRange enclosing, BOOL *stop) {
    (void)substring; (void)range; (void)enclosing; (void)stop;
    words += 1;
  }];
  NSUInteger characters = [text lengthOfBytesUsingEncoding:NSUTF32StringEncoding] / 4;
  NSUInteger withoutBlanks = [[[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                               componentsJoinedByString:@""] lengthOfBytesUsingEncoding:NSUTF32StringEncoding] / 4;
  NSMutableString *info = [NSMutableString string];
  if (document.fileURL) {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:document.fileURL.path error:nil];
    [info appendFormat:@"Full path: %@\nModified: %@\n\n", document.fileURL.path,
        [NSDateFormatter localizedStringFromDate:attributes.fileModificationDate ?: [NSDate date]
                                       dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterMediumStyle]];
  }
  [info appendFormat:@"Characters (without line endings): %lu\nCharacters (without blanks): %lu\nWords: %lu\nLines: %ld\nDocument length (bytes in UTF-8): %ld\nSelected: %ld bytes",
      (unsigned long)characters, (unsigned long)withoutBlanks, (unsigned long)words,
      [editor getGeneralProperty:SCI_GETLINECOUNT], [editor getGeneralProperty:SCI_GETLENGTH],
      [editor getGeneralProperty:SCI_GETSELECTIONEND] - [editor getGeneralProperty:SCI_GETSELECTIONSTART]];
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Summary";
  alert.informativeText = info;
  [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark - Theme

- (void)applyThemeToAllDocuments {
  NativeTheme *theme = [self currentTheme];
  for (NativeDocument *document in self.documents) document.theme = theme;
  [self applyWindowAppearance];
  [self refreshPanelsForce:YES];
}

- (void)toggleTheme:(id)sender {
  (void)sender;
  self.darkTheme = !self.darkTheme;
  [self applyThemeToAllDocuments];
  [self savePreferences];
}

#pragma mark - Format

- (void)selectLanguage:(NSMenuItem *)sender {
  NativeDocument *document = self.activeDocument;
  if (!document) return;
  [document setLanguage:sender.representedObject];
  [self scheduleSessionPersistence];
}

- (void)defineCustomLanguage:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Define Your Language";
  alert.informativeText = @"Pick a built-in language to base it on, then list extra keywords separated by spaces.";
  [alert addButtonWithTitle:@"Save Language"];
  [alert addButtonWithTitle:@"Cancel"];
  NSStackView *fields = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 300, 92)];
  fields.orientation = NSUserInterfaceLayoutOrientationVertical;
  fields.spacing = 7;
  NSTextField *nameField = [NSTextField textFieldWithString:@""];
  nameField.placeholderString = @"Language name";
  NSPopUpButton *baseField = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  for (NativeLanguage *language in [NativeLanguage allLanguages]) {
    if (!language.lexer) continue;
    [baseField addItemWithTitle:language.name];
    baseField.lastItem.representedObject = language.identifier;
  }
  NSTextField *keywordsField = [NSTextField textFieldWithString:@""];
  keywordsField.placeholderString = @"Keywords separated by spaces";
  [fields addArrangedSubview:nameField];
  [fields addArrangedSubview:baseField];
  [fields addArrangedSubview:keywordsField];
  alert.accessoryView = fields;
  if ([alert runModal] != NSAlertFirstButtonReturn || nameField.stringValue.length == 0) return;

  NSDictionary *definition = @{
    @"name": nameField.stringValue,
    @"base": baseField.selectedItem.representedObject ?: @"cpp",
    @"keywords": keywordsField.stringValue
  };
  NSMutableArray *definitions = [[[NSUserDefaults standardUserDefaults] arrayForKey:kCustomLanguagesKey] mutableCopy] ?: [NSMutableArray array];
  [definitions removeObjectsAtIndexes:[definitions indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry, NSUInteger idx, BOOL *stop) {
    (void)idx; (void)stop;
    return [entry[@"name"] isEqualToString:definition[@"name"]];
  }]];
  [definitions addObject:definition];
  [[NSUserDefaults standardUserDefaults] setObject:definitions forKey:kCustomLanguagesKey];
  [self addCustomLanguageMenuItem:definition];
  [self selectCustomLanguage:definition];
}

- (void)addCustomLanguageMenuItem:(NSDictionary *)definition {
  for (NSMenuItem *item in self.languageMenu.itemArray) {
    if (item.action == @selector(selectUserLanguage:) && [item.title isEqualToString:definition[@"name"]]) {
      item.representedObject = definition;
      return;
    }
  }
  NSMenuItem *item = [self addMenuItem:definition[@"name"] action:@selector(selectUserLanguage:) key:@"" toMenu:self.languageMenu];
  item.representedObject = definition;
}

- (void)selectCustomLanguage:(NSDictionary *)definition {
  NativeDocument *document = self.activeDocument;
  if (!document) return;
  [document setUserLanguageName:definition[@"name"] baseLanguage:definition[@"base"] keywords:definition[@"keywords"] ?: @""];
  [self scheduleSessionPersistence];
}

- (void)selectUserLanguage:(NSMenuItem *)sender {
  [self selectCustomLanguage:sender.representedObject];
}

- (void)selectEncoding:(NSMenuItem *)sender {
  NativeDocument *document = self.activeDocument;
  if (!document) return;
  NSDictionary *choice = sender.representedObject;
  NSStringEncoding encoding = [choice[@"encoding"] unsignedIntegerValue];
  if (![document.editor.string canBeConvertedToEncoding:encoding]) {
    [self showErrorMessage:[NSString stringWithFormat:@"This document has characters that can't be represented in %@.", sender.title]];
    return;
  }
  document.encoding = encoding;
  document.writesBOM = [choice[@"bom"] boolValue];
  document.dirty = YES;
  [self updateDocument:document];
  [self scheduleSessionPersistence];
}

- (void)selectLineEnding:(NSMenuItem *)sender {
  NativeDocument *document = self.activeDocument;
  if (!document) return;
  [document convertLineEndingsTo:sender.representedObject];
  [self updateDocument:document];
  [self scheduleSessionPersistence];
}

#pragma mark - Session and preferences

- (void)scheduleSessionPersistence {
  [self.sessionSaveTimer invalidate];
  __weak NativeEditorController *weakSelf = self;
  self.sessionSaveTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:NO block:^(NSTimer *timer) {
    (void)timer;
    [weakSelf persistSession];
  }];
}

- (void)savePreferences {
  [[NSUserDefaults standardUserDefaults] setObject:@{@"dark": @(self.darkTheme), @"view": self.viewOptions}
                                            forKey:kPreferencesDefaultsKey];
}

- (void)restorePreferences {
  NSDictionary *preferences = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kPreferencesDefaultsKey];
  self.darkTheme = preferences ? [preferences[@"dark"] boolValue] : NO;
  NSDictionary *view = preferences[@"view"];
  if ([view isKindOfClass:NSDictionary.class]) [self.viewOptions addEntriesFromDictionary:view];
  // Preferences saved before view options existed.
  if (preferences[@"wrap"]) self.viewOptions[NativeViewWordWrap] = preferences[@"wrap"];
  if (preferences[@"lineNumbers"]) self.viewOptions[NativeViewLineNumbers] = preferences[@"lineNumbers"];
}

- (NSArray<NSNumber *> *)bookmarkLinesForDocument:(NativeDocument *)document {
  NSMutableArray<NSNumber *> *lines = [NSMutableArray array];
  long mask = 1L << kNativeBookmarkMarker;
  long line = [document.editor getGeneralProperty:SCI_MARKERNEXT parameter:0 extra:mask];
  while (line >= 0) {
    [lines addObject:@(line)];
    line = [document.editor getGeneralProperty:SCI_MARKERNEXT parameter:line + 1 extra:mask];
  }
  return lines;
}

- (void)persistSession {
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"NativeEditorNoSession"]) return;
  NSMutableArray *saved = [NSMutableArray arrayWithCapacity:self.documents.count];
  for (NativeDocument *document in self.documents) {
    NSMutableDictionary *entry = [@{
      @"name": document.name ?: @"new 1",
      @"path": document.fileURL.path ?: @"",
      @"dirty": @(document.isDirty),
      @"encoding": @(document.encoding),
      @"bom": @(document.writesBOM),
      @"eol": document.lineEnding ?: @"LF",
      @"language": document.language ?: @"text",
      @"userLanguageName": document.userLanguageName ?: @"",
      @"userKeywords": document.userKeywords ?: @"",
      @"readOnly": @(document.isReadOnly),
      @"bookmarks": [self bookmarkLinesForDocument:document],
      @"firstLine": @([document.editor getGeneralProperty:SCI_GETFIRSTVISIBLELINE]),
      @"caret": @([document.editor getGeneralProperty:SCI_GETCURRENTPOS]),
      @"pinned": @([self.pinnedDocuments containsObject:document.identifier]),
      @"color": self.tabColors[document.identifier] ?: @0
    } mutableCopy];
    if (document.isDirty || !document.fileURL) {
      long length = [document.editor getGeneralProperty:SCI_GETLENGTH];
      if ((NSUInteger)length <= kMaxSessionContentLength) entry[@"content"] = document.editor.string ?: @"";
    }
    [saved addObject:entry];
  }
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setObject:saved forKey:kSessionDefaultsKey];
  [defaults setInteger:[self.tabView indexOfTabViewItem:self.tabView.selectedTabViewItem] forKey:@"NativeEditor.ActiveTab.v1"];
  [defaults setObject:self.currentMacro ?: @[] forKey:@"NativeEditor.CurrentMacro.v1"];
  [defaults setBool:!self.projectPane.hidden forKey:@"NativeEditor.WorkspaceVisible.v1"];
}

- (void)restoreSession {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  self.currentMacro = [defaults arrayForKey:@"NativeEditor.CurrentMacro.v1"] ?: @[];
  self.projectURL = [defaults URLForKey:@"NativeEditor.ProjectURL.v1"];
  if (self.projectURL && [defaults boolForKey:@"NativeEditor.WorkspaceVisible.v1"] &&
      [[NSFileManager defaultManager] fileExistsAtPath:self.projectURL.path]) {
    [self openProjectAtURL:self.projectURL];
  }
  BOOL skipSession = ![self.viewOptions[@"rememberSession"] boolValue] || [defaults boolForKey:@"NativeEditorNoSession"];
  NSArray *savedSession = skipSession ? @[] : [defaults arrayForKey:kSessionDefaultsKey];
  for (NSDictionary *entry in savedSession) {
    NSString *path = entry[@"path"];
    NSURL *url = path.length ? [NSURL fileURLWithPath:path] : nil;
    NSString *content = entry[@"content"];
    BOOL exists = url && [[NSFileManager defaultManager] fileExistsAtPath:url.path];
    if (url && !exists && !content) continue;
    if (!url && !content.length && ![entry[@"dirty"] boolValue]) continue;

    NativeDocument *document = [self createDocument];
    NSError *error = nil;
    if (exists) [document openURL:url error:&error];
    if (!exists || !url) {
      document.name = entry[@"name"] ?: document.name;
      document.fileURL = url;
    }
    if (content && ([entry[@"dirty"] boolValue] || !exists)) {
      [document setText:content];
      document.encoding = [entry[@"encoding"] unsignedIntegerValue] ?: NSUTF8StringEncoding;
      document.writesBOM = [entry[@"bom"] boolValue];
      document.lineEnding = entry[@"eol"] ?: @"LF";
      long eolMode = [document.lineEnding isEqualToString:@"CRLF"] ? SC_EOL_CRLF : [document.lineEnding isEqualToString:@"CR"] ? SC_EOL_CR : SC_EOL_LF;
      [document.editor setGeneralProperty:SCI_SETEOLMODE value:eolMode];
      if ([entry[@"dirty"] boolValue] || (url && !exists)) document.dirty = YES;
    }
    if ([entry[@"userLanguageName"] length]) {
      [document setUserLanguageName:entry[@"userLanguageName"] baseLanguage:entry[@"language"] ?: @"text"
                           keywords:entry[@"userKeywords"] ?: @""];
    } else if (entry[@"language"] && !(exists && [entry[@"language"] isEqualToString:@"text"])) {
      [document setLanguage:entry[@"language"]];
    }
    for (NSNumber *line in entry[@"bookmarks"]) {
      [document.editor setGeneralProperty:SCI_MARKERADD parameter:line.integerValue value:kNativeBookmarkMarker];
    }
    document.readOnly = [entry[@"readOnly"] boolValue];
    if ([entry[@"pinned"] boolValue]) [self.pinnedDocuments addObject:document.identifier];
    if ([entry[@"color"] integerValue]) self.tabColors[document.identifier] = entry[@"color"];
    long caret = [entry[@"caret"] longValue];
    if (caret > 0 && caret <= [document.editor getGeneralProperty:SCI_GETLENGTH]) [document.editor setGeneralProperty:SCI_GOTOPOS value:caret];
    [document.editor setGeneralProperty:SCI_SETFIRSTVISIBLELINE value:[entry[@"firstLine"] longValue]];
    if (error) [self showError:error];
    [self updateDocument:document];
  }
  NSInteger activeIndex = [defaults integerForKey:@"NativeEditor.ActiveTab.v1"];
  if (activeIndex >= 0 && activeIndex < self.tabView.numberOfTabViewItems) [self.tabView selectTabViewItemAtIndex:activeIndex];
}

- (void)showDebugInfo:(id)sender {
  (void)sender;
  NSDictionary *info = NSBundle.mainBundle.infoDictionary;
  NSString *text = [NSString stringWithFormat:@"%@ v%@ (build %@)\nmacOS %@\nArchitecture: %@\nScintilla 5.6.7, Lexilla 5.5.4\nApp path: %@\nOpen documents: %lu",
      AppName(), info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"], NSProcessInfo.processInfo.operatingSystemVersionString,
#if defined(__arm64__)
      @"arm64",
#else
      @"x86_64",
#endif
      NSBundle.mainBundle.bundlePath, (unsigned long)self.documents.count];
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Debug Info";
  alert.informativeText = text;
  [alert addButtonWithTitle:@"Copy to Clipboard"];
  [alert addButtonWithTitle:@"Close"];
  if ([alert runModal] == NSAlertFirstButtonReturn) [self copyToPasteboard:text];
}

#pragma mark - Errors

- (void)showError:(NSError *)error {
  if (!error) return;
  [self showErrorMessage:error.localizedDescription];
}

- (void)showErrorMessage:(NSString *)message {
  NSAlert *alert = [[NSAlert alloc] init];
  alert.alertStyle = NSAlertStyleWarning;
  alert.messageText = @"The operation could not be completed.";
  alert.informativeText = message;
  if (self.window.attachedSheet) [alert runModal];
  else [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

@end
