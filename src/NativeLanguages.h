#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NativeStyleRole) {
  NativeStyleDefault = 0,
  NativeStyleComment,
  NativeStyleKeyword,
  NativeStyleKeyword2,
  NativeStyleString,
  NativeStyleNumber,
  NativeStyleOperator,
  NativeStylePreprocessor,
  NativeStyleTag,
  NativeStyleAttribute,
  NativeStyleType,
  NativeStyleVariable,
  NativeStyleHeading,
  NativeStyleError,
  NativeStyleAdded,
  NativeStyleDeleted,
  NativeStyleRoleCount
};

// One entry of the Language menu: which Lexilla lexer to use, its keyword lists,
// how its token styles map to theme colors, and its comment syntax.
@interface NativeLanguage : NSObject
@property(nonatomic, readonly) NSString *identifier;
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly, nullable) NSString *lexer;
@property(nonatomic, readonly) NSArray<NSString *> *extensions;
@property(nonatomic, readonly) NSArray<NSString *> *keywordSets;
@property(nonatomic, readonly) NSDictionary<NSString *, NSString *> *lexerProperties;
@property(nonatomic, readonly) NSDictionary<NSNumber *, NSNumber *> *styleRoles;
@property(nonatomic, readonly, nullable) NSString *lineComment;
@property(nonatomic, readonly, nullable) NSString *blockCommentStart;
@property(nonatomic, readonly, nullable) NSString *blockCommentEnd;

+ (NSArray<NativeLanguage *> *)allLanguages;
+ (NativeLanguage *)plainText;
+ (nullable NativeLanguage *)languageWithIdentifier:(NSString *)identifier;
+ (NativeLanguage *)languageForFileName:(NSString *)fileName firstLine:(nullable NSString *)firstLine;
@end

@interface NativeTheme : NSObject
@property(nonatomic, readonly, getter=isDark) BOOL dark;
@property(nonatomic, readonly) NSColor *background;
@property(nonatomic, readonly) NSColor *foreground;
@property(nonatomic, readonly) NSColor *caret;
@property(nonatomic, readonly) NSColor *caretLine;
@property(nonatomic, readonly) NSColor *selection;
@property(nonatomic, readonly) NSColor *marginBackground;
@property(nonatomic, readonly) NSColor *lineNumber;
@property(nonatomic, readonly) NSColor *foldMargin;
@property(nonatomic, readonly) NSColor *foldSymbol;
@property(nonatomic, readonly) NSColor *braceMatch;
@property(nonatomic, readonly) NSColor *braceBad;
@property(nonatomic, readonly) NSColor *indentGuide;
@property(nonatomic, readonly) NSColor *whitespace;
@property(nonatomic, readonly) NSColor *smartHighlight;
@property(nonatomic, readonly) NSColor *markHighlight;
@property(nonatomic, readonly) NSColor *bookmark;

+ (instancetype)themeDark:(BOOL)dark customBackground:(nullable NSColor *)background foreground:(nullable NSColor *)foreground;
+ (NSArray<NSString *> *)roleDisplayNames;
+ (NSString *)hexForColor:(NSColor *)color;
+ (nullable NSColor *)colorFromHex:(nullable NSString *)hex;
- (NSColor *)colorForRole:(NativeStyleRole)role;
- (BOOL)isBoldRole:(NativeStyleRole)role;
// Style Configurator overrides: {"background", "caretLine", "selection": "#RRGGBB",
// "roles": {"<role number>": {"color": "#RRGGBB", "bold": BOOL}}}.
- (void)applyOverrides:(nullable NSDictionary *)overrides;
@end

NS_ASSUME_NONNULL_END
