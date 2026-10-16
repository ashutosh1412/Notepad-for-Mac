#import "NativeDocument.h"
#import "NativeLanguages.h"
#include <cstring>
#include <string>
#include "ILexer.h"
#include "Lexilla.h"

// Markers 21-24 are Scintilla's change-history markers.
const int kNativeBookmarkMarker = 20;
const int kNativeSmartHighlightIndicator = 8;
const int kNativeMarkIndicator = 9;

NSString * const NativeViewWordWrap = @"wordWrap";
NSString * const NativeViewLineNumbers = @"lineNumbers";
NSString * const NativeViewWhitespace = @"whitespace";
NSString * const NativeViewEndOfLine = @"endOfLine";
NSString * const NativeViewIndentGuides = @"indentGuides";
NSString * const NativeViewCaretLine = @"caretLine";
NSString * const NativeViewTabWidth = @"tabWidth";
NSString * const NativeViewUseTabs = @"useTabs";
NSString * const NativeViewAutoIndent = @"autoIndent";
NSString * const NativeViewAutoComplete = @"autoComplete";
NSString * const NativeViewSmartHighlight = @"smartHighlight";
NSString * const NativeViewFontSize = @"fontSize";
NSString * const NativeViewFontName = @"fontName";
NSString * const NativeViewAutoClose = @"autoClose";
NSString * const NativeViewChangeHistory = @"changeHistory";
static const int kChangeHistoryMask = (1 << SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN) | (1 << SC_MARKNUM_HISTORY_SAVED) |
                                      (1 << SC_MARKNUM_HISTORY_MODIFIED) | (1 << SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED);

static long SciColour(NSColor *color) {
  NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.blackColor;
  long red = lround(rgb.redComponent * 255);
  long green = lround(rgb.greenComponent * 255);
  long blue = lround(rgb.blueComponent * 255);
  return red | (green << 8) | (blue << 16);
}

static long SciColourAlpha(NSColor *color, long alpha) {
  return SciColour(color) | (alpha << 24);
}

static BOOL IsWordByte(int ch) {
  return ch >= 0x80 || isalnum(ch) || ch == '_';
}

// Scintilla only sends notifications to its delegate, without saying which view
// sent them. One proxy per view keeps split editing and compare mode accurate.
@interface NativeEditorDelegate : NSObject <ScintillaNotificationProtocol>
@property(nonatomic, weak) NativeDocument *document;
@property(nonatomic, weak) ScintillaView *editor;
@end

@implementation NativeEditorDelegate
- (void)notification:(SCNotification *)notification {
  [self.document handleNotification:notification fromEditor:self.editor];
}
@end

@interface NativeDocument ()
@property(nonatomic, readwrite) NSString *identifier;
@property(nonatomic, strong, readwrite) ScintillaView *editor;
@property(nonatomic, strong, readwrite, nullable) ScintillaView *secondaryEditor;
@property(nonatomic, strong, readwrite, nullable) NSSplitView *splitContainer;
@property(nonatomic, weak, readwrite, nullable) NativeDocument *splitDocument;
@property(nonatomic, readwrite) NSMutableArray<NSDictionary *> *macroActions;
@property(nonatomic, readwrite) NativeLanguage *languageDefinition;
@property(nonatomic, strong) NativeEditorDelegate *primaryDelegate;
@property(nonatomic, strong, nullable) NativeEditorDelegate *secondaryDelegate;
@property(nonatomic, assign) void *lexerFactory;
@property(nonatomic, readwrite) NSUInteger changeCount;
// Positions of closing characters inserted by auto-close (innermost last), so typing
// a closer right before one of them skips over it instead of doubling it.
@property(nonatomic, strong) NSMutableArray<NSNumber *> *autoClosePositions;
@end

@implementation NativeDocument

- (instancetype)initWithLexerFactory:(void *)lexerFactory {
  self = [super init];
  if (!self) return nil;

  _identifier = NSUUID.UUID.UUIDString;
  _name = @"new 1";
  _encoding = NSUTF8StringEncoding;
  _lineEnding = @"LF";
  _userKeywords = @"";
  _lexerFactory = lexerFactory;
  _macroActions = [NSMutableArray array];
  _autoClosePositions = [NSMutableArray array];
  _theme = [NativeTheme themeDark:NO customBackground:nil foreground:nil];
  _viewOptions = @{};
  _languageDefinition = [NativeLanguage plainText];
  _editor = [[ScintillaView alloc] initWithFrame:NSZeroRect];
  _primaryDelegate = [[NativeEditorDelegate alloc] init];
  _primaryDelegate.document = self;
  _primaryDelegate.editor = _editor;
  _editor.delegate = _primaryDelegate;
  [self configureEditor:_editor];
  [_editor setGeneralProperty:SCI_SETCHANGEHISTORY value:SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS];
  [self setLanguage:@"text"];
  [_editor message:SCI_SETSAVEPOINT];
  return self;
}

- (void)dealloc {
  _editor.delegate = nil;
  _secondaryEditor.delegate = nil;
}

#pragma mark - Editor setup

- (void)configureEditor:(ScintillaView *)editor {
  [editor setGeneralProperty:SCI_SETMARGINTYPEN parameter:0 value:SC_MARGIN_NUMBER];
  [editor setGeneralProperty:SCI_SETMARGINTYPEN parameter:1 value:SC_MARGIN_SYMBOL];
  [editor setGeneralProperty:SCI_SETMARGINWIDTHN parameter:1 value:14];
  [editor setGeneralProperty:SCI_SETMARGINMASKN parameter:1 value:1L << kNativeBookmarkMarker];
  [editor setGeneralProperty:SCI_SETMARGINSENSITIVEN parameter:1 value:1];
  [editor setGeneralProperty:SCI_SETMARGINTYPEN parameter:2 value:SC_MARGIN_SYMBOL];
  [editor setGeneralProperty:SCI_SETMARGINWIDTHN parameter:2 value:14];
  [editor setGeneralProperty:SCI_SETMARGINMASKN parameter:2 value:SC_MASK_FOLDERS];
  [editor setGeneralProperty:SCI_SETMARGINSENSITIVEN parameter:2 value:1];
  [editor setGeneralProperty:SCI_SETMARGINTYPEN parameter:3 value:SC_MARGIN_SYMBOL];
  [editor setGeneralProperty:SCI_SETMARGINMASKN parameter:3 value:kChangeHistoryMask];
  [editor setGeneralProperty:SCI_SETAUTOMATICFOLD value:SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE];
  [editor setGeneralProperty:SCI_SETFOLDFLAGS value:SC_FOLDFLAG_LINEAFTER_CONTRACTED];
  [editor setGeneralProperty:SCI_MARKERDEFINE parameter:SC_MARKNUM_FOLDEROPEN value:SC_MARK_BOXMINUS];
  [editor setGeneralProperty:SCI_MARKERDEFINE parameter:SC_MARKNUM_FOLDER value:SC_MARK_BOXPLUS];
  [editor setGeneralProperty:SCI_MARKERDEFINE parameter:SC_MARKNUM_FOLDERSUB value:SC_MARK_VLINE];
  [editor setGeneralProperty:SCI_MARKERDEFINE parameter:SC_MARKNUM_FOLDERTAIL value:SC_MARK_LCORNER];
  [editor setGeneralProperty:SCI_MARKERDEFINE parameter:SC_MARKNUM_FOLDEREND value:SC_MARK_BOXPLUSCONNECTED];
  [editor setGeneralProperty:SCI_MARKERDEFINE parameter:SC_MARKNUM_FOLDEROPENMID value:SC_MARK_BOXMINUSCONNECTED];
  [editor setGeneralProperty:SCI_MARKERDEFINE parameter:SC_MARKNUM_FOLDERMIDTAIL value:SC_MARK_TCORNER];
  [editor setGeneralProperty:SCI_MARKERDEFINE parameter:kNativeBookmarkMarker value:SC_MARK_BOOKMARK];

  [editor setGeneralProperty:SCI_SETMULTIPLESELECTION value:1];
  [editor setGeneralProperty:SCI_SETADDITIONALSELECTIONTYPING value:1];
  [editor setGeneralProperty:SCI_SETMULTIPASTE value:SC_MULTIPASTE_EACH];
  [editor setGeneralProperty:SCI_SETMOUSESELECTIONRECTANGULARSWITCH value:1];
  [editor setGeneralProperty:SCI_SETVIRTUALSPACEOPTIONS value:SCVS_RECTANGULARSELECTION];
  [editor setGeneralProperty:SCI_SETSCROLLWIDTH value:1];
  [editor setGeneralProperty:SCI_SETSCROLLWIDTHTRACKING value:1];
  [editor setGeneralProperty:SCI_SETTABINDENTS value:1];
  [editor setGeneralProperty:SCI_SETBACKSPACEUNINDENTS value:1];
  [editor setGeneralProperty:SCI_SETCARETLINEVISIBLEALWAYS value:1];
  [editor setGeneralProperty:SCI_SETSELECTIONLAYER value:SC_LAYER_UNDER_TEXT];
  [editor setGeneralProperty:SCI_SETMOUSEDWELLTIME value:SC_TIME_FOREVER];
  [editor setGeneralProperty:SCI_AUTOCSETIGNORECASE value:1];
  [editor setGeneralProperty:SCI_AUTOCSETMAXHEIGHT value:10];
  [editor setGeneralProperty:SCI_AUTOCSETORDER value:SC_ORDER_PERFORMSORT];

  [editor setGeneralProperty:SCI_INDICSETSTYLE parameter:kNativeSmartHighlightIndicator value:INDIC_ROUNDBOX];
  [editor setGeneralProperty:SCI_INDICSETALPHA parameter:kNativeSmartHighlightIndicator value:100];
  [editor setGeneralProperty:SCI_INDICSETOUTLINEALPHA parameter:kNativeSmartHighlightIndicator value:150];
  [editor setGeneralProperty:SCI_INDICSETUNDER parameter:kNativeSmartHighlightIndicator value:1];
  [editor setGeneralProperty:SCI_INDICSETSTYLE parameter:kNativeMarkIndicator value:INDIC_ROUNDBOX];
  [editor setGeneralProperty:SCI_INDICSETALPHA parameter:kNativeMarkIndicator value:90];
  [editor setGeneralProperty:SCI_INDICSETOUTLINEALPHA parameter:kNativeMarkIndicator value:200];
  [editor setGeneralProperty:SCI_INDICSETUNDER parameter:kNativeMarkIndicator value:1];
  [self applyViewOptionsToEditor:editor];
}

- (void)styleEditor:(ScintillaView *)editor {
  NativeTheme *theme = self.theme;
  NSInteger fontSize = [self.viewOptions[NativeViewFontSize] integerValue] ?: 13;
  NSString *fontName = [self.viewOptions[NativeViewFontName] isKindOfClass:NSString.class] ? self.viewOptions[NativeViewFontName] : @"Menlo";
  [editor setStringProperty:SCI_STYLESETFONT parameter:STYLE_DEFAULT value:fontName];
  [editor setGeneralProperty:SCI_STYLESETSIZE parameter:STYLE_DEFAULT value:fontSize];
  [editor setGeneralProperty:SCI_STYLESETBOLD parameter:STYLE_DEFAULT value:0];
  [editor setGeneralProperty:SCI_STYLESETFORE parameter:STYLE_DEFAULT value:SciColour(theme.foreground)];
  [editor setGeneralProperty:SCI_STYLESETBACK parameter:STYLE_DEFAULT value:SciColour(theme.background)];
  [editor message:SCI_STYLECLEARALL];

  [self.languageDefinition.styleRoles enumerateKeysAndObjectsUsingBlock:^(NSNumber *style, NSNumber *role, BOOL *stop) {
    (void)stop;
    NativeStyleRole styleRole = (NativeStyleRole)role.integerValue;
    [editor setGeneralProperty:SCI_STYLESETFORE parameter:style.integerValue value:SciColour([theme colorForRole:styleRole])];
    [editor setGeneralProperty:SCI_STYLESETBOLD parameter:style.integerValue value:[theme isBoldRole:styleRole]];
  }];

  [editor setGeneralProperty:SCI_STYLESETFORE parameter:STYLE_LINENUMBER value:SciColour(theme.lineNumber)];
  [editor setGeneralProperty:SCI_STYLESETBACK parameter:STYLE_LINENUMBER value:SciColour(theme.marginBackground)];
  [editor setGeneralProperty:SCI_STYLESETFORE parameter:STYLE_BRACELIGHT value:SciColour(theme.braceMatch)];
  [editor setGeneralProperty:SCI_STYLESETBOLD parameter:STYLE_BRACELIGHT value:1];
  [editor setGeneralProperty:SCI_STYLESETFORE parameter:STYLE_BRACEBAD value:SciColour(theme.braceBad)];
  [editor setGeneralProperty:SCI_STYLESETFORE parameter:STYLE_INDENTGUIDE value:SciColour(theme.indentGuide)];
  [editor setGeneralProperty:SCI_SETELEMENTCOLOUR parameter:SC_ELEMENT_CARET value:SciColourAlpha(theme.caret, 0xFF)];
  [editor setGeneralProperty:SCI_SETELEMENTCOLOUR parameter:SC_ELEMENT_CARET_LINE_BACK value:SciColourAlpha(theme.caretLine, 0xFF)];
  [editor setGeneralProperty:SCI_SETELEMENTCOLOUR parameter:SC_ELEMENT_SELECTION_BACK value:SciColourAlpha(theme.selection, 0xFF)];
  [editor setGeneralProperty:SCI_SETELEMENTCOLOUR parameter:SC_ELEMENT_SELECTION_INACTIVE_BACK value:SciColourAlpha(theme.selection, 0xA0)];
  [editor setGeneralProperty:SCI_SETELEMENTCOLOUR parameter:SC_ELEMENT_WHITE_SPACE value:SciColourAlpha(theme.whitespace, 0xFF)];
  [editor setGeneralProperty:SCI_SETFOLDMARGINCOLOUR parameter:1 value:SciColour(theme.foldMargin)];
  [editor setGeneralProperty:SCI_SETFOLDMARGINHICOLOUR parameter:1 value:SciColour(theme.foldMargin)];
  for (int marker = SC_MARKNUM_FOLDEREND; marker <= SC_MARKNUM_FOLDEROPEN; marker += 1) {
    [editor setGeneralProperty:SCI_MARKERSETFORE parameter:marker value:SciColour(theme.foldMargin)];
    [editor setGeneralProperty:SCI_MARKERSETBACK parameter:marker value:SciColour(theme.foldSymbol)];
  }
  [editor setGeneralProperty:SCI_MARKERSETFORE parameter:kNativeBookmarkMarker value:SciColour(theme.bookmark)];
  [editor setGeneralProperty:SCI_MARKERSETBACK parameter:kNativeBookmarkMarker value:SciColour(theme.bookmark)];
  [editor setGeneralProperty:SCI_INDICSETFORE parameter:kNativeSmartHighlightIndicator value:SciColour(theme.smartHighlight)];
  [editor setGeneralProperty:SCI_INDICSETFORE parameter:kNativeMarkIndicator value:SciColour(theme.markHighlight)];
  [self updateLineNumberMarginForEditor:editor];
  [editor message:SCI_COLOURISE wParam:0 lParam:-1];
}

- (void)applyViewOptionsToEditor:(ScintillaView *)editor {
  NSDictionary *options = self.viewOptions;
  NSInteger tabWidth = [options[NativeViewTabWidth] integerValue] ?: 4;
  [editor setGeneralProperty:SCI_SETWRAPMODE value:[options[NativeViewWordWrap] boolValue] ? SC_WRAP_WORD : SC_WRAP_NONE];
  [editor setGeneralProperty:SCI_SETVIEWWS value:[options[NativeViewWhitespace] boolValue] ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE];
  [editor setGeneralProperty:SCI_SETVIEWEOL value:[options[NativeViewEndOfLine] boolValue]];
  [editor setGeneralProperty:SCI_SETINDENTATIONGUIDES value:[options[NativeViewIndentGuides] ?: @YES boolValue] ? SC_IV_LOOKBOTH : SC_IV_NONE];
  [editor setGeneralProperty:SCI_SETCARETLINEVISIBLE value:[options[NativeViewCaretLine] ?: @YES boolValue]];
  [editor setGeneralProperty:SCI_SETTABWIDTH value:tabWidth];
  [editor setGeneralProperty:SCI_SETINDENT value:0];
  [editor setGeneralProperty:SCI_SETUSETABS value:[options[NativeViewUseTabs] ?: @YES boolValue]];
  [editor setGeneralProperty:SCI_SETMARGINWIDTHN parameter:3 value:[options[NativeViewChangeHistory] ?: @YES boolValue] ? 4 : 0];
  [editor setGeneralProperty:SCI_SETWRAPVISUALFLAGS value:[options[@"wrapSymbol"] boolValue] ? SC_WRAPVISUALFLAG_END : SC_WRAPVISUALFLAG_NONE];
  // Non-printing and Unicode line-end characters, shown as small labels like Notepad++ does.
  NSDictionary<NSString *, NSString *> *nonPrinting = @{@"\u00A0": @"NBSP", @"\u200B": @"ZWSP", @"\u200C": @"ZWNJ", @"\u200D": @"ZWJ",
                                                        @"\u2060": @"WJ", @"\uFEFF": @"BOM", @"\u00AD": @"SHY"};
  NSDictionary<NSString *, NSString *> *controls = @{@"\u0085": @"NEL", @"\u2028": @"LS", @"\u2029": @"PS"};
  BOOL showNonPrinting = [options[@"nonPrinting"] boolValue], showControls = [options[@"controlChars"] boolValue];
  [nonPrinting enumerateKeysAndObjectsUsingBlock:^(NSString *character, NSString *label, BOOL *stop) {
    (void)stop;
    if (showNonPrinting) [editor message:SCI_SETREPRESENTATION wParam:(uptr_t)character.UTF8String lParam:(sptr_t)label.UTF8String];
    else [editor message:SCI_CLEARREPRESENTATION wParam:(uptr_t)character.UTF8String];
  }];
  [controls enumerateKeysAndObjectsUsingBlock:^(NSString *character, NSString *label, BOOL *stop) {
    (void)stop;
    if (showControls) [editor message:SCI_SETREPRESENTATION wParam:(uptr_t)character.UTF8String lParam:(sptr_t)label.UTF8String];
    else [editor message:SCI_CLEARREPRESENTATION wParam:(uptr_t)character.UTF8String];
  }];
  [self updateLineNumberMarginForEditor:editor];
}

- (void)updateLineNumberMarginForEditor:(ScintillaView *)editor {
  if (![self.viewOptions[NativeViewLineNumbers] ?: @YES boolValue]) {
    [editor setGeneralProperty:SCI_SETMARGINWIDTHN parameter:0 value:0];
    return;
  }
  long lines = [editor getGeneralProperty:SCI_GETLINECOUNT];
  NSUInteger lineDigits = [NSString stringWithFormat:@"%ld", lines].length;
  NSUInteger digits = MAX((NSUInteger)3, lineDigits);
  NSString *sample = [@"" stringByPaddingToLength:digits withString:@"9" startingAtIndex:0];
  long width = [editor message:SCI_TEXTWIDTH wParam:STYLE_LINENUMBER lParam:(sptr_t)sample.UTF8String];
  [editor setGeneralProperty:SCI_SETMARGINWIDTHN parameter:0 value:width + 10];
}

- (void)forEachEditor:(void (^)(ScintillaView *editor))block {
  block(self.editor);
  if (self.secondaryEditor && (!self.splitDocument || self.splitDocument == self)) block(self.secondaryEditor);
}

- (void)setTheme:(NativeTheme *)theme {
  _theme = theme;
  [self forEachEditor:^(ScintillaView *editor) { [self styleEditor:editor]; }];
  if (self.secondaryEditor && self.splitDocument && self.splitDocument != self) {
    [self.splitDocument styleEditor:self.secondaryEditor];
  }
}

- (void)setViewOptions:(NSDictionary<NSString *, id> *)viewOptions {
  BOOL fontChanged = ![viewOptions[NativeViewFontSize] isEqual:_viewOptions[NativeViewFontSize]] ||
                     ![viewOptions[NativeViewFontName] isEqual:_viewOptions[NativeViewFontName]];
  _viewOptions = [viewOptions copy];
  [self forEachEditor:^(ScintillaView *editor) {
    [self applyViewOptionsToEditor:editor];
    if (fontChanged) [self styleEditor:editor];
  }];
  if (self.secondaryEditor && self.splitDocument && self.splitDocument != self) {
    [self.splitDocument applyViewOptionsToEditor:self.secondaryEditor];
  }
}

- (void)setReadOnly:(BOOL)readOnly {
  _readOnly = readOnly;
  [self.editor setGeneralProperty:SCI_SETREADONLY value:readOnly];
  if (self.secondaryEditor && self.splitDocument == self) [self.secondaryEditor setGeneralProperty:SCI_SETREADONLY value:readOnly];
  [self notifyChange];
}

#pragma mark - Files and encodings

static NSString *DecodeText(NSData *data, NSStringEncoding *encoding, BOOL *bom) {
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  NSUInteger length = data.length;
  *bom = NO;
  if (length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    *encoding = NSUTF8StringEncoding;
    *bom = YES;
    return [[NSString alloc] initWithBytes:bytes + 3 length:length - 3 encoding:NSUTF8StringEncoding];
  }
  if (length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    *encoding = NSUTF16LittleEndianStringEncoding;
    *bom = YES;
    return [[NSString alloc] initWithBytes:bytes + 2 length:length - 2 encoding:NSUTF16LittleEndianStringEncoding];
  }
  if (length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    *encoding = NSUTF16BigEndianStringEncoding;
    *bom = YES;
    return [[NSString alloc] initWithBytes:bytes + 2 length:length - 2 encoding:NSUTF16BigEndianStringEncoding];
  }
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (text) {
    *encoding = NSUTF8StringEncoding;
    return text;
  }
  text = [[NSString alloc] initWithData:data encoding:NSWindowsCP1252StringEncoding];
  if (text) {
    *encoding = NSWindowsCP1252StringEncoding;
    return text;
  }
  *encoding = NSISOLatin1StringEncoding;
  return [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
}

static NSString *DetectLineEnding(NSString *text) {
  NSRange newline = [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]];
  if (newline.location == NSNotFound) return @"LF";
  if ([text characterAtIndex:newline.location] == '\n') return @"LF";
  if (newline.location + 1 < text.length && [text characterAtIndex:newline.location + 1] == '\n') return @"CRLF";
  return @"CR";
}

static long EolMode(NSString *lineEnding) {
  if ([lineEnding isEqualToString:@"CRLF"]) return SC_EOL_CRLF;
  if ([lineEnding isEqualToString:@"CR"]) return SC_EOL_CR;
  return SC_EOL_LF;
}

- (void)setEncoding:(NSStringEncoding)encoding {
  // NSUTF16StringEncoding is the platform-endian BOM form; store it explicitly.
  if (encoding == NSUTF16StringEncoding) {
    encoding = NSUTF16LittleEndianStringEncoding;
    _writesBOM = YES;
  }
  _encoding = encoding;
}

- (NSString *)encodingDisplayName {
  switch (self.encoding) {
    case NSUTF8StringEncoding: return self.writesBOM ? @"UTF-8-BOM" : @"UTF-8";
    case NSUTF16LittleEndianStringEncoding: return self.writesBOM ? @"UTF-16 LE BOM" : @"UTF-16 LE";
    case NSUTF16BigEndianStringEncoding: return self.writesBOM ? @"UTF-16 BE BOM" : @"UTF-16 BE";
    case NSWindowsCP1252StringEncoding: return @"Windows-1252";
    case NSISOLatin1StringEncoding: return @"ISO-8859-1";
    case NSMacOSRomanStringEncoding: return @"Mac Roman";
    default: {
      CFStringRef name = CFStringConvertEncodingToIANACharSetName(CFStringConvertNSStringEncodingToEncoding(self.encoding));
      return name ? [(__bridge NSString *)name uppercaseString] : @"Unknown";
    }
  }
}

- (NSString *)lineEndingDisplayName {
  if ([self.lineEnding isEqualToString:@"CRLF"]) return @"Windows (CR LF)";
  if ([self.lineEnding isEqualToString:@"CR"]) return @"Macintosh (CR)";
  return @"Unix (LF)";
}

- (void)setText:(NSString *)text {
  [self.editor setGeneralProperty:SCI_SETREADONLY value:0];
  [self.editor setGeneralProperty:SCI_SETUNDOCOLLECTION value:0];
  [self.editor setString:text ?: @""];
  [self.editor setGeneralProperty:SCI_SETCHANGEHISTORY value:SC_CHANGE_HISTORY_DISABLED];
  [self.editor message:SCI_EMPTYUNDOBUFFER];
  [self.editor setGeneralProperty:SCI_SETUNDOCOLLECTION value:1];
  // Notepad++-style change history: orange bar for unsaved edits, green for saved ones.
  [self.editor setGeneralProperty:SCI_SETCHANGEHISTORY value:SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS];
  [self.editor setGeneralProperty:SCI_SETREADONLY value:self.readOnly];
  [self.editor message:SCI_GOTOPOS wParam:0];
  [self updateLineNumberMarginForEditor:self.editor];
}

- (BOOL)openURL:(NSURL *)url error:(NSError **)error {
  NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
  if (!data) return NO;
  NSStringEncoding encoding = NSUTF8StringEncoding;
  BOOL bom = NO;
  NSString *contents = DecodeText(data, &encoding, &bom);

  _encoding = encoding;
  _writesBOM = bom;
  _lineEnding = DetectLineEnding(contents);
  [self.editor setGeneralProperty:SCI_SETEOLMODE value:EolMode(_lineEnding)];
  _fileURL = url;
  _name = url.lastPathComponent;
  [self setText:contents];
  NSRange firstLineEnd = [contents rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet];
  NSString *firstLine = [contents substringToIndex:firstLineEnd.location == NSNotFound ? MIN(contents.length, (NSUInteger)200) : firstLineEnd.location];
  NativeLanguage *language = [NativeLanguage languageForFileName:url.lastPathComponent firstLine:firstLine];
  [self setLanguage:language.identifier];
  [self.editor message:SCI_SETSAVEPOINT];
  _dirty = NO;
  [self rememberModificationDate];
  [self notifyChange];
  return YES;
}

- (BOOL)reloadFromDisk:(NSError **)error {
  if (!self.fileURL) return NO;
  long line = [self.editor getGeneralProperty:SCI_GETFIRSTVISIBLELINE];
  NSString *language = self.language;
  NSString *userLanguage = self.userLanguageName;
  NSString *userKeywords = self.userKeywords;
  if (![self openURL:self.fileURL error:error]) return NO;
  if (userLanguage) {
    [self setUserLanguageName:userLanguage baseLanguage:language keywords:userKeywords];
  } else {
    [self setLanguage:language];
  }
  [self.editor setGeneralProperty:SCI_SETFIRSTVISIBLELINE value:line];
  return YES;
}

- (BOOL)saveToURL:(NSURL *)url error:(NSError **)error {
  NSString *contents = self.editor.string ?: @"";
  NSData *encoded = [contents dataUsingEncoding:self.encoding allowLossyConversion:NO];
  if (!encoded) {
    if (error) {
      *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInapplicableStringEncodingError
                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:
                                 @"Some characters can't be saved as %@. Choose Encoding > UTF-8 and save again.", self.encodingDisplayName]}];
    }
    return NO;
  }
  NSMutableData *data = [NSMutableData data];
  if (self.writesBOM) {
    if (self.encoding == NSUTF8StringEncoding) [data appendBytes:"\xEF\xBB\xBF" length:3];
    if (self.encoding == NSUTF16LittleEndianStringEncoding) [data appendBytes:"\xFF\xFE" length:2];
    if (self.encoding == NSUTF16BigEndianStringEncoding) [data appendBytes:"\xFE\xFF" length:2];
  }
  [data appendData:encoded];
  if (![data writeToURL:url options:NSDataWritingAtomic error:error]) return NO;

  BOOL renamed = ![url isEqual:self.fileURL];
  _fileURL = url;
  _name = url.lastPathComponent;
  [self.editor message:SCI_SETSAVEPOINT];
  _dirty = NO;
  [self rememberModificationDate];
  if (renamed && [self.language isEqualToString:@"text"] && !self.userLanguageName) {
    [self setLanguage:[NativeLanguage languageForFileName:url.lastPathComponent firstLine:nil].identifier];
  }
  [self notifyChange];
  return YES;
}

- (void)rememberModificationDate {
  NSDate *date = nil;
  [self.fileURL removeCachedResourceValueForKey:NSURLContentModificationDateKey];
  [self.fileURL getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
  self.fileModificationDate = date;
}

- (BOOL)fileChangedOnDisk {
  if (!self.fileURL || !self.fileModificationDate) return NO;
  NSDate *date = nil;
  [self.fileURL removeCachedResourceValueForKey:NSURLContentModificationDateKey];
  if (![self.fileURL getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil] || !date) return YES;
  return ![date isEqualToDate:self.fileModificationDate];
}

- (BOOL)isPristine {
  return !self.fileURL && !self.isDirty && [self.editor getGeneralProperty:SCI_GETLENGTH] == 0;
}

- (void)convertLineEndingsTo:(NSString *)lineEnding {
  if ([lineEnding isEqualToString:self.lineEnding]) return;
  self.lineEnding = lineEnding;
  long mode = EolMode(lineEnding);
  [self.editor setGeneralProperty:SCI_SETEOLMODE value:mode];
  [self.editor setGeneralProperty:SCI_CONVERTEOLS value:mode];
  [self notifyChange];
}

#pragma mark - Languages

- (NSString *)language {
  return self.languageDefinition.identifier;
}

- (void)setLanguage:(NSString *)identifier {
  NativeLanguage *language = [NativeLanguage languageWithIdentifier:identifier] ?: [NativeLanguage plainText];
  _languageDefinition = language;
  _userLanguageName = nil;
  _userKeywords = @"";

  Scintilla::ILexer5 *lexer = NULL;
  if (self.lexerFactory && language.lexer) {
    Lexilla::CreateLexerFn createLexer = reinterpret_cast<Lexilla::CreateLexerFn>(self.lexerFactory);
    lexer = createLexer(language.lexer.UTF8String);
  }
  [self.editor setReferenceProperty:SCI_SETILEXER parameter:0 value:lexer];
  if (lexer) {
    [self.editor setLexerProperty:@"fold" value:@"1"];
    [self.editor setLexerProperty:@"fold.compact" value:@"0"];
    [self.editor setLexerProperty:@"fold.comment" value:@"1"];
    [self.editor setLexerProperty:@"fold.preprocessor" value:@"1"];
    [language.lexerProperties enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
      (void)stop;
      [self.editor setLexerProperty:key value:value];
    }];
    [language.keywordSets enumerateObjectsUsingBlock:^(NSString *keywords, NSUInteger index, BOOL *stop) {
      (void)stop;
      [self.editor message:SCI_SETKEYWORDS wParam:index lParam:(sptr_t)keywords.UTF8String];
    }];
  }
  [self forEachEditor:^(ScintillaView *editor) { [self styleEditor:editor]; }];
  [self notifyChange];
}

- (void)setUserLanguageName:(NSString *)name baseLanguage:(NSString *)base keywords:(NSString *)keywords {
  [self setLanguage:base];
  _userLanguageName = [name copy];
  _userKeywords = [keywords copy] ?: @"";
  if (_userKeywords.length > 0) {
    // User keywords use the lexer's secondary keyword list so they get their own color.
    NSString *existing = self.languageDefinition.keywordSets.count > 1 ? self.languageDefinition.keywordSets[1] : @"";
    NSString *combined = [NSString stringWithFormat:@"%@ %@", existing, _userKeywords];
    [self.editor message:SCI_SETKEYWORDS wParam:1 lParam:(sptr_t)combined.UTF8String];
    [self.editor message:SCI_COLOURISE wParam:0 lParam:-1];
  }
  [self notifyChange];
}

#pragma mark - Split and compare

- (NSSplitView *)enableSplitWithDocument:(NativeDocument *)document readOnly:(BOOL)readOnly {
  self.splitDocument = document;
  if (!self.secondaryEditor) {
    self.splitContainer = [[NSSplitView alloc] initWithFrame:NSZeroRect];
    self.splitContainer.vertical = YES;
    self.splitContainer.dividerStyle = NSSplitViewDividerStyleThin;
    self.splitContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.editor.frame = NSMakeRect(0, 0, 500, 600);
    self.secondaryEditor = [[ScintillaView alloc] initWithFrame:NSMakeRect(0, 0, 500, 600)];
    [self.splitContainer addArrangedSubview:self.editor];
    [self.splitContainer addArrangedSubview:self.secondaryEditor];
  }
  self.secondaryDelegate = [[NativeEditorDelegate alloc] init];
  self.secondaryDelegate.document = document;
  self.secondaryDelegate.editor = self.secondaryEditor;
  self.secondaryEditor.delegate = self.secondaryDelegate;

  long documentPointer = [document.editor getGeneralProperty:SCI_GETDOCPOINTER];
  [self.secondaryEditor setGeneralProperty:SCI_SETDOCPOINTER parameter:0 value:documentPointer];
  [document configureEditor:self.secondaryEditor];
  [document styleEditor:self.secondaryEditor];
  [self.secondaryEditor setGeneralProperty:SCI_SETREADONLY value:(readOnly || document.readOnly) ? 1 : 0];
  return self.splitContainer;
}

- (void)disableSplit {
  if (!self.secondaryEditor) return;
  self.secondaryEditor.delegate = nil;
  [self.secondaryEditor setGeneralProperty:SCI_SETDOCPOINTER parameter:0 value:0];
  [self.secondaryEditor removeFromSuperview];
  [self.editor removeFromSuperview];
  self.secondaryEditor = nil;
  self.secondaryDelegate = nil;
  self.splitContainer = nil;
  self.splitDocument = nil;
}

#pragma mark - Bookmarks and macros

- (void)toggleBookmarkAtLine:(NSInteger)line inEditor:(ScintillaView *)editor {
  long markers = [editor getGeneralProperty:SCI_MARKERGET parameter:line];
  if ((markers & (1L << kNativeBookmarkMarker)) != 0) {
    [editor setGeneralProperty:SCI_MARKERDELETE parameter:line value:kNativeBookmarkMarker];
  } else {
    [editor setGeneralProperty:SCI_MARKERADD parameter:line value:kNativeBookmarkMarker];
  }
  if (self.sessionHandler) self.sessionHandler(self);
}

- (void)goToNextBookmarkInEditor:(ScintillaView *)editor backwards:(BOOL)backwards {
  long position = [editor getGeneralProperty:SCI_GETCURRENTPOS];
  long currentLine = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:position];
  long mask = 1L << kNativeBookmarkMarker;
  long line;
  if (backwards) {
    line = [editor getGeneralProperty:SCI_MARKERPREVIOUS parameter:currentLine - 1 extra:mask];
    if (line < 0) line = [editor getGeneralProperty:SCI_MARKERPREVIOUS parameter:[editor getGeneralProperty:SCI_GETLINECOUNT] extra:mask];
  } else {
    line = [editor getGeneralProperty:SCI_MARKERNEXT parameter:currentLine + 1 extra:mask];
    if (line < 0) line = [editor getGeneralProperty:SCI_MARKERNEXT parameter:0 extra:mask];
  }
  if (line >= 0) {
    [editor setGeneralProperty:SCI_ENSUREVISIBLEENFORCEPOLICY value:line];
    [editor setGeneralProperty:SCI_GOTOLINE value:line];
  }
}

- (void)clearBookmarks {
  [self.editor setGeneralProperty:SCI_MARKERDELETEALL value:kNativeBookmarkMarker];
  if (self.sessionHandler) self.sessionHandler(self);
}

- (void)startMacroRecording {
  [_macroActions removeAllObjects];
  _recordingMacro = YES;
  [self forEachEditor:^(ScintillaView *editor) { [editor message:SCI_STARTRECORD]; }];
}

- (void)stopMacroRecording {
  [self forEachEditor:^(ScintillaView *editor) { [editor message:SCI_STOPRECORD]; }];
  _recordingMacro = NO;
}

- (void)playMacroActions:(NSArray<NSDictionary *> *)actions inEditor:(ScintillaView *)editor {
  [editor message:SCI_BEGINUNDOACTION];
  for (NSDictionary *action in actions) {
    unsigned int message = [action[@"message"] unsignedIntValue];
    uptr_t wParam = [action[@"wParam"] unsignedLongLongValue];
    NSData *bytes = action[@"bytes"];
    sptr_t lParam = bytes ? (sptr_t)bytes.bytes : (sptr_t)[action[@"lParam"] unsignedLongLongValue];
    [editor message:message wParam:wParam lParam:lParam];
  }
  [editor message:SCI_ENDUNDOACTION];
}

#pragma mark - Notifications

- (void)handleNotification:(SCNotification *)notification fromEditor:(ScintillaView *)editor {
  if (!editor) return;
  switch (notification->nmhdr.code) {
    case SCN_MACRORECORD:
      [self recordMacroNotification:notification];
      break;
    case SCN_MODIFIED:
      if (notification->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT)) {
        if (notification->linesAdded != 0) [self updateLineNumberMarginForEditor:editor];
        self.changeCount += 1;
        [self trackAutoCloseForModification:notification];
        if (self.sessionHandler) self.sessionHandler(self);
      }
      break;
    case SCN_SAVEPOINTREACHED:
      _dirty = NO;
      if (self.sessionHandler) self.sessionHandler(self);
      [self notifyChange];
      break;
    case SCN_SAVEPOINTLEFT:
      _dirty = YES;
      if (self.sessionHandler) self.sessionHandler(self);
      [self notifyChange];
      break;
    case SCN_MARGINCLICK:
      if (notification->margin == 1) {
        long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:notification->position];
        [self toggleBookmarkAtLine:line inEditor:editor];
      }
      break;
    case SCN_CHARADDED:
      [self handleCharacterAdded:notification->ch inEditor:editor];
      break;
    case SCN_URIDROPPED:
      if (notification->text && self.fileDropHandler) {
        self.fileDropHandler([NSURL fileURLWithPath:[NSString stringWithUTF8String:notification->text]]);
      }
      break;
    case SCN_ZOOM:
      [self updateLineNumberMarginForEditor:editor];
      break;
    case SCN_UPDATEUI:
      [self updateBraceHighlightInEditor:editor];
      if (self.autoClosePositions.count) {
        long caret = [editor getGeneralProperty:SCI_GETCURRENTPOS];
        long caretLine = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:caret];
        NSIndexSet *stale = [self.autoClosePositions indexesOfObjectsPassingTest:^BOOL(NSNumber *closer, NSUInteger index, BOOL *stop) {
          (void)index; (void)stop;
          return closer.longValue < caret || [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:closer.longValue] != caretLine;
        }];
        [self.autoClosePositions removeObjectsAtIndexes:stale];
      }
      if (notification->updated & SC_UPDATE_SELECTION) [self updateSmartHighlightInEditor:editor];
      [self notifyChange];
      break;
    default:
      break;
  }
}

- (void)recordMacroNotification:(SCNotification *)notification {
  if (!_recordingMacro) return;
  NSMutableDictionary *action = [@{
    @"message": @(notification->message),
    @"wParam": @(notification->wParam),
    @"lParam": @(notification->lParam)
  } mutableCopy];
  if (notification->message == SCI_REPLACESEL && notification->lParam) {
    action[@"bytes"] = [NSData dataWithBytes:((const char *)notification->lParam)
                                       length:strlen((const char *)notification->lParam) + 1];
  } else if (notification->message == SCI_ADDTEXT && notification->lParam && notification->wParam > 0) {
    action[@"bytes"] = [NSData dataWithBytes:(const void *)notification->lParam length:(NSUInteger)notification->wParam];
  }
  [_macroActions addObject:action];
}

- (void)handleCharacterAdded:(int)ch inEditor:(ScintillaView *)editor {
  long eolMode = [editor getGeneralProperty:SCI_GETEOLMODE];
  BOOL newline = ch == '\n' || (ch == '\r' && eolMode == SC_EOL_CR);
  if (newline && [self.viewOptions[NativeViewAutoIndent] ?: @YES boolValue]) {
    long position = [editor getGeneralProperty:SCI_GETCURRENTPOS];
    long line = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:position];
    if (line > 0) {
      long indent = [editor getGeneralProperty:SCI_GETLINEINDENTATION parameter:line - 1];
      if (indent > 0) {
        [editor setGeneralProperty:SCI_SETLINEINDENTATION parameter:line value:indent];
        long indentPosition = [editor getGeneralProperty:SCI_GETLINEINDENTPOSITION parameter:line];
        [editor setGeneralProperty:SCI_GOTOPOS value:indentPosition];
      }
    }
    return;
  }
  if ([self.viewOptions[NativeViewAutoClose] boolValue] && [self autoCloseCharacter:ch inEditor:editor]) return;
  if (IsWordByte(ch) && [self.viewOptions[NativeViewAutoComplete] boolValue]) [self showWordCompletionInEditor:editor];
}

- (void)trackAutoCloseForModification:(SCNotification *)notification {
  long position = notification->position;
  long length = notification->length;
  BOOL inserted = (notification->modificationType & SC_MOD_INSERTTEXT) != 0;
  NSMutableArray<NSNumber *> *updated = [NSMutableArray arrayWithCapacity:self.autoClosePositions.count];
  for (NSNumber *value in self.autoClosePositions) {
    long closer = value.longValue;
    if (inserted) {
      [updated addObject:@(position <= closer ? closer + length : closer)];
    } else if (position + length <= closer) {
      [updated addObject:@(closer - length)];
    } else if (position > closer) {
      [updated addObject:value];
    }
  }
  [self.autoClosePositions setArray:updated];
}

// Notepad++'s "Auto-Insert": typing an opening bracket or quote adds the closing one,
// and typing that closing character right after skips over the inserted one.
- (BOOL)autoCloseCharacter:(int)ch inEditor:(ScintillaView *)editor {
  if ([editor getGeneralProperty:SCI_GETSELECTIONS] != 1) return NO;
  long position = [editor getGeneralProperty:SCI_GETCURRENTPOS];
  int next = (int)[editor getGeneralProperty:SCI_GETCHARAT parameter:position];
  if ([self.autoClosePositions.lastObject longValue] == position && self.autoClosePositions.count && next == ch &&
      strchr(")]}\"'`", ch)) {
    [self.autoClosePositions removeLastObject];
    [editor setGeneralProperty:SCI_DELETERANGE parameter:position value:1];
    return YES;
  }
  const char *closer = NULL;
  switch (ch) {
    case '(': closer = ")"; break;
    case '[': closer = "]"; break;
    case '{': closer = "}"; break;
    case '"': closer = "\""; break;
    case '\'': closer = "'"; break;
    case '`': closer = "`"; break;
    default: return NO;
  }
  // Only close when the caret is followed by whitespace, end of line or a closer.
  if (next > 0 && !isspace(next) && !strchr(")]};,", next)) return NO;
  if (ch == '"' || ch == '\'' || ch == '`') {
    int previous = position >= 2 ? (int)[editor getGeneralProperty:SCI_GETCHARAT parameter:position - 2] : 0;
    if (IsWordByte(previous) || previous == ch) return NO;
  }
  [editor message:SCI_INSERTTEXT wParam:(uptr_t)position lParam:(sptr_t)closer];
  [self.autoClosePositions addObject:@(position)];
  return YES;
}

- (void)showWordCompletionInEditor:(ScintillaView *)editor {
  if ([editor getGeneralProperty:SCI_AUTOCACTIVE]) return;
  long position = [editor getGeneralProperty:SCI_GETCURRENTPOS];
  long wordStart = [editor getGeneralProperty:SCI_WORDSTARTPOSITION parameter:position extra:1];
  long typed = position - wordStart;
  long length = [editor getGeneralProperty:SCI_GETLENGTH];
  if (typed < 3 || length > 1024 * 1024) return;

  std::string prefixBytes(typed, '\0');
  [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:wordStart value:position];
  [editor message:SCI_GETTARGETTEXT wParam:0 lParam:(sptr_t)prefixBytes.data()];
  NSString *prefix = [[NSString alloc] initWithBytes:prefixBytes.data() length:prefixBytes.size() encoding:NSUTF8StringEncoding];
  if (!prefix.length) return;

  NSString *text = editor.string;
  NSString *pattern = [NSString stringWithFormat:@"(?<![\\w])%@[\\w]+", [NSRegularExpression escapedPatternForString:prefix]];
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
  NSMutableSet<NSString *> *words = [NSMutableSet set];
  [regex enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                       usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
    (void)flags;
    [words addObject:[text substringWithRange:match.range]];
    if (words.count > 500) *stop = YES;
  }];
  for (NSString *keywords in self.languageDefinition.keywordSets) {
    for (NSString *keyword in [keywords componentsSeparatedByString:@" "]) {
      if (keyword.length > prefix.length && [keyword.lowercaseString hasPrefix:prefix.lowercaseString]) [words addObject:keyword];
    }
  }
  if (!words.count) return;
  NSString *list = [[words allObjects] componentsJoinedByString:@" "];
  [editor message:SCI_AUTOCSHOW wParam:(uptr_t)typed lParam:(sptr_t)list.UTF8String];
}

- (void)updateBraceHighlightInEditor:(ScintillaView *)editor {
  static const char *braces = "()[]{}";
  long position = [editor getGeneralProperty:SCI_GETCURRENTPOS];
  long brace = -1;
  if (position > 0) {
    int before = (int)[editor getGeneralProperty:SCI_GETCHARAT parameter:position - 1];
    if (before > 0 && strchr(braces, before)) brace = position - 1;
  }
  if (brace < 0) {
    int after = (int)[editor getGeneralProperty:SCI_GETCHARAT parameter:position];
    if (after > 0 && strchr(braces, after)) brace = position;
  }
  if (brace < 0) {
    [editor setGeneralProperty:SCI_BRACEHIGHLIGHT parameter:-1 value:-1];
    return;
  }
  long match = [editor getGeneralProperty:SCI_BRACEMATCH parameter:brace extra:0];
  if (match >= 0) {
    [editor setGeneralProperty:SCI_BRACEHIGHLIGHT parameter:brace value:match];
  } else {
    [editor setGeneralProperty:SCI_BRACEBADLIGHT value:brace];
  }
}

// Notepad++'s "Smart Highlighting": select a whole word and every other
// occurrence of it in the document gets a green box.
- (void)updateSmartHighlightInEditor:(ScintillaView *)editor {
  long length = [editor getGeneralProperty:SCI_GETLENGTH];
  [editor setGeneralProperty:SCI_SETINDICATORCURRENT value:kNativeSmartHighlightIndicator];
  [editor setGeneralProperty:SCI_INDICATORCLEARRANGE parameter:0 value:length];
  if (![self.viewOptions[NativeViewSmartHighlight] ?: @YES boolValue]) return;
  if ([editor getGeneralProperty:SCI_GETSELECTIONS] != 1 || length > 20 * 1024 * 1024) return;

  long start = [editor getGeneralProperty:SCI_GETSELECTIONSTART];
  long end = [editor getGeneralProperty:SCI_GETSELECTIONEND];
  if (end <= start || end - start > 200) return;
  if ([editor getGeneralProperty:SCI_WORDSTARTPOSITION parameter:start extra:1] != start ||
      [editor getGeneralProperty:SCI_WORDENDPOSITION parameter:end extra:1] != end) return;
  std::string word(end - start, '\0');
  [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:start value:end];
  [editor message:SCI_GETTARGETTEXT wParam:0 lParam:(sptr_t)word.data()];
  for (char ch : word) {
    if (!IsWordByte((unsigned char)ch)) return;
  }

  [editor setGeneralProperty:SCI_SETSEARCHFLAGS value:SCFIND_MATCHCASE | SCFIND_WHOLEWORD];
  long searchStart = 0;
  int count = 0;
  while (searchStart < length && count < 5000) {
    [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:searchStart value:length];
    long found = [editor message:SCI_SEARCHINTARGET wParam:word.size() lParam:(sptr_t)word.data()];
    if (found < 0) break;
    long foundEnd = [editor getGeneralProperty:SCI_GETTARGETEND];
    if (found != start) [editor setGeneralProperty:SCI_INDICATORFILLRANGE parameter:found value:foundEnd - found];
    searchStart = MAX(foundEnd, found + 1);
    count += 1;
  }
  [editor setGeneralProperty:SCI_SETTARGETRANGE parameter:start value:end];
}

- (void)notifyChange {
  if (self.changeHandler) self.changeHandler(self);
}

@end
