// proxy-build-shortcut.m
//
// Build a signed `.shortcut` file in-process via WFShortcutPackageFile,
// then attempt to import it programmatically. Tests whether Shortcuts.app's
// signing path will accept our hand-crafted workflow plist (with an
// `WFAppIntentExecutionAction` for `ChatKit.OpenMessageIntent`).
//
// Usage: proxy-build-shortcut <output.shortcut>

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/runtime.h>

static id makeWorkflowDict(NSString *targetGUID, NSString *actionIdentifier) {
    // Use a generic AppIntent-execution shape; iterate through different
    // identifiers to see which one Shortcuts.app accepts.
    NSDictionary *action = @{
        @"WFWorkflowActionIdentifier": actionIdentifier,
        @"WFWorkflowActionParameters": @{
            @"target": @{
                @"Value": @{
                    @"Identifier": targetGUID,
                    @"TypeName": @"MessageEntity",
                },
                @"WFSerializationType": @"WFAppIntentEntityValue",
            },
        },
    };
    return @{
        @"WFWorkflowClientVersion": @"2607.0.4",
        @"WFWorkflowMinimumClientVersion": @1500,
        @"WFWorkflowMinimumClientVersionString": @"1500",
        @"WFWorkflowIcon": @{
            @"WFWorkflowIconStartColor": @431817727,
            @"WFWorkflowIconGlyphNumber": @61440,
        },
        @"WFWorkflowImportQuestions": @[],
        @"WFWorkflowTypes": @[],
        @"WFWorkflowInputContentItemClasses": @[@"WFStringContentItem"],
        @"WFWorkflowOutputContentItemClasses": @[],
        @"WFWorkflowActions": @[action],
    };
}

int main(int argc, char **argv) {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit", RTLD_NOW);
        if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }

        const char *outPath = (argc > 1) ? argv[1] : "/tmp/bm-probe/BMReveal.shortcut";

        // Try several action identifiers to see which one a hand-built plist
        // can use to invoke OpenMessageIntent.
        NSArray *candidateIdentifiers = @[
            @"com.apple.WorkflowKit.RunAppIntent",                 // generic guess
            @"com.apple.MobileSMS.OpenMessageIntent",              // bundle-qualified
            @"OpenMessageIntent",                                  // bare
            @"com.apple.shortcuts.action.appintent",               // alternative guess
            @"com.apple.WorkflowKit.AppIntentExecutionAction",     // class-name
        ];

        // Build the workflow plist with the first candidate identifier;
        // we'll generate a separate file per candidate so the user can try
        // each one in Shortcuts.app.
        for (NSString *ident in candidateIdentifiers) {
            NSDictionary *workflow = makeWorkflowDict(@"ABCDEF12-3456-7890-ABCD-EF1234567890", ident);
            NSError *plistErr = nil;
            NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:workflow
                                                                            format:NSPropertyListBinaryFormat_v1_0
                                                                           options:0
                                                                             error:&plistErr];
            if (!plistData) {
                printf("[%s] plist serialize failed: %s\n", [ident UTF8String], [[plistErr description] UTF8String]);
                continue;
            }

            // WFShortcutPackageFile initWithShortcutData:shortcutName:
            Class WFShortcutPackageFile = NSClassFromString(@"WFShortcutPackageFile");
            if (!WFShortcutPackageFile) { fprintf(stderr, "no WFShortcutPackageFile\n"); return 1; }
            id pkg = [[WFShortcutPackageFile alloc] performSelector:@selector(initWithShortcutData:shortcutName:)
                                                         withObject:plistData
                                                         withObject:[NSString stringWithFormat:@"BM Reveal %@", ident]];

            // Try the "extract signed shortcut file representation" with
            // signing method = local (people-who-know-me, no network).
            // SEL: -extractShortcutFileRepresentationWithSigningMethod:error:
            SEL sel = @selector(extractShortcutFileRepresentationWithSigningMethod:error:);
            NSMethodSignature *sig = [pkg methodSignatureForSelector:sel];
            if (!sig) {
                fprintf(stderr, "no extractShortcutFileRepresentationWithSigningMethod\n");
                return 1;
            }
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:pkg];
            // Signing method enum — values from Apple's headers: usually
            // 0=none/skip, 1=people-who-know-me, 2=anyone. Try 0 first.
            NSInteger method = 0;
            [inv setArgument:&method atIndex:2];
            __autoreleasing NSError *err = nil;
            NSError * __autoreleasing *errP = &err;
            [inv setArgument:&errP atIndex:3];
            [inv invoke];
            __unsafe_unretained id fileRep = nil;
            [inv getReturnValue:&fileRep];

            NSString *fname = [NSString stringWithFormat:@"%s.%@.shortcut", outPath, ident];
            // Sanitize fname (no slashes)
            fname = [fname stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
            // But keep the directory path
            fname = [NSString stringWithFormat:@"%s.%@.shortcut", outPath,
                     [[ident componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/."]]
                      componentsJoinedByString:@"_"]];

            if (fileRep) {
                // fileRep is a WFFileRepresentation; we need to extract NSData.
                id data = [fileRep performSelector:@selector(data)];
                if ([data isKindOfClass:[NSData class]]) {
                    [(NSData *)data writeToFile:fname atomically:YES];
                    printf("[%s] -> %s (%lu bytes)\n",
                           [ident UTF8String],
                           [fname UTF8String],
                           (unsigned long)[(NSData *)data length]);
                } else {
                    printf("[%s] extract OK but no data\n", [ident UTF8String]);
                }
            } else {
                printf("[%s] extract FAILED: %s\n",
                       [ident UTF8String],
                       err ? [[err description] UTF8String] : "(no error)");
            }
        }
    }
    return 0;
}
