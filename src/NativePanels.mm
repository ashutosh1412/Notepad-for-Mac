#import "NativeEditorController+Private.h"
#import <objc/runtime.h>
#include <string>

static NSString * const kStyleOverridesKey = @"NativeEditor.StyleOverrides.v1";

static NSString *PanelTextInRange(ScintillaView *editor, long start, long end) {
  if (end <= start) return @"";
  std::string buffer(end - start, '\0');
  [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:start value:end];
  [editor message:SCI_GETTARGETTEXT wParam:0 lParam:(sptr_t)buffer.data()];
  return [[NSString alloc] initWithBytes:buffer.data() length:buffer.size() encoding:NSUTF8StringEncoding] ?: @"";
}

#pragma mark - Function list parsing

// Each rule is @[pattern, kind]; capture group 1 is the name.
static NSArray<NSArray<NSString *> *> *FunctionRules(NSString *language) {
  NSString *cClass = @"^[ \t]*(?:template[ \t]*<[^>]*>[ \t]*)?(?:typedef[ \t]+)?(class|struct|union|enum(?:[ \t]+class)?|namespace)[ \t]+([A-Za-z_]\\w*)[^;]*$";
  NSString *cFunction = @"^[ \t]*(?:[\\w:<>\\*&,\\[\\]~]+[ \t]+)*[\\*&]?([A-Za-z_~][\\w:~]*)[ \t]*\\([^;{}]*?\\)[^;{}()]*\\{";
  NSString *managedClass = @"^[ \t]*(?:(?:public|private|protected|internal|abstract|final|static|sealed|partial|open|data|export|default|declare)[ \t]+)*(class|interface|enum|struct|record|object|trait|protocol|extension|impl|module|type)[ \t]+([A-Za-z_$][\\w$]*)";
  NSString *jsFunction = @"\\bfunction\\b[ \t]*\\*?[ \t]*([A-Za-z_$][\\w$]*)[ \t]*\\(";
  NSString *jsArrow = @"^[ \t]*(?:export[ \t]+)?(?:const|let|var)[ \t]+([A-Za-z_$][\\w$]*)[ \t]*(?::[^=]+)?=[ \t]*(?:async[ \t]+)?(?:function\\b|\\([^)]*\\)[ \t]*(?::[^=]+)?=>|[A-Za-z_$][\\w$]*[ \t]*=>)";
  NSString *jsMethod = @"^[ \t]+(?:(?:public|private|protected|static|async|get|set|override|readonly)[ \t]+)*([A-Za-z_$][\\w$]*)[ \t]*(?:<[^>]*>)?\\([^;{}]*\\)[ \t]*(?::[^{;]+)?\\{";
  NSDictionary<NSString *, NSArray *> *rules = @{
    @"c": @[@[cClass, @"class"], @[cFunction, @"function"]],
    @"cpp": @[@[cClass, @"class"], @[cFunction, @"function"]],
    @"objc": @[@[@"^@(?:interface|implementation|protocol)[ \t]+([A-Za-z_]\\w*)", @"class"],
               @[@"^[-+][ \t]*\\([^)]*\\)[ \t]*([A-Za-z_]\\w*)", @"function"], @[cFunction, @"function"]],
    @"cs": @[@[managedClass, @"class"], @[cFunction, @"function"]],
    @"java": @[@[managedClass, @"class"], @[cFunction, @"function"]],
    @"php": @[@[managedClass, @"class"], @[@"\\bfunction[ \t]+&?([A-Za-z_]\\w*)", @"function"]],
    @"javascript": @[@[managedClass, @"class"], @[jsFunction, @"function"], @[jsArrow, @"function"], @[jsMethod, @"function"]],
    @"typescript": @[@[managedClass, @"class"], @[jsFunction, @"function"], @[jsArrow, @"function"], @[jsMethod, @"function"]],
    @"go": @[@[@"^type[ \t]+([A-Za-z_]\\w*)[ \t]+(?:struct|interface)", @"class"],
             @[@"^func[ \t]+(?:\\([^)]*\\)[ \t]*)?([A-Za-z_]\\w*)", @"function"]],
    @"rust": @[@[@"^[ \t]*(?:pub(?:\\([^)]*\\))?[ \t]+)?(?:struct|enum|trait|union|mod)[ \t]+([A-Za-z_]\\w*)", @"class"],
               @[@"^[ \t]*impl(?:<[^>]*>)?[ \t]+(?:[\\w:<>, ]+[ \t]+for[ \t]+)?([A-Za-z_][\\w:]*)", @"class"],
               @[@"^[ \t]*(?:pub(?:\\([^)]*\\))?[ \t]+)?(?:const[ \t]+)?(?:async[ \t]+)?(?:unsafe[ \t]+)?(?:extern[ \t]+\"[^\"]*\"[ \t]+)?fn[ \t]+([A-Za-z_]\\w*)", @"function"]],
    @"swift": @[@[managedClass, @"class"], @[@"\\bfunc[ \t]+([A-Za-z_]\\w*|[^\\s(]+)", @"function"]],
    @"kotlin": @[@[managedClass, @"class"], @[@"\\bfun[ \t]+(?:<[^>]*>[ \t]*)?(?:[\\w.]+\\.)?([A-Za-z_]\\w*)", @"function"]],
    @"dart": @[@[managedClass, @"class"], @[cFunction, @"function"]],
    @"python": @[@[@"^[ \t]*class[ \t]+([A-Za-z_]\\w*)", @"class"], @[@"^[ \t]*(?:async[ \t]+)?def[ \t]+([A-Za-z_]\\w*)", @"function"]],
    @"ruby": @[@[@"^[ \t]*(?:class|module)[ \t]+([A-Z][\\w:]*)", @"class"], @[@"^[ \t]*def[ \t]+([\\w.]+[?!=]?)", @"function"]],
    @"lua": @[@[@"^[ \t]*(?:local[ \t]+)?function[ \t]+([\\w.:]+)", @"function"],
              @[@"^[ \t]*(?:local[ \t]+)?([\\w.]+)[ \t]*=[ \t]*function\\b", @"function"]],
    @"perl": @[@[@"^[ \t]*package[ \t]+([\\w:]+)", @"class"], @[@"^[ \t]*sub[ \t]+(\\w+)", @"function"]],
    @"bash": @[@[@"^[ \t]*(?:function[ \t]+)?([A-Za-z_][\\w.-]*)[ \t]*\\(\\)", @"function"], @[@"^[ \t]*function[ \t]+([A-Za-z_][\\w.-]*)", @"function"]],
    @"powershell": @[@[@"^[ \t]*function[ \t]+([\\w-]+)", @"function"], @[@"^[ \t]*class[ \t]+(\\w+)", @"class"]],
    @"batch": @[@[@"^:([A-Za-z_][\\w.-]*)", @"function"]],
    @"sql": @[@[@"\\bcreate[ \t]+(?:or[ \t]+replace[ \t]+)?(?:procedure|function|view|table|trigger|index)[ \t]+(?:if[ \t]+not[ \t]+exists[ \t]+)?([\\w.\\[\\]\"`]+)", @"function"]],
    @"markdown": @[@[@"^(#{1,6})[ \t]+(.+?)[ \t#]*$", @"heading"]],
    @"ini": @[@[@"^[ \t]*\\[([^\\]]+)\\]", @"section"]],
    @"toml": @[@[@"^[ \t]*\\[\\[?([^\\]]+)\\]", @"section"]],
    @"yaml": @[@[@"^([A-Za-z_][\\w.-]*)[ \t]*:", @"section"]],
    @"makefile": @[@[@"^([A-Za-z0-9_./%-][\\w./%-]*)[ \t]*::?(?!=)", @"function"]],
    @"css": @[@[@"^[ \t]*([^\\s{}/@][^{}\\n]*?)[ \t]*\\{", @"section"], @[@"^[ \t]*(@media[^{\\n]*?)[ \t]*\\{", @"section"]],
  };
  return rules[language] ?: @[];
}

static NSArray<NSDictionary *> *ParseFunctions(NSString *text, NSString *language, NSInteger tabWidth) {
  static NSSet *keywords;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    keywords = [NSSet setWithArray:@[@"if", @"else", @"for", @"while", @"switch", @"catch", @"return", @"sizeof", @"do",
                                     @"new", @"delete", @"try", @"foreach", @"using", @"lock", @"synchronized", @"with",
                                     @"elif", @"function", @"typeof", @"await", @"constructor"]];
  });
  NSArray *rules = FunctionRules(language);
  if (!rules.count || !text.length) return @[];
  NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
  NSMutableSet<NSNumber *> *seenLines = [NSMutableSet set];
  // Line starts let match offsets map to line numbers by binary search.
  NSMutableArray<NSNumber *> *lineStarts = [NSMutableArray arrayWithObject:@0];
  [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByLines | NSStringEnumerationSubstringNotRequired
                        usingBlock:^(NSString *substring, NSRange range, NSRange enclosing, BOOL *stop) {
    (void)substring; (void)range; (void)stop;
    if (NSMaxRange(enclosing) < text.length) [lineStarts addObject:@(NSMaxRange(enclosing))];
  }];
  NSUInteger (^lineForOffset)(NSUInteger) = ^NSUInteger(NSUInteger offset) {
    NSUInteger low = 0, high = lineStarts.count;
    while (low + 1 < high) {
      NSUInteger middle = (low + high) / 2;
      if (lineStarts[middle].unsignedIntegerValue <= offset) low = middle; else high = middle;
    }
    return low;
  };
  BOOL caseInsensitive = [language isEqualToString:@"sql"];
  for (NSArray *rule in rules) {
    NSRegularExpressionOptions options = NSRegularExpressionAnchorsMatchLines | (caseInsensitive ? NSRegularExpressionCaseInsensitive : 0);
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:rule[0] options:options error:nil];
    if (!regex) continue;
    NSString *kind = rule[1];
    [regex enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                         usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
      (void)flags;
      NSRange nameRange = [match rangeAtIndex:match.numberOfRanges - 1];
      if (nameRange.location == NSNotFound) return;
      NSString *name = [text substringWithRange:nameRange];
      if ([keywords containsObject:name]) return;
      NSUInteger line = lineForOffset(nameRange.location);
      if ([seenLines containsObject:@(line)]) return;
      [seenLines addObject:@(line)];
      NSInteger depth = 0;
      if ([kind isEqualToString:@"heading"]) {
        depth = (NSInteger)[match rangeAtIndex:1].length - 1;
      } else if (match.numberOfRanges > 2 && [kind isEqualToString:@"class"]) {
        name = [NSString stringWithFormat:@"%@ %@", [text substringWithRange:[match rangeAtIndex:1]], name];
      }
      if (![kind isEqualToString:@"heading"]) {
        NSUInteger start = lineStarts[line].unsignedIntegerValue;
        NSInteger columns = 0;
        for (NSUInteger index = start; index < text.length; index += 1) {
          unichar ch = [text characterAtIndex:index];
          if (ch == ' ') columns += 1;
          else if (ch == '\t') columns += tabWidth;
          else break;
        }
        depth = MIN(columns / MAX(tabWidth, (NSInteger)1), (NSInteger)4);
      }
      [entries addObject:@{@"name": name, @"line": @(line), @"kind": kind, @"depth": @(depth)}];
      if (entries.count > 5000) *stop = YES;
    }];
  }
  [entries sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
    return [left[@"line"] compare:right[@"line"]];
  }];
  return entries;
}

#pragma mark - Small helper objects

@interface NativeFunctionListSource : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, weak) NativeEditorController *controller;
@end

@implementation NativeFunctionListSource
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
  (void)tableView;
  return (NSInteger)self.controller.visibleFunctionEntries.count;
}
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
  (void)tableView; (void)column;
  NSDictionary *entry = self.controller.visibleFunctionEntries[row];
  NSDictionary *glyphs = @{@"class": @"◆", @"function": @"ƒ", @"heading": @"#", @"section": @"§"};
  NSString *indent = [@"" stringByPaddingToLength:(NSUInteger)[entry[@"depth"] integerValue] * 2 withString:@" " startingAtIndex:0];
  return [NSString stringWithFormat:@"%@%@ %@", indent, glyphs[entry[@"kind"]] ?: @"•", entry[@"name"]];
}
@end

@interface NativeDocumentMapDelegate : NSObject <ScintillaNotificationProtocol>
@property(nonatomic, weak) NativeEditorController *controller;
@property(nonatomic, assign) long expectedAnchor;
@property(nonatomic, assign) long expectedCaret;
@end

@interface NativeEditorController (DocumentMapClicks)
- (void)documentMapClicked;
@end

@implementation NativeDocumentMapDelegate
- (void)notification:(SCNotification *)notification {
  if (notification->nmhdr.code != SCN_UPDATEUI || !(notification->updated & SC_UPDATE_SELECTION)) return;
  ScintillaView *map = self.controller.documentMap;
  if ([map getGeneralProperty:SCI_GETANCHOR] == self.expectedAnchor &&
      [map getGeneralProperty:SCI_GETCURRENTPOS] == self.expectedCaret) return;
  [self.controller documentMapClicked];
}
@end

@implementation NativeEditorController (Panels)

#pragma mark - Side panel

- (NSSplitView *)buildSidePanel {
  self.functionEntries = @[];
  self.visibleFunctionEntries = @[];
  NativeFunctionListSource *source = [[NativeFunctionListSource alloc] init];
  source.controller = self;
  objc_setAssociatedObject(self, @selector(buildSidePanel), source, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  self.functionFilterField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
  self.functionFilterField.placeholderString = @"Filter functions";
  self.functionFilterField.target = self;
  self.functionFilterField.action = @selector(filterFunctionList:);
  self.functionFilterField.controlSize = NSControlSizeSmall;
  self.functionTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
  self.functionTable.headerView = nil;
  self.functionTable.dataSource = source;
  self.functionTable.delegate = source;
  self.functionTable.target = self;
  self.functionTable.action = @selector(functionListClicked:);
  self.functionTable.rowHeight = 18;
  NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"name"];
  column.resizingMask = NSTableColumnAutoresizingMask;
  NSTextFieldCell *cell = [[NSTextFieldCell alloc] init];
  cell.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
  cell.lineBreakMode = NSLineBreakByTruncatingTail;
  column.dataCell = cell;
  [self.functionTable addTableColumn:column];
  self.functionTable.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  scroll.hasVerticalScroller = YES;
  scroll.documentView = self.functionTable;
  NSTextField *title = [NSTextField labelWithString:@"Function List"];
  title.font = [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize];
  NSStackView *functionPane = [NSStackView stackViewWithViews:@[title, self.functionFilterField, scroll]];
  functionPane.orientation = NSUserInterfaceLayoutOrientationVertical;
  functionPane.alignment = NSLayoutAttributeLeading;
  functionPane.spacing = 4;
  functionPane.edgeInsets = NSEdgeInsetsMake(6, 6, 0, 0);
  [self.functionFilterField.widthAnchor constraintEqualToAnchor:functionPane.widthAnchor constant:-8].active = YES;
  [scroll.widthAnchor constraintEqualToAnchor:functionPane.widthAnchor constant:-6].active = YES;
  [scroll setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
  functionPane.hidden = YES;
  self.functionListPane = functionPane;

  self.documentMap = [[ScintillaView alloc] initWithFrame:NSMakeRect(0, 0, 200, 400)];
  NativeDocumentMapDelegate *mapDelegate = [[NativeDocumentMapDelegate alloc] init];
  mapDelegate.controller = self;
  mapDelegate.expectedAnchor = -1;
  self.documentMapDelegate = mapDelegate;
  self.documentMap.delegate = mapDelegate;
  self.documentMap.hidden = YES;

  self.sidePanel = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 250, 500)];
  self.sidePanel.vertical = NO;
  self.sidePanel.dividerStyle = NSSplitViewDividerStyleThin;
  [self.sidePanel addArrangedSubview:functionPane];
  [self.sidePanel addArrangedSubview:self.documentMap];
  self.sidePanel.hidden = YES;
  // Preferred sizes, weaker than divider drags (490) so the user can still resize.
  NSLayoutConstraint *width = [self.sidePanel.widthAnchor constraintEqualToConstant:260];
  width.priority = 480;
  NSLayoutConstraint *mapHeight = [self.documentMap.heightAnchor constraintEqualToConstant:320];
  mapHeight.priority = 480;
  [NSLayoutConstraint activateConstraints:@[width, mapHeight,
    [self.sidePanel.widthAnchor constraintGreaterThanOrEqualToConstant:150],
    [functionPane.heightAnchor constraintGreaterThanOrEqualToConstant:100],
    [self.documentMap.heightAnchor constraintGreaterThanOrEqualToConstant:100]]];
  return self.sidePanel;
}

- (void)updateSidePanelVisibility {
  BOOL visible = !self.functionListPane.hidden || !self.documentMap.hidden;
  self.sidePanel.hidden = !visible;
  [self.sidePanel adjustSubviews];
  [self.workspaceSplit adjustSubviews];
  [[NSUserDefaults standardUserDefaults] setBool:!self.functionListPane.hidden forKey:@"NativeEditor.FunctionListVisible.v1"];
  [[NSUserDefaults standardUserDefaults] setBool:!self.documentMap.hidden forKey:@"NativeEditor.DocumentMapVisible.v1"];
}

- (void)toggleFunctionList:(id)sender {
  (void)sender;
  self.functionListPane.hidden = !self.functionListPane.hidden;
  [self updateSidePanelVisibility];
  self.functionListSource = nil;
  [self refreshPanelsForce:YES];
}

- (void)toggleDocumentMap:(id)sender {
  (void)sender;
  self.documentMap.hidden = !self.documentMap.hidden;
  if (self.documentMap.hidden) {
    [self.documentMap setGeneralProperty:SCI_SETDOCPOINTER parameter:0 value:0];
    self.documentMapDocument = nil;
  }
  [self updateSidePanelVisibility];
  [self refreshPanelsForce:YES];
}

- (BOOL)validatePanelMenuItem:(NSMenuItem *)item {
  if (item.action == @selector(toggleFunctionList:)) {
    item.state = self.functionListPane.hidden ? NSControlStateValueOff : NSControlStateValueOn;
  } else if (item.action == @selector(toggleDocumentMap:)) {
    item.state = self.documentMap.hidden ? NSControlStateValueOff : NSControlStateValueOn;
  }
  return YES;
}

- (void)refreshPanelsForce:(BOOL)force {
  if (force) self.documentMapDocument = nil;
  if (force) [self syncToolbarToggles];
  if (!self.functionListPane.hidden) {
    NativeDocument *document = self.activeDocument;
    NSString *source = [NSString stringWithFormat:@"%@:%lu:%@", document.identifier, (unsigned long)document.changeCount, document.language];
    if (force || ![source isEqualToString:self.functionListSource]) {
      self.functionListSource = source;
      [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(rebuildFunctionList) object:nil];
      [self performSelector:@selector(rebuildFunctionList) withObject:nil afterDelay:force ? 0 : 0.6];
    }
    [self highlightCurrentFunction];
  }
  if (!self.documentMap.hidden) [self syncDocumentMap];
}

#pragma mark - Function list

- (void)rebuildFunctionList {
  NativeDocument *document = self.activeDocument;
  long length = [document.editor getGeneralProperty:SCI_GETLENGTH];
  NSInteger tabWidth = [self.viewOptions[NativeViewTabWidth] integerValue] ?: 4;
  self.functionEntries = length > 5 * 1024 * 1024 ? @[] : ParseFunctions(document.editor.string, document.language, tabWidth);
  [self filterFunctionList:nil];
}

- (void)filterFunctionList:(id)sender {
  (void)sender;
  NSString *filter = self.functionFilterField.stringValue;
  if (!filter.length) {
    self.visibleFunctionEntries = self.functionEntries;
  } else {
    self.visibleFunctionEntries = [self.functionEntries filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@", filter]];
  }
  [self.functionTable reloadData];
  [self highlightCurrentFunction];
}

- (void)highlightCurrentFunction {
  ScintillaView *editor = self.activeDocument.editor;
  long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:[editor getGeneralProperty:SCI_GETCURRENTPOS]];
  NSInteger row = -1;
  for (NSInteger index = 0; index < (NSInteger)self.visibleFunctionEntries.count; index += 1) {
    if ([self.visibleFunctionEntries[index][@"line"] longValue] > line) break;
    row = index;
  }
  if (row == self.functionTable.selectedRow) return;
  if (row < 0) [self.functionTable deselectAll:nil];
  else {
    [self.functionTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [self.functionTable scrollRowToVisible:row];
  }
}

- (void)functionListClicked:(id)sender {
  (void)sender;
  NSInteger row = self.functionTable.clickedRow;
  if (row < 0 || row >= (NSInteger)self.visibleFunctionEntries.count) return;
  ScintillaView *editor = self.activeDocument.editor;
  long line = [self.visibleFunctionEntries[row][@"line"] longValue];
  [editor setGeneralProperty:SCI_ENSUREVISIBLEENFORCEPOLICY value:line];
  [editor setGeneralProperty:SCI_GOTOLINE value:line];
  long linesOnScreen = [editor getGeneralProperty:SCI_LINESONSCREEN];
  long visible = [editor getGeneralProperty:SCI_VISIBLEFROMDOCLINE parameter:line];
  [editor setGeneralProperty:SCI_SETFIRSTVISIBLELINE value:MAX(0L, visible - linesOnScreen / 3)];
  [self.window makeFirstResponder:editor.content];
}

#pragma mark - Document map

- (void)configureDocumentMapForDocument:(NativeDocument *)document {
  ScintillaView *map = self.documentMap;
  long pointer = [document.editor getGeneralProperty:SCI_GETDOCPOINTER];
  [map setGeneralProperty:SCI_SETDOCPOINTER parameter:0 value:pointer];
  [document styleEditor:map];
  for (int margin = 0; margin <= 4; margin += 1) [map setGeneralProperty:SCI_SETMARGINWIDTHN parameter:margin value:0];
  [map setGeneralProperty:SCI_SETZOOM value:-10];
  [map setGeneralProperty:SCI_SETVSCROLLBAR value:0];
  [map setGeneralProperty:SCI_SETHSCROLLBAR value:0];
  [map setGeneralProperty:SCI_SETCARETSTYLE value:CARETSTYLE_INVISIBLE];
  [map setGeneralProperty:SCI_SETCARETLINEVISIBLE value:0];
  [map setGeneralProperty:SCI_SETWRAPMODE value:SC_WRAP_NONE];
  [map setGeneralProperty:SCI_SETINDENTATIONGUIDES value:SC_IV_NONE];
  [map setGeneralProperty:SCI_SETVIEWWS value:SCWS_INVISIBLE];
  [map setGeneralProperty:SCI_SETSELECTIONLAYER value:SC_LAYER_UNDER_TEXT];
  // The visible part of the main editor shows as a translucent band.
  NativeTheme *theme = document.theme;
  NSColor *band = [theme.selection colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  long colour = lround(band.redComponent * 255) | (lround(band.greenComponent * 255) << 8) | (lround(band.blueComponent * 255) << 16);
  [map setGeneralProperty:SCI_SETELEMENTCOLOUR parameter:SC_ELEMENT_SELECTION_BACK value:colour | (0x90L << 24)];
  [map setGeneralProperty:SCI_SETELEMENTCOLOUR parameter:SC_ELEMENT_SELECTION_INACTIVE_BACK value:colour | (0x90L << 24)];
  self.documentMapDocument = document;
}

- (void)syncDocumentMap {
  NativeDocument *document = self.activeDocument;
  if (!document) return;
  if (self.documentMapDocument != document) [self configureDocumentMapForDocument:document];
  ScintillaView *editor = document.editor;
  ScintillaView *map = self.documentMap;
  long firstVisible = [editor getGeneralProperty:SCI_GETFIRSTVISIBLELINE];
  long linesOnScreen = [editor getGeneralProperty:SCI_LINESONSCREEN];
  long firstLine = [editor getGeneralProperty:SCI_DOCLINEFROMVISIBLE parameter:firstVisible];
  long lastLine = [editor getGeneralProperty:SCI_DOCLINEFROMVISIBLE parameter:firstVisible + linesOnScreen];
  long lineCount = [map getGeneralProperty:SCI_GETLINECOUNT];
  long start = [map getGeneralProperty:SCI_POSITIONFROMLINE parameter:firstLine];
  long end = lastLine + 1 < lineCount ? [map getGeneralProperty:SCI_POSITIONFROMLINE parameter:lastLine + 1]
                                       : [map getGeneralProperty:SCI_GETLENGTH];
  NativeDocumentMapDelegate *delegate = self.documentMapDelegate;
  if ([map getGeneralProperty:SCI_GETANCHOR] != start || [map getGeneralProperty:SCI_GETCURRENTPOS] != end) {
    delegate.expectedAnchor = start;
    delegate.expectedCaret = end;
    [map setGeneralProperty:SCI_SETSEL parameter:start value:end];
  }
  long mapLines = [map getGeneralProperty:SCI_LINESONSCREEN];
  long target = (firstLine + lastLine) / 2 - mapLines / 2;
  target = MAX(0L, MIN(target, lineCount - mapLines));
  [map setGeneralProperty:SCI_SETFIRSTVISIBLELINE value:target];
}

- (void)documentMapClicked {
  NativeDocument *document = self.activeDocument;
  ScintillaView *map = self.documentMap;
  ScintillaView *editor = document.editor;
  long line = [map getGeneralProperty:SCI_LINEFROMPOSITION parameter:[map getGeneralProperty:SCI_GETCURRENTPOS]];
  long visible = [editor getGeneralProperty:SCI_VISIBLEFROMDOCLINE parameter:line];
  long linesOnScreen = [editor getGeneralProperty:SCI_LINESONSCREEN];
  [editor setGeneralProperty:SCI_SETFIRSTVISIBLELINE value:MAX(0L, visible - linesOnScreen / 2)];
  [self.window makeFirstResponder:editor.content];
  [self syncDocumentMap];
}

#pragma mark - Preferences

- (NSButton *)preferenceCheckbox:(NSString *)title key:(NSString *)key inverted:(BOOL)inverted {
  NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(preferenceCheckboxChanged:)];
  box.identifier = key;
  box.tag = inverted ? 1 : 0;
  BOOL value = [self.viewOptions[key] boolValue];
  box.state = (value != inverted) ? NSControlStateValueOn : NSControlStateValueOff;
  return box;
}

- (void)preferenceCheckboxChanged:(NSButton *)sender {
  BOOL on = sender.state == NSControlStateValueOn;
  self.viewOptions[sender.identifier] = @(sender.tag ? !on : on);
  [self applyViewOptions];
}

- (NSPopUpButton *)preferencePopup:(NSString *)key titles:(NSArray<NSString *> *)titles values:(NSArray *)values {
  NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  popup.identifier = key;
  [titles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger index, BOOL *stop) {
    (void)stop;
    [popup addItemWithTitle:title];
    popup.lastItem.representedObject = values[index];
    if ([values[index] isEqual:self.viewOptions[key]]) [popup selectItem:popup.lastItem];
  }];
  popup.target = self;
  popup.action = @selector(preferencePopupChanged:);
  return popup;
}

- (void)preferencePopupChanged:(NSPopUpButton *)sender {
  self.viewOptions[sender.identifier] = sender.selectedItem.representedObject;
  [self applyViewOptions];
}

- (void)darkModePreferenceChanged:(NSButton *)sender {
  self.darkTheme = sender.state == NSControlStateValueOn;
  [self applyThemeToAllDocuments];
  [self savePreferences];
}

- (NSView *)preferencePage:(NSArray<NSArray<NSView *> *> *)rows {
  NSGridView *grid = [NSGridView gridViewWithViews:rows];
  grid.rowSpacing = 8;
  grid.columnSpacing = 10;
  [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
  grid.translatesAutoresizingMaskIntoConstraints = NO;
  NSView *page = [[NSView alloc] initWithFrame:NSZeroRect];
  [page addSubview:grid];
  [NSLayoutConstraint activateConstraints:@[
    [grid.topAnchor constraintEqualToAnchor:page.topAnchor constant:16],
    [grid.leadingAnchor constraintEqualToAnchor:page.leadingAnchor constant:20],
  ]];
  return page;
}

- (NSTextField *)dateFormatField {
  NSTextField *field = [NSTextField textFieldWithString:[[NSUserDefaults standardUserDefaults] stringForKey:@"NativeEditor.DateTimeFormat"] ?: @"yyyy-MM-dd HH:mm:ss"];
  field.placeholderString = @"yyyy-MM-dd HH:mm:ss";
  field.target = self;
  field.action = @selector(dateFormatChanged:);
  [field.widthAnchor constraintEqualToConstant:200].active = YES;
  return field;
}

- (void)dateFormatChanged:(NSTextField *)sender {
  [[NSUserDefaults standardUserDefaults] setObject:sender.stringValue forKey:@"NativeEditor.DateTimeFormat"];
}

- (void)showPreferences:(id)sender {
  (void)sender;
  NSView *empty = [NSGridCell emptyContentView];
  NSArray *fonts = @[@"Menlo", @"Monaco", @"SF Mono", @"Courier New", @"Andale Mono", @"PT Mono", @"JetBrains Mono", @"Fira Code"];
  NSMutableArray *availableFonts = [NSMutableArray array];
  for (NSString *font in fonts) if ([NSFont fontWithName:font size:12] || [font isEqualToString:@"SF Mono"]) [availableFonts addObject:font];
  NSArray *sizes = @[@9, @10, @11, @12, @13, @14, @15, @16, @18, @20, @24];
  NSMutableArray *sizeTitles = [NSMutableArray array];
  for (NSNumber *size in sizes) [sizeTitles addObject:[NSString stringWithFormat:@"%@ pt", size]];
  NSButton *dark = [NSButton checkboxWithTitle:@"Dark mode" target:self action:@selector(darkModePreferenceChanged:)];
  dark.state = self.darkTheme ? NSControlStateValueOn : NSControlStateValueOff;

  NSView *general = [self preferencePage:@[
    @[[NSTextField labelWithString:@"Appearance:"], dark],
    @[[NSTextField labelWithString:@"Font:"], [self preferencePopup:NativeViewFontName titles:availableFonts values:availableFonts]],
    @[[NSTextField labelWithString:@"Font size:"], [self preferencePopup:NativeViewFontSize titles:sizeTitles values:sizes]],
    @[[NSTextField labelWithString:@"Session:"], [self preferenceCheckbox:@"Remember current session for next launch" key:@"rememberSession" inverted:NO]],
    @[empty, [NSTextField wrappingLabelWithString:@"When off, the app asks to save changes on quit and starts empty."]],
    @[[NSTextField labelWithString:@"Tab bar:"], [self preferenceCheckbox:@"Double click to close document" key:@"tabDoubleClickCloses" inverted:NO]],
    @[empty, [self preferenceCheckbox:@"Lock (no drag and drop)" key:@"tabBarLocked" inverted:NO]],
    @[[NSTextField labelWithString:@"Date/time format:"], [self dateFormatField]],
  ]];
  NSView *editing = [self preferencePage:@[
    @[[NSTextField labelWithString:@"Display:"], [self preferenceCheckbox:@"Line numbers" key:NativeViewLineNumbers inverted:NO]],
    @[empty, [self preferenceCheckbox:@"Highlight current line" key:NativeViewCaretLine inverted:NO]],
    @[empty, [self preferenceCheckbox:@"Word wrap" key:NativeViewWordWrap inverted:NO]],
    @[empty, [self preferenceCheckbox:@"Indent guides" key:NativeViewIndentGuides inverted:NO]],
    @[empty, [self preferenceCheckbox:@"Show spaces and tabs" key:NativeViewWhitespace inverted:NO]],
    @[empty, [self preferenceCheckbox:@"Show end of line" key:NativeViewEndOfLine inverted:NO]],
    @[empty, [self preferenceCheckbox:@"Change history margin" key:NativeViewChangeHistory inverted:NO]],
    @[[NSTextField labelWithString:@"Typing:"], [self preferenceCheckbox:@"Smart highlighting" key:NativeViewSmartHighlight inverted:NO]],
    @[empty, [self preferenceCheckbox:@"Auto-indent" key:NativeViewAutoIndent inverted:NO]],
    @[empty, [self preferenceCheckbox:@"Auto-close ( [ { \" ' `" key:NativeViewAutoClose inverted:NO]],
    @[empty, [self preferenceCheckbox:@"Word auto-completion" key:NativeViewAutoComplete inverted:NO]],
    @[[NSTextField labelWithString:@"Tab size:"], [self preferencePopup:NativeViewTabWidth titles:@[@"2", @"3", @"4", @"8"] values:@[@2, @3, @4, @8]]],
    @[empty, [self preferenceCheckbox:@"Replace tabs by spaces" key:NativeViewUseTabs inverted:YES]],
  ]];
  NSView *newDocument = [self preferencePage:@[
    @[[NSTextField labelWithString:@"Line endings:"], [self preferencePopup:@"defaultEOL" titles:@[@"Unix (LF)", @"Windows (CR LF)", @"Macintosh (CR)"] values:@[@"LF", @"CRLF", @"CR"]]],
    @[[NSTextField labelWithString:@"Encoding:"], [self preferencePopup:@"defaultBOM" titles:@[@"UTF-8", @"UTF-8 with BOM"] values:@[@NO, @YES]]],
    @[empty, [NSTextField wrappingLabelWithString:@"Applies to new tabs. Opened files keep their own line endings and encoding."]],
  ]];

  NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 520, 470)];
  for (NSArray *page in @[@[@"General", general], @[@"Editing", editing], @[@"New Document", newDocument]]) {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:page[0]];
    item.label = page[0];
    item.view = page[1];
    [tabs addTabViewItem:item];
  }
  NSWindow *window = self.preferencesWindow;
  if (!window) {
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 540, 500)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                           backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Preferences";
    window.releasedWhenClosed = NO;
    [window center];
    self.preferencesWindow = window;
  }
  NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 540, 500)];
  tabs.frame = NSInsetRect(content.bounds, 10, 10);
  tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [content addSubview:tabs];
  window.contentView = content;
  window.appearance = self.window.appearance;
  [window makeKeyAndOrderFront:nil];
}

#pragma mark - Style configurator

- (NSMutableDictionary *)styleOverridesForCurrentTheme {
  NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kStyleOverridesKey] ?: @{};
  NSMutableDictionary *theme = [all[self.darkTheme ? @"dark" : @"light"] mutableCopy] ?: [NSMutableDictionary dictionary];
  theme[@"roles"] = [theme[@"roles"] mutableCopy] ?: [NSMutableDictionary dictionary];
  return theme;
}

- (void)saveStyleOverrides:(NSDictionary *)overrides {
  NSMutableDictionary *all = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kStyleOverridesKey] mutableCopy] ?: [NSMutableDictionary dictionary];
  all[self.darkTheme ? @"dark" : @"light"] = overrides;
  [[NSUserDefaults standardUserDefaults] setObject:all forKey:kStyleOverridesKey];
  [self applyThemeToAllDocuments];
}

- (void)styleColorChanged:(NSColorWell *)sender {
  NSMutableDictionary *overrides = [self styleOverridesForCurrentTheme];
  NSString *hex = [NativeTheme hexForColor:sender.color];
  if ([sender.identifier hasPrefix:@"role:"]) {
    NSString *role = [sender.identifier substringFromIndex:5];
    NSMutableDictionary *style = [overrides[@"roles"][role] mutableCopy] ?: [NSMutableDictionary dictionary];
    style[@"color"] = hex;
    overrides[@"roles"][role] = style;
  } else {
    overrides[sender.identifier] = hex;
  }
  [self saveStyleOverrides:overrides];
}

- (void)styleBoldChanged:(NSButton *)sender {
  NSMutableDictionary *overrides = [self styleOverridesForCurrentTheme];
  NSString *role = [sender.identifier substringFromIndex:5];
  NSMutableDictionary *style = [overrides[@"roles"][role] mutableCopy] ?: [NSMutableDictionary dictionary];
  style[@"bold"] = @(sender.state == NSControlStateValueOn);
  overrides[@"roles"][role] = style;
  [self saveStyleOverrides:overrides];
}

- (void)resetStyles:(id)sender {
  (void)sender;
  [self saveStyleOverrides:@{}];
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"NativeEditor.CustomTheme.v1"];
  [self applyThemeToAllDocuments];
  [self showStyleConfigurator:nil];
}

- (NSColorWell *)styleWell:(NSColor *)color identifier:(NSString *)identifier {
  NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 44, 22)];
  well.color = color;
  well.identifier = identifier;
  well.target = self;
  well.action = @selector(styleColorChanged:);
  [well.widthAnchor constraintEqualToConstant:44].active = YES;
  [well.heightAnchor constraintEqualToConstant:22].active = YES;
  return well;
}

- (void)showStyleConfigurator:(id)sender {
  (void)sender;
  NativeTheme *theme = [self currentTheme];
  NSMutableArray *rows = [NSMutableArray array];
  NSTextField *heading = [NSTextField labelWithString:[NSString stringWithFormat:@"Editing the %@ theme. Switch themes with Settings > Dark Mode.",
                                                       self.darkTheme ? @"dark" : @"light"]];
  [rows addObject:@[heading, [NSGridCell emptyContentView], [NSGridCell emptyContentView]]];
  [rows addObject:@[[NSTextField labelWithString:@"Background"], [self styleWell:theme.background identifier:@"background"], [NSGridCell emptyContentView]]];
  [rows addObject:@[[NSTextField labelWithString:@"Current line"], [self styleWell:theme.caretLine identifier:@"caretLine"], [NSGridCell emptyContentView]]];
  [rows addObject:@[[NSTextField labelWithString:@"Selection"], [self styleWell:theme.selection identifier:@"selection"], [NSGridCell emptyContentView]]];
  NSArray<NSString *> *names = [NativeTheme roleDisplayNames];
  for (NSInteger role = 0; role < (NSInteger)names.count; role += 1) {
    NSString *identifier = [NSString stringWithFormat:@"role:%ld", (long)role];
    NSButton *bold = [NSButton checkboxWithTitle:@"Bold" target:self action:@selector(styleBoldChanged:)];
    bold.identifier = identifier;
    bold.state = [theme isBoldRole:(NativeStyleRole)role] ? NSControlStateValueOn : NSControlStateValueOff;
    [rows addObject:@[[NSTextField labelWithString:names[role]], [self styleWell:[theme colorForRole:(NativeStyleRole)role] identifier:identifier], bold]];
  }
  NSGridView *grid = [NSGridView gridViewWithViews:rows];
  grid.rowSpacing = 5;
  grid.columnSpacing = 12;
  [grid rowAtIndex:0].bottomPadding = 6;
  [grid mergeCellsInHorizontalRange:NSMakeRange(0, 3) verticalRange:NSMakeRange(0, 1)];
  [grid rowAtIndex:4].topPadding = 8;
  grid.translatesAutoresizingMaskIntoConstraints = NO;
  NSButton *reset = [NSButton buttonWithTitle:@"Reset to Defaults" target:self action:@selector(resetStyles:)];
  reset.translatesAutoresizingMaskIntoConstraints = NO;

  NSWindow *window = self.styleWindow;
  if (!window) {
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 640)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                           backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Style Configurator";
    window.releasedWhenClosed = NO;
    [window center];
    self.styleWindow = window;
  }
  NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 640)];
  [content addSubview:grid];
  [content addSubview:reset];
  [NSLayoutConstraint activateConstraints:@[
    [grid.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
    [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
    [reset.topAnchor constraintEqualToAnchor:grid.bottomAnchor constant:16],
    [reset.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
  ]];
  window.contentView = content;
  window.appearance = self.window.appearance;
  [window makeKeyAndOrderFront:nil];
}

#pragma mark - Printing

// Prints the whole document with syntax colors and line numbers, paginated.
- (void)printDocument:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  ScintillaView *editor = document.editor;
  if (!document) return;
  [editor message:SCI_COLOURISE wParam:0 lParam:-1];

  NativeTheme *theme = [NativeTheme themeDark:NO customBackground:nil foreground:nil];
  NSDictionary *overrides = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kStyleOverridesKey];
  [theme applyOverrides:overrides[@"light"]];
  NSString *fontName = [self.viewOptions[NativeViewFontName] isKindOfClass:NSString.class] ? self.viewOptions[NativeViewFontName] : @"Menlo";
  CGFloat size = MAX(8.0, [self.viewOptions[NativeViewFontSize] doubleValue] - 3);
  NSFont *font = [NSFont fontWithName:fontName size:size] ?: [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
  NSFont *boldFont = [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:NSBoldFontMask];
  NSDictionary *lineNumberAttributes = @{NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.grayColor};
  NSDictionary<NSNumber *, NSNumber *> *roles = document.languageDefinition.styleRoles;

  NSMutableAttributedString *output = [[NSMutableAttributedString alloc] init];
  long lineCount = [editor getGeneralProperty:SCI_GETLINECOUNT];
  int digits = (int)[NSString stringWithFormat:@"%ld", lineCount].length;
  for (long line = 0; line < lineCount; line += 1) {
    [output appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%*ld  ", digits, line + 1]
                                                                   attributes:lineNumberAttributes]];
    long position = [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:line];
    long end = [editor getGeneralProperty:SCI_GETLINEENDPOSITION parameter:line];
    while (position < end) {
      long style = [editor getGeneralProperty:SCI_GETSTYLEINDEXAT parameter:position];
      long runEnd = position + 1;
      while (runEnd < end && [editor getGeneralProperty:SCI_GETSTYLEINDEXAT parameter:runEnd] == style) runEnd += 1;
      NativeStyleRole role = (NativeStyleRole)(roles[@(style)] ?: @(NativeStyleDefault)).integerValue;
      NSDictionary *attributes = @{NSFontAttributeName: [theme isBoldRole:role] ? boldFont : font,
                                   NSForegroundColorAttributeName: [theme colorForRole:role]};
      [output appendAttributedString:[[NSAttributedString alloc] initWithString:PanelTextInRange(editor, position, runEnd) attributes:attributes]];
      position = runEnd;
    }
    [output appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:lineNumberAttributes]];
  }

  NSPrintInfo *info = [NSPrintInfo.sharedPrintInfo copy];
  info.horizontalPagination = NSPrintingPaginationModeFit;
  info.verticalPagination = NSPrintingPaginationModeAutomatic;
  info.dictionary[NSPrintHeaderAndFooter] = @YES;
  CGFloat width = info.paperSize.width - info.leftMargin - info.rightMargin;
  NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, width, 100)];
  textView.textContainer.widthTracksTextView = YES;
  textView.backgroundColor = NSColor.whiteColor;
  [textView.textStorage setAttributedString:output];
  [textView.layoutManager ensureLayoutForTextContainer:textView.textContainer];
  NSRect used = [textView.layoutManager usedRectForTextContainer:textView.textContainer];
  [textView setFrameSize:NSMakeSize(width, NSHeight(used) + 20)];
  NSPrintOperation *operation = [NSPrintOperation printOperationWithView:textView printInfo:info];
  operation.jobTitle = document.fileURL.path ?: document.name;
  BOOL printNow = [objc_getAssociatedObject(self, @selector(printNow:)) boolValue];
  operation.showsPrintPanel = !printNow;
  operation.showsProgressPanel = !printNow;
  [operation runOperationModalForWindow:self.window delegate:nil didRunSelector:nil contextInfo:NULL];
}

@end
