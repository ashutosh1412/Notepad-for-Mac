#import "NativeEditorController.h"
#import "NativeDocument.h"
#import "NativeLanguages.h"
#import "NativeChrome.h"

NS_ASSUME_NONNULL_BEGIN

@interface NativeFileNode : NSObject
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, assign) BOOL directory;
@property(nonatomic, assign) BOOL childrenLoaded;
@property(nonatomic, strong) NSArray<NativeFileNode *> *children;
- (instancetype)initWithURL:(NSURL *)url;
- (void)loadChildren;
@end

// Tabless container for the editors; NativeTabBar draws the tabs.
@interface NativeTabView : NSTabView
@end

@interface NativeEditorController ()
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NativeTabView *tabView;
@property(nonatomic, strong) NativeTabBar *tabBar;
@property(nonatomic, strong) NativeStatusBar *statusBar;
@property(nonatomic, strong, nullable) NSTimer *statusMessageTimer;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSButton *> *toolbarToggles;
@property(nonatomic, strong) NSMutableSet<NSString *> *monitoredDocuments;
// Files macOS asks to open before launch finishes (Finder double-click, Open With).
@property(nonatomic, strong, nullable) NSMutableArray<NSURL *> *pendingOpenURLs;
@property(nonatomic, strong) NSMutableArray<NSString *> *pinnedDocuments;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *tabColors;
@property(nonatomic, strong) NSView *toolbarView;
@property(nonatomic, strong) NSView *toolbarLine;
@property(nonatomic, strong) NSLayoutConstraint *editorTopConstraint;
@property(nonatomic, strong) NSLayoutConstraint *editorTopCompactConstraint;
@property(nonatomic, strong) NSLayoutConstraint *tabBarHeightConstraint;
@property(nonatomic, strong) NSLayoutConstraint *statusBarHeightConstraint;
@property(nonatomic, strong, nullable) NSMenu *editorMenu;
@property(nonatomic, strong, nullable) NSTimer *monitorTimer;
@property(nonatomic, strong) NSComboBox *searchField;
@property(nonatomic, strong) NSComboBox *replacementField;
@property(nonatomic, strong) NSPanel *findPanel;
@property(nonatomic, strong) NSSegmentedControl *findModeControl;
@property(nonatomic, strong) NSTextField *findStatusLabel;
@property(nonatomic, strong) NSTextField *findFiltersField;
@property(nonatomic, strong) NSTextField *findDirectoryField;
@property(nonatomic, strong) NSButton *backwardButton;
@property(nonatomic, strong) NSButton *wrapAroundButton;
@property(nonatomic, strong) NSButton *normalModeButton;
@property(nonatomic, strong) NSButton *bookmarkLineButton;
@property(nonatomic, strong) NSBox *findOptionsBox;
@property(nonatomic, copy) NSDictionary<NSString *, NSButton *> *findPanelButtons;
@property(nonatomic, strong) NSHashTable<NSView *> *findReplaceViews;
@property(nonatomic, strong) NSHashTable<NSView *> *findFilesViews;
@property(nonatomic, strong) NSButton *matchCaseButton;
@property(nonatomic, strong) NSButton *wholeWordButton;
@property(nonatomic, strong) NSButton *regexButton;
@property(nonatomic, strong) NSButton *extendedButton;
@property(nonatomic, strong) NSSplitView *workspaceSplit;
@property(nonatomic, strong) NSSplitView *editorSplit;
@property(nonatomic, strong) NSScrollView *projectPane;
@property(nonatomic, strong) NSScrollView *resultsPane;
@property(nonatomic, strong) NSMutableArray<NativeDocument *> *documents;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSTabViewItem *> *tabItems;
@property(nonatomic, assign) void *lexerFactory;
@property(nonatomic, strong) NSMenuItem *recordMacroMenuItem;
@property(nonatomic, strong) NSMenu *languageMenu;
@property(nonatomic, strong) NSMenu *recentMenu;
@property(nonatomic, strong) NSMenu *macroMenu;
@property(nonatomic, assign) BOOL skipTerminationConfirmation;
@property(nonatomic, assign) BOOL checkingExternalChanges;
@property(nonatomic, strong, nullable) NSTimer *sessionSaveTimer;
@property(nonatomic, strong, nullable) NSURL *projectURL;
@property(nonatomic, strong) NSOutlineView *projectOutline;
@property(nonatomic, strong, nullable) NativeFileNode *projectRootNode;
@property(nonatomic, strong) NSTableView *resultsTable;
@property(nonatomic, copy) NSArray<NSDictionary *> *searchResults;
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *viewOptions;
@property(nonatomic, strong) NSSplitView *sidePanel;
@property(nonatomic, strong) NSView *functionListPane;
@property(nonatomic, strong) NSSearchField *functionFilterField;
@property(nonatomic, strong) NSTableView *functionTable;
@property(nonatomic, copy) NSArray<NSDictionary *> *functionEntries;
@property(nonatomic, copy) NSArray<NSDictionary *> *visibleFunctionEntries;
@property(nonatomic, copy, nullable) NSString *functionListSource;
@property(nonatomic, strong) ScintillaView *documentMap;
@property(nonatomic, strong, nullable) id documentMapDelegate;
@property(nonatomic, weak, nullable) NativeDocument *documentMapDocument;
@property(nonatomic, assign) BOOL syncingDocumentMap;
@property(nonatomic, strong, nullable) NSWindow *preferencesWindow;
@property(nonatomic, strong, nullable) NSWindow *styleWindow;
@property(nonatomic, assign) BOOL darkTheme;
@property(nonatomic, copy) NSArray<NSDictionary *> *currentMacro;

- (nullable NativeDocument *)activeDocument;
- (ScintillaView *)activeEditor;
- (nullable NativeDocument *)documentWithIdentifier:(NSString *)identifier;
- (void)openURL:(NSURL *)url;
- (void)selectDocument:(NativeDocument *)document;
- (void)updateStatus;
- (void)setStatus:(NSString *)message;
- (void)showError:(nullable NSError *)error;
- (void)showErrorMessage:(NSString *)message;
- (void)scheduleSessionPersistence;
- (void)showSearchResultsPane:(BOOL)visible;
- (NSMenuItem *)addMenuItem:(NSString *)title action:(nullable SEL)action key:(NSString *)key toMenu:(NSMenu *)menu;
- (NSMenuItem *)addMenuItem:(NSString *)title action:(nullable SEL)action key:(NSString *)key
                  modifiers:(NSEventModifierFlags)modifiers toMenu:(NSMenu *)menu;
- (NSMenu *)submenu:(NSString *)title inMenu:(NSMenu *)menu;
- (NativeTheme *)currentTheme;
- (void)applyViewOptions;
- (void)applyThemeToAllDocuments;
- (void)savePreferences;
- (void)syncToolbarToggles;
@end

// Side panels, preferences, style configurator and printing (NativePanels.mm).
@interface NativeEditorController (Panels)
- (NSSplitView *)buildSidePanel;
- (void)refreshPanelsForce:(BOOL)force;
- (void)toggleFunctionList:(nullable id)sender;
- (void)toggleDocumentMap:(nullable id)sender;
- (void)showPreferences:(nullable id)sender;
- (void)showStyleConfigurator:(nullable id)sender;
- (void)printDocument:(nullable id)sender;
- (BOOL)validatePanelMenuItem:(NSMenuItem *)item;
@end

// Actions defined in the main implementation and other categories, declared for cross-file calls.
@interface NativeEditorController (CoreActions)
- (BOOL)closeDocument:(NativeDocument *)document;
- (void)rebuildRecentMenu;
- (void)newDocument:(nullable id)sender;
- (void)updateDocument:(NativeDocument *)document;
- (void)reopenWithEncoding:(NSMenuItem *)sender;
- (void)toggleSplitView:(nullable id)sender;
- (void)saveDocument:(nullable id)sender;
- (void)openSelectedSearchResult:(nullable id)sender;
- (void)clearMarks:(nullable id)sender;
- (void)copyBookmarkedLines:(nullable id)sender;
- (void)removeBookmarkedLines:(nullable id)sender;
- (void)trimBothWhitespace:(nullable id)sender;
- (void)eolToSpace:(nullable id)sender;
- (void)searchModeChanged:(nullable id)sender;
- (void)openInTerminal:(nullable id)sender;
@end

// Menu bar and context menus in Notepad++'s layout (NativeMenus.mm).
@interface NativeEditorController (Menus)
- (void)buildMainMenu;
- (NSMenu *)tabContextMenu;
- (NSMenu *)editorContextMenu;
- (void)menuNeedsUpdate:(NSMenu *)menu;
@end

// Commands added for parity with the latest Notepad++ (NativeParity.mm).
@interface NativeEditorController (Parity)
- (NSMutableDictionary *)toolObjects;
- (void)applyShortcutOverrides;
- (BOOL)validateParityMenuItem:(NSMenuItem *)item;
- (NSView *)buildIncrementalSearchBar;
- (void)startClipboardMonitoring;
- (void)refreshDocumentList;
- (void)syncScrollingForDocument:(NativeDocument *)document;
- (void)noteActiveDocumentForRecentWindow;
- (NSArray<NSDictionary *> *)userLanguageFilesDefinitions;
@end

@interface NativeEditorController (SelfTest)
- (void)runSelfTestWritingTo:(NSString *)path;
@end

// Commands implemented in NativeEditorCommands.mm.
@interface NativeEditorController (Commands)
- (void)buildMacroMenu:(NSMenu *)menu;
- (void)rebuildMacroMenu;
- (BOOL)validateCommandMenuItem:(NSMenuItem *)item;
- (void)buildRunMenu:(NSMenu *)menu;
- (void)findNext:(nullable id)sender;
- (void)findPrevious:(nullable id)sender;
- (void)markAll:(nullable id)sender;
- (void)countMatches:(nullable id)sender;
- (void)performProjectSearchInDirectory:(NSURL *)directory replacing:(BOOL)replace filters:(NSString *)filters;
@end

// Notepad++-style Find / Replace / Find in Files / Mark dialog (NativeFindPanel.mm).
@interface NativeEditorController (FindPanel)
- (void)buildFindPanel;
- (void)setFindPanelMessage:(NSString *)message;
- (void)focusFind:(nullable id)sender;
- (void)focusReplace:(nullable id)sender;
- (void)findInProject:(nullable id)sender;
- (void)replaceInProject:(nullable id)sender;
- (void)showMarkPanel:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
