#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"

@class NativeLanguage, NativeTheme;

NS_ASSUME_NONNULL_BEGIN

extern const int kNativeBookmarkMarker;
extern const int kNativeSmartHighlightIndicator;
extern const int kNativeMarkIndicator;

// Keys for -[NativeDocument viewOptions]. Values are NSNumbers.
extern NSString * const NativeViewWordWrap;
extern NSString * const NativeViewLineNumbers;
extern NSString * const NativeViewWhitespace;
extern NSString * const NativeViewEndOfLine;
extern NSString * const NativeViewIndentGuides;
extern NSString * const NativeViewCaretLine;
extern NSString * const NativeViewTabWidth;
extern NSString * const NativeViewUseTabs;
extern NSString * const NativeViewAutoIndent;
extern NSString * const NativeViewAutoComplete;
extern NSString * const NativeViewSmartHighlight;
extern NSString * const NativeViewFontSize;
extern NSString * const NativeViewFontName;
extern NSString * const NativeViewAutoClose;
extern NSString * const NativeViewChangeHistory;

@interface NativeDocument : NSObject

@property(nonatomic, readonly) NSString *identifier;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong, nullable) NSURL *fileURL;
@property(nonatomic, strong, nullable) NSDate *fileModificationDate;
@property(nonatomic, strong, readonly) ScintillaView *editor;
@property(nonatomic, strong, readonly, nullable) ScintillaView *secondaryEditor;
@property(nonatomic, strong, readonly, nullable) NSSplitView *splitContainer;
@property(nonatomic, weak, readonly, nullable) NativeDocument *splitDocument;
@property(nonatomic, assign) NSStringEncoding encoding;
@property(nonatomic, assign) BOOL writesBOM;
@property(nonatomic, readonly) NSString *encodingDisplayName;
@property(nonatomic, copy) NSString *lineEnding;
@property(nonatomic, readonly) NSString *lineEndingDisplayName;
@property(nonatomic, readonly) NSString *language;
@property(nonatomic, readonly) NativeLanguage *languageDefinition;
@property(nonatomic, copy, nullable) NSString *userLanguageName;
@property(nonatomic, copy) NSString *userKeywords;
@property(nonatomic, strong) NativeTheme *theme;
@property(nonatomic, copy) NSDictionary<NSString *, id> *viewOptions;
@property(nonatomic, assign, getter=isReadOnly) BOOL readOnly;
@property(nonatomic, assign, getter=isDirty) BOOL dirty;
@property(nonatomic, copy, nullable) void (^changeHandler)(NativeDocument *document);
@property(nonatomic, copy, nullable) void (^sessionHandler)(NativeDocument *document);
@property(nonatomic, copy, nullable) void (^fileDropHandler)(NSURL *url);
// Increments on every text change; panels use it to know when to refresh.
@property(nonatomic, readonly) NSUInteger changeCount;
@property(nonatomic, readonly) NSMutableArray<NSDictionary *> *macroActions;
@property(nonatomic, assign, getter=isRecordingMacro) BOOL recordingMacro;

- (instancetype)initWithLexerFactory:(void *)lexerFactory;
- (BOOL)openURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;
- (BOOL)reloadFromDisk:(NSError * _Nullable * _Nullable)error;
- (BOOL)saveToURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;
- (BOOL)fileChangedOnDisk;
- (BOOL)isPristine;
- (void)setText:(NSString *)text;
- (void)setLanguage:(NSString *)language;
- (void)setUserLanguageName:(NSString *)name baseLanguage:(NSString *)base keywords:(NSString *)keywords;
- (void)convertLineEndingsTo:(NSString *)lineEnding;
- (NSSplitView *)enableSplitWithDocument:(NativeDocument *)document readOnly:(BOOL)readOnly;
- (void)disableSplit;
- (void)styleEditor:(ScintillaView *)editor;
- (void)toggleBookmarkAtLine:(NSInteger)line inEditor:(ScintillaView *)editor;
- (void)goToNextBookmarkInEditor:(ScintillaView *)editor backwards:(BOOL)backwards;
- (void)clearBookmarks;
- (void)startMacroRecording;
- (void)stopMacroRecording;
- (void)playMacroActions:(NSArray<NSDictionary *> *)actions inEditor:(ScintillaView *)editor;
- (void)handleNotification:(SCNotification *)notification fromEditor:(ScintillaView *)editor;

@end

NS_ASSUME_NONNULL_END
