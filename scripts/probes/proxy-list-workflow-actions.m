#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/runtime.h>

int main(int argc, char **argv) {
    dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit", RTLD_NOW);
    unsigned int count;
    Class *classes = objc_copyClassList(&count);
    // WFAction is the base class; subclasses implement specific actions.
    for (unsigned int i = 0; i < count; i++) {
        Class c = classes[i];
        const char *name = class_getName(c);
        // Walk superclass chain to find WFAction
        Class sup = c;
        int found = 0;
        for (int j = 0; j < 10 && sup; j++) {
            const char *sn = class_getName(sup);
            if (sn && (strcmp(sn, "WFAction") == 0 || strcmp(sn, "WFAppIntentAction") == 0)) { found = 1; break; }
            sup = class_getSuperclass(sup);
        }
        if (found) printf("%s\n", name);
    }
    free(classes);
    return 0;
}
