#import "NativeEditorController+Private.h"
#import <CommonCrypto/CommonDigest.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <fnmatch.h>
#include <string>

static NSString * const kSavedMacrosKey = @"NativeEditor.SavedMacros.v1";
static NSString * const kPluginPacksKey = @"NativeEditor.PluginPacks.v1";
static NSString * const kFindFiltersKey = @"NativeEditor.FindInFilesFilters.v1";
static const NSInteger kMaxSearchResults = 10000;

#pragma mark - Scintilla text helpers

static NSString *TextInRange(ScintillaView *editor, long start, long end) {
  if (end <= start) return @"";
  std::string buffer(end - start, '\0');
  [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:start value:end];
  [editor message:SCI_GETTARGETTEXT wParam:0 lParam:(sptr_t)buffer.data()];
  return [[NSString alloc] initWithBytes:buffer.data() length:buffer.size() encoding:NSUTF8StringEncoding] ?: @"";
}

static long ReplaceRange(ScintillaView *editor, long start, long end, NSString *text) {
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:start value:end];
  [editor message:SCI_REPLACETARGET wParam:data.length lParam:(sptr_t)(data.length ? data.bytes : "")];
  return (long)data.length;
}

static NSString *LineText(ScintillaView *editor, long line) {
  long start = [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:line];
  long end = [editor getGeneralProperty:SCI_GETLINEENDPOSITION parameter:line];
  return TextInRange(editor, start, end);
}

static NSString *EolString(ScintillaView *editor) {
  long mode = [editor getGeneralProperty:SCI_GETEOLMODE];
  return mode == SC_EOL_CRLF ? @"\r\n" : mode == SC_EOL_CR ? @"\r" : @"\n";
}

static unichar HexValue(NSString *hex) {
  unsigned int value = 0;
  [[NSScanner scannerWithString:hex] scanHexInt:&value];
  return (unichar)value;
}

// Notepad++'s "Extended" search mode: \n \r \t \0 \\ \xHH \uHHHH.
static NSString *UnescapeExtended(NSString *text) {
  NSMutableString *result = [NSMutableString stringWithCapacity:text.length];
  for (NSUInteger index = 0; index < text.length; index += 1) {
    unichar ch = [text characterAtIndex:index];
    if (ch != '\\' || index + 1 >= text.length) {
      [result appendFormat:@"%C", ch];
      continue;
    }
    unichar next = [text characterAtIndex:++index];
    switch (next) {
      case 'n': [result appendString:@"\n"]; break;
      case 'r': [result appendString:@"\r"]; break;
      case 't': [result appendString:@"\t"]; break;
      case '0': [result appendFormat:@"%C", (unichar)0]; break;
      case '\\': [result appendString:@"\\"]; break;
      case 'x':
        if (index + 2 < text.length) {
          [result appendFormat:@"%C", HexValue([text substringWithRange:NSMakeRange(index + 1, 2)])];
          index += 2;
        }
        break;
      case 'u':
        if (index + 4 < text.length) {
          [result appendFormat:@"%C", HexValue([text substringWithRange:NSMakeRange(index + 1, 4)])];
          index += 4;
        }
        break;
      default: [result appendFormat:@"\\%C", next]; break;
    }
  }
  return result;
}

@implementation NativeEditorController (Commands)

#pragma mark - Menus

- (void)buildMacroMenu:(NSMenu *)menu {
  const NSEventModifierFlags cmdShift = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [menu removeAllItems];
  self.recordMacroMenuItem = [self addMenuItem:@"Start Recording" action:@selector(startMacroRecordingCommand:) key:@"r" modifiers:cmdShift toMenu:menu];
  [self addMenuItem:@"Stop Recording" action:@selector(stopMacroRecordingCommand:) key:@"" toMenu:menu];
  [self addMenuItem:@"Playback" action:@selector(playMacro:) key:@"p" modifiers:cmdShift toMenu:menu];
  [self addMenuItem:@"Save Current Recorded Macro…" action:@selector(saveCurrentMacro:) key:@"" toMenu:menu];
  [self addMenuItem:@"Run a Macro Multiple Times…" action:@selector(runMacroMultipleTimes:) key:@"" toMenu:menu];
  NSArray<NSDictionary *> *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kSavedMacrosKey];
  if (saved.count) {
    [menu addItem:NSMenuItem.separatorItem];
    [saved enumerateObjectsUsingBlock:^(NSDictionary *macro, NSUInteger index, BOOL *stop) {
      (void)stop;
      NSMenuItem *item = [self addMenuItem:macro[@"name"] action:@selector(playSavedMacro:) key:@"" toMenu:menu];
      item.tag = (NSInteger)index;
    }];
    [menu addItem:NSMenuItem.separatorItem];
    [self addMenuItem:@"Delete Saved Macro…" action:@selector(deleteSavedMacro:) key:@"" toMenu:menu];
  }
}

- (void)rebuildMacroMenu {
  [self buildMacroMenu:self.macroMenu];
}

- (BOOL)validateCommandMenuItem:(NSMenuItem *)item {
  SEL action = item.action;
  NativeDocument *document = self.activeDocument;
  if (action == @selector(startMacroRecordingCommand:)) {
    return !document.isRecordingMacro;
  } else if (action == @selector(stopMacroRecordingCommand:)) {
    return document.isRecordingMacro;
  } else if (action == @selector(playMacro:) || action == @selector(saveCurrentMacro:) || action == @selector(runMacroMultipleTimes:)) {
    return self.currentMacro.count > 0 && !document.isRecordingMacro;
  } else if (action == @selector(toggleReadOnly:)) {
    item.state = document.isReadOnly ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(toggleColumnSelection:)) {
    item.state = [self.activeEditor getGeneralProperty:SCI_GETSELECTIONMODE] == SC_SEL_RECTANGLE ? NSControlStateValueOn : NSControlStateValueOff;
  } else if (action == @selector(undo:)) {
    return [self.activeEditor getGeneralProperty:SCI_CANUNDO] != 0;
  } else if (action == @selector(redo:)) {
    return [self.activeEditor getGeneralProperty:SCI_CANREDO] != 0;
  }
  return YES;
}

#pragma mark - Basic editing

// The search and replace fields are ordinary text fields, so standard edit
// commands go to them when they have focus.
- (NSText *)focusedFieldEditor {
  NSResponder *responder = self.window.firstResponder;
  return [responder isKindOfClass:NSText.class] && ![(NSView *)responder isDescendantOf:self.tabView] ? (NSText *)responder : nil;
}

- (BOOL)editorIsWritable {
  if (self.activeDocument.isReadOnly) {
    [self setStatus:@"This document is read-only"];
    NSBeep();
    return NO;
  }
  return YES;
}

- (void)undo:(id)sender {
  NSText *field = [self focusedFieldEditor];
  if (field) { [field.undoManager undo]; return; }
  (void)sender;
  [self.activeEditor message:SCI_UNDO];
}

- (void)redo:(id)sender {
  NSText *field = [self focusedFieldEditor];
  if (field) { [field.undoManager redo]; return; }
  (void)sender;
  [self.activeEditor message:SCI_REDO];
}

- (void)cut:(id)sender {
  NSText *field = [self focusedFieldEditor];
  if (field) { [field cut:sender]; return; }
  [self.activeEditor message:SCI_CUT];
}

- (void)copy:(id)sender {
  NSText *field = [self focusedFieldEditor];
  if (field) { [field copy:sender]; return; }
  [self.activeEditor message:SCI_COPY];
}

- (void)paste:(id)sender {
  NSText *field = [self focusedFieldEditor];
  if (field) { [field paste:sender]; return; }
  [self.activeEditor message:SCI_PASTE];
}

- (void)selectAll:(id)sender {
  NSText *field = [self focusedFieldEditor];
  if (field) { [field selectAll:sender]; return; }
  [self.activeEditor message:SCI_SELECTALL];
}

- (void)deleteSelection:(id)sender {
  (void)sender;
  [self.activeEditor message:SCI_CLEAR];
}

- (void)duplicateLine:(id)sender { (void)sender; [self.activeEditor message:SCI_SELECTIONDUPLICATE]; }
- (void)deleteLine:(id)sender { (void)sender; [self.activeEditor message:SCI_LINEDELETE]; }
- (void)transposeLine:(id)sender { (void)sender; [self.activeEditor message:SCI_LINETRANSPOSE]; }
- (void)moveLineUp:(id)sender { (void)sender; [self.activeEditor message:SCI_MOVESELECTEDLINESUP]; }
- (void)moveLineDown:(id)sender { (void)sender; [self.activeEditor message:SCI_MOVESELECTEDLINESDOWN]; }
- (void)indentLines:(id)sender { (void)sender; [self.activeEditor message:SCI_TAB]; }
- (void)outdentLines:(id)sender { (void)sender; [self.activeEditor message:SCI_BACKTAB]; }
- (void)uppercaseSelection:(id)sender { (void)sender; [self.activeEditor message:SCI_UPPERCASE]; }
- (void)lowercaseSelection:(id)sender { (void)sender; [self.activeEditor message:SCI_LOWERCASE]; }

- (void)insertLineAbove:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  [editor message:SCI_BEGINUNDOACTION];
  [editor message:SCI_HOME];
  [editor message:SCI_NEWLINE];
  [editor message:SCI_LINEUP];
  [editor message:SCI_ENDUNDOACTION];
}

- (void)insertLineBelow:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  [editor message:SCI_LINEEND];
  [editor message:SCI_NEWLINE];
}

- (void)joinLines:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  if (![self editorIsWritable]) return;
  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  if (start == end) {
    long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:start];
    if (line + 1 >= [editor getGeneralProperty:SCI_GETLINECOUNT]) return;
    end = [editor getGeneralProperty:SCI_GETLINEENDPOSITION parameter:line + 1];
    start = [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:line];
  }
  [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:start value:end];
  [editor message:SCI_LINESJOIN];
}

- (void)toggleColumnSelection:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  long mode = [editor getGeneralProperty:SCI_GETSELECTIONMODE];
  [editor setGeneralProperty:SCI_SETSELECTIONMODE value:mode == SC_SEL_RECTANGLE ? SC_SEL_STREAM : SC_SEL_RECTANGLE];
  [self setStatus:mode == SC_SEL_RECTANGLE ? @"Column mode off" : @"Column mode on (Option-drag also selects columns)"];
}

- (void)selectWordAtCaretIfEmpty:(ScintillaView *)editor {
  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  if (start != end) return;
  long wordStart = [editor getGeneralProperty:SCI_WORDSTARTPOSITION parameter:start extra:1];
  long wordEnd = [editor getGeneralProperty:SCI_WORDENDPOSITION parameter:start extra:1];
  [editor setGeneralProperty:SCI_SETSEL parameter:wordStart value:wordEnd];
}

- (void)addNextSelection:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  [self selectWordAtCaretIfEmpty:editor];
  [editor setGeneralProperty:SCI_SETSEARCHFLAGS value:SCFIND_MATCHCASE];
  [editor message:SCI_TARGETWHOLEDOCUMENT];
  [editor message:SCI_MULTIPLESELECTADDNEXT];
}

- (void)selectAllOccurrences:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  [self selectWordAtCaretIfEmpty:editor];
  [editor setGeneralProperty:SCI_SETSEARCHFLAGS value:SCFIND_MATCHCASE];
  [editor message:SCI_TARGETWHOLEDOCUMENT];
  [editor message:SCI_MULTIPLESELECTADDEACH];
  [self setStatus:[NSString stringWithFormat:@"%ld selections", [editor getGeneralProperty:SCI_GETSELECTIONS]]];
}

- (void)toggleReadOnly:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  document.readOnly = !document.isReadOnly;
  [self scheduleSessionPersistence];
}

- (void)insertText:(NSString *)text {
  if (![self editorIsWritable]) return;
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  [self.activeEditor message:SCI_REPLACESEL wParam:0 lParam:(sptr_t)[data bytes]];
}

- (void)insertShortDateTime:(id)sender {
  (void)sender;
  [self insertText:[NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle]];
}

- (void)insertLongDateTime:(id)sender {
  (void)sender;
  [self insertText:[NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterFullStyle timeStyle:NSDateFormatterMediumStyle]];
}

- (void)insertISODateTime:(id)sender {
  (void)sender;
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  formatter.timeZone = NSTimeZone.localTimeZone;
  [self insertText:[formatter stringFromDate:[NSDate date]]];
}

#pragma mark - Selection and line transforms

- (void)transformSelection:(NSString *(^)(NSString *text))transform {
  ScintillaView *editor = self.activeEditor;
  if (![self editorIsWritable]) return;
  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  if (start == end) {
    [self setStatus:@"Select some text first"];
    return;
  }
  NSString *text = TextInRange(editor, start, end);
  NSString *result = transform(text);
  if (!result || [result isEqualToString:text]) return;
  [editor message:SCI_BEGINUNDOACTION];
  long length = ReplaceRange(editor, start, end, result);
  [editor message:SCI_ENDUNDOACTION];
  [editor setGeneralProperty:SCI_SETSEL parameter:start value:start + length];
}

- (void)properCaseSelection:(id)sender {
  (void)sender;
  [self transformSelection:^NSString *(NSString *text) { return text.capitalizedString; }];
}

- (void)sentenceCaseSelection:(id)sender {
  (void)sender;
  [self transformSelection:^NSString *(NSString *text) {
    NSMutableString *result = [text.lowercaseString mutableCopy];
    __block BOOL capitalize = YES;
    [result enumerateSubstringsInRange:NSMakeRange(0, result.length) options:NSStringEnumerationByComposedCharacterSequences
                            usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
      (void)enclosing; (void)stop;
      if (capitalize && [character rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound) {
        [result replaceCharactersInRange:range withString:character.uppercaseString];
        capitalize = NO;
      } else if ([character rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@".!?"]].location != NSNotFound) {
        capitalize = YES;
      }
    }];
    return result;
  }];
}

- (void)invertCaseSelection:(id)sender {
  (void)sender;
  [self transformSelection:^NSString *(NSString *text) {
    NSMutableString *result = [NSMutableString stringWithCapacity:text.length];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
      (void)range; (void)enclosing; (void)stop;
      [result appendString:[character isEqualToString:character.uppercaseString] ? character.lowercaseString : character.uppercaseString];
    }];
    return result;
  }];
}

- (void)randomCaseSelection:(id)sender {
  (void)sender;
  [self transformSelection:^NSString *(NSString *text) {
    NSMutableString *result = [NSMutableString stringWithCapacity:text.length];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
      (void)range; (void)enclosing; (void)stop;
      [result appendString:arc4random_uniform(2) ? character.uppercaseString : character.lowercaseString];
    }];
    return result;
  }];
}

// Applies a transform to the selected lines, or to the whole document when nothing is selected.
- (void)transformLines:(NSArray<NSString *> *(^)(NSArray<NSString *> *lines))transform {
  ScintillaView *editor = self.activeEditor;
  if (![self editorIsWritable]) return;
  long selectionStart = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long selectionEnd = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  BOOL hasSelection = selectionStart != selectionEnd;
  long firstLine = 0;
  long lastLine = [editor getGeneralProperty:SCI_GETLINECOUNT] - 1;
  if (hasSelection) {
    firstLine = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:selectionStart];
    lastLine = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:selectionEnd];
    if (lastLine > firstLine && selectionEnd == [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:lastLine]) lastLine -= 1;
  }
  long start = [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:firstLine];
  long end = [editor getGeneralProperty:SCI_GETLINEENDPOSITION parameter:lastLine];
  NSString *text = TextInRange(editor, start, end);
  NSString *normalized = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                          stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
  NSArray<NSString *> *lines = [normalized componentsSeparatedByString:@"\n"];
  NSArray<NSString *> *result = transform(lines);
  NSString *replacement = [result componentsJoinedByString:EolString(editor)];
  if ([replacement isEqualToString:text]) {
    [self setStatus:@"No change"];
    return;
  }
  [editor message:SCI_BEGINUNDOACTION];
  long length = ReplaceRange(editor, start, end, replacement);
  [editor message:SCI_ENDUNDOACTION];
  if (hasSelection) [editor setGeneralProperty:SCI_SETSEL parameter:start value:start + length];
  else [editor setGeneralProperty:SCI_GOTOPOS value:MIN(selectionStart, start + length)];
  long removed = (long)lines.count - (long)result.count;
  [self setStatus:removed > 0 ? [NSString stringWithFormat:@"%ld lines removed", removed]
                              : [NSString stringWithFormat:@"%lu lines processed", (unsigned long)result.count]];
}

- (void)removeDuplicateLines:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) {
    return [[NSOrderedSet orderedSetWithArray:lines] array];
  }];
}

- (void)removeConsecutiveDuplicateLines:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *line in lines) if (![line isEqualToString:result.lastObject]) [result addObject:line];
    return result;
  }];
}

- (void)removeEmptyLines:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) {
    return [lines filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
  }];
}

- (void)removeBlankLines:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *line in lines) {
      if ([line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length) [result addObject:line];
    }
    return result;
  }];
}

- (void)sortLinesAscending:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) { return [lines sortedArrayUsingSelector:@selector(compare:)]; }];
}

- (void)sortLinesDescending:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) {
    return [[[lines sortedArrayUsingSelector:@selector(compare:)] reverseObjectEnumerator] allObjects];
  }];
}

- (void)sortLinesIgnoringCase:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) { return [lines sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]; }];
}

- (void)sortLinesAsIntegers:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) {
    return [lines sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
      long long a = [left stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].longLongValue;
      long long b = [right stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].longLongValue;
      return a < b ? NSOrderedAscending : a > b ? NSOrderedDescending : [left compare:right];
    }];
  }];
}

- (void)sortLinesByLength:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) {
    return [lines sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
      return left.length < right.length ? NSOrderedAscending : left.length > right.length ? NSOrderedDescending : NSOrderedSame;
    }];
  }];
}

- (void)reverseLines:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) { return lines.reverseObjectEnumerator.allObjects; }];
}

- (void)shuffleLines:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) {
    NSMutableArray *result = [lines mutableCopy];
    for (NSUInteger index = result.count; index > 1; index -= 1) {
      [result exchangeObjectAtIndex:index - 1 withObjectAtIndex:arc4random_uniform((uint32_t)index)];
    }
    return result;
  }];
}

- (NSArray<NSString *> *)lines:(NSArray<NSString *> *)lines trimmingLeading:(BOOL)leading trailing:(BOOL)trailing {
  NSMutableArray *result = [NSMutableArray arrayWithCapacity:lines.count];
  NSCharacterSet *blanks = NSCharacterSet.whitespaceCharacterSet;
  for (NSString *line in lines) {
    NSUInteger start = 0;
    NSUInteger end = line.length;
    if (leading) while (start < end && [blanks characterIsMember:[line characterAtIndex:start]]) start += 1;
    if (trailing) while (end > start && [blanks characterIsMember:[line characterAtIndex:end - 1]]) end -= 1;
    [result addObject:[line substringWithRange:NSMakeRange(start, end - start)]];
  }
  return result;
}

- (void)trimWhitespace:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) { return [self lines:lines trimmingLeading:NO trailing:YES]; }];
}

- (void)trimLeadingWhitespace:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) { return [self lines:lines trimmingLeading:YES trailing:NO]; }];
}

- (void)trimBothWhitespace:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) { return [self lines:lines trimmingLeading:YES trailing:YES]; }];
}

- (void)eolToSpace:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) { return @[[lines componentsJoinedByString:@" "]]; }];
}

- (NSInteger)tabWidth {
  return [self.viewOptions[NativeViewTabWidth] integerValue] ?: 4;
}

- (void)tabsToSpaces:(id)sender {
  (void)sender;
  NSInteger width = [self tabWidth];
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:lines.count];
    for (NSString *line in lines) {
      NSMutableString *expanded = [NSMutableString stringWithCapacity:line.length];
      for (NSUInteger index = 0; index < line.length; index += 1) {
        unichar ch = [line characterAtIndex:index];
        if (ch == '\t') {
          NSInteger spaces = width - (NSInteger)(expanded.length % width);
          [expanded appendString:[@"" stringByPaddingToLength:spaces withString:@" " startingAtIndex:0]];
        } else {
          [expanded appendFormat:@"%C", ch];
        }
      }
      [result addObject:expanded];
    }
    return result;
  }];
}

- (NSString *)tabbedRunOfWidth:(NSInteger)width startingAtColumn:(NSInteger)column tabWidth:(NSInteger)tabWidth {
  NSMutableString *run = [NSMutableString string];
  NSInteger position = column;
  NSInteger end = column + width;
  while (position < end) {
    NSInteger nextStop = (position / tabWidth + 1) * tabWidth;
    if (nextStop <= end && nextStop - position > 1) {
      [run appendString:@"\t"];
      position = nextStop;
    } else if (nextStop <= end && nextStop - position == 1 && end - position > 1) {
      [run appendString:@"\t"];
      position = nextStop;
    } else {
      [run appendString:@" "];
      position += 1;
    }
  }
  return run;
}

- (NSArray<NSString *> *)convertSpacesInLines:(NSArray<NSString *> *)lines leadingOnly:(BOOL)leadingOnly {
  NSInteger width = [self tabWidth];
  NSMutableArray *result = [NSMutableArray arrayWithCapacity:lines.count];
  for (NSString *line in lines) {
    NSMutableString *converted = [NSMutableString string];
    NSInteger column = 0;
    NSUInteger index = 0;
    BOOL leading = YES;
    while (index < line.length) {
      unichar ch = [line characterAtIndex:index];
      if (ch == ' ' && (leading || !leadingOnly)) {
        NSUInteger runEnd = index;
        while (runEnd < line.length && [line characterAtIndex:runEnd] == ' ') runEnd += 1;
        NSInteger runWidth = (NSInteger)(runEnd - index);
        [converted appendString:runWidth > 1 ? [self tabbedRunOfWidth:runWidth startingAtColumn:column tabWidth:width]
                                             : @" "];
        column += runWidth;
        index = runEnd;
        continue;
      }
      if (ch == '\t') {
        column = (column / width + 1) * width;
      } else {
        leading = NO;
        column += 1;
      }
      [converted appendFormat:@"%C", ch];
      index += 1;
    }
    [result addObject:converted];
  }
  return result;
}

- (void)spacesToTabsAll:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) { return [self convertSpacesInLines:lines leadingOnly:NO]; }];
}

- (void)spacesToTabsLeading:(id)sender {
  (void)sender;
  [self transformLines:^NSArray *(NSArray<NSString *> *lines) { return [self convertSpacesInLines:lines leadingOnly:YES]; }];
}

#pragma mark - Comments

- (void)toggleComment:(id)sender {
  ScintillaView *editor = self.activeEditor;
  NativeLanguage *language = self.activeDocument.languageDefinition;
  NSString *prefix = language.lineComment;
  if (!prefix) {
    [self toggleBlockComment:sender];
    return;
  }
  if (![self editorIsWritable]) return;
  long selectionStart = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long selectionEnd = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  long firstLine = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:selectionStart];
  long lastLine = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:selectionEnd];
  if (lastLine > firstLine && selectionEnd == [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:lastLine]) lastLine -= 1;
  NSData *prefixData = [prefix dataUsingEncoding:NSUTF8StringEncoding];
  long prefixLength = (long)prefixData.length;

  BOOL allCommented = YES;
  BOOL anyLine = NO;
  for (long line = firstLine; line <= lastLine; line += 1) {
    long indent = [editor getGeneralProperty:SCI_GETLINEINDENTPOSITION parameter:line];
    long end = [editor getGeneralProperty:SCI_GETLINEENDPOSITION parameter:line];
    if (indent == end) continue;
    anyLine = YES;
    if (![TextInRange(editor, indent, MIN(end, indent + prefixLength)) isEqualToString:prefix]) {
      allCommented = NO;
      break;
    }
  }
  if (!anyLine) return;

  NSString *insertion = [prefix stringByAppendingString:@" "];
  [editor message:SCI_BEGINUNDOACTION];
  for (long line = lastLine; line >= firstLine; line -= 1) {
    long indent = [editor getGeneralProperty:SCI_GETLINEINDENTPOSITION parameter:line];
    long end = [editor getGeneralProperty:SCI_GETLINEENDPOSITION parameter:line];
    if (indent == end) continue;
    if (allCommented) {
      long removeLength = prefixLength;
      if (indent + prefixLength < end && [editor getGeneralProperty:SCI_GETCHARAT parameter:indent + prefixLength] == ' ') removeLength += 1;
      [editor setGeneralProperty:SCI_DELETERANGE parameter:indent value:removeLength];
    } else {
      [editor message:SCI_INSERTTEXT wParam:(uptr_t)indent lParam:(sptr_t)insertion.UTF8String];
    }
  }
  [editor message:SCI_ENDUNDOACTION];
}

- (void)toggleBlockComment:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  NativeLanguage *language = self.activeDocument.languageDefinition;
  NSString *open = language.blockCommentStart;
  NSString *close = language.blockCommentEnd;
  if (!open || !close) {
    [self setStatus:[NSString stringWithFormat:@"%@ has no block comment syntax", language.name]];
    return;
  }
  if (![self editorIsWritable]) return;
  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  if (start == end) {
    long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:start];
    start = [editor getGeneralProperty:SCI_GETLINEINDENTPOSITION parameter:line];
    end = [editor getGeneralProperty:SCI_GETLINEENDPOSITION parameter:line];
  }
  NSString *text = TextInRange(editor, start, end);
  NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  NSString *replacement;
  if ([trimmed hasPrefix:open] && [trimmed hasSuffix:close] && trimmed.length >= open.length + close.length) {
    NSString *inner = [trimmed substringWithRange:NSMakeRange(open.length, trimmed.length - open.length - close.length)];
    if ([inner hasPrefix:@" "]) inner = [inner substringFromIndex:1];
    if ([inner hasSuffix:@" "]) inner = [inner substringToIndex:inner.length - 1];
    replacement = inner;
  } else {
    replacement = [NSString stringWithFormat:@"%@ %@ %@", open, text, close];
  }
  [editor message:SCI_BEGINUNDOACTION];
  long length = ReplaceRange(editor, start, end, replacement);
  [editor message:SCI_ENDUNDOACTION];
  [editor setGeneralProperty:SCI_SETSEL parameter:start value:start + length];
}

#pragma mark - Column editor

- (void)showColumnEditor:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  if (![self editorIsWritable]) return;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Column Editor";
  alert.informativeText = @"Inserts at the caret column on every line of a column selection, or from the current line to the end of the document.";
  NSGridView *grid = [NSGridView gridViewWithNumberOfColumns:2 rows:0];
  grid.rowSpacing = 6;
  NSButton *textMode = [NSButton radioButtonWithTitle:@"Text to insert" target:nil action:nil];
  NSButton *numberMode = [NSButton radioButtonWithTitle:@"Number to insert" target:nil action:nil];
  textMode.state = NSControlStateValueOn;
  NSTextField *textField = [NSTextField textFieldWithString:@""];
  NSTextField *initialField = [NSTextField textFieldWithString:@"1"];
  NSTextField *stepField = [NSTextField textFieldWithString:@"1"];
  NSButton *leadingZeros = [NSButton checkboxWithTitle:@"Leading zeros" target:nil action:nil];
  NSPopUpButton *format = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  [format addItemsWithTitles:@[@"Dec", @"Hex", @"Oct", @"Bin"]];
  [grid addRowWithViews:@[textMode, textField]];
  [grid addRowWithViews:@[numberMode, [NSGridCell emptyContentView]]];
  [grid addRowWithViews:@[[NSTextField labelWithString:@"Initial number:"], initialField]];
  [grid addRowWithViews:@[[NSTextField labelWithString:@"Increase by:"], stepField]];
  [grid addRowWithViews:@[leadingZeros, format]];
  [grid columnAtIndex:1].width = 160;
  grid.frame = NSMakeRect(0, 0, 320, 150);
  alert.accessoryView = grid;
  [alert addButtonWithTitle:@"Insert"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;

  // Each target is a (position, virtual space) pair, top to bottom.
  NSMutableArray<NSArray<NSNumber *> *> *targets = [NSMutableArray array];
  long selections = [editor getGeneralProperty:SCI_GETSELECTIONS];
  BOOL rectangular = [editor getGeneralProperty:SCI_SELECTIONISRECTANGLE] != 0;
  if (selections > 1 || rectangular) {
    for (long index = 0; index < selections; index += 1) {
      long position = [editor getGeneralProperty:SCI_GETSELECTIONNSTART parameter:index];
      long virtualSpace = [editor getGeneralProperty:SCI_GETSELECTIONNSTARTVIRTUALSPACE parameter:index];
      [targets addObject:@[@(position), @(virtualSpace)]];
    }
    [targets sortUsingComparator:^NSComparisonResult(NSArray *left, NSArray *right) { return [left[0] compare:right[0]]; }];
  } else {
    long caret = [editor getGeneralProperty:SCI_GETCURRENTPOS];
    long column = [editor getGeneralProperty:SCI_GETCOLUMN parameter:caret];
    long firstLine = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:caret];
    long lineCount = [editor getGeneralProperty:SCI_GETLINECOUNT];
    for (long line = firstLine; line < lineCount; line += 1) {
      long position = [editor getGeneralProperty:SCI_FINDCOLUMN parameter:line extra:column];
      long actualColumn = [editor getGeneralProperty:SCI_GETCOLUMN parameter:position];
      [targets addObject:@[@(position), @(MAX(0L, column - actualColumn))]];
    }
  }

  BOOL numbers = numberMode.state == NSControlStateValueOn;
  long long initial = initialField.stringValue.longLongValue;
  long long step = stepField.stringValue.longLongValue;
  NSInteger base = [@[@10, @16, @8, @2][format.indexOfSelectedItem] integerValue];
  NSString *(^formatNumber)(long long) = ^NSString *(long long value) {
    if (base == 10) return [NSString stringWithFormat:@"%lld", value];
    NSMutableString *digits = [NSMutableString string];
    unsigned long long remaining = (unsigned long long)value;
    do {
      [digits insertString:[NSString stringWithFormat:@"%c", "0123456789ABCDEF"[remaining % base]] atIndex:0];
      remaining /= base;
    } while (remaining > 0);
    return digits;
  };
  NSUInteger width = 0;
  if (numbers && leadingZeros.state == NSControlStateValueOn) {
    width = MAX(formatNumber(initial).length, formatNumber(initial + step * (long long)(targets.count - 1)).length);
  }

  [editor message:SCI_BEGINUNDOACTION];
  for (NSInteger index = (NSInteger)targets.count - 1; index >= 0; index -= 1) {
    NSString *text = textField.stringValue;
    if (numbers) {
      text = formatNumber(initial + step * index);
      while (text.length < width) text = [@"0" stringByAppendingString:text];
    }
    long padding = [targets[index][1] longValue];
    if (padding > 0) text = [[@"" stringByPaddingToLength:padding withString:@" " startingAtIndex:0] stringByAppendingString:text];
    [editor message:SCI_INSERTTEXT wParam:(uptr_t)[targets[index][0] longValue] lParam:(sptr_t)text.UTF8String];
  }
  [editor message:SCI_ENDUNDOACTION];
}

#pragma mark - Find and replace

- (void)useSelectionForFind:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  [self selectWordAtCaretIfEmpty:editor];
  self.searchField.stringValue = TextInRange(editor, [editor getGeneralProperty:SCI_GETSELECTIONSTART],
                                             [editor getGeneralProperty:SCI_GETSELECTIONEND]);
}

- (void)remember:(NSString *)value inHistory:(NSString *)key comboBox:(NSComboBox *)comboBox {
  if (!value.length) return;
  NSMutableArray<NSString *> *history = [[[NSUserDefaults standardUserDefaults] arrayForKey:key] mutableCopy] ?: [NSMutableArray array];
  if ([history.firstObject isEqualToString:value]) return;
  [history removeObject:value];
  [history insertObject:value atIndex:0];
  if (history.count > 20) [history removeObjectsInRange:NSMakeRange(20, history.count - 20)];
  [[NSUserDefaults standardUserDefaults] setObject:history forKey:key];
  [comboBox removeAllItems];
  [comboBox addItemsWithObjectValues:history];
  comboBox.stringValue = value;
}

- (void)rememberSearchQuery:(NSString *)query {
  [self remember:query inHistory:@"NativeEditor.SearchHistory.v1" comboBox:self.searchField];
  [self remember:self.replacementField.stringValue inHistory:@"NativeEditor.ReplaceHistory.v1" comboBox:self.replacementField];
}

- (BOOL)usesRegex {
  return self.regexButton.state == NSControlStateValueOn;
}

- (NSData *)searchPattern {
  NSString *query = self.searchField.stringValue;
  if (!query.length) return nil;
  if (!self.usesRegex && self.extendedButton.state == NSControlStateValueOn) query = UnescapeExtended(query);
  return [query dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)replacementData {
  NSString *replacement = self.replacementField.stringValue ?: @"";
  if (self.usesRegex) {
    // Accept Perl-style $1 references as well as Scintilla's \1.
    replacement = [replacement stringByReplacingOccurrencesOfString:@"\\$(\\d)" withString:@"\\\\$1"
                                                            options:NSRegularExpressionSearch range:NSMakeRange(0, replacement.length)];
  } else if (self.extendedButton.state == NSControlStateValueOn) {
    replacement = UnescapeExtended(replacement);
  }
  return [replacement dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
}

- (long)searchFlags {
  long flags = 0;
  if (self.matchCaseButton.state == NSControlStateValueOn) flags |= SCFIND_MATCHCASE;
  if (self.wholeWordButton.state == NSControlStateValueOn) flags |= SCFIND_WHOLEWORD;
  if (self.usesRegex) flags |= SCFIND_REGEXP | SCFIND_CXX11REGEX;
  return flags;
}

- (long)search:(ScintillaView *)editor pattern:(NSData *)pattern from:(long)start to:(long)end {
  [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:start value:end];
  return [editor message:SCI_SEARCHINTARGET wParam:pattern.length lParam:(sptr_t)pattern.bytes];
}

- (BOOL)reportInvalidPattern:(long)result {
  if (result != -2) return NO;
  [self setStatus:@"Find: invalid regular expression"];
  NSBeep();
  return YES;
}

- (BOOL)findInEditor:(ScintillaView *)editor forward:(BOOL)forward {
  NSData *pattern = [self searchPattern];
  if (!pattern) {
    [self focusFind:nil];
    return NO;
  }
  BOOL wrapAround = self.wrapAroundButton.state == NSControlStateValueOn;
  [self rememberSearchQuery:self.searchField.stringValue];
  [editor setGeneralProperty:SCI_SETSEARCHFLAGS value:[self searchFlags]];
  long length = [editor getGeneralProperty:SCI_GETLENGTH];
  long selectionStart = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long selectionEnd = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  BOOL wrapped = NO;
  long found;
  if (forward) {
    found = [self search:editor pattern:pattern from:selectionEnd to:length];
    if (found >= 0 && found == selectionEnd && [editor getGeneralProperty:SCI_GETTARGETEND] == found && selectionStart == selectionEnd) {
      found = selectionEnd < length ? [self search:editor pattern:pattern from:[editor getGeneralProperty:SCI_POSITIONAFTER parameter:selectionEnd] to:length] : -1;
    }
    if (found == -1 && wrapAround) {
      wrapped = YES;
      found = [self search:editor pattern:pattern from:0 to:selectionEnd];
    }
  } else {
    found = [self search:editor pattern:pattern from:selectionStart to:0];
    if (found == -1 && wrapAround) {
      wrapped = YES;
      found = [self search:editor pattern:pattern from:length to:selectionStart];
    }
  }
  if ([self reportInvalidPattern:found]) return NO;
  if (found < 0) {
    [self setStatus:[NSString stringWithFormat:@"Find: can't find the text \"%@\"", self.searchField.stringValue]];
    NSBeep();
    return NO;
  }
  long targetEnd = [editor getGeneralProperty:SCI_GETTARGETEND];
  long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:found];
  [editor setGeneralProperty:SCI_ENSUREVISIBLEENFORCEPOLICY value:line];
  [editor setGeneralProperty:SCI_SETSEL parameter:found value:targetEnd];
  [editor setGeneralProperty:SCI_SCROLLRANGE parameter:targetEnd value:found];
  [self setStatus:wrapped ? (forward ? @"Find: reached the end of the document, continued from the top"
                                     : @"Find: reached the top of the document, continued from the bottom")
                          : [NSString stringWithFormat:@"Find: found at line %ld", line + 1]];
  return YES;
}

- (void)findNext:(id)sender {
  (void)sender;
  [self findInEditor:self.activeEditor forward:YES];
}

- (void)findPrevious:(id)sender {
  (void)sender;
  [self findInEditor:self.activeEditor forward:NO];
}

- (void)replaceCurrent:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  NSData *pattern = [self searchPattern];
  if (!pattern || ![self editorIsWritable]) return;
  [editor setGeneralProperty:SCI_SETSEARCHFLAGS value:[self searchFlags]];
  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  long found = [self search:editor pattern:pattern from:start to:end];
  if ([self reportInvalidPattern:found]) return;
  if (found == start && [editor getGeneralProperty:SCI_GETTARGETEND] == end && end > start) {
    NSData *replacement = [self replacementData];
    unsigned int message = self.usesRegex ? SCI_REPLACETARGETRE : SCI_REPLACETARGET;
    long inserted = [editor message:message wParam:replacement.length lParam:(sptr_t)(replacement.length ? replacement.bytes : "")];
    [editor setGeneralProperty:SCI_GOTOPOS value:start + inserted];
  }
  [self findInEditor:editor forward:YES];
}

// Calls block for every match in the document; the block returns the new
// position to continue from, which lets replacement shift the search.
- (NSInteger)enumerateMatchesInEditor:(ScintillaView *)editor usingBlock:(long (^)(long start, long end))block {
  NSData *pattern = [self searchPattern];
  if (!pattern) return 0;
  [editor setGeneralProperty:SCI_SETSEARCHFLAGS value:[self searchFlags]];
  long position = 0;
  NSInteger count = 0;
  while (position <= [editor getGeneralProperty:SCI_GETLENGTH] && count < 1000000) {
    long found = [self search:editor pattern:pattern from:position to:[editor getGeneralProperty:SCI_GETLENGTH]];
    if ([self reportInvalidPattern:found]) return -1;
    if (found < 0) break;
    long end = [editor getGeneralProperty:SCI_GETTARGETEND];
    long next = block(found, end);
    count += 1;
    long length = [editor getGeneralProperty:SCI_GETLENGTH];
    if (next <= found) next = found < length ? [editor getGeneralProperty:SCI_POSITIONAFTER parameter:found] : length + 1;
    position = next;
  }
  return count;
}

- (NSInteger)replaceAllInEditor:(ScintillaView *)editor {
  NSData *replacement = [self replacementData];
  unsigned int message = self.usesRegex ? SCI_REPLACETARGETRE : SCI_REPLACETARGET;
  [editor message:SCI_BEGINUNDOACTION];
  NSInteger count = [self enumerateMatchesInEditor:editor usingBlock:^long(long start, long end) {
    long inserted = [editor message:message wParam:replacement.length lParam:(sptr_t)(replacement.length ? replacement.bytes : "")];
    if (end == start) {
      long length = [editor getGeneralProperty:SCI_GETLENGTH];
      return start + inserted < length ? [editor getGeneralProperty:SCI_POSITIONAFTER parameter:start + inserted] : length + 1;
    }
    return start + inserted;
  }];
  [editor message:SCI_ENDUNDOACTION];
  return count;
}

- (void)replaceAll:(id)sender {
  (void)sender;
  if (![self searchPattern] || ![self editorIsWritable]) return;
  [self rememberSearchQuery:self.searchField.stringValue];
  NSInteger count = [self replaceAllInEditor:self.activeEditor];
  if (count >= 0) [self setStatus:[NSString stringWithFormat:@"Replace All: %ld occurrences were replaced", (long)count]];
}

- (void)replaceAllInOpenDocuments:(id)sender {
  (void)sender;
  if (![self searchPattern]) return;
  NSInteger total = 0;
  NSInteger documents = 0;
  for (NativeDocument *document in self.documents) {
    if (document.isReadOnly) continue;
    NSInteger count = [self replaceAllInEditor:document.editor];
    if (count < 0) return;
    total += count;
    if (count) documents += 1;
  }
  [self setStatus:[NSString stringWithFormat:@"Replace in Opened Documents: %ld occurrences replaced in %ld documents", (long)total, (long)documents]];
}

- (void)countMatches:(id)sender {
  (void)sender;
  NSInteger count = [self enumerateMatchesInEditor:self.activeEditor usingBlock:^long(long start, long end) { (void)start; return end; }];
  if (count >= 0) [self setStatus:[NSString stringWithFormat:@"Count: %ld matches", (long)count]];
}

- (void)markAll:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  [self clearMarks:nil];
  [editor setGeneralProperty:SCI_SETINDICATORCURRENT value:kNativeMarkIndicator];
  BOOL bookmark = self.bookmarkLineButton.state == NSControlStateValueOn;
  NSInteger count = [self enumerateMatchesInEditor:editor usingBlock:^long(long start, long end) {
    [editor setGeneralProperty:SCI_SETINDICATORCURRENT value:kNativeMarkIndicator];
    [editor setGeneralProperty:SCI_INDICATORFILLRANGE parameter:start value:end - start];
    if (bookmark) {
      long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:start];
      if (!([editor getGeneralProperty:SCI_MARKERGET parameter:line] & (1L << kNativeBookmarkMarker))) {
        [editor setGeneralProperty:SCI_MARKERADD parameter:line value:kNativeBookmarkMarker];
      }
    }
    return end;
  }];
  if (count >= 0) [self setStatus:[NSString stringWithFormat:@"Mark: %ld matches", (long)count]];
}

- (void)clearMarks:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  [editor setGeneralProperty:SCI_SETINDICATORCURRENT value:kNativeMarkIndicator];
  [editor setGeneralProperty:SCI_INDICATORCLEARRANGE parameter:0 value:[editor getGeneralProperty:SCI_GETLENGTH]];
}

- (NSArray<NSDictionary *> *)findAllInDocuments:(NSArray<NativeDocument *> *)documents {
  NSMutableArray *results = [NSMutableArray array];
  for (NativeDocument *document in documents) {
    ScintillaView *editor = document.editor;
    __block long lastLine = -1;
    NSInteger count = [self enumerateMatchesInEditor:editor usingBlock:^long(long start, long end) {
      long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:start];
      if (line != lastLine && results.count < kMaxSearchResults) {
        NSString *text = [LineText(editor, line) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (text.length > 400) text = [text substringToIndex:400];
        [results addObject:@{@"document": document.identifier, @"name": document.name, @"line": @(line + 1),
                             @"text": text, @"position": @(start), @"length": @(end - start)}];
        lastLine = line;
      }
      return end;
    }];
    if (count < 0) return nil;
  }
  return results;
}

- (void)presentResults:(NSArray<NSDictionary *> *)results title:(NSString *)title {
  self.searchResults = results ?: @[];
  [self.resultsTable reloadData];
  [self.resultsTable tableColumnWithIdentifier:@"text"].title = title;
  [self showSearchResultsPane:YES];
  NSMutableSet *files = [NSMutableSet set];
  for (NSDictionary *result in self.searchResults) [files addObject:result[@"document"] ?: result[@"url"]];
  [self setStatus:[NSString stringWithFormat:@"%@: %lu hits in %lu files%@", title, (unsigned long)self.searchResults.count,
                   (unsigned long)files.count, self.searchResults.count >= kMaxSearchResults ? @" (results truncated)" : @""]];
}

- (void)findAllInCurrentDocument:(id)sender {
  (void)sender;
  if (![self searchPattern]) return;
  [self rememberSearchQuery:self.searchField.stringValue];
  NSArray *results = [self findAllInDocuments:@[self.activeDocument]];
  if (results) [self presentResults:results title:[NSString stringWithFormat:@"Search \"%@\"", self.searchField.stringValue]];
}

- (void)findAllInOpenDocuments:(id)sender {
  (void)sender;
  if (![self searchPattern]) return;
  [self rememberSearchQuery:self.searchField.stringValue];
  NSArray *results = [self findAllInDocuments:self.documents];
  if (results) [self presentResults:results title:[NSString stringWithFormat:@"Search \"%@\"", self.searchField.stringValue]];
}

- (void)goToLine:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  long lineCount = [editor getGeneralProperty:SCI_GETLINECOUNT];
  long current = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:[editor getGeneralProperty:SCI_GETCURRENTPOS]] + 1;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Go to Line";
  alert.informativeText = [NSString stringWithFormat:@"You are here: %ld. Enter a line from 1 to %ld.", current, lineCount];
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
  field.stringValue = [NSString stringWithFormat:@"%ld", current];
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Go"];
  [alert addButtonWithTitle:@"Cancel"];
  alert.window.initialFirstResponder = field;
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  long line = MAX(1L, MIN((long)field.integerValue, lineCount)) - 1;
  [editor setGeneralProperty:SCI_ENSUREVISIBLEENFORCEPOLICY value:line];
  [editor setGeneralProperty:SCI_GOTOLINE value:line];
  [self.window makeFirstResponder:editor.content];
}

- (long)braceAtCaret:(ScintillaView *)editor {
  long position = [editor getGeneralProperty:SCI_GETCURRENTPOS];
  const char *braces = "()[]{}<>";
  int after = (int)[editor getGeneralProperty:SCI_GETCHARAT parameter:position];
  if (after > 0 && strchr(braces, after)) return position;
  int before = position > 0 ? (int)[editor getGeneralProperty:SCI_GETCHARAT parameter:position - 1] : 0;
  if (before > 0 && strchr(braces, before)) return position - 1;
  return -1;
}

- (void)goToMatchingBrace:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  long brace = [self braceAtCaret:editor];
  long match = brace >= 0 ? [editor getGeneralProperty:SCI_BRACEMATCH parameter:brace extra:0] : -1;
  if (match >= 0) [editor setGeneralProperty:SCI_GOTOPOS value:match];
  else NSBeep();
}

- (void)selectToMatchingBrace:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  long brace = [self braceAtCaret:editor];
  long match = brace >= 0 ? [editor getGeneralProperty:SCI_BRACEMATCH parameter:brace extra:0] : -1;
  if (match < 0) {
    NSBeep();
    return;
  }
  [editor setGeneralProperty:SCI_SETSEL parameter:MIN(brace, match) value:MAX(brace, match) + 1];
}

#pragma mark - Find in files

static BOOL MatchesFilters(NSString *name, NSArray<NSString *> *include, NSArray<NSString *> *exclude) {
  for (NSString *pattern in exclude) if (fnmatch(pattern.UTF8String, name.UTF8String, FNM_CASEFOLD) == 0) return NO;
  if (!include.count) return YES;
  for (NSString *pattern in include) {
    if ([pattern isEqualToString:@"*.*"] || [pattern isEqualToString:@"*"]) return YES;
    if (fnmatch(pattern.UTF8String, name.UTF8String, FNM_CASEFOLD) == 0) return YES;
  }
  return NO;
}

- (void)performProjectSearchInDirectory:(NSURL *)directory replacing:(BOOL)replace filters:(NSString *)filters {
  NSString *query = self.searchField.stringValue;
  if (!query.length) return;
  [self rememberSearchQuery:query];
  if (!self.usesRegex && self.extendedButton.state == NSControlStateValueOn) query = UnescapeExtended(query);
  NSString *patternText = self.usesRegex ? query : [NSRegularExpression escapedPatternForString:query];
  if (self.wholeWordButton.state == NSControlStateValueOn) patternText = [NSString stringWithFormat:@"\\b(?:%@)\\b", patternText];
  NSRegularExpressionOptions options = NSRegularExpressionAnchorsMatchLines;
  if (self.matchCaseButton.state != NSControlStateValueOn) options |= NSRegularExpressionCaseInsensitive;
  NSError *regexError = nil;
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:patternText options:options error:&regexError];
  if (!regex) {
    [self showError:regexError];
    return;
  }
  NSString *template_ = self.usesRegex ? self.replacementField.stringValue
                                       : [NSRegularExpression escapedTemplateForString:self.extendedButton.state == NSControlStateValueOn
                                            ? UnescapeExtended(self.replacementField.stringValue) : self.replacementField.stringValue];
  NSMutableArray *include = [NSMutableArray array];
  NSMutableArray *exclude = [NSMutableArray array];
  for (NSString *filter in [filters componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ;,"]]) {
    if (!filter.length) continue;
    if ([filter hasPrefix:@"!"]) [exclude addObject:[filter substringFromIndex:1]];
    else [include addObject:filter];
  }

  NSDirectoryEnumerator<NSURL *> *enumerator = [[NSFileManager defaultManager] enumeratorAtURL:directory
      includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLFileSizeKey] options:NSDirectoryEnumerationSkipsHiddenFiles
      errorHandler:^BOOL(NSURL *url, NSError *error) { (void)url; (void)error; return YES; }];
  NSSet *excludedDirectories = [NSSet setWithArray:@[@".git", @"node_modules", @".svn", @".hg", @"DerivedData", @"__pycache__"]];
  NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
  NSMutableArray<NSDictionary *> *matchingFiles = [NSMutableArray array];
  NSInteger totalMatches = 0;
  NSInteger scanned = 0;

  for (NSURL *url in enumerator) {
    NSNumber *isDirectory = nil;
    [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
    if (isDirectory.boolValue) {
      if ([excludedDirectories containsObject:url.lastPathComponent]) [enumerator skipDescendants];
      continue;
    }
    if (!MatchesFilters(url.lastPathComponent, include, exclude)) continue;
    if (++scanned > 20000) break;
    NSNumber *fileSize = nil;
    [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
    if (fileSize.unsignedLongLongValue > 4 * 1024 * 1024) continue;
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length) continue;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    BOOL unicodeFile = data.length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF));
    if (!unicodeFile && memchr(bytes, 0, MIN(data.length, (NSUInteger)8192))) continue;
    NSStringEncoding encoding = NSUTF8StringEncoding;
    NSString *text = [[NSString alloc] initWithData:data encoding:encoding];
    if (!text) text = [NSString stringWithContentsOfURL:url usedEncoding:&encoding error:nil];
    if (!text) continue;

    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!matches.count) continue;
    totalMatches += (NSInteger)matches.count;
    [matchingFiles addObject:@{@"url": url, @"count": @(matches.count), @"encoding": @(encoding)}];
    if (replace) continue;

    NSUInteger lineNumber = 1;
    NSUInteger scanPosition = 0;
    NSUInteger lastReportedLine = 0;
    for (NSTextCheckingResult *match in matches) {
      while (scanPosition < match.range.location) {
        NSRange newline = [text rangeOfString:@"\n" options:NSLiteralSearch range:NSMakeRange(scanPosition, match.range.location - scanPosition)];
        if (newline.location == NSNotFound) break;
        lineNumber += 1;
        scanPosition = NSMaxRange(newline);
      }
      if (lineNumber == lastReportedLine) continue;
      lastReportedLine = lineNumber;
      NSRange lineRange = [text lineRangeForRange:NSMakeRange(match.range.location, 0)];
      NSString *lineText = [[text substringWithRange:lineRange] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      if (lineText.length > 400) lineText = [lineText substringToIndex:400];
      NSString *relative = [url.path hasPrefix:directory.path] ? [url.path substringFromIndex:directory.path.length + 1] : url.path;
      [results addObject:@{@"url": url, @"name": relative, @"line": @(lineNumber), @"text": lineText}];
      if (results.count >= kMaxSearchResults) break;
    }
    if (results.count >= kMaxSearchResults) break;
  }

  if (!replace) {
    [self presentResults:results title:[NSString stringWithFormat:@"Search \"%@\" in %@", self.searchField.stringValue, directory.lastPathComponent]];
    return;
  }
  if (!totalMatches) {
    [self setStatus:@"Replace in Files: no matches"];
    return;
  }

  NSAlert *confirm = [[NSAlert alloc] init];
  confirm.messageText = [NSString stringWithFormat:@"Replace %ld occurrences in %lu files?", (long)totalMatches, (unsigned long)matchingFiles.count];
  confirm.informativeText = [NSString stringWithFormat:@"Files under %@ will be changed on disk. This can't be undone from the editor.", directory.path];
  [confirm addButtonWithTitle:@"Replace"];
  [confirm addButtonWithTitle:@"Cancel"];
  if ([confirm runModal] != NSAlertFirstButtonReturn) return;

  NSInteger replaced = 0;
  NSMutableArray<NSString *> *skipped = [NSMutableArray array];
  NSMutableSet<NSURL *> *changed = [NSMutableSet set];
  for (NSDictionary *file in matchingFiles) {
    NSURL *url = file[@"url"];
    BOOL dirtyOpen = NO;
    for (NativeDocument *document in self.documents) {
      if (document.isDirty && [document.fileURL.URLByResolvingSymlinksInPath isEqual:url.URLByResolvingSymlinksInPath]) dirtyOpen = YES;
    }
    if (dirtyOpen) {
      [skipped addObject:url.lastPathComponent];
      continue;
    }
    NSStringEncoding encoding = [file[@"encoding"] unsignedIntegerValue];
    NSString *text = [NSString stringWithContentsOfURL:url encoding:encoding error:nil];
    if (!text) continue;
    NSMutableString *updated = [text mutableCopy];
    NSUInteger count = [regex replaceMatchesInString:updated options:0 range:NSMakeRange(0, updated.length) withTemplate:template_];
    NSData *data = [updated dataUsingEncoding:encoding allowLossyConversion:NO];
    if (data && [data writeToURL:url options:NSDataWritingAtomic error:nil]) {
      replaced += (NSInteger)count;
      [changed addObject:url.URLByResolvingSymlinksInPath];
    }
  }
  for (NativeDocument *document in self.documents) {
    if (document.fileURL && [changed containsObject:document.fileURL.URLByResolvingSymlinksInPath]) [document reloadFromDisk:nil];
  }
  [self setStatus:[NSString stringWithFormat:@"Replace in Files: %ld occurrences replaced in %lu files%@", (long)replaced,
                   (unsigned long)changed.count, skipped.count ? [NSString stringWithFormat:@"; skipped unsaved: %@",
                   [skipped componentsJoinedByString:@", "]] : @""]];
}

#pragma mark - Bookmarks

- (void)toggleBookmark:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:[editor getGeneralProperty:SCI_GETCURRENTPOS]];
  [self.activeDocument toggleBookmarkAtLine:line inEditor:editor];
}

- (void)nextBookmark:(id)sender {
  (void)sender;
  [self.activeDocument goToNextBookmarkInEditor:self.activeEditor backwards:NO];
}

- (void)previousBookmark:(id)sender {
  (void)sender;
  [self.activeDocument goToNextBookmarkInEditor:self.activeEditor backwards:YES];
}

- (void)clearBookmarks:(id)sender {
  (void)sender;
  [self.activeDocument clearBookmarks];
}

- (NSIndexSet *)bookmarkedLinesInEditor:(ScintillaView *)editor {
  NSMutableIndexSet *lines = [NSMutableIndexSet indexSet];
  long mask = 1L << kNativeBookmarkMarker;
  long line = [editor getGeneralProperty:SCI_MARKERNEXT parameter:0 extra:mask];
  while (line >= 0) {
    [lines addIndex:(NSUInteger)line];
    line = [editor getGeneralProperty:SCI_MARKERNEXT parameter:line + 1 extra:mask];
  }
  return lines;
}

- (void)copyBookmarkedLines:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  NSMutableArray *lines = [NSMutableArray array];
  [[self bookmarkedLinesInEditor:editor] enumerateIndexesUsingBlock:^(NSUInteger line, BOOL *stop) {
    (void)stop;
    [lines addObject:LineText(editor, (long)line)];
  }];
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:[lines componentsJoinedByString:EolString(editor)] forType:NSPasteboardTypeString];
  [self setStatus:[NSString stringWithFormat:@"Copied %lu bookmarked lines", (unsigned long)lines.count]];
}

- (void)removeLinesInEditor:(ScintillaView *)editor where:(BOOL (^)(BOOL bookmarked))predicate {
  if (![self editorIsWritable]) return;
  NSIndexSet *bookmarked = [self bookmarkedLinesInEditor:editor];
  long lineCount = [editor getGeneralProperty:SCI_GETLINECOUNT];
  [editor message:SCI_BEGINUNDOACTION];
  for (long line = lineCount - 1; line >= 0; line -= 1) {
    if (!predicate([bookmarked containsIndex:(NSUInteger)line])) continue;
    long start = [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:line];
    long end = line + 1 < [editor getGeneralProperty:SCI_GETLINECOUNT]
        ? [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:line + 1] : [editor getGeneralProperty:SCI_GETLENGTH];
    if (line + 1 >= [editor getGeneralProperty:SCI_GETLINECOUNT] && line > 0) {
      start = [editor getGeneralProperty:SCI_GETLINEENDPOSITION parameter:line - 1];
    }
    [editor setGeneralProperty:SCI_DELETERANGE parameter:start value:end - start];
  }
  [editor message:SCI_ENDUNDOACTION];
}

- (void)removeBookmarkedLines:(id)sender {
  (void)sender;
  [self removeLinesInEditor:self.activeEditor where:^BOOL(BOOL bookmarked) { return bookmarked; }];
}

- (void)removeUnbookmarkedLines:(id)sender {
  (void)sender;
  [self removeLinesInEditor:self.activeEditor where:^BOOL(BOOL bookmarked) { return !bookmarked; }];
}

- (void)inverseBookmarks:(id)sender {
  (void)sender;
  ScintillaView *editor = self.activeEditor;
  long lineCount = [editor getGeneralProperty:SCI_GETLINECOUNT];
  for (long line = 0; line < lineCount; line += 1) [self.activeDocument toggleBookmarkAtLine:line inEditor:editor];
}

#pragma mark - Macros

- (void)toggleMacroRecording:(id)sender {
  (void)sender;
  NativeDocument *document = self.activeDocument;
  if (!document) return;
  if (document.isRecordingMacro) {
    [document stopMacroRecording];
    self.currentMacro = [document.macroActions copy];
    [self setStatus:[NSString stringWithFormat:@"Macro recorded: %lu actions", (unsigned long)self.currentMacro.count]];
    [self scheduleSessionPersistence];
  } else {
    for (NativeDocument *other in self.documents) if (other.isRecordingMacro) [other stopMacroRecording];
    [document startMacroRecording];
    [self setStatus:@"Recording macro… (Macro > Stop Recording when done)"];
  }
}

- (void)startMacroRecordingCommand:(id)sender {
  if (!self.activeDocument.isRecordingMacro) [self toggleMacroRecording:sender];
}

- (void)stopMacroRecordingCommand:(id)sender {
  if (self.activeDocument.isRecordingMacro) [self toggleMacroRecording:sender];
}

- (void)playMacro:(id)sender {
  (void)sender;
  if (!self.currentMacro.count || ![self editorIsWritable]) return;
  [self.activeDocument playMacroActions:self.currentMacro inEditor:self.activeEditor];
}

- (void)runMacroMultipleTimes:(id)sender {
  (void)sender;
  if (!self.currentMacro.count || ![self editorIsWritable]) return;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Run a Macro Multiple Times";
  NSStackView *stack = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 260, 52)];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  NSTextField *timesField = [NSTextField textFieldWithString:@"1"];
  NSButton *untilEnd = [NSButton checkboxWithTitle:@"Run until the end of file" target:nil action:nil];
  [stack addArrangedSubview:timesField];
  [stack addArrangedSubview:untilEnd];
  alert.accessoryView = stack;
  [alert addButtonWithTitle:@"Run"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  ScintillaView *editor = self.activeEditor;
  NSInteger times = untilEnd.state == NSControlStateValueOn ? 1000000 : MAX(1, timesField.integerValue);
  NSInteger runs = 0;
  for (; runs < times; runs += 1) {
    long before = [editor getGeneralProperty:SCI_GETCURRENTPOS];
    long lengthBefore = [editor getGeneralProperty:SCI_GETLENGTH];
    [self.activeDocument playMacroActions:self.currentMacro inEditor:editor];
    if (untilEnd.state != NSControlStateValueOn) continue;
    long after = [editor getGeneralProperty:SCI_GETCURRENTPOS];
    if (after >= [editor getGeneralProperty:SCI_GETLENGTH] || (after == before && lengthBefore == [editor getGeneralProperty:SCI_GETLENGTH])) {
      runs += 1;
      break;
    }
  }
  [self setStatus:[NSString stringWithFormat:@"Macro ran %ld times", (long)runs]];
}

- (void)saveCurrentMacro:(id)sender {
  (void)sender;
  if (!self.currentMacro.count) return;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Save Current Recorded Macro";
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
  field.placeholderString = @"Macro name";
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Save"];
  [alert addButtonWithTitle:@"Cancel"];
  alert.window.initialFirstResponder = field;
  if ([alert runModal] != NSAlertFirstButtonReturn || !field.stringValue.length) return;
  NSMutableArray *saved = [[[NSUserDefaults standardUserDefaults] arrayForKey:kSavedMacrosKey] mutableCopy] ?: [NSMutableArray array];
  [saved addObject:@{@"name": field.stringValue, @"actions": self.currentMacro}];
  [[NSUserDefaults standardUserDefaults] setObject:saved forKey:kSavedMacrosKey];
  [self rebuildMacroMenu];
}

- (void)playSavedMacro:(NSMenuItem *)sender {
  NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kSavedMacrosKey];
  if (sender.tag < 0 || sender.tag >= (NSInteger)saved.count || ![self editorIsWritable]) return;
  [self.activeDocument playMacroActions:saved[sender.tag][@"actions"] inEditor:self.activeEditor];
}

- (void)deleteSavedMacro:(id)sender {
  (void)sender;
  NSMutableArray *saved = [[[NSUserDefaults standardUserDefaults] arrayForKey:kSavedMacrosKey] mutableCopy];
  if (!saved.count) return;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Delete Saved Macro";
  NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 260, 28) pullsDown:NO];
  for (NSDictionary *macro in saved) [popup addItemWithTitle:macro[@"name"]];
  alert.accessoryView = popup;
  [alert addButtonWithTitle:@"Delete"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  [saved removeObjectAtIndex:(NSUInteger)popup.indexOfSelectedItem];
  [[NSUserDefaults standardUserDefaults] setObject:saved forKey:kSavedMacrosKey];
  [self rebuildMacroMenu];
}

#pragma mark - Run menu

- (void)buildRunMenu:(NSMenu *)menu {
  [self addMenuItem:@"Run…" action:@selector(runCommand:) key:@"r" modifiers:NSEventModifierFlagCommand | NSEventModifierFlagControl toMenu:menu];
  [menu addItem:NSMenuItem.separatorItem];
  [self addMenuItem:@"Launch in Default Browser" action:@selector(openInBrowser:) key:@"" toMenu:menu];
  [self addMenuItem:@"Open Containing Folder in Terminal" action:@selector(openInTerminal:) key:@"" toMenu:menu];
  [self addMenuItem:@"Open Containing Folder in Finder" action:@selector(revealInFinder:) key:@"" toMenu:menu];
  [menu addItem:NSMenuItem.separatorItem];
  [self addMenuItem:@"Search on Google" action:@selector(searchOnGoogle:) key:@"" toMenu:menu];
  [self addMenuItem:@"Search on Wikipedia" action:@selector(searchOnWikipedia:) key:@"" toMenu:menu];
}

- (NSString *)currentWord {
  ScintillaView *editor = self.activeEditor;
  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  if (start == end) {
    start = [editor getGeneralProperty:SCI_WORDSTARTPOSITION parameter:start extra:1];
    end = [editor getGeneralProperty:SCI_WORDENDPOSITION parameter:end extra:1];
  }
  return TextInRange(editor, start, end);
}

// Notepad++'s Run dialog variables: $(FULL_CURRENT_PATH), $(CURRENT_DIRECTORY),
// $(FILE_NAME), $(NAME_PART), $(EXT_PART), $(CURRENT_WORD), $(CURRENT_LINE).
- (NSString *)expandRunVariables:(NSString *)command {
  NativeDocument *document = self.activeDocument;
  ScintillaView *editor = self.activeEditor;
  NSString *path = document.fileURL.path ?: @"";
  NSString *(^quoted)(NSString *) = ^NSString *(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
  };
  long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:[editor getGeneralProperty:SCI_GETCURRENTPOS]] + 1;
  NSDictionary *variables = @{
    @"$(FULL_CURRENT_PATH)": quoted(path),
    @"$(CURRENT_DIRECTORY)": quoted(path.stringByDeletingLastPathComponent),
    @"$(FILE_NAME)": quoted(path.lastPathComponent),
    @"$(NAME_PART)": quoted(path.lastPathComponent.stringByDeletingPathExtension),
    @"$(EXT_PART)": quoted(path.pathExtension),
    @"$(CURRENT_WORD)": quoted([self currentWord]),
    @"$(CURRENT_LINE)": [NSString stringWithFormat:@"%ld", line],
  };
  NSMutableString *expanded = [command mutableCopy];
  [variables enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
    (void)stop;
    [expanded replaceOccurrencesOfString:key withString:value options:0 range:NSMakeRange(0, expanded.length)];
  }];
  return expanded;
}

- (void)runCommand:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Run";
  alert.informativeText = @"The program to run. Variables: $(FULL_CURRENT_PATH) $(CURRENT_DIRECTORY) $(FILE_NAME) $(NAME_PART) $(EXT_PART) $(CURRENT_WORD) $(CURRENT_LINE). The command runs in your login shell; its output appears in a Terminal window.";
  NSComboBox *field = [[NSComboBox alloc] initWithFrame:NSMakeRect(0, 0, 420, 26)];
  NSArray *history = [[NSUserDefaults standardUserDefaults] arrayForKey:@"NativeEditor.RunHistory.v1"] ?: @[];
  [field addItemsWithObjectValues:history];
  field.stringValue = history.firstObject ?: @"";
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Run"];
  [alert addButtonWithTitle:@"Cancel"];
  alert.window.initialFirstResponder = field;
  if ([alert runModal] != NSAlertFirstButtonReturn || !field.stringValue.length) return;
  NSString *command = field.stringValue;
  NSMutableArray *updated = [history mutableCopy];
  [updated removeObject:command];
  [updated insertObject:command atIndex:0];
  if (updated.count > 15) [updated removeLastObject];
  [[NSUserDefaults standardUserDefaults] setObject:updated forKey:@"NativeEditor.RunHistory.v1"];

  // Run through a temporary .command file so output is visible in Terminal.
  NSString *script = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"notepad-run-%@.command", NSUUID.UUID.UUIDString]];
  NSString *directory = self.activeDocument.fileURL.URLByDeletingLastPathComponent.path ?: NSHomeDirectory();
  NSString *body = [NSString stringWithFormat:@"#!/bin/zsh -l\ncd '%@' || exit 1\n%@\nrm -f \"$0\"\n",
                    [directory stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"], [self expandRunVariables:command]];
  NSError *error = nil;
  if (![body writeToFile:script atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
    [self showError:error];
    return;
  }
  [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0700} ofItemAtPath:script error:nil];
  [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:script]];
}

- (void)openInBrowser:(id)sender {
  (void)sender;
  NSURL *url = self.activeDocument.fileURL;
  if (!url) {
    [self setStatus:@"Save the file first to open it in a browser"];
    return;
  }
  NSURL *browser = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:[NSURL URLWithString:@"https://example.com"]];
  if (browser) {
    [[NSWorkspace sharedWorkspace] openURLs:@[url] withApplicationAtURL:browser configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
  } else {
    [[NSWorkspace sharedWorkspace] openURL:url];
  }
}

- (void)openInTerminal:(id)sender {
  (void)sender;
  NSURL *directory = self.activeDocument.fileURL.URLByDeletingLastPathComponent ?: [NSURL fileURLWithPath:NSHomeDirectory()];
  NSURL *terminal = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.apple.Terminal"];
  if (terminal) {
    [[NSWorkspace sharedWorkspace] openURLs:@[directory] withApplicationAtURL:terminal configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
  }
}

- (void)searchWebWithFormat:(NSString *)format {
  NSString *word = [[self currentWord] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!word.length) {
    [self setStatus:@"Select a word to search for"];
    return;
  }
  NSString *encoded = [word stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[NSString stringWithFormat:format, encoded]]];
}

- (void)searchOnGoogle:(id)sender {
  (void)sender;
  [self searchWebWithFormat:@"https://www.google.com/search?q=%@"];
}

- (void)searchOnWikipedia:(id)sender {
  (void)sender;
  [self searchWebWithFormat:@"https://en.wikipedia.org/wiki/Special:Search?search=%@"];
}

#pragma mark - Tools

- (NSString *)selectionOrDocumentText {
  ScintillaView *editor = self.activeEditor;
  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  return start == end ? editor.string : TextInRange(editor, start, end);
}

- (void)showHash:(NSMenuItem *)sender {
  NSString *algorithm = sender.representedObject;
  NSData *data = [[self selectionOrDocumentText] dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  unsigned char digest[CC_SHA512_DIGEST_LENGTH];
  NSUInteger length = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if ([algorithm isEqualToString:@"MD5"]) { CC_MD5(data.bytes, (CC_LONG)data.length, digest); length = CC_MD5_DIGEST_LENGTH; }
#pragma clang diagnostic pop
  if ([algorithm isEqualToString:@"SHA-1"]) { CC_SHA1(data.bytes, (CC_LONG)data.length, digest); length = CC_SHA1_DIGEST_LENGTH; }
  if ([algorithm isEqualToString:@"SHA-256"]) { CC_SHA256(data.bytes, (CC_LONG)data.length, digest); length = CC_SHA256_DIGEST_LENGTH; }
  if ([algorithm isEqualToString:@"SHA-512"]) { CC_SHA512(data.bytes, (CC_LONG)data.length, digest); length = CC_SHA512_DIGEST_LENGTH; }
  NSMutableString *hex = [NSMutableString stringWithCapacity:length * 2];
  for (NSUInteger index = 0; index < length; index += 1) [hex appendFormat:@"%02x", digest[index]];
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = [NSString stringWithFormat:@"%@ (UTF-8)", algorithm];
  alert.informativeText = hex;
  [alert addButtonWithTitle:@"Copy to Clipboard"];
  [alert addButtonWithTitle:@"Close"];
  if ([alert runModal] == NSAlertFirstButtonReturn) {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:hex forType:NSPasteboardTypeString];
  }
}

- (void)base64Encode:(id)sender {
  (void)sender;
  [self transformSelection:^NSString *(NSString *text) {
    return [[text dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
  }];
}

- (void)base64Decode:(id)sender {
  (void)sender;
  [self transformSelection:^NSString *(NSString *text) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:text options:NSDataBase64DecodingIgnoreUnknownCharacters];
    NSString *decoded = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!decoded) [self setStatus:@"Base64 Decode: the selection isn't Base64-encoded UTF-8 text"];
    return decoded;
  }];
}

- (void)urlEncode:(id)sender {
  (void)sender;
  [self transformSelection:^NSString *(NSString *text) {
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-._~"];
    return [text stringByAddingPercentEncodingWithAllowedCharacters:allowed];
  }];
}

- (void)urlDecode:(id)sender {
  (void)sender;
  [self transformSelection:^NSString *(NSString *text) {
    return [[text stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding];
  }];
}

#pragma mark - Plugin packs

- (NSMutableArray<NSDictionary *> *)installedPluginPacks {
  NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kPluginPacksKey];
  return stored ? [stored mutableCopy] : [NSMutableArray array];
}

- (void)importPluginPack:(id)sender {
  (void)sender;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseDirectories = NO;
  panel.canChooseFiles = YES;
  panel.allowsMultipleSelection = NO;
  if (@available(macOS 11.0, *)) {
    panel.allowedContentTypes = @[UTTypeJSON];
  }
  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    if (response != NSModalResponseOK || !panel.URL) return;
    NSNumber *fileSize = nil;
    [panel.URL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
    if (fileSize.unsignedIntegerValue > 512 * 1024) {
      [self showErrorMessage:@"Plugin packs must be smaller than 512 KB."];
      return;
    }
    NSData *data = [NSData dataWithContentsOfURL:panel.URL];
    NSError *error = nil;
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (![parsed isKindOfClass:NSDictionary.class]) {
      [self showError:error ?: [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil]];
      return;
    }
    NSDictionary *pack = parsed;
    NSString *identifier = pack[@"id"];
    NSString *name = pack[@"name"];
    NSArray *snippets = [pack[@"snippets"] isKindOfClass:NSArray.class] ? pack[@"snippets"] : @[];
    NSArray *rawActions = [pack[@"actions"] isKindOfClass:NSArray.class] ? pack[@"actions"] : @[];
    if (![identifier isKindOfClass:NSString.class] || !identifier.length || ![name isKindOfClass:NSString.class] || !name.length ||
        snippets.count > 100 || rawActions.count > 100) {
      [self showErrorMessage:@"A pack needs an id, a name, and at most 100 snippets and 100 actions."];
      return;
    }
    for (NSDictionary *snippet in snippets) {
      if (![snippet isKindOfClass:NSDictionary.class] || ![snippet[@"name"] isKindOfClass:NSString.class] ||
          ![snippet[@"body"] isKindOfClass:NSString.class] || [snippet[@"body"] length] > 10000) {
        [self showErrorMessage:@"The pack contains an invalid or oversized snippet."];
        return;
      }
    }
    // Actions accept {"find","replace"} or {"pattern","replacement"} keys; both are literal text.
    NSMutableArray *actions = [NSMutableArray array];
    for (NSDictionary *action in rawActions) {
      NSString *find = [action isKindOfClass:NSDictionary.class] ? (action[@"find"] ?: action[@"pattern"]) : nil;
      NSString *replace = [action isKindOfClass:NSDictionary.class] ? (action[@"replace"] ?: action[@"replacement"]) : nil;
      if (![action[@"name"] isKindOfClass:NSString.class] || ![find isKindOfClass:NSString.class] || !find.length ||
          ![replace isKindOfClass:NSString.class] || find.length > 200 || replace.length > 1000) {
        [self showErrorMessage:@"The pack contains an invalid or oversized text action."];
        return;
      }
      [actions addObject:@{@"name": action[@"name"], @"find": find, @"replace": replace}];
    }
    NSMutableArray *packs = [self installedPluginPacks];
    [packs removeObjectsAtIndexes:[packs indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry, NSUInteger idx, BOOL *stop) {
      (void)idx; (void)stop;
      return [entry[@"id"] isEqualToString:identifier];
    }]];
    [packs addObject:@{@"id": identifier, @"name": name, @"enabled": @YES, @"snippets": snippets, @"actions": actions}];
    [[NSUserDefaults standardUserDefaults] setObject:packs forKey:kPluginPacksKey];
    [self setStatus:[NSString stringWithFormat:@"Installed data-only pack: %@", name]];
  }];
}

- (NSArray<NSDictionary *> *)pluginEntriesForKey:(NSString *)key {
  NSMutableArray *entries = [NSMutableArray array];
  for (NSDictionary *pack in [self installedPluginPacks]) {
    if (![pack[@"enabled"] boolValue]) continue;
    for (NSDictionary *entry in pack[key] ?: @[]) {
      NSMutableDictionary *annotated = [entry mutableCopy];
      annotated[@"packName"] = pack[@"name"] ?: @"Plugin pack";
      [entries addObject:annotated];
    }
  }
  return entries;
}

- (NSInteger)choosePluginEntry:(NSArray<NSDictionary *> *)entries title:(NSString *)title button:(NSString *)button {
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = title;
  [alert addButtonWithTitle:button];
  [alert addButtonWithTitle:@"Cancel"];
  NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 320, 28) pullsDown:NO];
  for (NSDictionary *entry in entries) {
    [popup addItemWithTitle:[NSString stringWithFormat:@"%@  ·  %@", entry[@"name"], entry[@"packName"]]];
  }
  alert.accessoryView = popup;
  return [alert runModal] == NSAlertFirstButtonReturn ? popup.indexOfSelectedItem : -1;
}

- (void)insertSnippet:(id)sender {
  (void)sender;
  NSArray<NSDictionary *> *snippets = [self pluginEntriesForKey:@"snippets"];
  if (!snippets.count) {
    [self setStatus:@"No enabled plugin snippets. Use Plugins > Import JSON Plugin Pack first."];
    return;
  }
  NSInteger index = [self choosePluginEntry:snippets title:@"Insert Snippet" button:@"Insert"];
  if (index < 0) return;
  NSString *body = [snippets[index][@"body"] stringByReplacingOccurrencesOfString:@"$1" withString:@""];
  [self insertText:body];
}

- (void)runPluginAction:(id)sender {
  (void)sender;
  NSArray<NSDictionary *> *actions = [self pluginEntriesForKey:@"actions"];
  if (!actions.count) {
    [self setStatus:@"No enabled plugin text actions. Use Plugins > Import JSON Plugin Pack first."];
    return;
  }
  NSInteger index = [self choosePluginEntry:actions title:@"Run Text Action" button:@"Run"];
  if (index < 0 || ![self editorIsWritable]) return;
  NSDictionary *action = actions[index];
  NSData *find = [action[@"find"] dataUsingEncoding:NSUTF8StringEncoding];
  NSData *replace = [action[@"replace"] dataUsingEncoding:NSUTF8StringEncoding];
  ScintillaView *editor = self.activeEditor;
  [editor setGeneralProperty:SCI_SETSEARCHFLAGS value:SCFIND_MATCHCASE];
  [editor message:SCI_BEGINUNDOACTION];
  long position = 0;
  long count = 0;
  while (position <= [editor getGeneralProperty:SCI_GETLENGTH]) {
    long found = [self search:editor pattern:find from:position to:[editor getGeneralProperty:SCI_GETLENGTH]];
    if (found < 0) break;
    long inserted = [editor message:SCI_REPLACETARGET wParam:replace.length lParam:(sptr_t)(replace.length ? replace.bytes : "")];
    position = found + MAX(inserted, 1L);
    count += 1;
  }
  [editor message:SCI_ENDUNDOACTION];
  [self setStatus:[NSString stringWithFormat:@"%@: %ld replacements", action[@"name"], count]];
}

- (void)managePluginPacks:(id)sender {
  (void)sender;
  NSMutableArray *packs = [self installedPluginPacks];
  if (!packs.count) {
    [self importPluginPack:nil];
    return;
  }
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Manage Plugin Packs";
  [alert addButtonWithTitle:@"Toggle Enabled"];
  [alert addButtonWithTitle:@"Remove"];
  [alert addButtonWithTitle:@"Close"];
  NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 320, 28) pullsDown:NO];
  for (NSDictionary *pack in packs) {
    [popup addItemWithTitle:[NSString stringWithFormat:@"%@%@", [pack[@"enabled"] boolValue] ? @"✓ " : @"○ ", pack[@"name"]]];
  }
  alert.accessoryView = popup;
  NSModalResponse response = [alert runModal];
  NSInteger index = popup.indexOfSelectedItem;
  if (index < 0 || index >= (NSInteger)packs.count || response == NSAlertThirdButtonReturn) return;
  if (response == NSAlertFirstButtonReturn) {
    NSMutableDictionary *selectedPack = [packs[index] mutableCopy];
    selectedPack[@"enabled"] = @(![selectedPack[@"enabled"] boolValue]);
    packs[index] = selectedPack;
  }
  if (response == NSAlertSecondButtonReturn) [packs removeObjectAtIndex:index];
  [[NSUserDefaults standardUserDefaults] setObject:packs forKey:kPluginPacksKey];
}

@end
