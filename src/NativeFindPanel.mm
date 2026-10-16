#import "NativeEditorController+Private.h"
#include <string>

typedef NS_ENUM(NSInteger, NativeFindMode) {
  NativeFindModeFind = 0,
  NativeFindModeReplace,
  NativeFindModeFiles,
  NativeFindModeMark
};

@interface NativeFlippedView : NSView
@end

@implementation NativeFlippedView
- (BOOL)isFlipped {
  return YES;
}
@end

@implementation NativeEditorController (FindPanel)

#pragma mark - Building

- (NSTextField *)findLabel:(NSString *)title frame:(NSRect)frame {
  NSTextField *label = [NSTextField labelWithString:title];
  label.alignment = NSTextAlignmentRight;
  label.frame = frame;
  return label;
}

- (NSComboBox *)findCombo:(NSRect)frame {
  NSComboBox *combo = [[NSComboBox alloc] initWithFrame:frame];
  combo.completes = NO;
  combo.numberOfVisibleItems = 12;
  return combo;
}

- (NSButton *)findButton:(NSString *)title action:(SEL)action {
  NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
  button.bezelStyle = NSBezelStyleRounded;
  button.controlSize = NSControlSizeRegular;
  return button;
}

- (void)buildFindPanel {
  NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 720, 330)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
                                                backing:NSBackingStoreBuffered defer:YES];
  panel.title = @"Find";
  panel.floatingPanel = YES;
  panel.hidesOnDeactivate = YES;
  panel.releasedWhenClosed = NO;
  panel.becomesKeyOnlyIfNeeded = NO;
  NativeFlippedView *content = [[NativeFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 720, 330)];
  panel.contentView = content;

  NSSegmentedControl *tabs = [NSSegmentedControl segmentedControlWithLabels:@[@"Find", @"Replace", @"Find in Files", @"Mark"]
                                                                trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                      target:self action:@selector(findPanelModeChanged:)];
  tabs.frame = NSMakeRect(12, 10, 400, 24);
  tabs.selectedSegment = 0;
  [content addSubview:tabs];
  self.findModeControl = tabs;

  NSHashTable *replaceRow = [NSHashTable weakObjectsHashTable];
  NSHashTable *filesRows = [NSHashTable weakObjectsHashTable];

  [content addSubview:[self findLabel:@"Find what :" frame:NSMakeRect(12, 50, 104, 18)]];
  self.searchField = [self findCombo:NSMakeRect(122, 46, 330, 25)];
  self.searchField.target = self;
  self.searchField.action = @selector(findPanelDefaultAction:);
  [self.searchField addItemsWithObjectValues:[[NSUserDefaults standardUserDefaults] arrayForKey:@"NativeEditor.SearchHistory.v1"] ?: @[]];
  [content addSubview:self.searchField];

  NSTextField *replaceLabel = [self findLabel:@"Replace with :" frame:NSMakeRect(12, 84, 104, 18)];
  self.replacementField = [self findCombo:NSMakeRect(122, 80, 330, 25)];
  [self.replacementField addItemsWithObjectValues:[[NSUserDefaults standardUserDefaults] arrayForKey:@"NativeEditor.ReplaceHistory.v1"] ?: @[]];
  for (NSView *view in @[replaceLabel, self.replacementField]) {
    [content addSubview:view];
    [replaceRow addObject:view];
  }

  NSTextField *filtersLabel = [self findLabel:@"Filters :" frame:NSMakeRect(12, 118, 104, 18)];
  self.findFiltersField = [[NSTextField alloc] initWithFrame:NSMakeRect(122, 114, 330, 24)];
  self.findFiltersField.stringValue = [[NSUserDefaults standardUserDefaults] stringForKey:@"NativeEditor.FindInFilesFilters.v1"] ?: @"*.*";
  self.findFiltersField.placeholderString = @"*.cpp *.h !*.min.js";
  NSTextField *directoryLabel = [self findLabel:@"Directory :" frame:NSMakeRect(12, 150, 104, 18)];
  self.findDirectoryField = [[NSTextField alloc] initWithFrame:NSMakeRect(122, 146, 296, 24)];
  NSButton *browse = [NSButton buttonWithTitle:@"…" target:self action:@selector(chooseFindPanelDirectory:)];
  browse.frame = NSMakeRect(422, 145, 32, 26);
  for (NSView *view in @[filtersLabel, self.findFiltersField, directoryLabel, self.findDirectoryField, browse]) {
    [content addSubview:view];
    [filesRows addObject:view];
  }

  // Options (left) and search mode (middle), as in Notepad++.
  NSBox *options = [[NSBox alloc] initWithFrame:NSMakeRect(10, 184, 210, 112)];
  options.title = @"Options";
  options.titleFont = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  self.backwardButton = [NSButton checkboxWithTitle:@"Backward direction" target:nil action:nil];
  self.wholeWordButton = [NSButton checkboxWithTitle:@"Match whole word only" target:nil action:nil];
  self.matchCaseButton = [NSButton checkboxWithTitle:@"Match case" target:nil action:nil];
  self.wrapAroundButton = [NSButton checkboxWithTitle:@"Wrap around" target:nil action:nil];
  self.wrapAroundButton.state = NSControlStateValueOn;
  self.bookmarkLineButton = [NSButton checkboxWithTitle:@"Bookmark line" target:nil action:nil];
  CGFloat y = NSHeight(options.contentView.bounds) - 22;
  for (NSButton *box in @[self.backwardButton, self.wholeWordButton, self.matchCaseButton, self.wrapAroundButton]) {
    box.frame = NSMakeRect(6, y, 196, 18);
    [options.contentView addSubview:box];
    y -= 21;
  }
  [content addSubview:options];
  self.findOptionsBox = options;

  NSBox *mode = [[NSBox alloc] initWithFrame:NSMakeRect(228, 184, 226, 112)];
  mode.title = @"Search Mode";
  mode.titleFont = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  self.normalModeButton = [NSButton radioButtonWithTitle:@"Normal" target:self action:@selector(searchModeChanged:)];
  self.extendedButton = [NSButton radioButtonWithTitle:@"Extended (\\n, \\r, \\t, \\0, \\x…)" target:self action:@selector(searchModeChanged:)];
  self.regexButton = [NSButton radioButtonWithTitle:@"Regular expression" target:self action:@selector(searchModeChanged:)];
  self.normalModeButton.state = NSControlStateValueOn;
  y = NSHeight(mode.contentView.bounds) - 22;
  for (NSButton *radio in @[self.normalModeButton, self.extendedButton, self.regexButton]) {
    radio.frame = NSMakeRect(6, y, 212, 18);
    [mode.contentView addSubview:radio];
    y -= 23;
  }
  [content addSubview:mode];

  self.bookmarkLineButton.frame = NSMakeRect(16, 154, 200, 18);
  [content addSubview:self.bookmarkLineButton];

  NSMutableDictionary *buttons = [NSMutableDictionary dictionary];
  NSArray *definitions = @[
    @[@"findNext", @"Find Next", NSStringFromSelector(@selector(findPanelFindNext:))],
    @[@"count", @"Count", NSStringFromSelector(@selector(countMatches:))],
    @[@"findAllCurrent", @"Find All in Current Document", NSStringFromSelector(@selector(findAllInCurrentDocument:))],
    @[@"findAllOpen", @"Find All in All Opened Documents", NSStringFromSelector(@selector(findAllInOpenDocuments:))],
    @[@"replace", @"Replace", NSStringFromSelector(@selector(replaceCurrent:))],
    @[@"replaceAll", @"Replace All", NSStringFromSelector(@selector(replaceAll:))],
    @[@"replaceAllOpen", @"Replace All in All Opened Documents", NSStringFromSelector(@selector(replaceAllInOpenDocuments:))],
    @[@"findInFiles", @"Find All", NSStringFromSelector(@selector(findPanelFindInFiles:))],
    @[@"replaceInFiles", @"Replace in Files", NSStringFromSelector(@selector(findPanelReplaceInFiles:))],
    @[@"markAll", @"Mark All", NSStringFromSelector(@selector(markAll:))],
    @[@"clearMarks", @"Clear all marks", NSStringFromSelector(@selector(clearMarks:))],
    @[@"copyMarked", @"Copy Marked Text", NSStringFromSelector(@selector(copyMarkedText:))],
    @[@"close", @"Close", NSStringFromSelector(@selector(closeFindPanel:))],
  ];
  for (NSArray *definition in definitions) {
    NSButton *button = [self findButton:definition[1] action:NSSelectorFromString(definition[2])];
    [content addSubview:button];
    buttons[definition[0]] = button;
  }
  ((NSButton *)buttons[@"close"]).keyEquivalent = @"\e";
  self.findPanelButtons = buttons;

  self.findStatusLabel = [NSTextField labelWithString:@""];
  self.findStatusLabel.frame = NSMakeRect(12, 304, 696, 18);
  self.findStatusLabel.textColor = NSColor.secondaryLabelColor;
  self.findStatusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
  [content addSubview:self.findStatusLabel];

  self.findReplaceViews = replaceRow;
  self.findFilesViews = filesRows;
  self.findPanel = panel;
  [self layoutFindPanelForMode:NativeFindModeFind];
}

- (void)layoutFindPanelForMode:(NativeFindMode)mode {
  self.findModeControl.selectedSegment = mode;
  self.findPanel.title = @[@"Find", @"Replace", @"Find in Files", @"Mark"][mode];
  BOOL showReplace = mode == NativeFindModeReplace || mode == NativeFindModeFiles;
  for (NSView *view in self.findReplaceViews) view.hidden = !showReplace;
  for (NSView *view in self.findFilesViews) view.hidden = mode != NativeFindModeFiles;
  self.bookmarkLineButton.hidden = mode != NativeFindModeMark;
  self.backwardButton.enabled = mode == NativeFindModeFind || mode == NativeFindModeReplace;
  self.wrapAroundButton.enabled = mode == NativeFindModeFind || mode == NativeFindModeReplace;

  NSArray<NSString *> *visible = @[
    @[@"findNext", @"count", @"findAllCurrent", @"findAllOpen", @"close"],
    @[@"findNext", @"replace", @"replaceAll", @"replaceAllOpen", @"close"],
    @[@"findInFiles", @"replaceInFiles", @"close"],
    @[@"markAll", @"clearMarks", @"copyMarked", @"close"],
  ][mode];
  [self.findPanelButtons enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSButton *button, BOOL *stop) {
    (void)stop;
    button.hidden = ![visible containsObject:key];
  }];
  CGFloat y = 44;
  for (NSString *key in visible) {
    NSButton *button = self.findPanelButtons[key];
    if ([key isEqualToString:@"close"]) y = MAX(y + 8, 196.0);
    button.frame = NSMakeRect(466, y, 244, 28);
    y += 32;
  }
  NSButton *primary = self.findPanelButtons[visible.firstObject];
  self.findPanel.defaultButtonCell = primary.cell;
}

#pragma mark - Showing

- (void)showFindPanelMode:(NativeFindMode)mode {
  ScintillaView *editor = self.activeEditor;
  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  if (end > start && end - start < 300) {
    std::string buffer(end - start, '\0');
    [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:start value:end];
    [editor message:SCI_GETTARGETTEXT wParam:0 lParam:(sptr_t)buffer.data()];
    NSString *selection = [[NSString alloc] initWithBytes:buffer.data() length:buffer.size() encoding:NSUTF8StringEncoding];
    if (selection.length && ![selection containsString:@"\n"]) self.searchField.stringValue = selection;
  }
  if (mode == NativeFindModeFiles && !self.findDirectoryField.stringValue.length) {
    self.findDirectoryField.stringValue = self.projectURL.path ?: self.activeDocument.fileURL.URLByDeletingLastPathComponent.path ?: NSHomeDirectory();
  }
  [self layoutFindPanelForMode:mode];
  self.findPanel.appearance = self.window.appearance;
  if (!self.findPanel.isVisible) {
    NSRect frame = self.window.frame;
    [self.findPanel setFrameTopLeftPoint:NSMakePoint(NSMidX(frame) - NSWidth(self.findPanel.frame) / 2, NSMaxY(frame) - 120)];
  }
  [self.findPanel makeKeyAndOrderFront:nil];
  [self.findPanel makeFirstResponder:self.searchField];
  [self.searchField selectText:nil];
}

- (void)focusFind:(id)sender {
  (void)sender;
  [self showFindPanelMode:NativeFindModeFind];
}

- (void)focusReplace:(id)sender {
  (void)sender;
  [self showFindPanelMode:NativeFindModeReplace];
}

- (void)findInProject:(id)sender {
  (void)sender;
  [self showFindPanelMode:NativeFindModeFiles];
}

- (void)replaceInProject:(id)sender {
  (void)sender;
  [self showFindPanelMode:NativeFindModeFiles];
}

- (void)showMarkPanel:(id)sender {
  (void)sender;
  [self showFindPanelMode:NativeFindModeMark];
}

- (void)findPanelModeChanged:(NSSegmentedControl *)sender {
  [self layoutFindPanelForMode:(NativeFindMode)sender.selectedSegment];
}

- (void)searchModeChanged:(id)sender {
  (void)sender;
}

- (void)closeFindPanel:(id)sender {
  (void)sender;
  [self.findPanel orderOut:nil];
  [self.window makeKeyAndOrderFront:nil];
}

- (void)setFindPanelMessage:(NSString *)message {
  if (self.findPanel.isVisible) self.findStatusLabel.stringValue = message;
}

#pragma mark - Actions

- (void)findPanelDefaultAction:(id)sender {
  switch ((NativeFindMode)self.findModeControl.selectedSegment) {
    case NativeFindModeFiles: [self findPanelFindInFiles:sender]; break;
    case NativeFindModeMark: [self markAll:sender]; break;
    default: [self findPanelFindNext:sender]; break;
  }
}

- (void)findPanelFindNext:(id)sender {
  if (self.backwardButton.state == NSControlStateValueOn) [self findPrevious:sender];
  else [self findNext:sender];
}

- (void)chooseFindPanelDirectory:(id)sender {
  (void)sender;
  NSOpenPanel *open = [NSOpenPanel openPanel];
  open.canChooseFiles = NO;
  open.canChooseDirectories = YES;
  if (self.findDirectoryField.stringValue.length) open.directoryURL = [NSURL fileURLWithPath:self.findDirectoryField.stringValue];
  [open beginSheetModalForWindow:self.findPanel completionHandler:^(NSModalResponse response) {
    if (response == NSModalResponseOK && open.URL) self.findDirectoryField.stringValue = open.URL.path;
  }];
}

- (NSURL *)findPanelDirectory {
  BOOL isDirectory = NO;
  NSString *path = self.findDirectoryField.stringValue.stringByExpandingTildeInPath;
  if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) {
    [self setStatus:@"Find in Files: choose an existing directory"];
    NSBeep();
    return nil;
  }
  [[NSUserDefaults standardUserDefaults] setObject:self.findFiltersField.stringValue forKey:@"NativeEditor.FindInFilesFilters.v1"];
  return [NSURL fileURLWithPath:path];
}

- (void)findPanelFindInFiles:(id)sender {
  (void)sender;
  NSURL *directory = [self findPanelDirectory];
  if (directory && self.searchField.stringValue.length) {
    [self performProjectSearchInDirectory:directory replacing:NO filters:self.findFiltersField.stringValue];
  }
}

- (void)findPanelReplaceInFiles:(id)sender {
  (void)sender;
  NSURL *directory = [self findPanelDirectory];
  if (directory && self.searchField.stringValue.length) {
    [self performProjectSearchInDirectory:directory replacing:YES filters:self.findFiltersField.stringValue];
  }
}

- (void)copyMarkedText:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  long length = [editor getGeneralProperty:SCI_GETLENGTH];
  NSMutableArray<NSString *> *pieces = [NSMutableArray array];
  long position = 0;
  while (position < length) {
    long end = [editor getGeneralProperty:SCI_INDICATOREND parameter:kNativeMarkIndicator extra:position];
    if ([editor getGeneralProperty:SCI_INDICATORVALUEAT parameter:kNativeMarkIndicator extra:position] && end > position) {
      std::string buffer(end - position, '\0');
      [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:position value:end];
      [editor message:SCI_GETTARGETTEXT wParam:0 lParam:(sptr_t)buffer.data()];
      NSString *piece = [[NSString alloc] initWithBytes:buffer.data() length:buffer.size() encoding:NSUTF8StringEncoding];
      if (piece) [pieces addObject:piece];
    }
    if (end <= position) break;
    position = end;
  }
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:[pieces componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
  [self setStatus:[NSString stringWithFormat:@"Copied %lu marked pieces of text", (unsigned long)pieces.count]];
}

@end
