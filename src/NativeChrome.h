#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Small Notepad++-style "floppy disk" document icon (blue saved, red modified, gray read-only).
NSImage *NativeFloppyIcon(NSColor *color, CGFloat size);
// SF Symbol tinted with palette colors (first color = primary layer); nil if unavailable.
NSImage * _Nullable NativeSymbolIcon(NSString *name, NSArray<NSColor *> *palette, CGFloat pointSize);
// Two overlapping floppies, as on Notepad++'s Save All button.
NSImage *NativeSaveAllIcon(CGFloat size);
// Notepad++'s five tab colors (index 1-5); nil for 0.
NSColor * _Nullable NativeTabColor(NSInteger index);

typedef NS_ENUM(NSInteger, NativeTabState) {
  NativeTabStateSaved = 0,
  NativeTabStateModified,
  NativeTabStateReadOnly,
  NativeTabStateMonitoring
};

// Notepad++-style tab strip: left-aligned tabs with a disk icon, title and close box,
// an orange line on the active tab. It drives a tabless NSTabView.
@interface NativeTabBar : NSView
@property(nonatomic, weak, nullable) NSTabView *tabView;
@property(nonatomic, assign) BOOL dark;
@property(nonatomic, copy, nullable) NativeTabState (^stateProvider)(NSTabViewItem *item);
@property(nonatomic, copy, nullable) NSString * _Nullable (^toolTipProvider)(NSTabViewItem *item);
// Pinned tabs show a pin; colored tabs (1-5, Notepad++'s "Apply Color to Tab") get a tint.
@property(nonatomic, copy, nullable) BOOL (^pinnedProvider)(NSTabViewItem *item);
@property(nonatomic, copy, nullable) NSInteger (^colorProvider)(NSTabViewItem *item);
@property(nonatomic, assign) BOOL doubleClickCloses;
@property(nonatomic, assign) BOOL locked;
@property(nonatomic, copy, nullable) void (^closeHandler)(NSTabViewItem *item);
@property(nonatomic, copy, nullable) void (^newTabHandler)(void);
@property(nonatomic, copy, nullable) NSMenu * _Nullable (^menuProvider)(NSTabViewItem *item);
@property(nonatomic, copy, nullable) void (^reorderHandler)(NSInteger from, NSInteger to);
- (void)reload;
@end

// Status bar with bordered panels, like Notepad++'s. The first panel stretches.
@interface NativeStatusBar : NSView
@property(nonatomic, assign) BOOL dark;
- (void)setFields:(NSArray<NSString *> *)fields;
@end

NS_ASSUME_NONNULL_END
