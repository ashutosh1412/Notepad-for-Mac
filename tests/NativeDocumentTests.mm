// Headless checks for NativeDocument file handling. Run with: bash native-prototype/tests/run.sh
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include "ILexer.h"
#include "Lexilla.h"
#import "NativeDocument.h"

static int failures = 0;

#define CHECK(condition, message)                         \
  do {                                                    \
    if (condition) {                                      \
      printf("  ok    %s\n", message);                    \
    } else {                                              \
      printf("  FAIL  %s\n", message);                    \
      failures += 1;                                      \
    }                                                     \
  } while (0)

static NSURL *WriteFile(NSString *directory, NSString *name, NSData *data) {
  NSURL *url = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:name]];
  [data writeToURL:url atomically:YES];
  return url;
}

static NSData *Bytes(const char *bytes, size_t length) {
  return [NSData dataWithBytes:bytes length:length];
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 2) {
      fprintf(stderr, "usage: %s path/to/liblexilla.dylib\n", argv[0]);
      return 2;
    }
    [NSApplication sharedApplication];
    void *lexilla = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    void *factory = lexilla ? dlsym(lexilla, LEXILLA_CREATELEXER) : NULL;
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];

    printf("CRLF files keep CRLF after editing\n");
    {
      NSURL *url = WriteFile(directory, @"crlf.txt", Bytes("one\r\ntwo\r\n", 10));
      NativeDocument *document = [[NativeDocument alloc] initWithLexerFactory:factory];
      CHECK([document openURL:url error:nil], "opens");
      CHECK([document.lineEnding isEqualToString:@"CRLF"], "detects CRLF");
      [document.editor setGeneralProperty:SCI_GOTOPOS value:3];
      [document.editor message:SCI_NEWLINE];
      [document.editor message:SCI_REPLACESEL wParam:0 lParam:(sptr_t)"new"];
      CHECK(document.isDirty, "editing marks the document dirty");
      CHECK([document saveToURL:url error:nil], "saves");
      NSData *saved = [NSData dataWithContentsOfURL:url];
      CHECK([saved isEqualToData:Bytes("one\r\nnew\r\ntwo\r\n", 15)], "no doubled carriage returns");
      CHECK(!document.isDirty, "save clears dirty");
    }

    printf("Line ending conversion\n");
    {
      NSURL *url = WriteFile(directory, @"lf.txt", Bytes("a\nb\n", 4));
      NativeDocument *document = [[NativeDocument alloc] initWithLexerFactory:factory];
      [document openURL:url error:nil];
      [document convertLineEndingsTo:@"CRLF"];
      [document saveToURL:url error:nil];
      CHECK([[NSData dataWithContentsOfURL:url] isEqualToData:Bytes("a\r\nb\r\n", 6)], "LF converts to CRLF");
    }

    printf("Encodings and byte order marks\n");
    {
      NSURL *url = WriteFile(directory, @"bom.txt", Bytes("\xEF\xBB\xBFh\xC3\xA9", 6));
      NativeDocument *document = [[NativeDocument alloc] initWithLexerFactory:factory];
      [document openURL:url error:nil];
      CHECK([document.encodingDisplayName isEqualToString:@"UTF-8-BOM"], "detects UTF-8 BOM");
      CHECK([document.editor.string isEqualToString:@"hé"], "BOM is not part of the text");
      [document saveToURL:url error:nil];
      CHECK([[NSData dataWithContentsOfURL:url] isEqualToData:Bytes("\xEF\xBB\xBFh\xC3\xA9", 6)], "BOM round-trips");

      NSURL *utf16 = WriteFile(directory, @"utf16.txt", Bytes("\xFF\xFEh\x00i\x00", 6));
      NativeDocument *wide = [[NativeDocument alloc] initWithLexerFactory:factory];
      [wide openURL:utf16 error:nil];
      CHECK([wide.encodingDisplayName isEqualToString:@"UTF-16 LE BOM"], "detects UTF-16 LE");
      CHECK([wide.editor.string isEqualToString:@"hi"], "decodes UTF-16 LE");
      [wide saveToURL:utf16 error:nil];
      CHECK([[NSData dataWithContentsOfURL:utf16] isEqualToData:Bytes("\xFF\xFEh\x00i\x00", 6)], "UTF-16 LE round-trips with one BOM");

      NSURL *latin = WriteFile(directory, @"latin.txt", Bytes("caf\xE9", 4));
      NativeDocument *legacy = [[NativeDocument alloc] initWithLexerFactory:factory];
      CHECK([legacy openURL:latin error:nil], "opens non-UTF-8 bytes");
      CHECK([legacy.editor.string isEqualToString:@"café"], "falls back to Windows-1252");
      [legacy saveToURL:latin error:nil];
      CHECK([[NSData dataWithContentsOfURL:latin] isEqualToData:Bytes("caf\xE9", 4)], "Windows-1252 round-trips");
    }

    printf("Languages\n");
    {
      NSURL *url = WriteFile(directory, @"script", [@"#!/usr/bin/env python3\nprint(1)\n" dataUsingEncoding:NSUTF8StringEncoding]);
      NativeDocument *document = [[NativeDocument alloc] initWithLexerFactory:factory];
      [document openURL:url error:nil];
      CHECK([document.language isEqualToString:@"python"], "detects Python from shebang");
      NSURL *js = WriteFile(directory, @"app.js", [@"const x = 1;\n" dataUsingEncoding:NSUTF8StringEncoding]);
      [document openURL:js error:nil];
      CHECK([document.language isEqualToString:@"javascript"], "detects JavaScript from extension");
      [document.editor message:SCI_COLOURISE wParam:0 lParam:-1];
      CHECK([document.editor getGeneralProperty:SCI_GETSTYLEAT parameter:0] == 5, "colors 'const' as a keyword");
    }

    printf("Auto-close brackets and quotes\n");
    {
      NativeDocument *document = [[NativeDocument alloc] initWithLexerFactory:factory];
      document.viewOptions = @{NativeViewAutoClose: @YES, NativeViewAutoComplete: @NO};
      ScintillaView *editor = document.editor;
      void (^type)(const char *) = ^(const char *text) {
        for (const char *ch = text; *ch; ch += 1) {
          char single[2] = {*ch, 0};
          [editor message:SCI_REPLACESEL wParam:0 lParam:(sptr_t)single];
          SCNotification notification = {};
          notification.nmhdr.code = SCN_CHARADDED;
          notification.ch = *ch;
          [document handleNotification:&notification fromEditor:editor];
        }
      };
      type("f(");
      CHECK([editor.string isEqualToString:@"f()"], "typing ( inserts )");
      type("a, \"x");
      CHECK([editor.string isEqualToString:@"f(a, \"x\")"], "quote closes inside brackets");
      type("\")");
      CHECK([editor.string isEqualToString:@"f(a, \"x\")"], "typing the closers skips over them");
      CHECK([editor getGeneralProperty:SCI_GETCURRENTPOS] == 9, "caret ends after the closing bracket");
      type(" don't");
      CHECK([editor.string isEqualToString:@"f(a, \"x\") don't"], "apostrophe inside a word is not doubled");
    }

    printf("Large files\n");
    {
      NSMutableData *big = [NSMutableData data];
      for (int line = 0; line < 500000; line += 1) {
        NSString *text = [NSString stringWithFormat:@"%06d int value_%d = compute(%d, \"some text\"); // comment\r\n", line, line, line];
        [big appendData:[text dataUsingEncoding:NSUTF8StringEncoding]];
      }
      NSURL *url = WriteFile(directory, @"big.cpp", big);
      NativeDocument *document = [[NativeDocument alloc] initWithLexerFactory:factory];
      NSDate *start = [NSDate date];
      BOOL opened = [document openURL:url error:nil];
      NSTimeInterval openTime = -start.timeIntervalSinceNow;
      printf("        %.1f MB opened in %.2f s\n", big.length / 1048576.0, openTime);
      CHECK(opened && [document.editor getGeneralProperty:SCI_GETLINECOUNT] == 500001, "opens a 500,000-line file");
      CHECK(openTime < 5.0, "opens it in under 5 seconds");
      start = [NSDate date];
      CHECK([document saveToURL:url error:nil], "saves it");
      printf("        saved in %.2f s\n", -start.timeIntervalSinceNow);
      CHECK([[NSData dataWithContentsOfURL:url] isEqualToData:big], "large file round-trips byte for byte");
    }

    printf("Undo after open\n");
    {
      NSURL *url = WriteFile(directory, @"undo.txt", Bytes("text", 4));
      NativeDocument *document = [[NativeDocument alloc] initWithLexerFactory:factory];
      [document openURL:url error:nil];
      CHECK([document.editor getGeneralProperty:SCI_CANUNDO] == 0, "opening a file is not undoable");
    }

    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
    printf(failures ? "\n%d FAILED\n" : "\nAll checks passed\n", failures);
    return failures ? 1 : 0;
  }
}
