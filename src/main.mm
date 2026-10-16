#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include "ILexer.h"
#include "Lexilla.h"
#import "NativeEditorController.h"

// Settings, session and support files from the app's earlier name ("Notepad++ Native").
static void MigrateFromPreviousIdentity(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults boolForKey:@"NativeEditor.MigratedFromNative"]) return;
  NSDictionary *previous = [defaults persistentDomainForName:@"com.ai.notepadplusplus.native"];
  if (previous.count && ![defaults objectForKey:@"NativeEditor.Preferences.v1"] && ![defaults objectForKey:@"NativeEditor.Session.v1"]) {
    [previous enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
      (void)stop;
      [defaults setObject:value forKey:key];
    }];
  }
  NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
  NSURL *oldFolder = [support URLByAppendingPathComponent:@"Notepad++ Native"];
  NSURL *newFolder = [support URLByAppendingPathComponent:@"Notepad++"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:oldFolder.path] && ![[NSFileManager defaultManager] fileExistsAtPath:newFolder.path]) {
    [[NSFileManager defaultManager] moveItemAtURL:oldFolder toURL:newFolder error:nil];
  }
  [defaults setBool:YES forKey:@"NativeEditor.MigratedFromNative"];
}

int main(int argc, const char *argv[]) {
  (void)argc;
  (void)argv;
  @autoreleasepool {
    MigrateFromPreviousIdentity();
    NSString *lexillaPath = [[[NSBundle mainBundle] privateFrameworksPath]
        stringByAppendingPathComponent:@"liblexilla.dylib"];
    void *lexillaHandle = dlopen(lexillaPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    void *lexerFactory = lexillaHandle ? dlsym(lexillaHandle, LEXILLA_CREATELEXER) : NULL;

    NSApplication *application = [NSApplication sharedApplication];
    [application setActivationPolicy:NSApplicationActivationPolicyRegular];
    NativeEditorController *controller = [[NativeEditorController alloc] initWithLexerFactory:lexerFactory];
    application.delegate = controller;
    application.servicesProvider = controller;
    [application run];
    if (lexillaHandle) dlclose(lexillaHandle);
  }
  return 0;
}