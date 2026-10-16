#import "NativeEditorController+Private.h"
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#include <string>

// Commands that bring the app to parity with the latest Notepad++ menus.

static const int kTokenStyleIndicatorBase = 10;  // indicators 10-14: "Using 1st..5th Style"

static NSString *RangeText(ScintillaView *editor, long start, long end) {
  if (end <= start) return @"";
  std::string buffer(end - start, '\0');
  [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:start value:end];
  [editor message:SCI_GETTARGETTEXT wParam:0 lParam:(sptr_t)buffer.data()];
  return [[NSString alloc] initWithBytes:buffer.data() length:buffer.size() encoding:NSUTF8StringEncoding] ?: @"";
}

static void ReplaceText(ScintillaView *editor, long start, long end, NSString *text) {
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:start value:end];
  [editor message:SCI_REPLACETARGET wParam:data.length lParam:(sptr_t)(data.length ? data.bytes : "")];
}

static NSString *AppSupportFolder(NSString *child) {
  NSURL *base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
  NSURL *folder = [[base URLByAppendingPathComponent:@"Notepad++"] URLByAppendingPathComponent:child];
  [[NSFileManager defaultManager] createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
  return folder.path;
}

#pragma mark - Table helper

// Small block-based table data source used by the tool windows.
@interface NativeBlockTable : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, copy) NSInteger (^count)(void);
@property(nonatomic, copy) id (^value)(NSInteger row, NSString *column);
@end

@implementation NativeBlockTable
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
  (void)tableView;
  return self.count ? self.count() : 0;
}
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
  (void)tableView;
  return self.value ? self.value(row, column.identifier) : nil;
}
@end

static NSTableView *MakeTable(NSArray<NSArray *> *columns, NativeBlockTable *source) {
  NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
  table.usesAlternatingRowBackgroundColors = YES;
  table.dataSource = source;
  table.delegate = source;
  for (NSArray *column in columns) {
    NSTableColumn *tableColumn = [[NSTableColumn alloc] initWithIdentifier:column[0]];
    tableColumn.title = column[1];
    tableColumn.width = [column[2] doubleValue];
    [table addTableColumn:tableColumn];
  }
  return table;
}

static NSPanel *MakeToolPanel(NSString *title, NSSize size) {
  NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow
        backing:NSBackingStoreBuffered defer:YES];
  panel.title = title;
  panel.releasedWhenClosed = NO;
  panel.hidesOnDeactivate = YES;
  [panel center];
  return panel;
}

@implementation NativeEditorController (Parity)

- (NSMutableDictionary *)toolObjects {
  NSMutableDictionary *objects = objc_getAssociatedObject(self, _cmd);
  if (!objects) {
    objects = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(self, _cmd, objects, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return objects;
}

- (BOOL)requireWritable {
  if (!self.activeDocument.isReadOnly) return YES;
  [self setStatus:@"This document is read-only"];
  NSBeep();
  return NO;
}

- (void)insertIntoEditor:(NSString *)text {
  if (![self requireWritable]) return;
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  [self.activeEditor message:SCI_REPLACESEL wParam:0 lParam:(sptr_t)(data.length ? data.bytes : "")];
}

- (NSString *)selectedText {
  ScintillaView *editor = self.activeEditor;
  return RangeText(editor, [editor getGeneralProperty:SCI_GETSELECTIONSTART], [editor getGeneralProperty:SCI_GETSELECTIONEND]);
}

- (NSString *)wordOrSelection {
  ScintillaView *editor = self.activeEditor;
  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  if (start == end) {
    start = [editor getGeneralProperty:SCI_WORDSTARTPOSITION parameter:start extra:1];
    end = [editor getGeneralProperty:SCI_WORDENDPOSITION parameter:end extra:1];
  }
  return RangeText(editor, start, end);
}

- (void)replaceSelectionWith:(NSString *(^)(NSString *text))transform {
  ScintillaView *editor = self.activeEditor;
  if (![self requireWritable]) return;
  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  if (start == end) {
    [self setStatus:@"Select some text first"];
    return;
  }
  NSString *result = transform(RangeText(editor, start, end));
  if (!result) return;
  [editor message:SCI_BEGINUNDOACTION];
  ReplaceText(editor, start, end, result);
  [editor message:SCI_ENDUNDOACTION];
  [editor setGeneralProperty:SCI_SETSEL parameter:start value:start + (long)[result lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
}

#pragma mark - File

- (void)openContainingFolderAsWorkspace:(id)sender {
  (void)sender;
  NSURL *folder = self.activeDocument.fileURL.URLByDeletingLastPathComponent;
  if (folder) [self openURL:folder];
}

- (void)openInDefaultViewer:(id)sender {
  (void)sender;
  NSURL *url = self.activeDocument.fileURL;
  if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)closeDocumentsMatching:(BOOL (^)(NativeDocument *document, NSInteger index, NSInteger activeIndex))predicate {
  NativeDocument *active = self.activeDocument;
  NSArray<NSTabViewItem *> *items = [self.tabView.tabViewItems copy];
  NSInteger activeIndex = [items indexOfObject:self.tabItems[active.identifier]];
  NSMutableArray *targets = [NSMutableArray array];
  [items enumerateObjectsUsingBlock:^(NSTabViewItem *item, NSUInteger index, BOOL *stop) {
    (void)stop;
    NativeDocument *document = [self documentWithIdentifier:item.identifier];
    if (document && predicate(document, (NSInteger)index, activeIndex)) [targets addObject:document];
  }];
  for (NativeDocument *document in targets) {
    if (![self closeDocumentFromParity:document]) return;
  }
  if ([self documentWithIdentifier:active.identifier]) [self selectDocument:active];
}

- (BOOL)closeDocumentFromParity:(NativeDocument *)document {
  BOOL (*closeImp)(id, SEL, NativeDocument *) = (BOOL (*)(id, SEL, NativeDocument *))[self methodForSelector:@selector(closeDocument:)];
  return closeImp(self, @selector(closeDocument:), document);
}

- (void)closeAllButPinned:(id)sender {
  (void)sender;
  [self closeDocumentsMatching:^BOOL(NativeDocument *document, NSInteger index, NSInteger activeIndex) {
    (void)index; (void)activeIndex;
    return ![self.pinnedDocuments containsObject:document.identifier];
  }];
}

- (void)closeAllToTheLeft:(id)sender {
  (void)sender;
  [self closeDocumentsMatching:^BOOL(NativeDocument *document, NSInteger index, NSInteger activeIndex) {
    (void)document;
    return index < activeIndex;
  }];
}

- (void)closeAllToTheRight:(id)sender {
  (void)sender;
  [self closeDocumentsMatching:^BOOL(NativeDocument *document, NSInteger index, NSInteger activeIndex) {
    (void)document;
    return index > activeIndex;
  }];
}

- (void)moveToTrash:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  if (!document.fileURL) return;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = [NSString stringWithFormat:@"Move \"%@\" to the Trash?", document.fileURL.lastPathComponent];
  alert.informativeText = @"The tab will be closed. You can restore the file from the Trash.";
  [alert addButtonWithTitle:@"Move to Trash"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  NSError *error = nil;
  if (![[NSFileManager defaultManager] trashItemAtURL:document.fileURL resultingItemURL:nil error:&error]) {
    [self showError:error];
    return;
  }
  [document.editor message:SCI_SETSAVEPOINT];
  document.dirty = NO;
  [self closeDocumentFromParity:document];
}

// Session files use Notepad++'s XML layout, so sessions can be exchanged with it.
- (void)saveSession:(id)sender {
  (void)sender;
  NSSavePanel *panel = [NSSavePanel savePanel];
  panel.nameFieldStringValue = @"session.xml";
  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    if (response != NSModalResponseOK || !panel.URL) return;
    NSXMLElement *files = [NSXMLElement elementWithName:@"mainView"];
    NSInteger activeIndex = 0, index = 0;
    for (NSTabViewItem *item in self.tabView.tabViewItems) {
      NativeDocument *document = [self documentWithIdentifier:item.identifier];
      if (!document.fileURL) continue;
      if (document == self.activeDocument) activeIndex = index;
      NSXMLElement *file = [NSXMLElement elementWithName:@"File"];
      [file addAttribute:[NSXMLNode attributeWithName:@"firstVisibleLine" stringValue:[NSString stringWithFormat:@"%ld", [document.editor getGeneralProperty:SCI_GETFIRSTVISIBLELINE]]]];
      [file addAttribute:[NSXMLNode attributeWithName:@"lang" stringValue:document.languageDefinition.name]];
      [file addAttribute:[NSXMLNode attributeWithName:@"filename" stringValue:document.fileURL.path]];
      [files addChild:file];
      index += 1;
    }
    [files addAttribute:[NSXMLNode attributeWithName:@"activeIndex" stringValue:[NSString stringWithFormat:@"%ld", (long)activeIndex]]];
    NSXMLElement *session = [NSXMLElement elementWithName:@"Session"];
    [session addAttribute:[NSXMLNode attributeWithName:@"activeView" stringValue:@"0"]];
    [session addChild:files];
    [session addChild:[NSXMLElement elementWithName:@"subView"]];
    NSXMLElement *root = [NSXMLElement elementWithName:@"NotepadPlus"];
    [root addChild:session];
    NSXMLDocument *xml = [NSXMLDocument documentWithRootElement:root];
    xml.characterEncoding = @"UTF-8";
    NSError *error = nil;
    if (![[xml XMLDataWithOptions:NSXMLNodePrettyPrint] writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) [self showError:error];
  }];
}

- (void)loadSession:(id)sender {
  (void)sender;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    if (response != NSModalResponseOK || !panel.URL) return;
    NSError *error = nil;
    NSXMLDocument *xml = [[NSXMLDocument alloc] initWithContentsOfURL:panel.URL options:0 error:&error];
    NSArray<NSXMLNode *> *names = [xml nodesForXPath:@"//Session/*/File/@filename" error:&error];
    if (!names.count) {
      [self showErrorMessage:@"That file isn't a Notepad++ session."];
      return;
    }
    for (NSXMLNode *name in names) {
      if ([[NSFileManager defaultManager] fileExistsAtPath:name.stringValue]) [self openURL:[NSURL fileURLWithPath:name.stringValue]];
    }
  }];
}

- (void)printNow:(id)sender {
  (void)sender;
  objc_setAssociatedObject(self, @selector(printNow:), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [self printDocument:nil];
  objc_setAssociatedObject(self, @selector(printNow:), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Edit

- (void)beginEndSelect:(id)sender {
  ScintillaView *editor = self.activeEditor;
  NSNumber *mark = self.toolObjects[@"beginSelect"];
  long position = [editor getGeneralProperty:SCI_GETCURRENTPOS];
  if (!mark) {
    self.toolObjects[@"beginSelect"] = @(position);
    self.toolObjects[@"beginSelectColumn"] = @([sender tag] == 1);
    [self setStatus:@"Begin/End Select: move the caret and choose the command again"];
    return;
  }
  [self.toolObjects removeObjectForKey:@"beginSelect"];
  if ([self.toolObjects[@"beginSelectColumn"] boolValue]) {
    [editor setGeneralProperty:SCI_SETSELECTIONMODE value:SC_SEL_RECTANGLE];
    [editor setGeneralProperty:SCI_SETRECTANGULARSELECTIONANCHOR value:mark.longValue];
    [editor setGeneralProperty:SCI_SETRECTANGULARSELECTIONCARET value:position];
  } else {
    [editor setGeneralProperty:SCI_SETSEL parameter:mark.longValue value:position];
  }
}

- (void)beginEndSelectColumn:(id)sender {
  (void)sender;
  NSMenuItem *marker = [[NSMenuItem alloc] init];
  marker.tag = 1;
  [self beginEndSelect:marker];
}

- (void)insertCustomDateTime:(id)sender {
  (void)sender;
  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  formatter.dateFormat = [[NSUserDefaults standardUserDefaults] stringForKey:@"NativeEditor.DateTimeFormat"] ?: @"yyyy-MM-dd HH:mm:ss";
  [self insertIntoEditor:[formatter stringFromDate:[NSDate date]]];
}

- (void)copyStringToPasteboard:(NSString *)string {
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:string forType:NSPasteboardTypeString];
}

- (void)copyDirectoryPath:(id)sender {
  (void)sender;
  NSString *path = self.activeDocument.fileURL.URLByDeletingLastPathComponent.path;
  if (path) [self copyStringToPasteboard:path];
}

- (void)copyAllFileNames:(id)sender {
  (void)sender;
  NSMutableArray *names = [NSMutableArray array];
  for (NSTabViewItem *item in self.tabView.tabViewItems) {
    NativeDocument *document = [self documentWithIdentifier:item.identifier];
    [names addObject:document.fileURL.lastPathComponent ?: document.name];
  }
  [self copyStringToPasteboard:[names componentsJoinedByString:@"\n"]];
}

- (void)copyAllFilePaths:(id)sender {
  (void)sender;
  NSMutableArray *paths = [NSMutableArray array];
  for (NSTabViewItem *item in self.tabView.tabViewItems) {
    NativeDocument *document = [self documentWithIdentifier:item.identifier];
    [paths addObject:document.fileURL.path ?: document.name];
  }
  [self copyStringToPasteboard:[paths componentsJoinedByString:@"\n"]];
}

// "Blend" variants change only the first letter and leave the rest as typed.
- (void)properCaseBlend:(id)sender {
  (void)sender;
  [self replaceSelectionWith:^NSString *(NSString *text) {
    NSMutableString *result = [text mutableCopy];
    __block BOOL atWordStart = YES;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
      (void)enclosing; (void)stop;
      BOOL letter = [character rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet].location != NSNotFound;
      if (letter && atWordStart) [result replaceCharactersInRange:range withString:character.uppercaseString];
      atWordStart = !letter && ![character isEqualToString:@"'"];
    }];
    return result;
  }];
}

- (void)sentenceCaseBlend:(id)sender {
  (void)sender;
  [self replaceSelectionWith:^NSString *(NSString *text) {
    NSMutableString *result = [text mutableCopy];
    __block BOOL capitalize = YES;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
      (void)enclosing; (void)stop;
      if (capitalize && [character rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound) {
        [result replaceCharactersInRange:range withString:character.uppercaseString];
        capitalize = NO;
      } else if ([@".!?" containsString:character]) {
        capitalize = YES;
      }
    }];
    return result;
  }];
}

- (void)splitLines:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  if (![self requireWritable]) return;
  long edge = [editor getGeneralProperty:SCI_GETEDGECOLUMN];
  long width = edge > 0 ? edge * [editor message:SCI_TEXTWIDTH wParam:STYLE_DEFAULT lParam:(sptr_t)"0"] : 0;
  [editor message:SCI_TARGETFROMSELECTION];
  [editor message:SCI_LINESSPLIT wParam:(uptr_t)width];
}

- (void)sortLinesBy:(NSMenuItem *)sender {
  NSString *kind = sender.representedObject[@"kind"];
  BOOL ascending = [sender.representedObject[@"ascending"] boolValue];
  ScintillaView *editor = self.activeEditor;
  if (![self requireWritable]) return;
  long selectionStart = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long selectionEnd = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  long firstLine = 0, lastLine = [editor getGeneralProperty:SCI_GETLINECOUNT] - 1;
  if (selectionEnd > selectionStart) {
    firstLine = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:selectionStart];
    lastLine = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:selectionEnd];
    if (lastLine > firstLine && selectionEnd == [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:lastLine]) lastLine -= 1;
  }
  long start = [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:firstLine];
  long end = [editor getGeneralProperty:SCI_GETLINEENDPOSITION parameter:lastLine];
  long mode = [editor getGeneralProperty:SCI_GETEOLMODE];
  NSString *eol = mode == SC_EOL_CRLF ? @"\r\n" : mode == SC_EOL_CR ? @"\r" : @"\n";
  NSString *text = [[RangeText(editor, start, end) stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                    stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
  NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
  NSComparisonResult (^numeric)(NSString *, NSString *, NSString *) = ^NSComparisonResult(NSString *left, NSString *right, NSString *separator) {
    NSString *(^normalize)(NSString *) = ^NSString *(NSString *value) {
      NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      if ([separator isEqualToString:@","]) {
        trimmed = [[trimmed stringByReplacingOccurrencesOfString:@"." withString:@""] stringByReplacingOccurrencesOfString:@"," withString:@"."];
      } else {
        trimmed = [trimmed stringByReplacingOccurrencesOfString:@"," withString:@""];
      }
      return trimmed;
    };
    double a = normalize(left).doubleValue, b = normalize(right).doubleValue;
    return a < b ? NSOrderedAscending : a > b ? NSOrderedDescending : NSOrderedSame;
  };
  NSArray *sorted = [lines sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSString *left, NSString *right) {
    NSComparisonResult result;
    if ([kind isEqualToString:@"lexi"]) result = [left caseInsensitiveCompare:right];
    else if ([kind isEqualToString:@"locale"]) result = [left localizedCompare:right];
    else if ([kind isEqualToString:@"int"]) {
      long long a = [left stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].longLongValue;
      long long b = [right stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].longLongValue;
      result = a < b ? NSOrderedAscending : a > b ? NSOrderedDescending : NSOrderedSame;
    } else if ([kind isEqualToString:@"comma"]) result = numeric(left, right, @",");
    else if ([kind isEqualToString:@"dot"]) result = numeric(left, right, @".");
    else if ([kind isEqualToString:@"length"]) result = left.length < right.length ? NSOrderedAscending : left.length > right.length ? NSOrderedDescending : NSOrderedSame;
    else result = [left compare:right];
    return ascending ? result : (NSComparisonResult)(-result);
  }];
  NSString *replacement = [sorted componentsJoinedByString:eol];
  [editor message:SCI_BEGINUNDOACTION];
  ReplaceText(editor, start, end, replacement);
  [editor message:SCI_ENDUNDOACTION];
  [self setStatus:[NSString stringWithFormat:@"Sorted %lu lines", (unsigned long)lines.count]];
}

// mode: 1 comment, 2 uncomment
- (void)applyLineComment:(int)mode {
  ScintillaView *editor = self.activeEditor;
  NSString *prefix = self.activeDocument.languageDefinition.lineComment;
  if (!prefix) {
    if (mode == 1) [self blockComment:nil]; else [self blockUncomment:nil];
    return;
  }
  if (![self requireWritable]) return;
  long selectionStart = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long selectionEnd = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  long firstLine = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:selectionStart];
  long lastLine = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:selectionEnd];
  if (lastLine > firstLine && selectionEnd == [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:lastLine]) lastLine -= 1;
  long prefixLength = (long)[prefix lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  NSString *insertion = [prefix stringByAppendingString:@" "];
  [editor message:SCI_BEGINUNDOACTION];
  for (long line = lastLine; line >= firstLine; line -= 1) {
    long indent = [editor getGeneralProperty:SCI_GETLINEINDENTPOSITION parameter:line];
    long end = [editor getGeneralProperty:SCI_GETLINEENDPOSITION parameter:line];
    if (indent == end) continue;
    BOOL commented = [RangeText(editor, indent, MIN(end, indent + prefixLength)) isEqualToString:prefix];
    if (mode == 1) {
      [editor message:SCI_INSERTTEXT wParam:(uptr_t)indent lParam:(sptr_t)insertion.UTF8String];
    } else if (commented) {
      long length = prefixLength;
      if (indent + length < end && [editor getGeneralProperty:SCI_GETCHARAT parameter:indent + length] == ' ') length += 1;
      [editor setGeneralProperty:SCI_DELETERANGE parameter:indent value:length];
    }
  }
  [editor message:SCI_ENDUNDOACTION];
}

- (void)singleLineComment:(id)sender {
  (void)sender;
  [self applyLineComment:1];
}

- (void)singleLineUncomment:(id)sender {
  (void)sender;
  [self applyLineComment:2];
}

- (BOOL)blockDelimiters:(NSString **)open close:(NSString **)close {
  NativeLanguage *language = self.activeDocument.languageDefinition;
  *open = language.blockCommentStart;
  *close = language.blockCommentEnd;
  if (*open && *close) return YES;
  [self setStatus:[NSString stringWithFormat:@"%@ has no block comment syntax", language.name]];
  return NO;
}

- (void)blockComment:(id)sender {
  (void)sender;
  NSString *open = nil, *close = nil;
  if (![self blockDelimiters:&open close:&close] || ![self requireWritable]) return;
  ScintillaView *editor = self.activeEditor;
  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  if (start == end) {
    long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:start];
    start = [editor getGeneralProperty:SCI_GETLINEINDENTPOSITION parameter:line];
    end = [editor getGeneralProperty:SCI_GETLINEENDPOSITION parameter:line];
  }
  NSString *text = [NSString stringWithFormat:@"%@%@%@", open, RangeText(editor, start, end), close];
  [editor message:SCI_BEGINUNDOACTION];
  ReplaceText(editor, start, end, text);
  [editor message:SCI_ENDUNDOACTION];
}

- (void)blockUncomment:(id)sender {
  (void)sender;
  NSString *open = nil, *close = nil;
  if (![self blockDelimiters:&open close:&close] || ![self requireWritable]) return;
  ScintillaView *editor = self.activeEditor;
  // Find the comment surrounding the caret (or selection).
  long caret = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long length = [editor getGeneralProperty:SCI_GETLENGTH];
  NSData *openData = [open dataUsingEncoding:NSUTF8StringEncoding], *closeData = [close dataUsingEncoding:NSUTF8StringEncoding];
  [editor setGeneralProperty:SCI_SETSEARCHFLAGS value:SCFIND_MATCHCASE];
  [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:MIN(length, caret + (long)openData.length) value:0];
  long openAt = [editor message:SCI_SEARCHINTARGET wParam:openData.length lParam:(sptr_t)openData.bytes];
  if (openAt < 0) {
    [self setStatus:@"Block Uncomment: no block comment around the caret"];
    return;
  }
  [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:openAt + (long)openData.length value:length];
  long closeAt = [editor message:SCI_SEARCHINTARGET wParam:closeData.length lParam:(sptr_t)closeData.bytes];
  if (closeAt < 0 || closeAt + (long)closeData.length < caret) {
    [self setStatus:@"Block Uncomment: no block comment around the caret"];
    return;
  }
  [editor message:SCI_BEGINUNDOACTION];
  [editor setGeneralProperty:SCI_DELETERANGE parameter:closeAt value:(long)closeData.length];
  [editor setGeneralProperty:SCI_DELETERANGE parameter:openAt value:(long)openData.length];
  [editor message:SCI_ENDUNDOACTION];
}

- (void)showCompletionList:(NSArray<NSString *> *)words typed:(long)typed {
  ScintillaView *editor = self.activeEditor;
  if (!words.count) {
    [self setStatus:@"No completion available"];
    return;
  }
  NSString *list = [[[NSOrderedSet orderedSetWithArray:words].array sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)] componentsJoinedByString:@" "];
  [editor setGeneralProperty:SCI_AUTOCSETSEPARATOR value:' '];
  [editor message:SCI_AUTOCSHOW wParam:(uptr_t)typed lParam:(sptr_t)list.UTF8String];
}

- (NSString *)typedWordPrefix:(long *)typed {
  ScintillaView *editor = self.activeEditor;
  long position = [editor getGeneralProperty:SCI_GETCURRENTPOS];
  long start = [editor getGeneralProperty:SCI_WORDSTARTPOSITION parameter:position extra:1];
  *typed = position - start;
  return RangeText(editor, start, position);
}

- (void)functionCompletion:(id)sender {
  (void)sender;
  long typed = 0;
  NSString *prefix = [self typedWordPrefix:&typed].lowercaseString;
  NSMutableArray *words = [NSMutableArray array];
  for (NSString *set in self.activeDocument.languageDefinition.keywordSets) {
    for (NSString *word in [set componentsSeparatedByString:@" "]) {
      if (word.length && (!prefix.length || [word.lowercaseString hasPrefix:prefix])) [words addObject:word];
    }
  }
  [self showCompletionList:words typed:typed];
}

- (void)wordCompletion:(id)sender {
  (void)sender;
  long typed = 0;
  NSString *prefix = [self typedWordPrefix:&typed];
  NSString *text = self.activeEditor.string;
  NSString *pattern = [NSString stringWithFormat:@"(?<![\\w])%@[\\w]+", [NSRegularExpression escapedPatternForString:prefix]];
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
  NSMutableArray *words = [NSMutableArray array];
  [regex enumerateMatchesInString:text options:0 range:NSMakeRange(0, MIN(text.length, (NSUInteger)2000000))
                       usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
    (void)flags;
    NSString *word = [text substringWithRange:match.range];
    if (![word isEqualToString:prefix]) [words addObject:word];
    if (words.count > 2000) *stop = YES;
  }];
  [self showCompletionList:words typed:typed];
}

- (void)functionParametersHint:(id)sender {
  (void)sender;
  [self setStatus:@"Function parameter hints need an API definition file, which this language doesn't have yet"];
}

- (void)pathCompletion:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  long position = [editor getGeneralProperty:SCI_GETCURRENTPOS];
  long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:position];
  NSString *before = RangeText(editor, [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:line], position);
  NSRange space = [before rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\"'<>("] options:NSBackwardsSearch];
  NSString *typedPath = space.location == NSNotFound ? before : [before substringFromIndex:NSMaxRange(space)];
  NSString *expanded = typedPath.stringByExpandingTildeInPath;
  if (![expanded hasPrefix:@"/"]) {
    NSString *base = self.activeDocument.fileURL.URLByDeletingLastPathComponent.path ?: NSHomeDirectory();
    expanded = [base stringByAppendingPathComponent:expanded];
  }
  NSString *directory = [typedPath hasSuffix:@"/"] || !typedPath.length ? expanded : expanded.stringByDeletingLastPathComponent;
  NSString *partial = [typedPath hasSuffix:@"/"] || !typedPath.length ? @"" : typedPath.lastPathComponent;
  NSMutableArray *entries = [NSMutableArray array];
  for (NSString *entry in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil]) {
    if ([entry hasPrefix:@"."] && ![partial hasPrefix:@"."]) continue;
    if (partial.length && ![entry.lowercaseString hasPrefix:partial.lowercaseString]) continue;
    if ([entry containsString:@" "]) continue;
    [entries addObject:entry];
  }
  [self showCompletionList:entries typed:(long)[partial lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
}

- (void)trimBothAndEolToSpace:(id)sender {
  [self trimBothWhitespace:sender];
  [self eolToSpace:sender];
}

- (void)pasteHTMLContent:(id)sender {
  (void)sender;
  NSString *html = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeHTML];
  if (html) [self insertIntoEditor:html];
  else [self setStatus:@"The clipboard has no HTML content"];
}

- (void)pasteRTFContent:(id)sender {
  (void)sender;
  NSData *rtf = [NSPasteboard.generalPasteboard dataForType:NSPasteboardTypeRTF];
  NSString *text = rtf ? [[NSString alloc] initWithData:rtf encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:rtf encoding:NSMacOSRomanStringEncoding] : nil;
  if (text) [self insertIntoEditor:text];
  else [self setStatus:@"The clipboard has no RTF content"];
}

- (NSURL *)urlForSelectedPath {
  NSString *path = [[self wordOrSelection] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\r\n\"'<>"]];
  if (!path.length) return nil;
  path = path.stringByExpandingTildeInPath;
  if (![path hasPrefix:@"/"]) {
    NSString *base = self.activeDocument.fileURL.URLByDeletingLastPathComponent.path ?: NSHomeDirectory();
    path = [base stringByAppendingPathComponent:path];
  }
  return [[NSFileManager defaultManager] fileExistsAtPath:path] ? [NSURL fileURLWithPath:path] : nil;
}

- (void)openFileFromSelection:(id)sender {
  (void)sender;
  NSURL *url = [self urlForSelectedPath];
  if (url) [self openURL:url];
  else [self setStatus:@"Open File: the selection isn't the path of an existing file"];
}

- (void)openContainingFolderOfSelection:(id)sender {
  (void)sender;
  NSURL *url = [self urlForSelectedPath];
  if (url) [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
  else [self setStatus:@"The selection isn't the path of an existing file"];
}

- (void)redactSelection:(id)sender {
  (void)sender;
  BOOL dots = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) != 0;
  [self replaceSelectionWith:^NSString *(NSString *text) {
    NSMutableString *result = [NSMutableString stringWithCapacity:text.length];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
      (void)range; (void)enclosing; (void)stop;
      BOOL keep = [character rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound;
      [result appendString:keep ? character : (dots ? @"●" : @"█")];
    }];
    return result;
  }];
}

- (NSDictionary<NSString *, NSString *> *)searchEngines {
  return @{@"Google": @"https://www.google.com/search?q=%@", @"DuckDuckGo": @"https://duckduckgo.com/?q=%@",
           @"Bing": @"https://www.bing.com/search?q=%@", @"Yahoo!": @"https://search.yahoo.com/search?p=%@",
           @"Stack Overflow": @"https://stackoverflow.com/search?q=%@"};
}

- (void)searchOnInternet:(id)sender {
  (void)sender;
  NSString *word = [[self wordOrSelection] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!word.length) {
    [self setStatus:@"Select a word to search for"];
    return;
  }
  NSString *urlTemplate = [[NSUserDefaults standardUserDefaults] stringForKey:@"NativeEditor.SearchEngine"] ?: self.searchEngines[@"Google"];
  NSString *encoded = [word stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
  NSURL *url = [NSURL URLWithString:[urlTemplate stringByReplacingOccurrencesOfString:@"%@" withString:encoded]];
  if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)changeSearchEngine:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Search Engine";
  alert.informativeText = @"Used by On Selection > Search on Internet. A custom URL uses %@ where the search text goes.";
  NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 360, 26) pullsDown:NO];
  NSArray *names = [self.searchEngines.allKeys sortedArrayUsingSelector:@selector(compare:)];
  [popup addItemsWithTitles:names];
  [popup addItemWithTitle:@"Custom…"];
  NSString *current = [[NSUserDefaults standardUserDefaults] stringForKey:@"NativeEditor.SearchEngine"] ?: self.searchEngines[@"Google"];
  for (NSString *name in names) if ([self.searchEngines[name] isEqualToString:current]) [popup selectItemWithTitle:name];
  alert.accessoryView = popup;
  [alert addButtonWithTitle:@"OK"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  NSString *urlTemplate = self.searchEngines[popup.titleOfSelectedItem];
  if (!urlTemplate) {
    NSAlert *custom = [[NSAlert alloc] init];
    custom.messageText = @"Custom search URL";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 360, 24)];
    field.stringValue = current;
    custom.accessoryView = field;
    [custom addButtonWithTitle:@"OK"];
    [custom addButtonWithTitle:@"Cancel"];
    if ([custom runModal] != NSAlertFirstButtonReturn || ![field.stringValue containsString:@"%@"]) return;
    urlTemplate = field.stringValue;
  }
  [[NSUserDefaults standardUserDefaults] setObject:urlTemplate forKey:@"NativeEditor.SearchEngine"];
}

- (long)multiSelectFlags:(NSInteger)tag {
  return [@[@0, @(SCFIND_MATCHCASE), @(SCFIND_WHOLEWORD), @(SCFIND_MATCHCASE | SCFIND_WHOLEWORD)][MAX(0, MIN(3, tag))] longValue];
}

- (void)prepareMultiSelect:(ScintillaView *)editor tag:(NSInteger)tag {
  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  if (start == end) {
    [editor setGeneralProperty:SCI_SETSEL parameter:[editor getGeneralProperty:SCI_WORDSTARTPOSITION parameter:start extra:1]
                         value:[editor getGeneralProperty:SCI_WORDENDPOSITION parameter:start extra:1]];
  }
  [editor setGeneralProperty:SCI_SETSEARCHFLAGS value:[self multiSelectFlags:tag]];
  [editor message:SCI_TARGETWHOLEDOCUMENT];
}

- (void)multiSelectAll:(NSMenuItem *)sender {
  ScintillaView *editor = self.activeEditor;
  [self prepareMultiSelect:editor tag:sender.tag];
  [editor message:SCI_MULTIPLESELECTADDEACH];
  [self setStatus:[NSString stringWithFormat:@"%ld selections", [editor getGeneralProperty:SCI_GETSELECTIONS]]];
}

- (void)multiSelectNext:(NSMenuItem *)sender {
  ScintillaView *editor = self.activeEditor;
  [self prepareMultiSelect:editor tag:sender.tag];
  [editor message:SCI_MULTIPLESELECTADDNEXT];
}

- (void)undoLatestMultiSelect:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  if ([editor getGeneralProperty:SCI_GETSELECTIONS] > 1) {
    [editor setGeneralProperty:SCI_DROPSELECTIONN value:[editor getGeneralProperty:SCI_GETMAINSELECTION]];
  }
}

- (void)skipCurrentMultiSelect:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  long previous = [editor getGeneralProperty:SCI_GETMAINSELECTION];
  long count = [editor getGeneralProperty:SCI_GETSELECTIONS];
  [editor message:SCI_TARGETWHOLEDOCUMENT];
  [editor message:SCI_MULTIPLESELECTADDNEXT];
  if ([editor getGeneralProperty:SCI_GETSELECTIONS] > count) [editor setGeneralProperty:SCI_DROPSELECTIONN value:previous];
}

- (void)showColumnModeInfo:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Column Mode";
  alert.informativeText = @"Hold Option and drag with the mouse to select a column (rectangular) block.\n\n"
                          @"With the keyboard, hold Option+Shift and use the arrow keys.\n\n"
                          @"Type to edit every line of the block at once, or use Edit > Column Editor to insert text or numbers.";
  [alert runModal];
}

- (void)readOnlyAllDocuments:(id)sender {
  (void)sender;
  for (NativeDocument *document in self.documents) document.readOnly = YES;
}

- (void)clearReadOnlyAllDocuments:(id)sender {
  (void)sender;
  for (NativeDocument *document in self.documents) {
    if (![self.monitoredDocuments containsObject:document.identifier]) document.readOnly = NO;
  }
}

// The Unix equivalent of Windows' read-only attribute: the owner write permission.
- (void)toggleReadOnlyAttribute:(id)sender {
  (void)sender;
  NSString *path = self.activeDocument.fileURL.path;
  if (!path) return;
  NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  NSUInteger permissions = [attributes[NSFilePosixPermissions] unsignedIntegerValue];
  NSUInteger updated = (permissions & S_IWUSR) ? (permissions & ~(NSUInteger)(S_IWUSR | S_IWGRP | S_IWOTH)) : (permissions | S_IWUSR);
  NSError *error = nil;
  if (![[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(updated)} ofItemAtPath:path error:&error]) [self showError:error];
  else [self setStatus:(updated & S_IWUSR) ? @"File is writable" : @"File is now read-only on disk"];
}

#pragma mark - Search

- (void)selectAndFind:(BOOL)forward {
  ScintillaView *editor = self.activeEditor;
  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  if (start == end) {
    start = [editor getGeneralProperty:SCI_WORDSTARTPOSITION parameter:start extra:1];
    end = [editor getGeneralProperty:SCI_WORDENDPOSITION parameter:end extra:1];
    [editor setGeneralProperty:SCI_SETSEL parameter:start value:end];
  }
  NSString *word = RangeText(editor, start, end);
  if (!word.length) return;
  self.searchField.stringValue = word;
  self.normalModeButton.state = NSControlStateValueOn;
  if (forward) [self findNext:nil]; else [self findPrevious:nil];
}

- (void)selectAndFindNext:(id)sender {
  (void)sender;
  [self selectAndFind:YES];
}

- (void)selectAndFindPrevious:(id)sender {
  (void)sender;
  [self selectAndFind:NO];
}

// Volatile find uses the word at the caret without changing the Find dialog's text.
- (void)volatileFind:(BOOL)forward {
  NSString *saved = self.searchField.stringValue;
  NSControlStateValue regex = self.regexButton.state, extended = self.extendedButton.state, normal = self.normalModeButton.state;
  ScintillaView *editor = self.activeEditor;
  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  if (start == end) {
    start = [editor getGeneralProperty:SCI_WORDSTARTPOSITION parameter:start extra:1];
    end = [editor getGeneralProperty:SCI_WORDENDPOSITION parameter:end extra:1];
    [editor setGeneralProperty:SCI_SETSEL parameter:start value:end];
  }
  self.searchField.stringValue = RangeText(editor, start, end);
  self.normalModeButton.state = NSControlStateValueOn;
  self.regexButton.state = NSControlStateValueOff;
  self.extendedButton.state = NSControlStateValueOff;
  if (forward) [self findNext:nil]; else [self findPrevious:nil];
  self.searchField.stringValue = saved;
  self.regexButton.state = regex;
  self.extendedButton.state = extended;
  self.normalModeButton.state = normal;
}

- (void)volatileFindNext:(id)sender {
  (void)sender;
  [self volatileFind:YES];
}

- (void)volatileFindPrevious:(id)sender {
  (void)sender;
  [self volatileFind:NO];
}

- (void)moveSearchResultBy:(NSInteger)delta {
  if (!self.searchResults.count) {
    [self setStatus:@"No search results"];
    return;
  }
  NSInteger row = self.resultsTable.selectedRow + delta;
  row = (row + (NSInteger)self.searchResults.count) % (NSInteger)self.searchResults.count;
  [self.resultsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
  [self.resultsTable scrollRowToVisible:row];
  [self openSelectedSearchResult:nil];
}

- (void)nextSearchResult:(id)sender {
  (void)sender;
  [self moveSearchResultBy:1];
}

- (void)previousSearchResult:(id)sender {
  (void)sender;
  [self moveSearchResultBy:-1];
}

- (void)goToChange:(BOOL)forward {
  ScintillaView *editor = self.activeEditor;
  long mask = (1L << SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN) | (1L << SC_MARKNUM_HISTORY_SAVED) |
              (1L << SC_MARKNUM_HISTORY_MODIFIED) | (1L << SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED);
  long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:[editor getGeneralProperty:SCI_GETCURRENTPOS]];
  long count = [editor getGeneralProperty:SCI_GETLINECOUNT];
  long step = forward ? 1 : -1;
  long probe = line;
  // Skip the change block the caret is in, then find the next one.
  while (probe >= 0 && probe < count && ([editor getGeneralProperty:SCI_MARKERGET parameter:probe] & mask)) probe += step;
  while (probe >= 0 && probe < count && !([editor getGeneralProperty:SCI_MARKERGET parameter:probe] & mask)) probe += step;
  if (probe < 0 || probe >= count) {
    [self setStatus:@"No more changes"];
    NSBeep();
    return;
  }
  if (!forward) {
    while (probe > 0 && ([editor getGeneralProperty:SCI_MARKERGET parameter:probe - 1] & mask)) probe -= 1;
  }
  [editor setGeneralProperty:SCI_ENSUREVISIBLEENFORCEPOLICY value:probe];
  [editor setGeneralProperty:SCI_GOTOLINE value:probe];
}

- (void)goToNextChange:(id)sender {
  (void)sender;
  [self goToChange:YES];
}

- (void)goToPreviousChange:(id)sender {
  (void)sender;
  [self goToChange:NO];
}

- (void)clearChangeHistory:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Clear Change History?";
  alert.informativeText = @"This also clears the undo history of the current document.";
  [alert addButtonWithTitle:@"Clear"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  ScintillaView *editor = self.activeDocument.editor;
  [editor setGeneralProperty:SCI_SETCHANGEHISTORY value:SC_CHANGE_HISTORY_DISABLED];
  [editor message:SCI_EMPTYUNDOBUFFER];
  [editor setGeneralProperty:SCI_SETCHANGEHISTORY value:SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS];
}

- (void)configureTokenStyles:(ScintillaView *)editor {
  NSArray<NSNumber *> *colors = @[@0xFFFF00, @0x0080FF, @0x00FFFF, @0xFF0080, @0x008000];  // BGR, like Notepad++'s five styles
  for (int index = 0; index < 5; index += 1) {
    int indicator = kTokenStyleIndicatorBase + index;
    [editor setGeneralProperty:SCI_INDICSETSTYLE parameter:indicator value:INDIC_ROUNDBOX];
    [editor setGeneralProperty:SCI_INDICSETFORE parameter:indicator value:colors[index].longValue];
    [editor setGeneralProperty:SCI_INDICSETALPHA parameter:indicator value:110];
    [editor setGeneralProperty:SCI_INDICSETOUTLINEALPHA parameter:indicator value:200];
    [editor setGeneralProperty:SCI_INDICSETUNDER parameter:indicator value:1];
  }
}

- (void)styleToken:(NSInteger)style all:(BOOL)all {
  ScintillaView *editor = self.activeEditor;
  [self configureTokenStyles:editor];
  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  if (start == end) {
    start = [editor getGeneralProperty:SCI_WORDSTARTPOSITION parameter:start extra:1];
    end = [editor getGeneralProperty:SCI_WORDENDPOSITION parameter:end extra:1];
  }
  if (end <= start) return;
  int indicator = kTokenStyleIndicatorBase + (int)style - 1;
  [editor setGeneralProperty:SCI_SETINDICATORCURRENT value:indicator];
  if (!all) {
    [editor setGeneralProperty:SCI_INDICATORFILLRANGE parameter:start value:end - start];
    return;
  }
  std::string token(end - start, '\0');
  [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:start value:end];
  [editor message:SCI_GETTARGETTEXT wParam:0 lParam:(sptr_t)token.data()];
  [editor setGeneralProperty:SCI_SETSEARCHFLAGS value:SCFIND_MATCHCASE];
  long position = 0, length = [editor getGeneralProperty:SCI_GETLENGTH];
  NSInteger count = 0;
  while (position < length) {
    [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:position value:length];
    long found = [editor message:SCI_SEARCHINTARGET wParam:token.size() lParam:(sptr_t)token.data()];
    if (found < 0) break;
    long foundEnd = [editor getGeneralProperty:SCI_GETTARGETEND];
    [editor setGeneralProperty:SCI_SETINDICATORCURRENT value:indicator];
    [editor setGeneralProperty:SCI_INDICATORFILLRANGE parameter:found value:foundEnd - found];
    position = MAX(foundEnd, found + 1);
    count += 1;
  }
  [self setStatus:[NSString stringWithFormat:@"Styled %ld occurrences", (long)count]];
}

- (void)styleAllOccurrences:(NSMenuItem *)sender {
  [self styleToken:sender.tag all:YES];
}

- (void)styleOneToken:(NSMenuItem *)sender {
  [self styleToken:sender.tag all:NO];
}

- (void)clearStyle:(NSMenuItem *)sender {
  ScintillaView *editor = self.activeEditor;
  long length = [editor getGeneralProperty:SCI_GETLENGTH];
  for (NSInteger style = 1; style <= 5; style += 1) {
    if (sender.tag && sender.tag != style) continue;
    [editor setGeneralProperty:SCI_SETINDICATORCURRENT value:kTokenStyleIndicatorBase + style - 1];
    [editor setGeneralProperty:SCI_INDICATORCLEARRANGE parameter:0 value:length];
  }
}

- (int)indicatorForStyleTag:(NSInteger)tag {
  return tag == 6 ? kNativeMarkIndicator : kTokenStyleIndicatorBase + (int)tag - 1;
}

- (void)jumpToStyle:(NSInteger)tag forward:(BOOL)forward {
  ScintillaView *editor = self.activeEditor;
  int indicator = [self indicatorForStyleTag:tag];
  long length = [editor getGeneralProperty:SCI_GETLENGTH];
  long position = forward ? [editor getGeneralProperty:SCI_GETSELECTIONEND] : [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  for (int pass = 0; pass < 2; pass += 1) {
    if (forward) {
      while (position < length) {
        if ([editor getGeneralProperty:SCI_INDICATORVALUEAT parameter:indicator extra:position]) {
          long end = [editor getGeneralProperty:SCI_INDICATOREND parameter:indicator extra:position];
          [editor setGeneralProperty:SCI_SETSEL parameter:position value:end];
          [editor message:SCI_SCROLLCARET];
          return;
        }
        long next = [editor getGeneralProperty:SCI_INDICATOREND parameter:indicator extra:position];
        position = next > position ? next : position + 1;
      }
      position = 0;
    } else {
      while (position > 0) {
        long probe = position - 1;
        if ([editor getGeneralProperty:SCI_INDICATORVALUEAT parameter:indicator extra:probe]) {
          long start = [editor getGeneralProperty:SCI_INDICATORSTART parameter:indicator extra:probe];
          [editor setGeneralProperty:SCI_SETSEL parameter:start value:position];
          [editor message:SCI_SCROLLCARET];
          return;
        }
        long previous = [editor getGeneralProperty:SCI_INDICATORSTART parameter:indicator extra:probe];
        position = previous < position ? previous : position - 1;
      }
      position = length;
    }
  }
  [self setStatus:@"No styled text found"];
  NSBeep();
}

- (void)jumpUpToStyle:(NSMenuItem *)sender {
  [self jumpToStyle:sender.tag forward:NO];
}

- (void)jumpDownToStyle:(NSMenuItem *)sender {
  [self jumpToStyle:sender.tag forward:YES];
}

- (void)copyStyledText:(NSMenuItem *)sender {
  ScintillaView *editor = self.activeEditor;
  NSMutableArray<NSNumber *> *indicators = [NSMutableArray array];
  if (sender.tag == 0) for (int index = 0; index < 5; index += 1) [indicators addObject:@(kTokenStyleIndicatorBase + index)];
  else [indicators addObject:@([self indicatorForStyleTag:sender.tag])];
  long length = [editor getGeneralProperty:SCI_GETLENGTH];
  NSMutableArray *pieces = [NSMutableArray array];
  long position = 0;
  while (position < length) {
    long next = length;
    BOOL styled = NO;
    for (NSNumber *indicator in indicators) {
      long end = [editor getGeneralProperty:SCI_INDICATOREND parameter:indicator.intValue extra:position];
      if ([editor getGeneralProperty:SCI_INDICATORVALUEAT parameter:indicator.intValue extra:position]) {
        styled = YES;
        next = MIN(next, end);
      } else if (end > position) {
        next = MIN(next, end);
      }
    }
    if (next <= position) next = position + 1;
    if (styled) [pieces addObject:RangeText(editor, position, next)];
    position = next;
  }
  [self copyStringToPasteboard:[pieces componentsJoinedByString:@"\n"]];
  [self setStatus:[NSString stringWithFormat:@"Copied %lu styled pieces", (unsigned long)pieces.count]];
}

- (NSIndexSet *)bookmarkedLines:(ScintillaView *)editor {
  NSMutableIndexSet *lines = [NSMutableIndexSet indexSet];
  long mask = 1L << kNativeBookmarkMarker;
  long line = [editor getGeneralProperty:SCI_MARKERNEXT parameter:0 extra:mask];
  while (line >= 0) {
    [lines addIndex:(NSUInteger)line];
    line = [editor getGeneralProperty:SCI_MARKERNEXT parameter:line + 1 extra:mask];
  }
  return lines;
}

- (void)cutBookmarkedLines:(id)sender {
  if (![self requireWritable]) return;
  [self copyBookmarkedLines:sender];
  [self removeBookmarkedLines:sender];
}

- (void)pasteToBookmarkedLines:(id)sender {
  (void)sender;
  if (![self requireWritable]) return;
  NSString *clip = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
  if (!clip) return;
  ScintillaView *editor = self.activeEditor;
  NSIndexSet *lines = [self bookmarkedLines:editor];
  [editor message:SCI_BEGINUNDOACTION];
  [lines enumerateIndexesWithOptions:NSEnumerationReverse usingBlock:^(NSUInteger line, BOOL *stop) {
    (void)stop;
    ReplaceText(editor, [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:(long)line],
                [editor getGeneralProperty:SCI_GETLINEENDPOSITION parameter:(long)line], clip);
  }];
  [editor message:SCI_ENDUNDOACTION];
}

- (void)findCharactersInRange:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Find characters in range";
  NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 96)];
  NSButton *nonAscii = [NSButton radioButtonWithTitle:@"Non-ASCII characters (128-255)" target:self action:@selector(searchModeChanged:)];
  NSButton *ascii = [NSButton radioButtonWithTitle:@"ASCII characters (0-127)" target:self action:@selector(searchModeChanged:)];
  NSButton *custom = [NSButton radioButtonWithTitle:@"My range:" target:self action:@selector(searchModeChanged:)];
  nonAscii.frame = NSMakeRect(0, 72, 300, 20);
  ascii.frame = NSMakeRect(0, 48, 300, 20);
  custom.frame = NSMakeRect(0, 24, 90, 20);
  nonAscii.state = NSControlStateValueOn;
  NSTextField *from = [NSTextField textFieldWithString:@"128"];
  NSTextField *to = [NSTextField textFieldWithString:@"255"];
  from.frame = NSMakeRect(96, 22, 70, 22);
  to.frame = NSMakeRect(176, 22, 70, 22);
  for (NSView *view in @[nonAscii, ascii, custom, from, to]) [box addSubview:view];
  alert.accessoryView = box;
  [alert addButtonWithTitle:@"Find Next"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  unichar low = 128, high = 255;
  if (ascii.state == NSControlStateValueOn) { low = 0; high = 127; }
  if (custom.state == NSControlStateValueOn) { low = (unichar)MAX(0, from.intValue); high = (unichar)MAX(from.intValue, to.intValue); }
  ScintillaView *editor = self.activeEditor;
  NSString *text = editor.string;
  long caretBytes = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  long caretChars = [editor getGeneralProperty:SCI_COUNTCHARACTERS parameter:0 extra:caretBytes];
  NSUInteger index = 0, codePoints = 0;
  for (; index < text.length; index += 1) {
    unichar ch = [text characterAtIndex:index];
    if (CFStringIsSurrogateLowCharacter(ch)) continue;
    if ((long)codePoints >= caretChars && ch >= low && ch <= high) {
      long position = [editor getGeneralProperty:SCI_POSITIONRELATIVE parameter:0 extra:(long)codePoints];
      [editor setGeneralProperty:SCI_SETSEL parameter:position value:[editor getGeneralProperty:SCI_POSITIONAFTER parameter:position]];
      [editor message:SCI_SCROLLCARET];
      return;
    }
    codePoints += 1;
  }
  [self setStatus:@"No character in that range after the caret"];
  NSBeep();
}

#pragma mark - Incremental search

- (NSView *)buildIncrementalSearchBar {
  NSSearchField *field = [[NSSearchField alloc] initWithFrame:NSZeroRect];
  field.placeholderString = @"Find";
  field.sendsSearchStringImmediately = YES;
  field.target = self;
  field.action = @selector(incrementalSearchChanged:);
  field.delegate = (id<NSSearchFieldDelegate>)self;
  NSButton *previous = [NSButton buttonWithTitle:@"<" target:self action:@selector(incrementalPrevious:)];
  NSButton *next = [NSButton buttonWithTitle:@">" target:self action:@selector(incrementalNext:)];
  NSButton *highlight = [NSButton checkboxWithTitle:@"Highlight all" target:self action:@selector(incrementalSearchChanged:)];
  NSButton *matchCase = [NSButton checkboxWithTitle:@"Match case" target:self action:@selector(incrementalSearchChanged:)];
  NSTextField *status = [NSTextField labelWithString:@""];
  status.textColor = NSColor.secondaryLabelColor;
  NSButton *close = [NSButton buttonWithTitle:@"✕" target:self action:@selector(toggleIncrementalSearch:)];
  close.bordered = NO;
  NSStackView *bar = [NSStackView stackViewWithViews:@[close, [NSTextField labelWithString:@"Find :"], field, previous, next, highlight, matchCase, status]];
  bar.spacing = 6;
  bar.edgeInsets = NSEdgeInsetsMake(3, 6, 3, 6);
  bar.hidden = YES;
  [field.widthAnchor constraintEqualToConstant:240].active = YES;
  self.toolObjects[@"incField"] = field;
  self.toolObjects[@"incHighlight"] = highlight;
  self.toolObjects[@"incMatchCase"] = matchCase;
  self.toolObjects[@"incStatus"] = status;
  self.toolObjects[@"incBar"] = bar;
  return bar;
}

- (void)toggleIncrementalSearch:(id)sender {
  (void)sender;
  NSView *bar = self.toolObjects[@"incBar"];
  bar.hidden = !bar.hidden;
  NSLayoutConstraint *height = self.toolObjects[@"incHeight"];
  height.constant = bar.hidden ? 0 : 30;
  if (!bar.hidden) {
    self.toolObjects[@"incStart"] = @([self.activeEditor getGeneralProperty:SCI_GETSELECTIONSTART]);
    [self.window makeFirstResponder:self.toolObjects[@"incField"]];
  } else {
    [self clearMarks:nil];
    [self.window makeFirstResponder:self.activeEditor.content];
  }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
  (void)textView;
  if (control != self.toolObjects[@"incField"]) return NO;
  if (command == @selector(cancelOperation:)) {
    [self toggleIncrementalSearch:nil];
    return YES;
  }
  if (command == @selector(insertNewline:)) {
    BOOL backwards = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) != 0;
    if (backwards) [self incrementalPrevious:nil]; else [self incrementalNext:nil];
    return YES;
  }
  return NO;
}

- (void)incrementalFind:(BOOL)forward fromStart:(BOOL)fromStart {
  NSSearchField *field = self.toolObjects[@"incField"];
  NSTextField *status = self.toolObjects[@"incStatus"];
  ScintillaView *editor = self.activeEditor;
  NSData *pattern = [field.stringValue dataUsingEncoding:NSUTF8StringEncoding];
  BOOL matchCase = [self.toolObjects[@"incMatchCase"] state] == NSControlStateValueOn;
  long flags = matchCase ? SCFIND_MATCHCASE : 0;
  long length = [editor getGeneralProperty:SCI_GETLENGTH];
  [editor setGeneralProperty:SCI_SETINDICATORCURRENT value:kNativeMarkIndicator];
  [editor setGeneralProperty:SCI_INDICATORCLEARRANGE parameter:0 value:length];
  if (!pattern.length) {
    status.stringValue = @"";
    return;
  }
  [editor setGeneralProperty:SCI_SETSEARCHFLAGS value:flags];
  long from = fromStart ? [self.toolObjects[@"incStart"] longValue]
                        : (forward ? [editor getGeneralProperty:SCI_GETSELECTIONEND] : [editor getGeneralProperty:SCI_GETSELECTIONSTART]);
  [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:from value:forward ? length : 0];
  long found = [editor message:SCI_SEARCHINTARGET wParam:pattern.length lParam:(sptr_t)pattern.bytes];
  BOOL wrapped = NO;
  if (found < 0) {
    [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:forward ? 0 : length value:from];
    found = [editor message:SCI_SEARCHINTARGET wParam:pattern.length lParam:(sptr_t)pattern.bytes];
    wrapped = found >= 0;
  }
  if (found < 0) {
    status.stringValue = @"Phrase not found";
    status.textColor = NSColor.systemRedColor;
    return;
  }
  long end = [editor getGeneralProperty:SCI_GETTARGETEND];
  [editor setGeneralProperty:SCI_SETSEL parameter:found value:end];
  [editor message:SCI_SCROLLCARET];
  status.textColor = NSColor.secondaryLabelColor;
  status.stringValue = wrapped ? @"Reached the end of the page, continued from the top" : @"";
  if ([self.toolObjects[@"incHighlight"] state] == NSControlStateValueOn) {
    long position = 0;
    NSInteger count = 0;
    while (position < length) {
      [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:position value:length];
      long hit = [editor message:SCI_SEARCHINTARGET wParam:pattern.length lParam:(sptr_t)pattern.bytes];
      if (hit < 0) break;
      long hitEnd = [editor getGeneralProperty:SCI_GETTARGETEND];
      [editor setGeneralProperty:SCI_SETINDICATORCURRENT value:kNativeMarkIndicator];
      [editor setGeneralProperty:SCI_INDICATORFILLRANGE parameter:hit value:hitEnd - hit];
      position = MAX(hitEnd, hit + 1);
      count += 1;
    }
    status.stringValue = [NSString stringWithFormat:@"%ld matches%@", (long)count, wrapped ? @" (wrapped)" : @""];
  }
}

- (void)incrementalSearchChanged:(id)sender {
  (void)sender;
  [self incrementalFind:YES fromStart:YES];
}

- (void)incrementalNext:(id)sender {
  (void)sender;
  [self incrementalFind:YES fromStart:NO];
}

- (void)incrementalPrevious:(id)sender {
  (void)sender;
  [self incrementalFind:NO fromStart:NO];
}

#pragma mark - View

// Post-It hides the toolbar, tab bar and status bar and floats the window; F12 toggles it.
- (void)setChromeHidden:(BOOL)hidden {
  for (NSView *view in @[self.toolbarView, self.toolbarLine]) view.hidden = hidden;
  self.editorTopConstraint.active = !hidden;
  self.editorTopCompactConstraint.active = hidden;
  self.tabBar.hidden = hidden;
  self.tabBarHeightConstraint.constant = hidden ? 0 : 28;
  self.statusBar.hidden = hidden;
  self.statusBarHeightConstraint.constant = hidden ? 0 : 22;
}

- (void)togglePostIt:(id)sender {
  (void)sender;
  BOOL enable = ![self.toolObjects[@"postIt"] boolValue];
  self.toolObjects[@"postIt"] = @(enable);
  [self setChromeHidden:enable];
  self.window.level = enable ? NSFloatingWindowLevel : NSNormalWindowLevel;
}

- (void)toggleDistractionFree:(id)sender {
  (void)sender;
  BOOL enable = ![self.toolObjects[@"distractionFree"] boolValue];
  self.toolObjects[@"distractionFree"] = @(enable);
  [self setChromeHidden:enable];
  BOOL fullScreen = (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
  if (enable != fullScreen) [self.window toggleFullScreen:nil];
  if (enable) {
    self.toolObjects[@"dfmPanels"] = @[@(self.projectPane.hidden), @(self.sidePanel.hidden)];
    self.projectPane.hidden = YES;
    self.sidePanel.hidden = YES;
  } else if (self.toolObjects[@"dfmPanels"]) {
    self.projectPane.hidden = [self.toolObjects[@"dfmPanels"][0] boolValue];
    self.sidePanel.hidden = [self.toolObjects[@"dfmPanels"][1] boolValue];
  }
  [self.workspaceSplit adjustSubviews];
  // Center a comfortable text column, as Notepad++ does in Distraction Free Mode.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    for (NativeDocument *document in self.documents) {
      ScintillaView *editor = document.editor;
      long character = [editor message:SCI_TEXTWIDTH wParam:STYLE_DEFAULT lParam:(sptr_t)"0"];
      long margin = enable ? MAX(0L, ((long)NSWidth(editor.bounds) - character * 110) / 2) : 1;
      [editor setGeneralProperty:SCI_SETMARGINLEFT value:margin];
      [editor setGeneralProperty:SCI_SETMARGINRIGHT value:enable ? margin : 1];
    }
  });
}

- (void)viewInBrowser:(NSMenuItem *)sender {
  NSURL *url = self.activeDocument.fileURL;
  if (!url) {
    [self setStatus:@"Save the file first to view it in a browser"];
    return;
  }
  NSURL *browser = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:sender.representedObject];
  if (!browser) {
    [self setStatus:[NSString stringWithFormat:@"%@ isn't installed", sender.title]];
    return;
  }
  [[NSWorkspace sharedWorkspace] openURLs:@[url] withApplicationAtURL:browser configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
}

- (void)moveToOtherView:(id)sender {
  [self toggleSplitView:sender];
  [self setStatus:@"Shown in a second view beside the first"];
}

- (void)launchNewInstanceWith:(NSURL *)url {
  NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
  configuration.createsNewApplicationInstance = YES;
  configuration.arguments = @[@"-NativeEditorNoSession", @"YES"];
  [[NSWorkspace sharedWorkspace] openURLs:@[url] withApplicationAtURL:NSBundle.mainBundle.bundleURL configuration:configuration completionHandler:nil];
}

- (BOOL)documentCanMoveToInstance:(NativeDocument *)document {
  if (document.fileURL && !document.isDirty) return YES;
  [self showErrorMessage:@"Save the document first. Only saved files without unsaved changes can move to another instance."];
  return NO;
}

- (void)moveToNewInstance:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  if (![self documentCanMoveToInstance:document]) return;
  [self launchNewInstanceWith:document.fileURL];
  [self closeDocumentFromParity:document];
}

- (void)openInNewInstance:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  if ([self documentCanMoveToInstance:document]) [self launchNewInstanceWith:document.fileURL];
}

- (void)selectTabNumber:(NSMenuItem *)sender {
  if (sender.tag < self.tabView.numberOfTabViewItems) [self.tabView selectTabViewItemAtIndex:sender.tag];
}

- (void)selectFirstTab:(id)sender {
  (void)sender;
  if (self.tabView.numberOfTabViewItems) [self.tabView selectTabViewItemAtIndex:0];
}

- (void)selectLastTab:(id)sender {
  (void)sender;
  if (self.tabView.numberOfTabViewItems) [self.tabView selectTabViewItemAtIndex:self.tabView.numberOfTabViewItems - 1];
}

- (void)moveActiveTabTo:(NSInteger)target {
  NSTabViewItem *item = self.tabView.selectedTabViewItem;
  NSInteger from = [self.tabView indexOfTabViewItem:item];
  target = MAX(0, MIN(target, self.tabView.numberOfTabViewItems - 1));
  if (!item || from == target) return;
  [self.tabView removeTabViewItem:item];
  [self.tabView insertTabViewItem:item atIndex:target];
  [self.tabView selectTabViewItem:item];
  NativeDocument *document = self.documents[from];
  [self.documents removeObjectAtIndex:from];
  [self.documents insertObject:document atIndex:target];
  [self.tabBar reload];
  [self scheduleSessionPersistence];
}

- (NSInteger)activeTabIndex {
  return [self.tabView indexOfTabViewItem:self.tabView.selectedTabViewItem];
}

- (void)moveTabToStart:(id)sender {
  (void)sender;
  [self moveActiveTabTo:(NSInteger)self.pinnedDocuments.count];
}

- (void)moveTabToEnd:(id)sender {
  (void)sender;
  [self moveActiveTabTo:self.tabView.numberOfTabViewItems - 1];
}

- (void)moveTabForward:(id)sender {
  (void)sender;
  [self moveActiveTabTo:[self activeTabIndex] + 1];
}

- (void)moveTabBackward:(id)sender {
  (void)sender;
  [self moveActiveTabTo:[self activeTabIndex] - 1];
}

- (void)applyTabColor:(NSMenuItem *)sender {
  NativeDocument *document = self.activeDocument;
  if (!document) return;
  if (sender.tag) self.tabColors[document.identifier] = @(sender.tag);
  else [self.tabColors removeObjectForKey:document.identifier];
  [self.tabBar reload];
  [self scheduleSessionPersistence];
}

- (void)togglePinTab:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  if (!document) return;
  if ([self.pinnedDocuments containsObject:document.identifier]) {
    [self.pinnedDocuments removeObject:document.identifier];
    [self moveActiveTabTo:(NSInteger)self.pinnedDocuments.count];
  } else {
    [self moveActiveTabTo:(NSInteger)self.pinnedDocuments.count];
    [self.pinnedDocuments addObject:document.identifier];
  }
  [self.tabBar reload];
  [self scheduleSessionPersistence];
}

- (void)focusOnAnotherView:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  if (!document.secondaryEditor) {
    [self setStatus:@"There is no other view. Use View > Move/Clone Current Document first."];
    return;
  }
  ScintillaView *target = self.activeEditor == document.editor ? document.secondaryEditor : document.editor;
  [self.window makeFirstResponder:target.content];
}

- (void)hideLines:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  long first = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:[editor getGeneralProperty:SCI_GETSELECTIONSTART]];
  long last = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:[editor getGeneralProperty:SCI_GETSELECTIONEND]];
  if (first == 0 && last == 0) return;
  [editor setGeneralProperty:SCI_HIDELINES parameter:MAX(1L, first) value:last];
  [self setStatus:@"Lines hidden. View > Show Hidden Lines brings them back."];
}

- (void)showHiddenLines:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  [editor setGeneralProperty:SCI_SHOWLINES parameter:0 value:[editor getGeneralProperty:SCI_GETLINECOUNT] - 1];
}

- (void)foldCurrent:(long)action {
  ScintillaView *editor = self.activeEditor;
  long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:[editor getGeneralProperty:SCI_GETCURRENTPOS]];
  if (!([editor getGeneralProperty:SCI_GETFOLDLEVEL parameter:line] & SC_FOLDLEVELHEADERFLAG)) {
    line = [editor getGeneralProperty:SCI_GETFOLDPARENT parameter:line];
  }
  if (line >= 0) [editor setGeneralProperty:SCI_FOLDLINE parameter:line value:action];
}

- (void)foldCurrentLevel:(id)sender {
  (void)sender;
  [self foldCurrent:SC_FOLDACTION_CONTRACT];
}

- (void)unfoldCurrentLevel:(id)sender {
  (void)sender;
  [self foldCurrent:SC_FOLDACTION_EXPAND];
}

- (void)foldToLevel:(NSInteger)level action:(long)action {
  ScintillaView *editor = self.activeEditor;
  [editor message:SCI_COLOURISE wParam:0 lParam:-1];
  long count = [editor getGeneralProperty:SCI_GETLINECOUNT];
  for (long line = 0; line < count; line += 1) {
    long value = [editor getGeneralProperty:SCI_GETFOLDLEVEL parameter:line];
    if (!(value & SC_FOLDLEVELHEADERFLAG)) continue;
    if ((value & SC_FOLDLEVELNUMBERMASK) - SC_FOLDLEVELBASE == level - 1) {
      [editor setGeneralProperty:SCI_FOLDLINE parameter:line value:action];
    }
  }
}

- (void)foldLevel:(NSMenuItem *)sender {
  [self foldToLevel:sender.tag action:SC_FOLDACTION_CONTRACT];
}

- (void)unfoldLevel:(NSMenuItem *)sender {
  [self foldToLevel:sender.tag action:SC_FOLDACTION_EXPAND];
}

- (void)toggleSyncVerticalScrolling:(id)sender {
  (void)sender;
  self.toolObjects[@"syncV"] = @(![self.toolObjects[@"syncV"] boolValue]);
}

- (void)toggleSyncHorizontalScrolling:(id)sender {
  (void)sender;
  self.toolObjects[@"syncH"] = @(![self.toolObjects[@"syncH"] boolValue]);
}

// Called on every editor update; keeps the two views of a split aligned when enabled.
- (void)syncScrollingForDocument:(NativeDocument *)document {
  if (!document.secondaryEditor) return;
  BOOL vertical = [self.toolObjects[@"syncV"] boolValue], horizontal = [self.toolObjects[@"syncH"] boolValue];
  if (!vertical && !horizontal) return;
  ScintillaView *source = self.activeEditor;
  ScintillaView *target = source == document.editor ? document.secondaryEditor : document.editor;
  if (vertical) [target setGeneralProperty:SCI_SETFIRSTVISIBLELINE value:[source getGeneralProperty:SCI_GETFIRSTVISIBLELINE]];
  if (horizontal) [target setGeneralProperty:SCI_SETXOFFSET value:[source getGeneralProperty:SCI_GETXOFFSET]];
}

- (void)textDirectionRTL:(id)sender {
  (void)sender;
  [self.activeEditor setGeneralProperty:SCI_SETBIDIRECTIONAL value:SC_BIDIRECTIONAL_R2L];
  if ([self.activeEditor getGeneralProperty:SCI_GETBIDIRECTIONAL] != SC_BIDIRECTIONAL_R2L) {
    [self setStatus:@"Right-to-left layout isn't supported by the macOS editing component"];
  }
}

- (void)textDirectionLTR:(id)sender {
  (void)sender;
  [self.activeEditor setGeneralProperty:SCI_SETBIDIRECTIONAL value:SC_BIDIRECTIONAL_L2R];
}

#pragma mark - Document list panel

- (void)toggleDocumentList:(id)sender {
  (void)sender;
  NSScrollView *pane = self.toolObjects[@"docListPane"];
  if (!pane) {
    NativeBlockTable *source = [[NativeBlockTable alloc] init];
    __weak NativeEditorController *weakSelf = self;
    source.count = ^NSInteger { return weakSelf.tabView.numberOfTabViewItems; };
    source.value = ^id(NSInteger row, NSString *column) {
      NativeDocument *document = [weakSelf documentWithIdentifier:weakSelf.tabView.tabViewItems[row].identifier];
      NSString *name = document.fileURL.lastPathComponent ?: document.name;
      if ([column isEqualToString:@"ext"]) return name.pathExtension;
      return [NSString stringWithFormat:@"%@%@", document.isDirty ? @"* " : @"", name.stringByDeletingPathExtension.length ? name.stringByDeletingPathExtension : name];
    };
    NSTableView *table = MakeTable(@[@[@"name", @"Name", @170], @[@"ext", @"Ext.", @50]], source);
    table.target = self;
    table.action = @selector(documentListClicked:);
    pane = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 250, 200)];
    pane.hasVerticalScroller = YES;
    pane.documentView = table;
    pane.hidden = YES;
    self.toolObjects[@"docListSource"] = source;
    self.toolObjects[@"docListTable"] = table;
    self.toolObjects[@"docListPane"] = pane;
    [self.sidePanel insertArrangedSubview:pane atIndex:0];
    [pane.heightAnchor constraintGreaterThanOrEqualToConstant:80].active = YES;
  }
  pane.hidden = !pane.hidden;
  self.sidePanel.hidden = pane.hidden && self.functionListPane.hidden && self.documentMap.hidden;
  [self.sidePanel adjustSubviews];
  [self.workspaceSplit adjustSubviews];
  [self refreshDocumentList];
}

- (void)refreshDocumentList {
  NSScrollView *pane = self.toolObjects[@"docListPane"];
  if (!pane || pane.hidden) return;
  NSTableView *table = self.toolObjects[@"docListTable"];
  [table reloadData];
  NSInteger index = [self activeTabIndex];
  if (index >= 0) [table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)index] byExtendingSelection:NO];
}

- (void)documentListClicked:(NSTableView *)sender {
  if (sender.clickedRow >= 0 && sender.clickedRow < self.tabView.numberOfTabViewItems) {
    [self.tabView selectTabViewItemAtIndex:sender.clickedRow];
  }
}

#pragma mark - Project panels

- (void)toggleProjectPanel:(NSMenuItem *)sender {
  NSString *key = [NSString stringWithFormat:@"project%ld", (long)sender.tag];
  NSPanel *panel = self.toolObjects[key];
  if (panel) {
    if (panel.isVisible) [panel orderOut:nil]; else [panel makeKeyAndOrderFront:nil];
    return;
  }
  NSString *defaultsKey = [NSString stringWithFormat:@"NativeEditor.ProjectPanel%ld", (long)sender.tag];
  NSMutableArray<NSString *> *files = [[[NSUserDefaults standardUserDefaults] arrayForKey:defaultsKey] mutableCopy] ?: [NSMutableArray array];
  panel = MakeToolPanel([NSString stringWithFormat:@"Project Panel %ld", (long)sender.tag], NSMakeSize(320, 420));
  NativeBlockTable *source = [[NativeBlockTable alloc] init];
  source.count = ^NSInteger { return (NSInteger)files.count; };
  source.value = ^id(NSInteger row, NSString *column) {
    return [column isEqualToString:@"name"] ? files[row].lastPathComponent : files[row].stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath;
  };
  NSTableView *table = MakeTable(@[@[@"name", @"File", @130], @[@"folder", @"Folder", @170]], source);
  table.allowsMultipleSelection = YES;
  table.target = self;
  table.doubleAction = @selector(projectPanelOpen:);
  objc_setAssociatedObject(table, "files", files, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(table, "key", defaultsKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 36, 320, 384)];
  scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scroll.hasVerticalScroller = YES;
  scroll.documentView = table;
  [panel.contentView addSubview:scroll];
  CGFloat x = 6;
  for (NSArray *button in @[@[@"Add Files…", NSStringFromSelector(@selector(projectPanelAddFiles:))],
                            @[@"Add Current", NSStringFromSelector(@selector(projectPanelAddCurrent:))],
                            @[@"Remove", NSStringFromSelector(@selector(projectPanelRemove:))]]) {
    NSButton *control = [NSButton buttonWithTitle:button[0] target:self action:NSSelectorFromString(button[1])];
    control.controlSize = NSControlSizeSmall;
    [control sizeToFit];
    control.frame = NSMakeRect(x, 6, NSWidth(control.frame) + 8, 24);
    objc_setAssociatedObject(control, "table", table, OBJC_ASSOCIATION_ASSIGN);
    [panel.contentView addSubview:control];
    x += NSWidth(control.frame) + 4;
  }
  self.toolObjects[key] = panel;
  self.toolObjects[[key stringByAppendingString:@"Source"]] = source;
  [panel makeKeyAndOrderFront:nil];
}

- (void)saveProjectTable:(NSTableView *)table {
  [[NSUserDefaults standardUserDefaults] setObject:objc_getAssociatedObject(table, "files") forKey:objc_getAssociatedObject(table, "key")];
  [table reloadData];
}

- (void)projectPanelOpen:(NSTableView *)sender {
  NSMutableArray *files = objc_getAssociatedObject(sender, "files");
  if (sender.clickedRow >= 0) [self openURL:[NSURL fileURLWithPath:files[sender.clickedRow]]];
}

- (void)projectPanelAddFiles:(NSButton *)sender {
  NSTableView *table = objc_getAssociatedObject(sender, "table");
  NSOpenPanel *open = [NSOpenPanel openPanel];
  open.allowsMultipleSelection = YES;
  if ([open runModal] != NSModalResponseOK) return;
  NSMutableArray *files = objc_getAssociatedObject(table, "files");
  for (NSURL *url in open.URLs) if (![files containsObject:url.path]) [files addObject:url.path];
  [self saveProjectTable:table];
}

- (void)projectPanelAddCurrent:(NSButton *)sender {
  NSTableView *table = objc_getAssociatedObject(sender, "table");
  NSString *path = self.activeDocument.fileURL.path;
  NSMutableArray *files = objc_getAssociatedObject(table, "files");
  if (path && ![files containsObject:path]) [files addObject:path];
  [self saveProjectTable:table];
}

- (void)projectPanelRemove:(NSButton *)sender {
  NSTableView *table = objc_getAssociatedObject(sender, "table");
  NSMutableArray *files = objc_getAssociatedObject(table, "files");
  [files removeObjectsAtIndexes:table.selectedRowIndexes];
  [self saveProjectTable:table];
}

#pragma mark - Character panel and clipboard history

- (void)toggleCharacterPanel:(id)sender {
  (void)sender;
  NSPanel *panel = self.toolObjects[@"charPanel"];
  if (panel) {
    if (panel.isVisible) [panel orderOut:nil]; else [panel orderFront:nil];
    return;
  }
  panel = MakeToolPanel(@"Character Panel", NSMakeSize(360, 480));
  NativeBlockTable *source = [[NativeBlockTable alloc] init];
  NSString *(^character)(NSInteger) = ^NSString *(NSInteger value) {
    if (value < 32) return @[@"NUL", @"SOH", @"STX", @"ETX", @"EOT", @"ENQ", @"ACK", @"BEL", @"BS", @"TAB", @"LF", @"VT", @"FF", @"CR", @"SO", @"SI",
                             @"DLE", @"DC1", @"DC2", @"DC3", @"DC4", @"NAK", @"SYN", @"ETB", @"CAN", @"EM", @"SUB", @"ESC", @"FS", @"GS", @"RS", @"US"][value];
    if (value == 127) return @"DEL";
    uint8_t byte = (uint8_t)value;
    return [[NSString alloc] initWithBytes:&byte length:1 encoding:NSWindowsCP1252StringEncoding] ?: @"";
  };
  source.count = ^NSInteger { return 256; };
  source.value = ^id(NSInteger row, NSString *column) {
    if ([column isEqualToString:@"value"]) return @(row);
    if ([column isEqualToString:@"hex"]) return [NSString stringWithFormat:@"%02lX", (long)row];
    if ([column isEqualToString:@"html"]) return row >= 32 ? [NSString stringWithFormat:@"&#%ld;", (long)row] : @"";
    return character(row);
  };
  NSTableView *table = MakeTable(@[@[@"value", @"Value", @60], @[@"hex", @"Hex", @50], @[@"char", @"Character", @100], @[@"html", @"HTML Number", @110]], source);
  table.target = self;
  table.doubleAction = @selector(characterPanelInsert:);
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:panel.contentView.bounds];
  scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scroll.hasVerticalScroller = YES;
  scroll.documentView = table;
  [panel.contentView addSubview:scroll];
  self.toolObjects[@"charPanel"] = panel;
  self.toolObjects[@"charSource"] = source;
  [panel orderFront:nil];
}

- (void)characterPanelInsert:(NSTableView *)sender {
  NSInteger row = sender.clickedRow;
  if (row < 0) return;
  uint8_t byte = (uint8_t)row;
  NSString *text = row < 128 ? [NSString stringWithFormat:@"%c", (char)row]
                             : [[NSString alloc] initWithBytes:&byte length:1 encoding:NSWindowsCP1252StringEncoding];
  if (text) [self insertIntoEditor:text];
  [self.window makeKeyWindow];
}

- (NSMutableArray<NSString *> *)clipboardEntries {
  NSMutableArray *entries = self.toolObjects[@"clipEntries"];
  if (!entries) {
    entries = [NSMutableArray array];
    self.toolObjects[@"clipEntries"] = entries;
  }
  return entries;
}

- (void)startClipboardMonitoring {
  __weak NativeEditorController *weakSelf = self;
  NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
    (void)t;
    NativeEditorController *strongSelf = weakSelf;
    NSInteger change = NSPasteboard.generalPasteboard.changeCount;
    if (change == [strongSelf.toolObjects[@"clipChange"] integerValue]) return;
    strongSelf.toolObjects[@"clipChange"] = @(change);
    NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (!text.length || text.length > 1000000) return;
    NSMutableArray *entries = [strongSelf clipboardEntries];
    [entries removeObject:text];
    [entries insertObject:text atIndex:0];
    if (entries.count > 30) [entries removeLastObject];
    [(NSTableView *)strongSelf.toolObjects[@"clipTable"] reloadData];
  }];
  self.toolObjects[@"clipTimer"] = timer;
}

- (void)toggleClipboardHistory:(id)sender {
  (void)sender;
  NSPanel *panel = self.toolObjects[@"clipPanel"];
  if (panel) {
    if (panel.isVisible) [panel orderOut:nil]; else [panel orderFront:nil];
    return;
  }
  panel = MakeToolPanel(@"Clipboard History", NSMakeSize(320, 400));
  NativeBlockTable *source = [[NativeBlockTable alloc] init];
  __weak NativeEditorController *weakSelf = self;
  source.count = ^NSInteger { return (NSInteger)[weakSelf clipboardEntries].count; };
  source.value = ^id(NSInteger row, NSString *column) {
    (void)column;
    NSString *entry = [weakSelf clipboardEntries][row];
    entry = [[entry stringByReplacingOccurrencesOfString:@"\n" withString:@" ⏎ "] stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
    return entry.length > 200 ? [[entry substringToIndex:200] stringByAppendingString:@"…"] : entry;
  };
  NSTableView *table = MakeTable(@[@[@"text", @"Double-click to paste", @300]], source);
  table.target = self;
  table.doubleAction = @selector(clipboardHistoryPaste:);
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:panel.contentView.bounds];
  scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scroll.hasVerticalScroller = YES;
  scroll.documentView = table;
  [panel.contentView addSubview:scroll];
  self.toolObjects[@"clipPanel"] = panel;
  self.toolObjects[@"clipSource"] = source;
  self.toolObjects[@"clipTable"] = table;
  [panel orderFront:nil];
}

- (void)clipboardHistoryPaste:(NSTableView *)sender {
  if (sender.clickedRow < 0) return;
  [self insertIntoEditor:[self clipboardEntries][sender.clickedRow]];
  [self.window makeKeyWindow];
}

#pragma mark - Encoding and language

// "Encode in": reinterpret the file's bytes with another encoding.
- (void)encodeIn:(NSMenuItem *)sender {
  NativeDocument *document = self.activeDocument;
  NSDictionary *choice = sender.representedObject;
  if (document.fileURL && !document.isDirty) {
    [self reopenWithEncoding:sender];
    return;
  }
  NSData *bytes = [document.editor.string dataUsingEncoding:document.encoding allowLossyConversion:YES];
  NSString *text = [[NSString alloc] initWithData:bytes encoding:[choice[@"encoding"] unsignedIntegerValue]];
  if (!text) {
    [self showErrorMessage:[NSString stringWithFormat:@"The text isn't valid %@.", sender.title]];
    return;
  }
  [document setText:text];
  document.encoding = [choice[@"encoding"] unsignedIntegerValue];
  document.writesBOM = [choice[@"bom"] boolValue];
  document.dirty = YES;
  [self updateDocument:document];
}

- (void)openUserLanguageFolder:(id)sender {
  (void)sender;
  NSString *folder = AppSupportFolder(@"userDefineLangs");
  NSString *readme = [folder stringByAppendingPathComponent:@"README.txt"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:readme]) {
    [@"Put language definitions here as .json files, then restart the app:\n{\"name\": \"My Language\", \"base\": \"cpp\", \"keywords\": \"foo bar baz\"}\n\"base\" is a language identifier such as cpp, python, javascript, sql or bash.\n"
        writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }
  [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:folder]];
}

- (NSArray<NSDictionary *> *)userLanguageFilesDefinitions {
  NSString *folder = AppSupportFolder(@"userDefineLangs");
  NSMutableArray *definitions = [NSMutableArray array];
  for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:nil]) {
    if (![name.pathExtension.lowercaseString isEqualToString:@"json"]) continue;
    NSData *data = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:name]];
    NSDictionary *definition = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([definition isKindOfClass:NSDictionary.class] && [definition[@"name"] isKindOfClass:NSString.class]) [definitions addObject:definition];
  }
  return definitions;
}

#pragma mark - Settings

- (NSString *)menuPathForItem:(NSMenuItem *)item {
  NSMutableArray *parts = [NSMutableArray arrayWithObject:item.title];
  NSMenu *menu = item.menu;
  while (menu.supermenu) {
    NSInteger index = [menu.supermenu indexOfItemWithSubmenu:menu];
    if (index < 0) break;
    [parts insertObject:[menu.supermenu itemAtIndex:index].title atIndex:0];
    menu = menu.supermenu;
  }
  return [parts componentsJoinedByString:@" > "];
}

- (void)collectMenuItems:(NSMenu *)menu into:(NSMutableArray<NSMenuItem *> *)items {
  for (NSMenuItem *item in menu.itemArray) {
    if (item.isSeparatorItem) continue;
    if (item.submenu) [self collectMenuItems:item.submenu into:items];
    else if (item.action) [items addObject:item];
  }
}

static NSString *ShortcutDescription(NSMenuItem *item) {
  if (!item.keyEquivalent.length) return @"";
  NSMutableString *text = [NSMutableString string];
  NSEventModifierFlags flags = item.keyEquivalentModifierMask;
  if (flags & NSEventModifierFlagControl) [text appendString:@"ctrl+"];
  if (flags & NSEventModifierFlagOption) [text appendString:@"option+"];
  if (flags & NSEventModifierFlagShift) [text appendString:@"shift+"];
  if (flags & NSEventModifierFlagCommand) [text appendString:@"cmd+"];
  NSDictionary *names = @{@"\r": @"return", @"\t": @"tab", @" ": @"space",
                          [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey]: @"up", [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey]: @"down",
                          [NSString stringWithFormat:@"%C", (unichar)NSF2FunctionKey]: @"f2", [NSString stringWithFormat:@"%C", (unichar)NSF4FunctionKey]: @"f4",
                          [NSString stringWithFormat:@"%C", (unichar)NSF12FunctionKey]: @"f12",
                          [NSString stringWithFormat:@"%C", (unichar)NSPageUpFunctionKey]: @"pageup", [NSString stringWithFormat:@"%C", (unichar)NSPageDownFunctionKey]: @"pagedown"};
  [text appendString:names[item.keyEquivalent] ?: item.keyEquivalent.lowercaseString];
  return text;
}

static BOOL ParseShortcut(NSString *text, NSString **key, NSEventModifierFlags *flags) {
  *flags = 0;
  NSArray *parts = [[text.lowercaseString stringByReplacingOccurrencesOfString:@" " withString:@""] componentsSeparatedByString:@"+"];
  NSString *last = parts.lastObject;
  for (NSString *part in [parts subarrayWithRange:NSMakeRange(0, parts.count - 1)]) {
    if ([part isEqualToString:@"cmd"] || [part isEqualToString:@"command"]) *flags |= NSEventModifierFlagCommand;
    else if ([part isEqualToString:@"shift"]) *flags |= NSEventModifierFlagShift;
    else if ([part isEqualToString:@"option"] || [part isEqualToString:@"alt"]) *flags |= NSEventModifierFlagOption;
    else if ([part isEqualToString:@"ctrl"] || [part isEqualToString:@"control"]) *flags |= NSEventModifierFlagControl;
    else return NO;
  }
  NSDictionary *names = @{@"return": @"\r", @"enter": @"\r", @"tab": @"\t", @"space": @" ",
                          @"up": [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey], @"down": [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey],
                          @"pageup": [NSString stringWithFormat:@"%C", (unichar)NSPageUpFunctionKey], @"pagedown": [NSString stringWithFormat:@"%C", (unichar)NSPageDownFunctionKey]};
  if (names[last]) *key = names[last];
  else if ([last hasPrefix:@"f"] && last.length > 1 && last.length <= 3 && [last substringFromIndex:1].integerValue > 0) {
    *key = [NSString stringWithFormat:@"%C", (unichar)(NSF1FunctionKey + [last substringFromIndex:1].integerValue - 1)];
  } else if (last.length == 1) *key = last;
  else return NO;
  return YES;
}

- (void)applyShortcutOverrides {
  NSDictionary<NSString *, NSString *> *overrides = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"NativeEditor.Shortcuts.v1"];
  if (!overrides.count) return;
  NSMutableArray<NSMenuItem *> *items = [NSMutableArray array];
  [self collectMenuItems:NSApp.mainMenu into:items];
  for (NSMenuItem *item in items) {
    NSString *shortcut = overrides[[self menuPathForItem:item]];
    if (!shortcut) continue;
    NSString *key = @"";
    NSEventModifierFlags flags = 0;
    if (shortcut.length && !ParseShortcut(shortcut, &key, &flags)) continue;
    item.keyEquivalent = key;
    item.keyEquivalentModifierMask = flags;
  }
}

- (void)showShortcutMapper:(id)sender {
  (void)sender;
  NSMutableArray<NSMenuItem *> *items = [NSMutableArray array];
  [self collectMenuItems:NSApp.mainMenu into:items];
  NSPanel *panel = MakeToolPanel(@"Shortcut Mapper", NSMakeSize(640, 520));
  panel.hidesOnDeactivate = NO;
  NativeBlockTable *source = [[NativeBlockTable alloc] init];
  NSMutableArray<NSMenuItem *> *visible = [items mutableCopy];
  source.count = ^NSInteger { return (NSInteger)visible.count; };
  __weak NativeEditorController *weakSelf = self;
  source.value = ^id(NSInteger row, NSString *column) {
    NSMenuItem *item = visible[row];
    return [column isEqualToString:@"name"] ? [weakSelf menuPathForItem:item] : ShortcutDescription(item);
  };
  NSTableView *table = MakeTable(@[@[@"name", @"Command", @430], @[@"shortcut", @"Shortcut", @170]], source);
  NSSearchField *filter = [[NSSearchField alloc] initWithFrame:NSMakeRect(8, 486, 300, 24)];
  filter.placeholderString = @"Filter";
  filter.autoresizingMask = NSViewMinYMargin;
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 40, 640, 440)];
  scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scroll.hasVerticalScroller = YES;
  scroll.documentView = table;
  NSButton *modify = [NSButton buttonWithTitle:@"Modify…" target:self action:@selector(shortcutMapperModify:)];
  NSButton *clear = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(shortcutMapperClear:)];
  NSButton *reset = [NSButton buttonWithTitle:@"Reset All" target:self action:@selector(shortcutMapperReset:)];
  modify.frame = NSMakeRect(8, 8, 100, 26);
  clear.frame = NSMakeRect(112, 8, 80, 26);
  reset.frame = NSMakeRect(196, 8, 100, 26);
  for (NSView *view in @[filter, scroll, modify, clear, reset]) [panel.contentView addSubview:view];
  objc_setAssociatedObject(filter, "apply", ^{
    [visible removeAllObjects];
    for (NSMenuItem *item in items) {
      if (!filter.stringValue.length || [[weakSelf menuPathForItem:item] localizedCaseInsensitiveContainsString:filter.stringValue]) [visible addObject:item];
    }
    [table reloadData];
  }, OBJC_ASSOCIATION_COPY_NONATOMIC);
  filter.target = self;
  filter.action = @selector(shortcutMapperFilter:);
  self.toolObjects[@"mapperPanel"] = panel;
  self.toolObjects[@"mapperSource"] = source;
  self.toolObjects[@"mapperTable"] = table;
  self.toolObjects[@"mapperVisible"] = visible;
  [panel makeKeyAndOrderFront:nil];
}

- (void)shortcutMapperFilter:(NSSearchField *)sender {
  void (^apply)(void) = objc_getAssociatedObject(sender, "apply");
  if (apply) apply();
}

- (NSMenuItem *)selectedMapperItem {
  NSTableView *table = self.toolObjects[@"mapperTable"];
  NSArray *visible = self.toolObjects[@"mapperVisible"];
  return table.selectedRow >= 0 && table.selectedRow < (NSInteger)visible.count ? visible[table.selectedRow] : nil;
}

- (void)saveShortcut:(NSString *)shortcut forItem:(NSMenuItem *)item {
  NSMutableDictionary *overrides = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"NativeEditor.Shortcuts.v1"] mutableCopy] ?: [NSMutableDictionary dictionary];
  overrides[[self menuPathForItem:item]] = shortcut;
  [[NSUserDefaults standardUserDefaults] setObject:overrides forKey:@"NativeEditor.Shortcuts.v1"];
  [self applyShortcutOverrides];
  [(NSTableView *)self.toolObjects[@"mapperTable"] reloadData];
}

- (void)shortcutMapperModify:(id)sender {
  (void)sender;
  NSMenuItem *item = [self selectedMapperItem];
  if (!item) return;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = [self menuPathForItem:item];
  alert.informativeText = @"Type a shortcut such as cmd+shift+k, ctrl+option+f, or f5.";
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
  field.stringValue = ShortcutDescription(item);
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"OK"];
  [alert addButtonWithTitle:@"Cancel"];
  alert.window.initialFirstResponder = field;
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  NSString *key = nil;
  NSEventModifierFlags flags = 0;
  if (!ParseShortcut(field.stringValue, &key, &flags)) {
    [self showErrorMessage:@"That shortcut couldn't be read. Use a form like cmd+shift+k."];
    return;
  }
  NSMutableArray<NSMenuItem *> *items = [NSMutableArray array];
  [self collectMenuItems:NSApp.mainMenu into:items];
  for (NSMenuItem *other in items) {
    if (other != item && [other.keyEquivalent isEqualToString:key] && other.keyEquivalentModifierMask == flags) {
      NSAlert *conflict = [[NSAlert alloc] init];
      conflict.messageText = @"Shortcut already in use";
      conflict.informativeText = [NSString stringWithFormat:@"%@ already uses it. Assign it anyway? The other command will lose it.", [self menuPathForItem:other]];
      [conflict addButtonWithTitle:@"Assign"];
      [conflict addButtonWithTitle:@"Cancel"];
      if ([conflict runModal] != NSAlertFirstButtonReturn) return;
      [self saveShortcut:@"" forItem:other];
    }
  }
  [self saveShortcut:field.stringValue forItem:item];
}

- (void)shortcutMapperClear:(id)sender {
  (void)sender;
  NSMenuItem *item = [self selectedMapperItem];
  if (item) [self saveShortcut:@"" forItem:item];
}

- (void)shortcutMapperReset:(id)sender {
  (void)sender;
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"NativeEditor.Shortcuts.v1"];
  [self buildMainMenu];
  [(NSPanel *)self.toolObjects[@"mapperPanel"] close];
  [self showShortcutMapper:nil];
}

// Imports a Notepad++ style theme (.xml from its "themes" folder).
- (void)importStyleTheme:(id)sender {
  (void)sender;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.allowsMultipleSelection = NO;
  if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
  NSError *error = nil;
  NSXMLDocument *xml = [[NSXMLDocument alloc] initWithContentsOfURL:panel.URL options:0 error:&error];
  if (!xml) {
    [self showError:error];
    return;
  }
  NSString *(^attribute)(NSString *, NSString *) = ^NSString *(NSString *path, NSString *name) {
    NSXMLElement *element = (NSXMLElement *)[[xml nodesForXPath:path error:nil] firstObject];
    return [element attributeForName:name].stringValue;
  };
  NSString *background = attribute(@"//GlobalStyles/WidgetStyle[@name='Default Style']", @"bgColor");
  NSString *foreground = attribute(@"//GlobalStyles/WidgetStyle[@name='Default Style']", @"fgColor");
  if (!background || !foreground) {
    [self showErrorMessage:@"That file isn't a Notepad++ style theme."];
    return;
  }
  NSMutableDictionary *overrides = [@{@"background": [@"#" stringByAppendingString:background]} mutableCopy];
  NSString *caretLine = attribute(@"//GlobalStyles/WidgetStyle[@name='Current line background colour']", @"bgColor");
  NSString *selection = attribute(@"//GlobalStyles/WidgetStyle[@name='Selected text colour']", @"bgColor");
  if (caretLine) overrides[@"caretLine"] = [@"#" stringByAppendingString:caretLine];
  if (selection) overrides[@"selection"] = [@"#" stringByAppendingString:selection];
  NSMutableDictionary *roles = [NSMutableDictionary dictionaryWithObject:@{@"color": [@"#" stringByAppendingString:foreground]} forKey:@"0"];
  NSDictionary *mapping = @{
    @"cpp/COMMENT": @(NativeStyleComment), @"cpp/NUMBER": @(NativeStyleNumber), @"cpp/INSTRUCTION WORD": @(NativeStyleKeyword),
    @"cpp/TYPE WORD": @(NativeStyleKeyword2), @"cpp/STRING": @(NativeStyleString), @"cpp/OPERATOR": @(NativeStyleOperator),
    @"cpp/PREPROCESSOR": @(NativeStylePreprocessor), @"html/TAG": @(NativeStyleTag), @"html/ATTRIBUTE": @(NativeStyleAttribute),
    @"python/CLASS NAME": @(NativeStyleType), @"php/VARIABLE": @(NativeStyleVariable), @"markdown/HEADER 1": @(NativeStyleHeading),
    @"diff/ADDED": @(NativeStyleAdded), @"diff/DELETED": @(NativeStyleDeleted), @"cpp/COMMENT LINE": @(NativeStyleComment),
  };
  [mapping enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *role, BOOL *stop) {
    (void)stop;
    NSArray *parts = [key componentsSeparatedByString:@"/"];
    NSString *path = [NSString stringWithFormat:@"//LexerType[@name='%@']/WordsStyle[@name='%@']", parts[0], parts[1]];
    NSString *color = attribute(path, @"fgColor");
    if (!color || roles[role.stringValue]) return;
    NSInteger fontStyle = attribute(path, @"fontStyle").integerValue;
    roles[role.stringValue] = @{@"color": [@"#" stringByAppendingString:color], @"bold": @((fontStyle & 1) != 0)};
  }];
  overrides[@"roles"] = roles;
  NSColor *backgroundColor = [NativeTheme colorFromHex:background];
  NSColor *rgb = [backgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  BOOL dark = (0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent) < 0.5;
  NSMutableDictionary *all = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"NativeEditor.StyleOverrides.v1"] mutableCopy] ?: [NSMutableDictionary dictionary];
  all[dark ? @"dark" : @"light"] = overrides;
  [[NSUserDefaults standardUserDefaults] setObject:all forKey:@"NativeEditor.StyleOverrides.v1"];
  self.darkTheme = dark;
  [self applyThemeToAllDocuments];
  [self savePreferences];
  [self setStatus:[NSString stringWithFormat:@"Imported theme %@", panel.URL.lastPathComponent.stringByDeletingPathExtension]];
}

#pragma mark - Tools

- (NSString *)hash:(NSString *)algorithm data:(NSData *)data {
  unsigned char digest[CC_SHA512_DIGEST_LENGTH];
  NSUInteger length = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if ([algorithm isEqualToString:@"MD5"]) { CC_MD5(data.bytes, (CC_LONG)data.length, digest); length = CC_MD5_DIGEST_LENGTH; }
#pragma clang diagnostic pop
  if ([algorithm isEqualToString:@"SHA-1"]) { CC_SHA1(data.bytes, (CC_LONG)data.length, digest); length = CC_SHA1_DIGEST_LENGTH; }
  if ([algorithm isEqualToString:@"SHA-256"]) { CC_SHA256(data.bytes, (CC_LONG)data.length, digest); length = CC_SHA256_DIGEST_LENGTH; }
  if ([algorithm isEqualToString:@"SHA-512"]) { CC_SHA512(data.bytes, (CC_LONG)data.length, digest); length = CC_SHA512_DIGEST_LENGTH; }
  NSMutableString *hex = [NSMutableString string];
  for (NSUInteger index = 0; index < length; index += 1) [hex appendFormat:@"%02x", digest[index]];
  return hex;
}

- (void)showHashResult:(NSString *)result title:(NSString *)title {
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = title;
  NSScrollView *scroll = [NSTextView scrollableTextView];
  scroll.frame = NSMakeRect(0, 0, 520, 160);
  NSTextView *text = scroll.documentView;
  text.string = result;
  text.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
  text.editable = NO;
  alert.accessoryView = scroll;
  [alert addButtonWithTitle:@"Copy to Clipboard"];
  [alert addButtonWithTitle:@"Close"];
  if ([alert runModal] == NSAlertFirstButtonReturn) [self copyStringToPasteboard:result];
}

- (void)hashGenerate:(NSMenuItem *)sender {
  NSString *algorithm = sender.representedObject;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = [algorithm stringByAppendingString:@" – Generate"];
  alert.informativeText = @"Each line gets its own hash.";
  NSScrollView *scroll = [NSTextView scrollableTextView];
  scroll.frame = NSMakeRect(0, 0, 420, 140);
  alert.accessoryView = scroll;
  [alert addButtonWithTitle:@"Generate"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  NSString *input = [(NSTextView *)scroll.documentView string];
  NSMutableArray *lines = [NSMutableArray array];
  for (NSString *line in [input componentsSeparatedByString:@"\n"]) {
    if (line.length) [lines addObject:[self hash:algorithm data:[line dataUsingEncoding:NSUTF8StringEncoding]]];
  }
  [self showHashResult:[lines componentsJoinedByString:@"\n"] title:algorithm];
}

- (void)hashFromFiles:(NSMenuItem *)sender {
  NSString *algorithm = sender.representedObject;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.allowsMultipleSelection = YES;
  if ([panel runModal] != NSModalResponseOK) return;
  NSMutableArray *lines = [NSMutableArray array];
  for (NSURL *url in panel.URLs) {
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    if (data) [lines addObject:[NSString stringWithFormat:@"%@  %@", [self hash:algorithm data:data], url.path]];
  }
  [self showHashResult:[lines componentsJoinedByString:@"\n"] title:algorithm];
}

- (void)hashSelectionToClipboard:(NSMenuItem *)sender {
  NSString *selection = [self selectedText];
  if (!selection.length) {
    [self setStatus:@"Select some text first"];
    return;
  }
  NSString *result = [self hash:sender.representedObject data:[selection dataUsingEncoding:NSUTF8StringEncoding]];
  [self copyStringToPasteboard:result];
  [self setStatus:[NSString stringWithFormat:@"%@ copied: %@", sender.representedObject, result]];
}

#pragma mark - Plugins (Converter, NppExport)

- (void)asciiToHex:(id)sender {
  (void)sender;
  [self replaceSelectionWith:^NSString *(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableString *hex = [NSMutableString string];
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    for (NSUInteger index = 0; index < data.length; index += 1) [hex appendFormat:@"%02X", bytes[index]];
    return hex;
  }];
}

- (void)hexToAscii:(id)sender {
  (void)sender;
  [self replaceSelectionWith:^NSString *(NSString *text) {
    NSString *clean = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
    if (clean.length % 2) return nil;
    NSMutableData *data = [NSMutableData data];
    for (NSUInteger index = 0; index < clean.length; index += 2) {
      unsigned int value = 0;
      if (![[NSScanner scannerWithString:[clean substringWithRange:NSMakeRange(index, 2)]] scanHexInt:&value]) return nil;
      uint8_t byte = (uint8_t)value;
      [data appendBytes:&byte length:1];
    }
    NSString *result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!result) [self setStatus:@"HEX -> ASCII: the selection isn't valid hex text"];
    return result;
  }];
}

- (NSAttributedString *)styledDocument {
  NativeDocument *document = self.activeDocument;
  ScintillaView *editor = document.editor;
  [editor message:SCI_COLOURISE wParam:0 lParam:-1];
  NativeTheme *theme = document.theme;
  NSString *fontName = [self.viewOptions[NativeViewFontName] isKindOfClass:NSString.class] ? self.viewOptions[NativeViewFontName] : @"Menlo";
  CGFloat size = [self.viewOptions[NativeViewFontSize] doubleValue] ?: 13;
  NSFont *font = [NSFont fontWithName:fontName size:size] ?: [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
  NSFont *bold = [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:NSBoldFontMask];
  NSDictionary<NSNumber *, NSNumber *> *roles = document.languageDefinition.styleRoles;
  NSMutableAttributedString *output = [[NSMutableAttributedString alloc] init];
  long length = [editor getGeneralProperty:SCI_GETLENGTH];
  long position = 0;
  while (position < length) {
    long style = [editor getGeneralProperty:SCI_GETSTYLEINDEXAT parameter:position];
    long end = position + 1;
    while (end < length && [editor getGeneralProperty:SCI_GETSTYLEINDEXAT parameter:end] == style) end += 1;
    NativeStyleRole role = (NativeStyleRole)(roles[@(style)] ?: @(NativeStyleDefault)).integerValue;
    [output appendAttributedString:[[NSAttributedString alloc] initWithString:RangeText(editor, position, end) attributes:@{
      NSFontAttributeName: [theme isBoldRole:role] ? bold : font, NSForegroundColorAttributeName: [theme colorForRole:role],
      NSBackgroundColorAttributeName: theme.background}]];
    position = end;
  }
  return output;
}

- (NSData *)exportData:(NSString *)type {
  NSAttributedString *styled = [self styledDocument];
  NSDictionary *attributes = @{NSDocumentTypeDocumentAttribute: type, NSBackgroundColorDocumentAttribute: self.activeDocument.theme.background};
  return [styled dataFromRange:NSMakeRange(0, styled.length) documentAttributes:attributes error:nil];
}

- (void)exportAs:(NSString *)type extension:(NSString *)extension {
  NSSavePanel *panel = [NSSavePanel savePanel];
  NSString *name = self.activeDocument.fileURL.lastPathComponent ?: self.activeDocument.name;
  panel.nameFieldStringValue = [name stringByAppendingPathExtension:extension];
  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    if (response != NSModalResponseOK || !panel.URL) return;
    NSError *error = nil;
    if (![[self exportData:type] writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) [self showError:error];
  }];
}

- (void)exportToRTF:(id)sender {
  (void)sender;
  [self exportAs:NSRTFTextDocumentType extension:@"rtf"];
}

- (void)exportToHTML:(id)sender {
  (void)sender;
  [self exportAs:NSHTMLTextDocumentType extension:@"html"];
}

- (void)copyRTFToClipboard:(id)sender {
  (void)sender;
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setData:[self exportData:NSRTFTextDocumentType] forType:NSPasteboardTypeRTF];
}

- (void)copyHTMLToClipboard:(id)sender {
  (void)sender;
  NSString *html = [[NSString alloc] initWithData:[self exportData:NSHTMLTextDocumentType] encoding:NSUTF8StringEncoding];
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:html ?: @"" forType:NSPasteboardTypeHTML];
  [NSPasteboard.generalPasteboard setString:html ?: @"" forType:NSPasteboardTypeString];
}

- (void)openPluginsFolder:(id)sender {
  (void)sender;
  NSString *folder = AppSupportFolder(@"plugins");
  NSString *readme = [folder stringByAppendingPathComponent:@"README.txt"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:readme]) {
    [@"Notepad++ plugins are Windows DLLs and can't run on macOS.\nThis app supports data-only JSON plugin packs (snippets and text actions): use Settings > Import > Import plugin(s).\n"
        writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }
  [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:folder]];
}

#pragma mark - Window menu

- (void)activateDocumentFromMenu:(NSMenuItem *)sender {
  NativeDocument *document = [self documentWithIdentifier:sender.representedObject];
  if (document) [self selectDocument:document];
}

- (void)noteActiveDocumentForRecentWindow {
  NSString *identifier = self.activeDocument.identifier;
  if (!identifier) return;
  NSMutableArray *recent = self.toolObjects[@"mru"] ?: [NSMutableArray array];
  [recent removeObject:identifier];
  [recent insertObject:identifier atIndex:0];
  if (recent.count > 50) [recent removeLastObject];
  self.toolObjects[@"mru"] = recent;
}

- (void)recentWindow:(id)sender {
  (void)sender;
  for (NSString *identifier in [self.toolObjects[@"mru"] copy]) {
    if ([identifier isEqualToString:self.activeDocument.identifier]) continue;
    NativeDocument *document = [self documentWithIdentifier:identifier];
    if (document) {
      [self selectDocument:document];
      return;
    }
  }
}

- (void)sortTabsBy:(NSMenuItem *)sender {
  NSInteger option = sender.tag;
  BOOL ascending = option % 2 == 0;
  NSInteger key = option / 2;
  NSArray<NativeDocument *> *sorted = [self.documents sortedArrayUsingComparator:^NSComparisonResult(NativeDocument *left, NativeDocument *right) {
    NSComparisonResult result = NSOrderedSame;
    NSString *leftName = left.fileURL.lastPathComponent ?: left.name, *rightName = right.fileURL.lastPathComponent ?: right.name;
    switch (key) {
      case 0: result = [leftName localizedStandardCompare:rightName]; break;
      case 1: result = [(left.fileURL.path ?: leftName) localizedStandardCompare:(right.fileURL.path ?: rightName)]; break;
      case 2: result = [leftName.pathExtension localizedStandardCompare:rightName.pathExtension]; break;
      case 3: {
        long a = [left.editor getGeneralProperty:SCI_GETLENGTH], b = [right.editor getGeneralProperty:SCI_GETLENGTH];
        result = a < b ? NSOrderedAscending : a > b ? NSOrderedDescending : NSOrderedSame;
        break;
      }
      default: result = [(left.fileModificationDate ?: NSDate.distantPast) compare:(right.fileModificationDate ?: NSDate.distantPast)]; break;
    }
    return ascending ? result : (NSComparisonResult)(-result);
  }];
  NativeDocument *active = self.activeDocument;
  [sorted enumerateObjectsUsingBlock:^(NativeDocument *document, NSUInteger index, BOOL *stop) {
    (void)stop;
    NSTabViewItem *item = self.tabItems[document.identifier];
    [self.tabView removeTabViewItem:item];
    [self.tabView insertTabViewItem:item atIndex:(NSInteger)index];
  }];
  [self.documents setArray:sorted];
  if (active) [self selectDocument:active];
  [self.tabBar reload];
  [self scheduleSessionPersistence];
}

// Notepad++'s "Windows…" dialog: list documents, activate, save or close them.
- (void)showDocumentList:(id)sender {
  (void)sender;
  NSPanel *panel = self.toolObjects[@"windowsPanel"];
  if (!panel) {
    panel = MakeToolPanel(@"Windows", NSMakeSize(620, 380));
    panel.hidesOnDeactivate = NO;
    NativeBlockTable *source = [[NativeBlockTable alloc] init];
    __weak NativeEditorController *weakSelf = self;
    source.count = ^NSInteger { return weakSelf.tabView.numberOfTabViewItems; };
    source.value = ^id(NSInteger row, NSString *column) {
      NativeDocument *document = [weakSelf documentWithIdentifier:weakSelf.tabView.tabViewItems[row].identifier];
      if ([column isEqualToString:@"name"]) return [NSString stringWithFormat:@"%@%@", document.fileURL.lastPathComponent ?: document.name, document.isDirty ? @"*" : @""];
      if ([column isEqualToString:@"path"]) return document.fileURL.URLByDeletingLastPathComponent.path ?: @"";
      if ([column isEqualToString:@"type"]) return document.languageDefinition.name;
      return [NSByteCountFormatter stringFromByteCount:[document.editor getGeneralProperty:SCI_GETLENGTH] countStyle:NSByteCountFormatterCountStyleFile];
    };
    NSTableView *table = MakeTable(@[@[@"name", @"Name", @170], @[@"path", @"Path", @250], @[@"type", @"Type", @90], @[@"size", @"Size", @70]], source);
    table.allowsMultipleSelection = YES;
    table.target = self;
    table.doubleAction = @selector(windowsDialogActivate:);
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 500, 380)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.documentView = table;
    [panel.contentView addSubview:scroll];
    CGFloat y = 340;
    for (NSArray *button in @[@[@"Activate", NSStringFromSelector(@selector(windowsDialogActivate:))],
                              @[@"Save", NSStringFromSelector(@selector(windowsDialogSave:))],
                              @[@"Close window(s)", NSStringFromSelector(@selector(windowsDialogClose:))]]) {
      NSButton *control = [NSButton buttonWithTitle:button[0] target:self action:NSSelectorFromString(button[1])];
      control.frame = NSMakeRect(506, y, 108, 28);
      control.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
      [panel.contentView addSubview:control];
      y -= 34;
    }
    self.toolObjects[@"windowsPanel"] = panel;
    self.toolObjects[@"windowsSource"] = source;
    self.toolObjects[@"windowsTable"] = table;
  }
  [(NSTableView *)self.toolObjects[@"windowsTable"] reloadData];
  [panel makeKeyAndOrderFront:nil];
}

- (NSArray<NativeDocument *> *)windowsDialogSelection {
  NSTableView *table = self.toolObjects[@"windowsTable"];
  NSMutableArray *documents = [NSMutableArray array];
  [table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
    (void)stop;
    if ((NSInteger)row < self.tabView.numberOfTabViewItems) {
      NativeDocument *document = [self documentWithIdentifier:self.tabView.tabViewItems[row].identifier];
      if (document) [documents addObject:document];
    }
  }];
  return documents;
}

- (void)windowsDialogActivate:(id)sender {
  (void)sender;
  NativeDocument *document = [self windowsDialogSelection].firstObject;
  if (document) [self selectDocument:document];
}

- (void)windowsDialogSave:(id)sender {
  (void)sender;
  for (NativeDocument *document in [self windowsDialogSelection]) {
    [self selectDocument:document];
    [self saveDocument:nil];
  }
  [(NSTableView *)self.toolObjects[@"windowsTable"] reloadData];
}

- (void)windowsDialogClose:(id)sender {
  (void)sender;
  for (NativeDocument *document in [self windowsDialogSelection]) [self closeDocumentFromParity:document];
  [(NSTableView *)self.toolObjects[@"windowsTable"] reloadData];
}

#pragma mark - ?

- (void)showCommandLineArguments:(id)sender {
  (void)sender;
  NSString *app = NSBundle.mainBundle.bundlePath;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Command Line Arguments";
  alert.informativeText = [NSString stringWithFormat:
      @"Open files:\n  open -a \"%@\" file1 file2\n\n"
      @"Open a folder as workspace:\n  open -a \"%@\" ~/project\n\n"
      @"New instance without the saved session:\n  open -n -a \"%@\" --args -NativeEditorNoSession YES\n\n"
      @"Finder: right-click a file > Open With, or Quick Actions > Open in Notepad++.", app, app, app];
  [alert runModal];
}

#pragma mark - Validation

- (BOOL)validateParityMenuItem:(NSMenuItem *)item {
  SEL action = item.action;
  NativeDocument *document = self.activeDocument;
  if (action == @selector(encodeIn:)) {
    NSDictionary *choice = item.representedObject;
    item.state = document.encoding == [choice[@"encoding"] unsignedIntegerValue] && document.writesBOM == [choice[@"bom"] boolValue]
        ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(togglePostIt:)) {
    item.state = [self.toolObjects[@"postIt"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(toggleDistractionFree:)) {
    item.state = [self.toolObjects[@"distractionFree"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(toggleSyncVerticalScrolling:)) {
    item.state = [self.toolObjects[@"syncV"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(toggleSyncHorizontalScrolling:)) {
    item.state = [self.toolObjects[@"syncH"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(toggleDocumentList:)) {
    NSView *pane = self.toolObjects[@"docListPane"];
    item.state = pane && !pane.hidden ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(toggleIncrementalSearch:)) {
    item.state = [self.toolObjects[@"incBar"] isHidden] ? NSControlStateValueOff : NSControlStateValueOn;
  } else if (action == @selector(toggleCharacterPanel:)) {
    item.state = [self.toolObjects[@"charPanel"] isVisible] ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(toggleClipboardHistory:)) {
    item.state = [self.toolObjects[@"clipPanel"] isVisible] ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(applyTabColor:)) {
    item.state = [self.tabColors[document.identifier] integerValue] == item.tag && item.tag ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(toggleReadOnlyAttribute:)) {
    NSString *path = document.fileURL.path;
    item.state = path && ![[NSFileManager defaultManager] isWritableFileAtPath:path] ? NSControlStateValueOn : NSControlStateValueOff;
    return path != nil;
  } else if (action == @selector(moveToTrash:) || action == @selector(openInDefaultViewer:) || action == @selector(openContainingFolderAsWorkspace:) ||
             action == @selector(copyDirectoryPath:) || action == @selector(moveToNewInstance:) || action == @selector(openInNewInstance:) ||
             action == @selector(viewInBrowser:) || action == @selector(openInTerminal:)) {
    return document.fileURL != nil;
  } else if (action == @selector(closeAllButPinned:)) {
    return self.pinnedDocuments.count > 0;
  } else if (action == @selector(focusOnAnotherView:)) {
    return document.secondaryEditor != nil;
  }
  return YES;
}

@end
