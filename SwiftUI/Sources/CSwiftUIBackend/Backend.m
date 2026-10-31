// UIKit implementation of SwiftUIBackend.h for iOS 6.
//
// iOS 6 has Auto Layout, but not layout anchors, `activateConstraints:`,
// UIStackView or layout guides. Constraints are made with
// `constraintWithItem:...` and installed on the items' nearest common
// ancestor, and stacks are SUIStackView, a small constraint-based stack.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SwiftUIBackend.h"

// From <crt_externs.h>, which the iOS SDK doesn't ship; libsystem_c exports them.
extern int *_NSGetArgc(void);
extern char ***_NSGetArgv(void);

static SUICallback SUILaunch;
static SUICallback SUIRender;
static BOOL SUIRenderScheduled;
static NSMutableArray *SUIPendingViews;
static UIViewController *SUIRootController;
/// Lists created in the current pass, and the last scroll offset of each list key.
static NSMutableArray *SUIPassLists;
static NSMapTable *SUILiveLists;
static NSMutableDictionary *SUIListOffsets;
/// Navigation controllers by key; they outlive render passes.
static NSMutableDictionary *SUINavigationControllers;
/// Associates a navigation controller with its state and its view.
static const void *SUINavigationStateKey = &SUINavigationStateKey;

#pragma mark - Helpers

static UIColor *SUIColorFromRGBA(unsigned long rgba) {
    return [UIColor colorWithRed:((rgba >> 24) & 0xFF) / 255.0
                           green:((rgba >> 16) & 0xFF) / 255.0
                            blue:((rgba >> 8) & 0xFF) / 255.0
                           alpha:(rgba & 0xFF) / 255.0];
}

/// iOS 6 only has regular and bold system fonts.
static UIFont *SUIFontMake(long size, long weight) {
    switch (weight) {
        case SUIFontWeightSemibold:
        case SUIFontWeightBold:
            return [UIFont boldSystemFontOfSize:size];
        default:
            return [UIFont systemFontOfSize:size];
    }
}

/// Keeps `view` alive until the render pass is committed.
static SUIViewRef SUIKeep(UIView *view) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [SUIPendingViews addObject:view];
    return (__bridge SUIViewRef)view;
}

static UIView *SUIView(SUIViewRef ref) {
    return (__bridge UIView *)ref;
}

#pragma mark - Constraints

/// `item.attribute relation toItem.toAttribute + constant`. `toItem` may be nil.
static NSLayoutConstraint *SUIConstraint(UIView *item, NSLayoutAttribute attribute, NSLayoutRelation relation,
                                         UIView *toItem, NSLayoutAttribute toAttribute, CGFloat constant) {
    return [NSLayoutConstraint constraintWithItem:item attribute:attribute relatedBy:relation
                                           toItem:toItem attribute:toAttribute multiplier:1 constant:constant];
}

static NSLayoutConstraint *SUIEqual(UIView *item, NSLayoutAttribute attribute,
                                    UIView *toItem, NSLayoutAttribute toAttribute, CGFloat constant) {
    return SUIConstraint(item, attribute, NSLayoutRelationEqual, toItem, toAttribute, constant);
}

/// A width or height constraint against a constant.
static NSLayoutConstraint *SUISize(UIView *item, NSLayoutAttribute attribute, NSLayoutRelation relation, CGFloat constant) {
    return SUIConstraint(item, attribute, relation, nil, NSLayoutAttributeNotAnAttribute, constant);
}

static NSLayoutConstraint *SUIWithPriority(NSLayoutConstraint *constraint, UILayoutPriority priority) {
    constraint.priority = priority;
    return constraint;
}

/// The view a constraint belongs on: the nearest common ancestor of its items.
static UIView *SUIConstraintOwner(NSLayoutConstraint *constraint) {
    UIView *first = constraint.firstItem;
    UIView *second = constraint.secondItem;
    if (!second) return first;
    for (UIView *view = first; view; view = view.superview) {
        if (second == view || [second isDescendantOfView:view]) return view;
    }
    return nil;
}

/// What iOS 8's `activateConstraints:` does.
static void SUIActivate(NSArray *constraints) {
    for (NSLayoutConstraint *constraint in constraints) {
        [SUIConstraintOwner(constraint) addConstraint:constraint];
    }
}

static void SUIDeactivate(NSLayoutConstraint *constraint) {
    [SUIConstraintOwner(constraint) removeConstraint:constraint];
}

static void SUIPin(UIView *child, UIView *parent, long top, long leading, long bottom, long trailing) {
    [parent addSubview:child];
    SUIActivate(@[
        SUIEqual(child, NSLayoutAttributeTop, parent, NSLayoutAttributeTop, top),
        SUIEqual(child, NSLayoutAttributeLeading, parent, NSLayoutAttributeLeading, leading),
        SUIEqual(parent, NSLayoutAttributeBottom, child, NSLayoutAttributeBottom, bottom),
        SUIEqual(parent, NSLayoutAttributeTrailing, child, NSLayoutAttributeTrailing, trailing),
    ]);
}

#pragma mark - Stack

/// A replacement for UIStackView's fill distribution. Children are chained
/// along the axis with `spacing` between them, and the child with the lowest
/// hugging priority (a Spacer) takes any extra space. Across the axis each
/// child is aligned and the stack is as wide as its widest child.
@interface SUIStackView : UIView
@property (nonatomic) BOOL vertical;
@property (nonatomic) CGFloat spacing;
@property (nonatomic) long alignment;
@property (nonatomic, strong) NSMutableArray *arrangedViews;
/// Ties the last child to the stack's trailing (or bottom) edge.
@property (nonatomic, strong) NSLayoutConstraint *endConstraint;
@end

@implementation SUIStackView

- (instancetype)init {
    if ((self = [super init])) {
        _arrangedViews = [NSMutableArray array];
    }
    return self;
}

/// An empty stack has no size.
- (CGSize)intrinsicContentSize {
    return self.arrangedViews.count ? CGSizeMake(UIViewNoIntrinsicMetric, UIViewNoIntrinsicMetric) : CGSizeMake(0, 0);
}

- (void)addArrangedView:(UIView *)child stretch:(BOOL)stretch {
    BOOL vertical = self.vertical;
    NSLayoutAttribute start = vertical ? NSLayoutAttributeTop : NSLayoutAttributeLeading;
    NSLayoutAttribute end = vertical ? NSLayoutAttributeBottom : NSLayoutAttributeTrailing;
    NSLayoutAttribute crossStart = vertical ? NSLayoutAttributeLeading : NSLayoutAttributeTop;
    NSLayoutAttribute crossEnd = vertical ? NSLayoutAttributeTrailing : NSLayoutAttributeBottom;
    NSLayoutAttribute crossCenter = vertical ? NSLayoutAttributeCenterX : NSLayoutAttributeCenterY;
    NSLayoutAttribute crossSize = vertical ? NSLayoutAttributeWidth : NSLayoutAttributeHeight;

    child.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:child];
    UIView *previous = self.arrangedViews.lastObject;
    [self.arrangedViews addObject:child];
    if (self.arrangedViews.count == 1) [self invalidateIntrinsicContentSize];

    NSMutableArray *constraints = [NSMutableArray array];
    if (previous) {
        SUIDeactivate(self.endConstraint);
        [constraints addObject:SUIEqual(child, start, previous, end, self.spacing)];
    } else {
        [constraints addObject:SUIEqual(child, start, self, start, 0)];
    }
    self.endConstraint = SUIEqual(self, end, child, end, 0);
    [constraints addObject:self.endConstraint];

    if (stretch) {
        [constraints addObject:SUIEqual(child, crossSize, self, crossSize, 0)];
        [constraints addObject:SUIEqual(child, crossStart, self, crossStart, 0)];
    } else {
        // Stay inside the stack, and pull it in to fit (weaker than hugging,
        // so the widest child decides).
        [constraints addObject:SUIConstraint(child, crossStart, NSLayoutRelationGreaterThanOrEqual, self, crossStart, 0)];
        [constraints addObject:SUIConstraint(self, crossEnd, NSLayoutRelationGreaterThanOrEqual, child, crossEnd, 0)];
        switch (self.alignment) {
            case SUIAlignmentLeading:
                [constraints addObject:SUIEqual(child, crossStart, self, crossStart, 0)];
                [constraints addObject:SUIWithPriority(SUIEqual(self, crossEnd, child, crossEnd, 0), 249)];
                break;
            case SUIAlignmentTrailing:
                [constraints addObject:SUIEqual(self, crossEnd, child, crossEnd, 0)];
                [constraints addObject:SUIWithPriority(SUIEqual(child, crossStart, self, crossStart, 0), 249)];
                break;
            default:
                [constraints addObject:SUIEqual(child, crossCenter, self, crossCenter, 0)];
                [constraints addObject:SUIWithPriority(SUIEqual(child, crossStart, self, crossStart, 0), 249)];
                break;
        }
    }
    SUIActivate(constraints);
}

@end

#pragma mark - Actions

@interface SUIActionTarget : NSObject
@property (nonatomic) SUICallback action;
@property (nonatomic) void *context;
@end

@implementation SUIActionTarget
- (void)fire {
    if (self.action) self.action(self.context);
}
@end

static const void *SUIActionTargetKey = &SUIActionTargetKey;

static void SUIAttachAction(UIControl *control, SUICallback action, void *context) {
    SUIActionTarget *target = [[SUIActionTarget alloc] init];
    target.action = action;
    target.context = context;
    [control addTarget:target action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    // UIControl holds targets weakly; the control owns its target here.
    objc_setAssociatedObject(control, SUIActionTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// A control that dims its content while touched, like a SwiftUI plain button.
@interface SUITappable : UIControl
@end

@implementation SUITappable
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.4 : 1.0;
}
@end

#pragma mark - App

@interface SUIAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SUIAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    SUIRootController = [[UIViewController alloc] init];
    SUIRootController.view.backgroundColor = [UIColor whiteColor];
    self.window.rootViewController = SUIRootController;
    [self.window makeKeyAndVisible];
    if (SUILaunch) SUILaunch(NULL);
    if (SUIRender) SUIRender(NULL);
    return YES;
}
@end

void sui_run(SUICallback launch, SUICallback render) {
    SUILaunch = launch;
    SUIRender = render;
    @autoreleasepool {
        UIApplicationMain(*_NSGetArgc(), *_NSGetArgv(), nil, NSStringFromClass([SUIAppDelegate class]));
    }
}

void sui_schedule_render(void) {
    if (SUIRenderScheduled) return;
    SUIRenderScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        SUIRenderScheduled = NO;
        if (SUIRender) SUIRender(NULL);
    });
}

void sui_dispatch_main(SUICallback callback, void *context) {
    dispatch_async_f(dispatch_get_main_queue(), context, callback);
}

void sui_dispatch_main_after(unsigned long milliseconds, SUICallback callback, void *context) {
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)milliseconds * NSEC_PER_MSEC),
                     dispatch_get_main_queue(), context, callback);
}

#pragma mark - Render pass

void sui_render_begin(void) {
    SUIPendingViews = [NSMutableArray array];
    SUIPassLists = [NSMutableArray array];
    if (!SUIListOffsets) {
        SUIListOffsets = [NSMutableDictionary dictionary];
        SUILiveLists = [NSMapTable strongToWeakObjectsMapTable];
    }
    // The lists on screen are about to be replaced; remember where they were.
    for (NSNumber *key in SUILiveLists) {
        UIScrollView *list = [SUILiveLists objectForKey:key];
        if (list.window) SUIListOffsets[key] = [NSValue valueWithCGPoint:list.contentOffset];
    }
}

/// Replaces `controller`'s content with `root`, filling or centered in each dimension.
/// On iOS 6 a controller's view already starts below the status and navigation bars.
///
/// The content goes in a new host view that fills the controller's view by
/// autoresizing, so no constraint is ever installed on the controller's view.
/// iOS 6 checks constraints on a view outside a window only when it joins one
/// (a pushed level), and by then constraints left over from replaced content
/// would reference views that are gone, which throws.
static void SUIInstall(UIViewController *controller, UIView *root, long fillWidth, long fillHeight) {
    UIView *view = controller.view;
    for (UIView *subview in [view.subviews copy]) {
        [subview removeFromSuperview];
    }
    UIView *container = [[UIView alloc] initWithFrame:view.bounds];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [view addSubview:container];

    if (objc_getAssociatedObject(root, SUINavigationStateKey)) {
        SUIPin(root, container, 0, 0, 0, 0);
        return;
    }
    [container addSubview:root];
    NSMutableArray *constraints = [NSMutableArray array];

    if (fillWidth) {
        [constraints addObject:SUIEqual(root, NSLayoutAttributeLeading, container, NSLayoutAttributeLeading, 0)];
        [constraints addObject:SUIEqual(root, NSLayoutAttributeTrailing, container, NSLayoutAttributeTrailing, 0)];
    } else {
        [constraints addObject:SUIEqual(root, NSLayoutAttributeCenterX, container, NSLayoutAttributeCenterX, 0)];
        [constraints addObject:SUIConstraint(root, NSLayoutAttributeLeading, NSLayoutRelationGreaterThanOrEqual, container, NSLayoutAttributeLeading, 0)];
        [constraints addObject:SUIConstraint(root, NSLayoutAttributeTrailing, NSLayoutRelationLessThanOrEqual, container, NSLayoutAttributeTrailing, 0)];
    }

    if (fillHeight) {
        [constraints addObject:SUIEqual(root, NSLayoutAttributeTop, container, NSLayoutAttributeTop, 0)];
        [constraints addObject:SUIEqual(root, NSLayoutAttributeBottom, container, NSLayoutAttributeBottom, 0)];
    } else {
        [constraints addObject:SUIEqual(root, NSLayoutAttributeCenterY, container, NSLayoutAttributeCenterY, 0)];
        [constraints addObject:SUIConstraint(root, NSLayoutAttributeTop, NSLayoutRelationGreaterThanOrEqual, container, NSLayoutAttributeTop, 0)];
        [constraints addObject:SUIConstraint(root, NSLayoutAttributeBottom, NSLayoutRelationLessThanOrEqual, container, NSLayoutAttributeBottom, 0)];
    }

    SUIActivate(constraints);
}

/// Scrolls each list made in this pass back to where its predecessor was.
static void SUIRestoreListOffsets(void) {
    for (UIScrollView *list in SUIPassLists) {
        NSValue *saved = SUIListOffsets[objc_getAssociatedObject(list, &SUIListOffsets)];
        if (!saved) continue;
        UIView *top = list;
        while (top.superview) top = top.superview;
        [top layoutIfNeeded];
        CGFloat maxY = MAX(0, list.contentSize.height - list.bounds.size.height);
        list.contentOffset = CGPointMake(0, MIN(saved.CGPointValue.y, maxY));
    }
    SUIPassLists = nil;
}

void sui_render_commit(SUIViewRef rootRef, long fillWidth, long fillHeight) {
    SUIInstall(SUIRootController, SUIView(rootRef), fillWidth, fillHeight);
    SUIRestoreListOffsets();
    SUIPendingViews = nil;
}

#pragma mark - Views

SUIViewRef sui_label_create(const char *utf8) {
    UILabel *label = [[UILabel alloc] init];
    label.text = [NSString stringWithUTF8String:utf8];
    label.numberOfLines = 0;
    label.font = SUIFontMake(17, SUIFontWeightRegular);
    // iOS 6 labels are opaque white by default.
    label.backgroundColor = [UIColor clearColor];
    return SUIKeep(label);
}

void sui_label_set_font(SUIViewRef label, long size, long weight) {
    ((UILabel *)SUIView(label)).font = SUIFontMake(size, weight);
}

void sui_label_set_color(SUIViewRef label, unsigned long rgba) {
    ((UILabel *)SUIView(label)).textColor = SUIColorFromRGBA(rgba);
}

/// iOS 6 has no borderless system button, so text buttons are custom buttons
/// that dim while touched. The default color is SwiftUI's accent blue.
static void SUIButtonSetColor(UIButton *button, UIColor *color) {
    [button setTitleColor:color forState:UIControlStateNormal];
    [button setTitleColor:[color colorWithAlphaComponent:0.3] forState:UIControlStateHighlighted];
}

SUIViewRef sui_button_create(const char *titleUTF8, SUICallback action, void *context) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:[NSString stringWithUTF8String:titleUTF8] forState:UIControlStateNormal];
    button.titleLabel.font = SUIFontMake(17, SUIFontWeightRegular);
    SUIButtonSetColor(button, SUIColorFromRGBA(0x007AFFFF));
    SUIAttachAction(button, action, context);
    return SUIKeep(button);
}

void sui_button_set_font(SUIViewRef button, long size, long weight) {
    ((UIButton *)SUIView(button)).titleLabel.font = SUIFontMake(size, weight);
}

void sui_button_set_color(SUIViewRef button, unsigned long rgba) {
    SUIButtonSetColor((UIButton *)SUIView(button), SUIColorFromRGBA(rgba));
}

SUIViewRef sui_tappable_create(SUIViewRef contentRef, SUICallback action, void *context) {
    SUITappable *control = [[SUITappable alloc] init];
    UIView *content = SUIView(contentRef);
    content.userInteractionEnabled = NO;
    SUIPin(content, control, 0, 0, 0, 0);
    SUIAttachAction(control, action, context);
    return SUIKeep(control);
}

SUIViewRef sui_stack_create(long axis, long spacing, long alignment) {
    SUIStackView *stack = [[SUIStackView alloc] init];
    stack.vertical = axis == SUIAxisVertical;
    stack.spacing = spacing;
    stack.alignment = alignment;
    return SUIKeep(stack);
}

void sui_stack_add(SUIViewRef stackRef, SUIViewRef childRef, long stretchCrossAxis) {
    [(SUIStackView *)SUIView(stackRef) addArrangedView:SUIView(childRef) stretch:stretchCrossAxis != 0];
}

/// Lets `view` grow and shrink freely in both directions.
static void SUIMakeFlexible(UIView *view) {
    for (NSNumber *axis in @[@(UILayoutConstraintAxisHorizontal), @(UILayoutConstraintAxisVertical)]) {
        [view setContentHuggingPriority:1 forAxis:axis.integerValue];
        [view setContentCompressionResistancePriority:1 forAxis:axis.integerValue];
    }
}

SUIViewRef sui_color_view_create(unsigned long rgba) {
    UIView *view = [[UIView alloc] init];
    view.backgroundColor = SUIColorFromRGBA(rgba);
    SUIMakeFlexible(view);
    return SUIKeep(view);
}

SUIViewRef sui_spacer_create(long minLength) {
    UIView *spacer = [[UIView alloc] init];
    SUIMakeFlexible(spacer);
    SUIActivate(@[
        SUIWithPriority(SUISize(spacer, NSLayoutAttributeWidth, NSLayoutRelationGreaterThanOrEqual, minLength), 999),
        SUIWithPriority(SUISize(spacer, NSLayoutAttributeHeight, NSLayoutRelationGreaterThanOrEqual, minLength), 999),
    ]);
    return SUIKeep(spacer);
}

SUIViewRef sui_padding_create(SUIViewRef child, long top, long leading, long bottom, long trailing) {
    UIView *container = [[UIView alloc] init];
    SUIPin(SUIView(child), container, top, leading, bottom, trailing);
    return SUIKeep(container);
}

SUIViewRef sui_background_create(SUIViewRef child, unsigned long rgba) {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = SUIColorFromRGBA(rgba);
    SUIPin(SUIView(child), container, 0, 0, 0, 0);
    return SUIKeep(container);
}

void sui_view_set_size(SUIViewRef ref, long width, long height) {
    UIView *view = SUIView(ref);
    if (width >= 0) SUIActivate(@[SUISize(view, NSLayoutAttributeWidth, NSLayoutRelationEqual, width)]);
    if (height >= 0) SUIActivate(@[SUISize(view, NSLayoutAttributeHeight, NSLayoutRelationEqual, height)]);
}

#pragma mark - List

/// A right-pointing chevron, like UITableViewCell's disclosure indicator.
@interface SUIChevronView : UIView
@end

@implementation SUIChevronView
- (instancetype)init {
    if ((self = [super init])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(1.5, 1.5)];
    [path addLineToPoint:CGPointMake(self.bounds.size.width - 1.5, self.bounds.size.height / 2)];
    [path addLineToPoint:CGPointMake(1.5, self.bounds.size.height - 1.5)];
    path.lineWidth = 2;
    path.lineCapStyle = kCGLineCapRound;
    path.lineJoinStyle = kCGLineJoinRound;
    [[UIColor colorWithRed:0.78 green:0.78 blue:0.8 alpha:1] setStroke];
    [path stroke];
}
@end

/// A list row that turns gray while touched, like a selected table cell.
@interface SUIListRow : UIControl
@end

@implementation SUIListRow
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? [UIColor colorWithWhite:0.85 alpha:1] : [UIColor whiteColor];
}
@end

SUIViewRef sui_list_create(unsigned long key) {
    UIScrollView *list = [[UIScrollView alloc] init];
    list.alwaysBounceVertical = YES;
    list.backgroundColor = [UIColor whiteColor];
    SUIMakeFlexible(list);

    SUIStackView *rows = [[SUIStackView alloc] init];
    rows.vertical = YES;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    SUIPin(rows, list, 0, 0, 0, 0);
    SUIActivate(@[SUIEqual(rows, NSLayoutAttributeWidth, list, NSLayoutAttributeWidth, 0)]);

    NSNumber *listKey = @(key);
    objc_setAssociatedObject(list, &SUIListOffsets, listKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [SUILiveLists setObject:list forKey:listKey];
    [SUIPassLists addObject:list];
    return SUIKeep(list);
}

void sui_list_add_row(SUIViewRef listRef, SUIViewRef contentRef, long disclosure, SUICallback action, void *context) {
    SUIStackView *rows = (SUIStackView *)SUIView(listRef).subviews.firstObject;
    UIView *content = SUIView(contentRef);

    UIControl *row = action ? [[SUIListRow alloc] init] : [[UIControl alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.backgroundColor = [UIColor whiteColor];
    content.userInteractionEnabled = action == NULL;
    [row addSubview:content];

    CGFloat trailing = 16;
    if (disclosure) {
        SUIChevronView *chevron = [[SUIChevronView alloc] init];
        chevron.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:chevron];
        SUIActivate(@[
            SUISize(chevron, NSLayoutAttributeWidth, NSLayoutRelationEqual, 8),
            SUISize(chevron, NSLayoutAttributeHeight, NSLayoutRelationEqual, 13),
            SUIEqual(chevron, NSLayoutAttributeCenterY, row, NSLayoutAttributeCenterY, 0),
            SUIEqual(row, NSLayoutAttributeTrailing, chevron, NSLayoutAttributeTrailing, 16),
        ]);
        trailing += 8 + 12;
    }

    // Rows are at least as tall as a table cell; content hugs the leading edge.
    SUIActivate(@[
        SUISize(row, NSLayoutAttributeHeight, NSLayoutRelationGreaterThanOrEqual, 44),
        SUIConstraint(row, NSLayoutAttributeTrailing, NSLayoutRelationGreaterThanOrEqual, content, NSLayoutAttributeTrailing, trailing),
        SUIConstraint(content, NSLayoutAttributeTop, NSLayoutRelationGreaterThanOrEqual, row, NSLayoutAttributeTop, 11),
        SUIConstraint(row, NSLayoutAttributeBottom, NSLayoutRelationGreaterThanOrEqual, content, NSLayoutAttributeBottom, 11),
        SUIEqual(content, NSLayoutAttributeCenterY, row, NSLayoutAttributeCenterY, 0),
        SUIEqual(content, NSLayoutAttributeLeading, row, NSLayoutAttributeLeading, 16),
    ]);

    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor colorWithRed:0.78 green:0.78 blue:0.8 alpha:1];
    [row addSubview:separator];
    SUIActivate(@[
        SUISize(separator, NSLayoutAttributeHeight, NSLayoutRelationEqual, 1.0 / [UIScreen mainScreen].scale),
        SUIEqual(separator, NSLayoutAttributeLeading, row, NSLayoutAttributeLeading, 16),
        SUIEqual(separator, NSLayoutAttributeTrailing, row, NSLayoutAttributeTrailing, 0),
        SUIEqual(separator, NSLayoutAttributeBottom, row, NSLayoutAttributeBottom, 0),
    ]);

    if (action) SUIAttachAction(row, action, context);
    [rows addArrangedView:row stretch:YES];
    [SUIPendingViews addObject:row];
}

#pragma mark - Navigation

/// One level of a navigation stack. Its content is replaced on every pass.
@interface SUILevelController : UIViewController
@end

@implementation SUILevelController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
}
@end

/// Tells Swift when the user pops levels with the back button.
@interface SUINavigationState : NSObject <UINavigationControllerDelegate>
@property (nonatomic, strong) NSMutableArray<SUILevelController *> *levels;
@property (nonatomic) NSInteger count;
@property (nonatomic) SUIIndexCallback didPop;
@property (nonatomic) void *context;
@end

@implementation SUINavigationState
- (void)navigationController:(UINavigationController *)navigationController
       didShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    NSInteger count = navigationController.viewControllers.count;
    if (count < self.count) {
        self.count = count;
        if (self.didPop) self.didPop(self.context, count);
    }
}
@end

static UINavigationController *SUINavigationController(SUIViewRef ref) {
    return objc_getAssociatedObject(SUIView(ref), SUINavigationStateKey);
}

static SUINavigationState *SUINavigationStateOf(UINavigationController *navigation) {
    return (SUINavigationState *)navigation.delegate;
}

SUIViewRef sui_navigation_create(unsigned long key) {
    if (!SUINavigationControllers) SUINavigationControllers = [NSMutableDictionary dictionary];
    UINavigationController *navigation = SUINavigationControllers[@(key)];
    if (!navigation) {
        SUILevelController *root = [[SUILevelController alloc] init];
        navigation = [[UINavigationController alloc] initWithRootViewController:root];
        SUINavigationState *state = [[SUINavigationState alloc] init];
        state.levels = [NSMutableArray arrayWithObject:root];
        state.count = 1;
        // The delegate is weak; the controller keeps its state alive.
        objc_setAssociatedObject(navigation, SUINavigationStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        navigation.delegate = state;
        objc_setAssociatedObject(navigation.view, SUINavigationStateKey, navigation, OBJC_ASSOCIATION_ASSIGN);
        [SUIRootController addChildViewController:navigation];
        [navigation didMoveToParentViewController:SUIRootController];
        SUINavigationControllers[@(key)] = navigation;
    }
    SUIMakeFlexible(navigation.view);
    return SUIKeep(navigation.view);
}

void sui_navigation_set_level(SUIViewRef navigationRef, long index, SUIViewRef contentRef,
                              long fillWidth, long fillHeight,
                              const char *titleUTF8, SUIViewRef trailingRef) {
    UINavigationController *navigation = SUINavigationController(navigationRef);
    SUINavigationState *state = SUINavigationStateOf(navigation);
    while (state.levels.count <= (NSUInteger)index) {
        [state.levels addObject:[[SUILevelController alloc] init]];
    }
    SUILevelController *level = state.levels[index];
    SUIInstall(level, SUIView(contentRef), fillWidth, fillHeight);
    level.navigationItem.title = titleUTF8 ? [NSString stringWithUTF8String:titleUTF8] : nil;

    if (trailingRef) {
        UIView *item = SUIView(trailingRef);
        CGSize size = [item systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
        item.translatesAutoresizingMaskIntoConstraints = YES;
        item.frame = CGRectMake(0, 0, size.width, size.height);
        level.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:item];
    } else {
        level.navigationItem.rightBarButtonItem = nil;
    }
}

void sui_navigation_commit(SUIViewRef navigationRef, long count, SUIIndexCallback didPop, void *context) {
    UINavigationController *navigation = SUINavigationController(navigationRef);
    SUINavigationState *state = SUINavigationStateOf(navigation);
    state.didPop = didPop;
    state.context = context;
    state.count = count;
    if ((NSUInteger)count < state.levels.count) {
        [state.levels removeObjectsInRange:NSMakeRange(count, state.levels.count - count)];
    }

    NSArray *current = navigation.viewControllers;
    NSArray *desired = [state.levels copy];
    if ([current isEqualToArray:desired]) return;

    BOOL isPush = desired.count == current.count + 1
        && [[desired subarrayWithRange:NSMakeRange(0, current.count)] isEqualToArray:current];
    BOOL isPop = desired.count < current.count
        && [[current subarrayWithRange:NSMakeRange(0, desired.count)] isEqualToArray:desired];
    if (isPush) {
        [navigation pushViewController:desired.lastObject animated:YES];
    } else if (isPop) {
        [navigation popToViewController:desired.lastObject animated:YES];
    } else {
        [navigation setViewControllers:desired animated:NO];
    }
}
