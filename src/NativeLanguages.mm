#import "NativeLanguages.h"

// Style maps are "role:style,style role:style" strings keyed by Lexilla style numbers
// from SciLexer.h. Several languages share the C++ lexer with their own keywords.
static NSString * const kCppStyles = @"comment:1,2,3,15,17,18,23,24 number:4 keyword:5 keyword2:16 "
                                     @"string:6,7,12,13,14,20,21,22,27 preprocessor:9 operator:10 type:19 error:12";
static NSString * const kHtmlStyles = @"tag:1,2,11 attribute:3,4 number:5 string:6,7,17,19 comment:9,20,29 variable:10 "
                                      @"preprocessor:12,13,18 keyword:22 "
                                      @"comment:42,43,44 number:45 keyword:47 string:48,49,52,53 operator:50 error:51 "
                                      @"string:119,120 keyword:121 number:122 variable:104,123,126 comment:124,125 operator:127";

static NSString * const kCKeywords = @"auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while _Bool _Complex bool true false NULL";
static NSString * const kCppKeywords = @"alignas alignof and and_eq asm auto bitand bitor bool break case catch char char8_t char16_t char32_t class co_await co_return co_yield compl concept const consteval constexpr constinit const_cast continue decltype default delete do double dynamic_cast else enum explicit export extern false final float for friend goto if inline int long mutable namespace new noexcept not not_eq nullptr operator or or_eq override private protected public register reinterpret_cast requires return short signed sizeof static static_assert static_cast struct switch template this thread_local throw true try typedef typeid typename union unsigned using virtual void volatile wchar_t while xor xor_eq";
static NSString * const kCppTypes = @"int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t size_t ssize_t ptrdiff_t intptr_t uintptr_t std string vector map set unordered_map unique_ptr shared_ptr";
static NSString * const kObjCKeywords = @"@interface @implementation @end @property @synthesize @dynamic @protocol @class @selector @encode @autoreleasepool @try @catch @finally @throw @optional @required @import self super nil Nil YES NO id instancetype SEL IMP BOOL nonatomic atomic strong weak copy assign readonly readwrite nullable nonnull";
static NSString * const kCSharpKeywords = @"abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly record ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using var virtual void volatile while async await dynamic get set init value yield where nameof when";
static NSString * const kJavaKeywords = @"abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null var record sealed permits yield";
static NSString * const kJavaScriptKeywords = @"abstract async await boolean break byte case catch char class const continue debugger default delete do double else enum export extends false final finally float for function get goto if implements import in instanceof int interface let long native new null of package private protected public return set short static super switch synchronized this throw throws transient true try typeof undefined var void volatile while with yield";
static NSString * const kTypeScriptKeywords = @"abstract any as asserts async await bigint boolean break case catch class const constructor continue debugger declare default delete do else enum export extends false finally for from function get if implements import in infer instanceof interface is keyof let module namespace never new null number object of package private protected public readonly require return satisfies set static string super switch symbol this throw true try type typeof undefined unique unknown var void while with yield";
static NSString * const kJavaScriptGlobals = @"Array Boolean Date Error JSON Map Math Number Object Promise Proxy Reflect RegExp Set String Symbol WeakMap WeakSet console document window globalThis process require module exports";
static NSString * const kGoKeywords = @"break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil iota";
static NSString * const kGoTypes = @"bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any append cap close copy delete len make new panic print println recover";
static NSString * const kSwiftKeywords = @"associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private protocol public rethrows static struct subscript typealias var break case continue default defer do else fallthrough for guard if in repeat return switch where while as Any catch false is nil super self Self throw throws true try async await actor some any final lazy mutating override required weak unowned convenience dynamic optional";
static NSString * const kKotlinKeywords = @"as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init param property receiver set setparam where actual abstract annotation companion const crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg";
static NSString * const kDartKeywords = @"abstract as assert async await break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory false final finally for Function get hide if implements import in interface is late library mixin new null on operator part required rethrow return sealed set show static super switch sync this throw true try typedef var void when while with yield";
static NSString * const kPythonKeywords = @"False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda match case nonlocal not or pass raise return try while with yield";
static NSString * const kPythonBuiltins = @"abs all any bin bool bytearray bytes callable chr classmethod compile complex dict dir divmod enumerate eval exec filter float format frozenset getattr globals hasattr hash help hex id input int isinstance issubclass iter len list locals map max min next object oct open ord pow print property range repr reversed round set setattr slice sorted staticmethod str sum super tuple type vars zip self cls __init__ __name__ __main__";
static NSString * const kRustKeywords = @"as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type union unsafe use where while abstract become box do final macro override priv try typeof unsized virtual yield";
static NSString * const kRustTypes = @"bool char str i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 String Vec Option Result Box Rc Arc Some None Ok Err HashMap HashSet";
static NSString * const kSqlKeywords = @"absolute action add after all alter and any as asc authorization avg before begin between bigint binary bit blob boolean both by call cascade case cast char character check close collate column commit connect constraint constraints continue convert count create cross current current_date current_time current_timestamp cursor database date day deallocate dec decimal declare default delete desc describe distinct double drop else end escape except exec execute exists fetch first float for foreign from full function grant group having hour identity if in index inner insert int integer intersect interval into is join key last left like limit max min minute modify month natural not null numeric of offset on open option or order outer primary procedure real references replace returns revoke right rollback row rows second select set smallint some sum table temporary then time timestamp to top transaction trigger true false truncate union unique update upper use user using values varchar view when where while with year";
static NSString * const kHtmlKeywords = @"a abbr address area article aside audio b base bdi bdo blockquote body br button canvas caption cite code col colgroup data datalist dd del details dfn dialog div dl dt em embed fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 head header hr html i iframe img input ins kbd label legend li link main map mark meta meter nav noscript object ol optgroup option output p param picture pre progress q rp rt ruby s samp script section select slot small source span strong style sub summary sup svg table tbody td template textarea tfoot th thead time title tr track u ul var video wbr "
                                         @"accept action align alt async autocomplete autofocus autoplay charset checked class cols colspan content contenteditable controls crossorigin data defer dir disabled download draggable enctype for form height hidden href hreflang http-equiv id integrity lang list loop max maxlength media method min multiple muted name novalidate onblur onchange onclick onerror onfocus oninput onkeydown onkeyup onload onmouseover onsubmit open pattern placeholder poster preload readonly rel required reversed role rows rowspan sandbox scope selected size sizes span spellcheck src srcdoc srcset start step style tabindex target title translate type value width wrap";
static NSString * const kPhpKeywords = @"abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new null or print private protected public readonly require require_once return static switch this throw trait try unset use var while xor yield true false self parent";
static NSString * const kBashKeywords = @"alias bg bind break builtin case cd command compgen complete continue declare dirs disown do done echo elif else enable esac eval exec exit export false fc fg fi for function getopts hash help history if in jobs kill let local logout popd printf pushd pwd read readonly return select set shift shopt source suspend test then time times trap true type typeset ulimit umask unalias unset until wait while awk cat chmod chown cp curl cut find grep head ln ls mkdir mv rm sed sort tail tar touch tr uniq wc xargs sudo";
static NSString * const kBatchKeywords = @"rem set if else exist errorlevel for in do break call copy chcp cd chdir choice cls country ctty date del erase dir echo exit goto loadfix loadhigh mkdir md move path pause prompt rename ren rmdir rd shift time type ver verify vol com con lpt nul defined not errorlevel cmdextversion setlocal endlocal pushd popd start title color assoc ftype";
static NSString * const kLuaKeywords = @"and break do else elseif end false for function goto if in local nil not or repeat return then true until while";
static NSString * const kLuaBuiltins = @"assert collectgarbage dofile error getmetatable ipairs load loadfile next pairs pcall print rawequal rawget rawlen rawset require select setmetatable tonumber tostring type xpcall string table math io os coroutine utf8 debug package self";
static NSString * const kPerlKeywords = @"__DATA__ __END__ __FILE__ __LINE__ __PACKAGE__ and cmp do else elsif eq for foreach ge goto gt if last le local lt my ne next no not or our package redo require return sub unless until use while xor chomp chop chr close defined delete die each eof eval exec exists exit grep join keys lc length map open pop print printf push ref reverse scalar shift sort splice split sprintf substr uc undef unshift values wantarray warn";
static NSString * const kRubyKeywords = @"__FILE__ __LINE__ BEGIN END alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require require_relative attr_accessor attr_reader attr_writer include extend puts private protected public raise lambda proc";
static NSString * const kPowerShellKeywords = @"begin break catch class continue data define do dynamicparam else elseif end enum exit filter finally for foreach from function if in param process return switch throw trap try until using var while workflow";
static NSString * const kPowerShellCmdlets = @"add-content clear-host copy-item foreach-object format-list format-table get-childitem get-command get-content get-date get-help get-item get-location get-member get-process get-service import-module invoke-command invoke-expression invoke-webrequest move-item new-item new-object out-file out-host remove-item rename-item select-object select-string set-content set-item set-location set-variable sort-object start-process stop-process test-path where-object write-error write-host write-output write-verbose write-warning";

static NSDictionary<NSString *, NSNumber *> *RoleNames(void) {
  static NSDictionary *names;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    names = @{
      @"default": @(NativeStyleDefault), @"comment": @(NativeStyleComment), @"keyword": @(NativeStyleKeyword),
      @"keyword2": @(NativeStyleKeyword2), @"string": @(NativeStyleString), @"number": @(NativeStyleNumber),
      @"operator": @(NativeStyleOperator), @"preprocessor": @(NativeStylePreprocessor), @"tag": @(NativeStyleTag),
      @"attribute": @(NativeStyleAttribute), @"type": @(NativeStyleType), @"variable": @(NativeStyleVariable),
      @"heading": @(NativeStyleHeading), @"error": @(NativeStyleError), @"added": @(NativeStyleAdded),
      @"deleted": @(NativeStyleDeleted)
    };
  });
  return names;
}

static NSDictionary<NSNumber *, NSNumber *> *ParseStyleRoles(NSString *spec) {
  NSMutableDictionary *roles = [NSMutableDictionary dictionary];
  for (NSString *group in [spec componentsSeparatedByString:@" "]) {
    NSArray<NSString *> *parts = [group componentsSeparatedByString:@":"];
    if (parts.count != 2) continue;
    NSNumber *role = RoleNames()[parts[0]];
    if (!role) continue;
    for (NSString *style in [parts[1] componentsSeparatedByString:@","]) roles[@(style.integerValue)] = role;
  }
  return roles;
}

@interface NativeLanguage ()
@property(nonatomic, readwrite) NSString *identifier;
@property(nonatomic, readwrite) NSString *name;
@property(nonatomic, readwrite, nullable) NSString *lexer;
@property(nonatomic, readwrite) NSArray<NSString *> *extensions;
@property(nonatomic, readwrite) NSArray<NSString *> *keywordSets;
@property(nonatomic, readwrite) NSDictionary<NSString *, NSString *> *lexerProperties;
@property(nonatomic, readwrite) NSDictionary<NSNumber *, NSNumber *> *styleRoles;
@property(nonatomic, readwrite, nullable) NSString *lineComment;
@property(nonatomic, readwrite, nullable) NSString *blockCommentStart;
@property(nonatomic, readwrite, nullable) NSString *blockCommentEnd;
@end

@implementation NativeLanguage

+ (instancetype)language:(NSString *)identifier name:(NSString *)name lexer:(NSString *)lexer
              extensions:(NSString *)extensions keywords:(NSArray<NSString *> *)keywords styles:(NSString *)styles
                 comment:(NSString *)lineComment block:(NSString *)blockStart :(NSString *)blockEnd {
  NativeLanguage *language = [[NativeLanguage alloc] init];
  language.identifier = identifier;
  language.name = name;
  language.lexer = lexer;
  language.extensions = extensions.length ? [extensions componentsSeparatedByString:@" "] : @[];
  language.keywordSets = keywords ?: @[];
  language.styleRoles = ParseStyleRoles(styles ?: @"");
  language.lexerProperties = @{};
  language.lineComment = lineComment;
  language.blockCommentStart = blockStart;
  language.blockCommentEnd = blockEnd;
  return language;
}

+ (NSArray<NativeLanguage *> *)allLanguages {
  static NSArray<NativeLanguage *> *languages;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NativeLanguage *javascript = [self language:@"javascript" name:@"JavaScript" lexer:@"cpp"
        extensions:@"js mjs cjs jsx" keywords:@[kJavaScriptKeywords, kJavaScriptGlobals] styles:kCppStyles
        comment:@"//" block:@"/*" :@"*/"];
    javascript.lexerProperties = @{@"lexer.cpp.backquoted.strings": @"1"};
    NativeLanguage *typescript = [self language:@"typescript" name:@"TypeScript" lexer:@"cpp"
        extensions:@"ts tsx mts cts" keywords:@[kTypeScriptKeywords, kJavaScriptGlobals] styles:kCppStyles
        comment:@"//" block:@"/*" :@"*/"];
    typescript.lexerProperties = javascript.lexerProperties;
    NativeLanguage *go = [self language:@"go" name:@"Go" lexer:@"cpp" extensions:@"go"
        keywords:@[kGoKeywords, kGoTypes] styles:kCppStyles comment:@"//" block:@"/*" :@"*/"];
    go.lexerProperties = javascript.lexerProperties;
    NativeLanguage *html = [self language:@"html" name:@"HTML" lexer:@"hypertext"
        extensions:@"html htm xhtml shtml vue svelte" keywords:@[kHtmlKeywords, kJavaScriptKeywords, @"", @"", kPhpKeywords]
        styles:kHtmlStyles comment:nil block:@"<!--" :@"-->"];
    html.lexerProperties = @{@"fold.html": @"1", @"fold.hypertext.comment": @"1"};
    NativeLanguage *php = [self language:@"php" name:@"PHP" lexer:@"hypertext"
        extensions:@"php php3 php4 php5 phtml" keywords:@[kHtmlKeywords, kJavaScriptKeywords, @"", @"", kPhpKeywords]
        styles:kHtmlStyles comment:@"//" block:@"/*" :@"*/"];
    php.lexerProperties = html.lexerProperties;
    NativeLanguage *xml = [self language:@"xml" name:@"XML" lexer:@"xml"
        extensions:@"xml xsd xsl xslt svg plist xaml csproj vcxproj props targets resx config rss atom" keywords:@[]
        styles:kHtmlStyles comment:nil block:@"<!--" :@"-->"];
    xml.lexerProperties = html.lexerProperties;

    languages = @[
      [self language:@"text" name:@"Normal Text" lexer:nil extensions:@"txt text log" keywords:nil styles:nil
             comment:nil block:nil :nil],
      [self language:@"bash" name:@"Shell" lexer:@"bash" extensions:@"sh bash zsh ksh command"
            keywords:@[kBashKeywords] styles:@"error:1 comment:2 number:3 keyword:4 string:5,6,11,12,13 operator:7 variable:9,10"
             comment:@"#" block:nil :nil],
      [self language:@"batch" name:@"Batch" lexer:@"batch" extensions:@"bat cmd nt"
            keywords:@[kBatchKeywords] styles:@"comment:1 keyword:2 tag:3 preprocessor:4 keyword2:5 variable:6 operator:7"
             comment:@"REM" block:nil :nil],
      [self language:@"c" name:@"C" lexer:@"cpp" extensions:@"c"
            keywords:@[kCKeywords, kCppTypes] styles:kCppStyles comment:@"//" block:@"/*" :@"*/"],
      [self language:@"cpp" name:@"C++" lexer:@"cpp" extensions:@"cpp cc cxx c++ h hh hpp hxx ino ipp inl tpp"
            keywords:@[kCppKeywords, kCppTypes] styles:kCppStyles comment:@"//" block:@"/*" :@"*/"],
      [self language:@"cs" name:@"C#" lexer:@"cpp" extensions:@"cs csx"
            keywords:@[kCSharpKeywords] styles:kCppStyles comment:@"//" block:@"/*" :@"*/"],
      [self language:@"css" name:@"CSS" lexer:@"css" extensions:@"css scss less"
            keywords:@[@"color background background-color border margin padding display position width height font font-size font-family font-weight text-align top left right bottom flex grid z-index overflow opacity transition transform content cursor box-shadow line-height"]
              styles:@"tag:1 type:2,10 keyword2:3,4,11,18,20,21 operator:5 keyword:6,15,17,19 error:7 string:8,13,14 comment:9 preprocessor:12,22 attribute:16 variable:23"
             comment:nil block:@"/*" :@"*/"],
      [self language:@"dart" name:@"Dart" lexer:@"cpp" extensions:@"dart"
            keywords:@[kDartKeywords] styles:kCppStyles comment:@"//" block:@"/*" :@"*/"],
      [self language:@"diff" name:@"Diff" lexer:@"diff" extensions:@"diff patch"
            keywords:nil styles:@"comment:1 keyword:2 heading:3 preprocessor:4 deleted:5,9,11 added:6,8,10 keyword2:7"
             comment:nil block:nil :nil],
      go,
      html,
      [self language:@"ini" name:@"INI / Properties" lexer:@"props" extensions:@"ini cfg conf properties prefs inf reg editorconfig gitconfig env"
            keywords:nil styles:@"comment:1 tag:2 operator:3 variable:4 attribute:5" comment:@";" block:nil :nil],
      [self language:@"java" name:@"Java" lexer:@"cpp" extensions:@"java"
            keywords:@[kJavaKeywords] styles:kCppStyles comment:@"//" block:@"/*" :@"*/"],
      javascript,
      [self language:@"json" name:@"JSON" lexer:@"json" extensions:@"json jsonc json5 geojson webmanifest babelrc eslintrc prettierrc"
            keywords:@[@"true false null"] styles:@"number:1 string:2,5 error:3,13 attribute:4 comment:6,7 operator:8 keyword:9,10,11,12"
             comment:nil block:nil :nil],
      [self language:@"kotlin" name:@"Kotlin" lexer:@"cpp" extensions:@"kt kts"
            keywords:@[kKotlinKeywords] styles:kCppStyles comment:@"//" block:@"/*" :@"*/"],
      [self language:@"lua" name:@"Lua" lexer:@"lua" extensions:@"lua"
            keywords:@[kLuaKeywords, kLuaBuiltins] styles:@"comment:1,2,3 number:4 keyword:5 string:6,7,8 preprocessor:9 operator:10 error:12 keyword2:13,14,15,16,17,18,19 tag:20"
             comment:@"--" block:@"--[[" :@"]]"],
      [self language:@"makefile" name:@"Makefile" lexer:@"makefile" extensions:@"mk mak make"
            keywords:nil styles:@"comment:1 preprocessor:2 variable:3 operator:4 tag:5 error:9" comment:@"#" block:nil :nil],
      [self language:@"markdown" name:@"Markdown" lexer:@"markdown" extensions:@"md markdown mdown mkd"
            keywords:nil styles:@"keyword:2,3 keyword2:4,5 heading:6,7,8,9,10,11 operator:12,13,14,17 comment:15 deleted:16 attribute:18 string:19,20,21"
             comment:nil block:@"<!--" :@"-->"],
      [self language:@"objc" name:@"Objective-C" lexer:@"cpp" extensions:@"m mm"
            keywords:@[[kCKeywords stringByAppendingFormat:@" %@", kObjCKeywords], kCppTypes] styles:kCppStyles comment:@"//" block:@"/*" :@"*/"],
      [self language:@"perl" name:@"Perl" lexer:@"perl" extensions:@"pl pm t pod"
            keywords:@[kPerlKeywords] styles:@"error:1 comment:2,3 number:4 keyword:5 string:6,7,17,18,19,23,24,25,26,27,28,29,30 operator:10 variable:12,13,14 preprocessor:9"
             comment:@"#" block:nil :nil],
      php,
      [self language:@"powershell" name:@"PowerShell" lexer:@"powershell" extensions:@"ps1 psm1 psd1"
            keywords:@[kPowerShellKeywords, kPowerShellCmdlets] styles:@"comment:1,13,16 string:2,3,14,15 number:4 variable:5 operator:6 keyword:8 keyword2:9,10 type:11"
             comment:@"#" block:@"<#" :@"#>"],
      [self language:@"python" name:@"Python" lexer:@"python" extensions:@"py pyw pyi pyx wsgi gyp"
            keywords:@[kPythonKeywords, kPythonBuiltins] styles:@"comment:1,12 number:2 string:3,4,6,7,16,17,18,19 keyword:5 type:8,9 operator:10 error:13 keyword2:14 preprocessor:15"
             comment:@"#" block:nil :nil],
      [self language:@"ruby" name:@"Ruby" lexer:@"ruby" extensions:@"rb rbw rake gemspec ru"
            keywords:@[kRubyKeywords] styles:@"error:1 comment:2,3 number:4 keyword:5 string:6,7,12,18,24,25,26,27,28 type:8,9,15 operator:10 variable:13,16,17 attribute:14"
             comment:@"#" block:nil :nil],
      [self language:@"rust" name:@"Rust" lexer:@"rust" extensions:@"rs"
            keywords:@[kRustKeywords, kRustTypes] styles:@"comment:1,2,3,4 number:5 keyword:6 keyword2:7 type:8,9,10,11,12 string:13,14,15,21,22,23,24,25 operator:16 variable:18 preprocessor:19 error:20"
             comment:@"//" block:@"/*" :@"*/"],
      [self language:@"sql" name:@"SQL" lexer:@"sql" extensions:@"sql ddl dml"
            keywords:@[kSqlKeywords] styles:@"comment:1,2,3,13,15 number:4 keyword:5 string:6,7 operator:10 keyword2:16 type:19,20,21,22 variable:23"
             comment:@"--" block:@"/*" :@"*/"],
      [self language:@"swift" name:@"Swift" lexer:@"cpp" extensions:@"swift"
            keywords:@[kSwiftKeywords] styles:kCppStyles comment:@"//" block:@"/*" :@"*/"],
      [self language:@"toml" name:@"TOML" lexer:@"toml" extensions:@"toml"
            keywords:@[@"true false inf nan"] styles:@"comment:1 keyword:3 number:4,14 tag:5 attribute:6 error:7,15 operator:8 string:9,10,11,12,13"
             comment:@"#" block:nil :nil],
      typescript,
      xml,
      [self language:@"yaml" name:@"YAML" lexer:@"yaml" extensions:@"yaml yml"
            keywords:@[@"true false yes no null on off"] styles:@"comment:1 attribute:2 keyword:3 number:4 variable:5 preprocessor:6 string:7 error:8 operator:9"
             comment:@"#" block:nil :nil],
#include "NativeLanguagesExtra.inc"
    ];
  });
  return languages;
}

+ (NativeLanguage *)plainText {
  return [self allLanguages].firstObject;
}

+ (NativeLanguage *)languageWithIdentifier:(NSString *)identifier {
  // Older sessions stored these identifiers before the language table existed.
  if ([identifier isEqualToString:@"shell"]) identifier = @"bash";
  for (NativeLanguage *language in [self allLanguages]) {
    if ([language.identifier isEqualToString:identifier]) return language;
  }
  return nil;
}

+ (NativeLanguage *)languageForFileName:(NSString *)fileName firstLine:(NSString *)firstLine {
  NSString *lowerName = fileName.lowercaseString;
  NSDictionary<NSString *, NSString *> *specialNames = @{
    @"makefile": @"makefile", @"gnumakefile": @"makefile", @"cmakelists.txt": @"makefile",
    @"dockerfile": @"bash", @".bashrc": @"bash", @".zshrc": @"bash", @".profile": @"bash",
    @".bash_profile": @"bash", @"gemfile": @"ruby", @"rakefile": @"ruby", @".gitignore": @"ini"
  };
  NativeLanguage *special = specialNames[lowerName] ? [self languageWithIdentifier:specialNames[lowerName]] : nil;
  if (special) return special;

  NSString *extension = lowerName.pathExtension;
  if (extension.length) {
    for (NativeLanguage *language in [self allLanguages]) {
      if ([language.extensions containsObject:extension]) return language;
    }
  }
  if ([firstLine hasPrefix:@"#!"]) {
    if ([firstLine containsString:@"python"]) return [self languageWithIdentifier:@"python"];
    if ([firstLine containsString:@"node"]) return [self languageWithIdentifier:@"javascript"];
    if ([firstLine containsString:@"ruby"]) return [self languageWithIdentifier:@"ruby"];
    if ([firstLine containsString:@"perl"]) return [self languageWithIdentifier:@"perl"];
    if ([firstLine containsString:@"sh"]) return [self languageWithIdentifier:@"bash"];
  }
  if ([firstLine hasPrefix:@"<?xml"]) return [self languageWithIdentifier:@"xml"];
  if ([firstLine.lowercaseString hasPrefix:@"<!doctype html"]) return [self languageWithIdentifier:@"html"];
  return [self plainText];
}

@end

static NSColor *Hex(unsigned int rgb) {
  return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0 green:((rgb >> 8) & 0xff) / 255.0
                              blue:(rgb & 0xff) / 255.0 alpha:1];
}

@interface NativeTheme ()
@property(nonatomic, readwrite, getter=isDark) BOOL dark;
@property(nonatomic, readwrite) NSColor *background;
@property(nonatomic, readwrite) NSColor *foreground;
@property(nonatomic, readwrite) NSColor *caret;
@property(nonatomic, readwrite) NSColor *caretLine;
@property(nonatomic, readwrite) NSColor *selection;
@property(nonatomic, readwrite) NSColor *marginBackground;
@property(nonatomic, readwrite) NSColor *lineNumber;
@property(nonatomic, readwrite) NSColor *foldMargin;
@property(nonatomic, readwrite) NSColor *foldSymbol;
@property(nonatomic, readwrite) NSColor *braceMatch;
@property(nonatomic, readwrite) NSColor *braceBad;
@property(nonatomic, readwrite) NSColor *indentGuide;
@property(nonatomic, readwrite) NSColor *whitespace;
@property(nonatomic, readwrite) NSColor *smartHighlight;
@property(nonatomic, readwrite) NSColor *markHighlight;
@property(nonatomic, readwrite) NSColor *bookmark;
@property(nonatomic, copy) NSArray<NSColor *> *roleColors;
@property(nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *boldOverrides;
@end

@implementation NativeTheme

+ (instancetype)themeDark:(BOOL)dark customBackground:(NSColor *)background foreground:(NSColor *)foreground {
  NativeTheme *theme = [[NativeTheme alloc] init];
  theme.dark = dark;
  if (dark) {
    // Close to Notepad++'s dark mode / VS-style palette.
    theme.background = Hex(0x1E1E1E);
    theme.foreground = Hex(0xDCDCDC);
    theme.caret = Hex(0xF0F0F0);
    theme.caretLine = Hex(0x2A2D2E);
    theme.selection = Hex(0x264F78);
    theme.marginBackground = Hex(0x1E1E1E);
    theme.lineNumber = Hex(0x858585);
    theme.foldMargin = Hex(0x252526);
    theme.foldSymbol = Hex(0x808080);
    theme.braceMatch = Hex(0xFFD700);
    theme.braceBad = Hex(0xF44747);
    theme.indentGuide = Hex(0x404040);
    theme.whitespace = Hex(0x505050);
    theme.smartHighlight = Hex(0x3A7A3A);
    theme.markHighlight = Hex(0x8A5A00);
    theme.bookmark = Hex(0x4A90D9);
    theme.roleColors = @[Hex(0xDCDCDC), Hex(0x6A9955), Hex(0x569CD6), Hex(0xC586C0), Hex(0xCE9178), Hex(0xB5CEA8),
                         Hex(0xD4D4D4), Hex(0xC586C0), Hex(0x569CD6), Hex(0x9CDCFE), Hex(0x4EC9B0), Hex(0x9CDCFE),
                         Hex(0x569CD6), Hex(0xF44747), Hex(0x6A9955), Hex(0xF44747)];
  } else {
    // Notepad++ "Default" stylers.xml colors.
    theme.background = Hex(0xFFFFFF);
    theme.foreground = Hex(0x000000);
    theme.caret = Hex(0x8000FF);
    theme.caretLine = Hex(0xE8E8FF);
    theme.selection = Hex(0xC0C0C0);
    theme.marginBackground = Hex(0xE4E4E4);
    theme.lineNumber = Hex(0x808080);
    theme.foldMargin = Hex(0xF3F3F3);
    theme.foldSymbol = Hex(0x808080);
    theme.braceMatch = Hex(0xFF0000);
    theme.braceBad = Hex(0x800000);
    theme.indentGuide = Hex(0xC0C0C0);
    theme.whitespace = Hex(0xFFB56A);
    theme.smartHighlight = Hex(0x00FF00);
    theme.markHighlight = Hex(0xFF0000);
    theme.bookmark = Hex(0x0080FF);
    theme.roleColors = @[Hex(0x000000), Hex(0x008000), Hex(0x0000FF), Hex(0x8000FF), Hex(0x808080), Hex(0xFF8000),
                         Hex(0x000080), Hex(0x804000), Hex(0x0000FF), Hex(0xFF0000), Hex(0x8000FF), Hex(0x000080),
                         Hex(0x0000FF), Hex(0xFF0000), Hex(0x008000), Hex(0xFF0000)];
  }
  if (background) {
    theme.background = background;
    theme.marginBackground = background;
  }
  if (foreground) {
    theme.foreground = foreground;
    NSMutableArray *colors = [theme.roleColors mutableCopy];
    colors[NativeStyleDefault] = foreground;
    theme.roleColors = colors;
  }
  return theme;
}

- (NSColor *)colorForRole:(NativeStyleRole)role {
  return role >= 0 && role < (NativeStyleRole)self.roleColors.count ? self.roleColors[role] : self.foreground;
}

+ (NSArray<NSString *> *)roleDisplayNames {
  return @[@"Default text", @"Comment", @"Keyword", @"Keyword 2 / built-in", @"String", @"Number", @"Operator",
           @"Preprocessor / directive", @"Tag", @"Attribute / key", @"Type / class", @"Variable",
           @"Heading", @"Error", @"Added (diff)", @"Deleted (diff)"];
}

+ (NSString *)hexForColor:(NSColor *)color {
  NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.blackColor;
  return [NSString stringWithFormat:@"#%02lX%02lX%02lX", lround(rgb.redComponent * 255),
                                    lround(rgb.greenComponent * 255), lround(rgb.blueComponent * 255)];
}

+ (NSColor *)colorFromHex:(NSString *)hex {
  if (![hex isKindOfClass:NSString.class]) return nil;
  NSString *text = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
  unsigned int rgb = 0;
  if (text.length != 6 || ![[NSScanner scannerWithString:text] scanHexInt:&rgb]) return nil;
  return Hex(rgb);
}

- (void)applyOverrides:(NSDictionary *)overrides {
  if (![overrides isKindOfClass:NSDictionary.class]) return;
  NSColor *background = [NativeTheme colorFromHex:overrides[@"background"]];
  if (background) {
    self.background = background;
    self.marginBackground = background;
  }
  NSColor *caretLine = [NativeTheme colorFromHex:overrides[@"caretLine"]];
  if (caretLine) self.caretLine = caretLine;
  NSColor *selection = [NativeTheme colorFromHex:overrides[@"selection"]];
  if (selection) self.selection = selection;
  NSMutableArray *colors = [self.roleColors mutableCopy];
  NSMutableDictionary *bold = [NSMutableDictionary dictionary];
  NSDictionary *roles = [overrides[@"roles"] isKindOfClass:NSDictionary.class] ? overrides[@"roles"] : @{};
  [roles enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *style, BOOL *stop) {
    (void)stop;
    NSInteger role = key.integerValue;
    if (role < 0 || role >= (NSInteger)colors.count || ![style isKindOfClass:NSDictionary.class]) return;
    NSColor *color = [NativeTheme colorFromHex:style[@"color"]];
    if (color) colors[role] = color;
    if (style[@"bold"]) bold[@(role)] = style[@"bold"];
  }];
  self.roleColors = colors;
  self.foreground = colors[NativeStyleDefault];
  self.boldOverrides = bold;
}

- (BOOL)isBoldRole:(NativeStyleRole)role {
  NSNumber *override = self.boldOverrides[@(role)];
  if (override) return override.boolValue;
  return role == NativeStyleKeyword || role == NativeStyleOperator || role == NativeStyleHeading ||
         (role == NativeStyleTag && !self.dark);
}

@end
