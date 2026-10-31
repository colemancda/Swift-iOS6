#import <UIKit/UIKit.h>
#import "HelloIOS6.h"

// iOS 6 has no UIStackView or layout anchors, so the labels are laid out
// with frames and autoresizing masks.

@interface HelloViewController : UIViewController
@end

@implementation HelloViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.10 green:0.12 blue:0.16 alpha:1.0];

    char greeting[128];
    hello_greeting(greeting, sizeof greeting);

    CGRect bounds = self.view.bounds;
    CGFloat width = bounds.size.width - 40;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, bounds.size.height / 2 - 70, width, 60)];
    title.text = [NSString stringWithUTF8String:greeting];
    title.font = [UIFont boldSystemFontOfSize:22];
    title.textColor = [UIColor whiteColor];
    title.backgroundColor = [UIColor clearColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:title];

    UIDevice *device = [UIDevice currentDevice];
    UILabel *detail = [[UILabel alloc] initWithFrame:CGRectMake(20, bounds.size.height / 2 - 4, width, 80)];
    detail.text = [NSString stringWithFormat:@"%@ %@\n1² + … + 10² = %ld (Swift)\nBuilt with Xcode clang + Embedded Swift for armv7",
                   device.systemName, device.systemVersion, hello_sum_of_squares(10)];
    detail.font = [UIFont systemFontOfSize:15];
    detail.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    detail.backgroundColor = [UIColor clearColor];
    detail.textAlignment = NSTextAlignmentCenter;
    detail.numberOfLines = 0;
    detail.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:detail];
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[HelloViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
