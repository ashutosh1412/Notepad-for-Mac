#import "NativeEditorController+Private.h"
#import <objc/message.h>

// In-app smoke test for menu commands. Run the app with
// NATIVE_EDITOR_SELFTEST=/path/report.txt; it writes a report and quits.

#if NATIVE_EDITOR_DEBUG_HOOKS
@implementation NativeEditorController (SelfTest)

- (void)runSelfTestWritingTo:(NSString *)path {
  NSMutableString *report = [NSMutableString string];
  __block NSInteger failures = 0;
  NativeDocument *document = nil;
  for (NativeDocument *candidate in self.documents) if (candidate.isPristine) document = candidate;
  if (!document) {
    [self newDocument:nil];
    document = self.activeDocument;
  }
  [self selectDocument:document];
  ScintillaView *editor = document.editor;
  void (^setText)(NSString *) = ^(NSString *text) {
    [document setText:text];
    [editor setGeneralProperty:SCI_SETSEL parameter:0 value:0];
  };
  void (^check)(BOOL, NSString *) = ^(BOOL ok, NSString *name) {
    [report appendFormat:@"%@  %@\n", ok ? @"ok  " : @"FAIL", name];
    NSLog(@"selftest %@ %@", ok ? @"ok" : @"FAIL", name);
    if (!ok) failures += 1;
  };
  NSMenuItem *(^item)(NSInteger, id) = ^NSMenuItem *(NSInteger tag, id represented) {
    NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    menuItem.tag = tag;
    menuItem.representedObject = represented;
    return menuItem;
  };
  #define CALL(selectorName, argument) ((void (*)(id, SEL, id))objc_msgSend)(self, NSSelectorFromString(selectorName), argument)

  setText(@"b10\na2\nc1\na2");
  [editor message:SCI_SELECTALL];
  CALL(@"sortLinesBy:", item(0, (@{@"kind": @"lex", @"ascending": @YES})));
  check([editor.string isEqualToString:@"a2\na2\nb10\nc1"], @"Sort lines lexicographically ascending");
  CALL(@"sortLinesBy:", item(0, (@{@"kind": @"length", @"ascending": @NO})));
  check([editor.string hasPrefix:@"b10"], @"Sort lines by length descending");
  setText(@"10\n9\n100");
  CALL(@"sortLinesBy:", item(0, (@{@"kind": @"int", @"ascending": @NO})));
  check([editor.string isEqualToString:@"100\n10\n9"], @"Sort lines as integers descending");
  setText(@"1,5\n1,25\n10,0");
  CALL(@"sortLinesBy:", item(0, (@{@"kind": @"comma", @"ascending": @YES})));
  check([editor.string isEqualToString:@"1,25\n1,5\n10,0"], @"Sort lines as decimals (comma)");

  [document setLanguage:@"cpp"];
  setText(@"int x;");
  CALL(@"singleLineComment:", nil);
  check([editor.string isEqualToString:@"// int x;"], @"Single line comment");
  CALL(@"singleLineUncomment:", nil);
  check([editor.string isEqualToString:@"int x;"], @"Single line uncomment");
  CALL(@"blockComment:", nil);
  check([editor.string isEqualToString:@"/*int x;*/"], @"Block comment");
  [editor setGeneralProperty:SCI_GOTOPOS value:4];
  CALL(@"blockUncomment:", nil);
  check([editor.string isEqualToString:@"int x;"], @"Block uncomment");

  [document setLanguage:@"text"];
  setText(@"hello world");
  [editor setGeneralProperty:SCI_SETSEL parameter:0 value:11];
  CALL(@"properCaseBlend:", nil);
  check([editor.string isEqualToString:@"Hello World"], @"Proper case (blend)");
  [editor setGeneralProperty:SCI_SETSEL parameter:0 value:5];
  CALL(@"asciiToHex:", nil);
  check([editor.string hasPrefix:@"48656C6C6F"], @"Converter ASCII -> HEX");
  [editor setGeneralProperty:SCI_SETSEL parameter:0 value:10];
  CALL(@"hexToAscii:", nil);
  check([editor.string isEqualToString:@"Hello World"], @"Converter HEX -> ASCII");
  [editor setGeneralProperty:SCI_SETSEL parameter:6 value:11];
  CALL(@"redactSelection:", nil);
  check([editor.string isEqualToString:@"Hello █████"], @"Redact selection");

  setText(@"cat dog cat Cat");
  [editor setGeneralProperty:SCI_SETSEL parameter:0 value:3];
  CALL(@"multiSelectAll:", item(1, nil));
  check([editor getGeneralProperty:SCI_GETSELECTIONS] == 2, @"Multi-select all (match case)");
  [editor setGeneralProperty:SCI_SETSEL parameter:0 value:3];
  CALL(@"multiSelectAll:", item(0, nil));
  check([editor getGeneralProperty:SCI_GETSELECTIONS] == 3, @"Multi-select all (ignore case)");
  CALL(@"undoLatestMultiSelect:", nil);
  check([editor getGeneralProperty:SCI_GETSELECTIONS] == 2, @"Undo latest added multi-select");

  setText(@"cat dog cat");
  [editor setGeneralProperty:SCI_SETSEL parameter:0 value:3];
  CALL(@"styleAllOccurrences:", item(1, nil));
  check([editor getGeneralProperty:SCI_INDICATORVALUEAT parameter:10 extra:8] != 0, @"Style all occurrences (1st style)");
  [editor setGeneralProperty:SCI_GOTOPOS value:0];
  CALL(@"jumpDownToStyle:", item(1, nil));
  check([editor getGeneralProperty:SCI_GETSELECTIONSTART] == 0 || [editor getGeneralProperty:SCI_GETSELECTIONSTART] == 8, @"Jump down to style");
  CALL(@"clearStyle:", item(0, nil));
  check([editor getGeneralProperty:SCI_INDICATORVALUEAT parameter:10 extra:8] == 0, @"Clear all styles");

  setText(@"a\nb\nc\nd");
  [editor setGeneralProperty:SCI_SETSEL parameter:2 value:5];
  CALL(@"hideLines:", nil);
  check([editor getGeneralProperty:SCI_GETLINEVISIBLE parameter:1] == 0, @"Hide lines");
  CALL(@"showHiddenLines:", nil);
  check([editor getGeneralProperty:SCI_GETLINEVISIBLE parameter:1] != 0, @"Show hidden lines");

  [document setLanguage:@"python"];
  setText(@"def a():\n    if x:\n        pass\n");
  CALL(@"foldLevel:", item(1, nil));
  check([editor getGeneralProperty:SCI_GETFOLDEXPANDED parameter:0] == 0, @"Fold level 1");
  CALL(@"unfoldLevel:", item(1, nil));
  check([editor getGeneralProperty:SCI_GETFOLDEXPANDED parameter:0] != 0, @"Unfold level 1");

  setText(@"x");
  NSString *before = document.encodingDisplayName;
  CALL(@"encodeIn:", item(0, (@{@"encoding": @(NSWindowsCP1252StringEncoding), @"bom": @NO})));
  check([document.encodingDisplayName isEqualToString:@"Windows-1252"] && ![before isEqualToString:document.encodingDisplayName], @"Encoding > ANSI");
  CALL(@"selectEncoding:", item(0, (@{@"encoding": @(NSUTF8StringEncoding), @"bom": @YES})));
  check([document.encodingDisplayName isEqualToString:@"UTF-8-BOM"], @"Encoding > Convert to UTF-8-BOM");

  [self newDocument:nil];
  NativeDocument *second = self.activeDocument;
  CALL(@"togglePinTab:", nil);
  check([self.pinnedDocuments containsObject:second.identifier] && [self.tabView indexOfTabViewItem:self.tabItems[second.identifier]] == 0, @"Pin tab moves it first");
  CALL(@"applyTabColor:", item(3, nil));
  check([self.tabColors[second.identifier] integerValue] == 3, @"Apply color 3 to tab");
  CALL(@"togglePinTab:", nil);
  CALL(@"moveTabToEnd:", nil);
  check([self.tabView indexOfTabViewItem:self.tabItems[second.identifier]] == self.tabView.numberOfTabViewItems - 1, @"Move tab to end");
  CALL(@"selectTabNumber:", item(0, nil));
  check([self.tabView indexOfTabViewItem:self.tabView.selectedTabViewItem] == 0, @"Select 1st tab");
  CALL(@"selectLastTab:", nil);
  check(self.activeDocument == second, @"Select last tab");
  [second.editor setString:@""];
  CALL(@"closeAllToTheLeft:", nil);
  check(self.tabView.numberOfTabViewItems >= 1, @"Close all to the left (keeps active)");

  CALL(@"toggleDocumentList:", nil);
  check(!self.sidePanel.hidden, @"Document List panel opens");
  CALL(@"toggleDocumentList:", nil);
  CALL(@"toggleIncrementalSearch:", nil);
  check(![self.toolObjects[@"incBar"] isHidden], @"Incremental search bar opens");
  CALL(@"toggleIncrementalSearch:", nil);
  CALL(@"togglePostIt:", nil);
  check(self.toolbarView.hidden && self.window.level == NSFloatingWindowLevel, @"Post-It hides chrome and floats");
  CALL(@"togglePostIt:", nil);
  check(!self.toolbarView.hidden, @"Post-It off restores chrome");

  NSMenu *tabMenu = [self tabContextMenu];
  check([tabMenu itemWithTitle:@"Close Multiple Tabs"] && [tabMenu itemWithTitle:@"Apply Color to Tab"] && [tabMenu itemWithTitle:@"Move Document"], @"Tab context menu has Notepad++ sections");
  check(self.activeDocument.editor.menu != nil, @"Editor has right-click menu");

  [report appendFormat:@"\n%@\n", failures ? [NSString stringWithFormat:@"%ld FAILED", (long)failures] : @"All self-test checks passed"];
  [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
  exit(failures ? 1 : 0);
}

@end
#endif
