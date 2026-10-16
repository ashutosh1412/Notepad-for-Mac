#import <Cocoa/Cocoa.h>

@class NativeDocument;

@interface NativeEditorController : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTabViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate>

- (instancetype)initWithLexerFactory:(void *)lexerFactory;

@end