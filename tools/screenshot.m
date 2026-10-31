// Writes a PNG of the screen to stdout, using UIKit's private UIGetScreenImage().
// Xcode 27 has no iOS 6 developer disk image, so idevicescreenshot can't.

#import <UIKit/UIKit.h>
#include <unistd.h>

extern CGImageRef UIGetScreenImage(void);

int main(void) {
    @autoreleasepool {
        CGImageRef screen = UIGetScreenImage();
        if (screen == NULL) {
            fprintf(stderr, "UIGetScreenImage failed\n");
            return 1;
        }
        NSData *png = UIImagePNGRepresentation([UIImage imageWithCGImage:screen]);
        CGImageRelease(screen);
        write(STDOUT_FILENO, png.bytes, png.length);
    }
    return 0;
}
