// Launches an app by bundle identifier through SpringBoardServices.
// Needs the com.apple.springboard.launchapplications entitlement (launch.plist).

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef int (*SBSLaunchFunc)(CFStringRef identifier, Boolean suspended);

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <bundle-id>\n", argv[0]);
        return 2;
    }
    void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    SBSLaunchFunc launch = sbs ? (SBSLaunchFunc)dlsym(sbs, "SBSLaunchApplicationWithIdentifier") : NULL;
    if (launch == NULL) {
        fprintf(stderr, "SpringBoardServices not available\n");
        return 1;
    }
    CFStringRef identifier = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    int result = launch(identifier, false);
    CFRelease(identifier);
    if (result != 0) {
        fprintf(stderr, "launch failed: %d\n", result);
    }
    return result;
}
