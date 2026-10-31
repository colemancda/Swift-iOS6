// UIKit implementation of SwiftUIBackend.h for iOS 6.
//
// Layout uses frames, not Auto Layout. Every render rebuilds the views on
// screen, and iOS 6's Auto Layout took seconds per pass on an A4 to add,
// remove and solve the constraints of a list. Instead each view is measured
// with SUIMeasure (its natural size for a proposed size) and containers place
// their children in -layoutSubviews:
//
// - SUIStackView: children along an axis, with spacing; leftover space goes
//   to flexible children (a Spacer, a List, a color), and a child that
//   doesn't fit is narrowed (text wraps).
// - SUIContainerView: one child inset by padding, optionally on a color.
// - SUIListView / SUIListRow: a scroll view of table-style rows.
// - SUIHostView: a screen's content, filling or centered in each dimension.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SwiftUIBackend.h"

// From <crt_externs.h>, which the iOS SDK doesn't ship; libsystem_c exports them.
extern int *_NSGetArgc(void);
extern char ***_NSGetArgv(void);

static SUICallback SUILaunch;
static SUICallback SUIRender;
static BOOL SUIRenderScheduled;
/// A render was asked for while a list was scrolling; it runs when scrolling stops.
static BOOL SUIRenderDeferred;
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

/// A proposed length with no limit.
static const CGFloat SUIUnbounded = 100000;

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
    [SUIPendingViews addObject:view];
    return (__bridge SUIViewRef)view;
}

static UIView *SUIView(SUIViewRef ref) {
    return (__bridge UIView *)ref;
}

#pragma mark - Measuring

/// Views that measure themselves and know whether they stretch.
@protocol SUILayout
/// The natural size within `proposal`.
- (CGSize)sui_measure:(CGSize)proposal;
/// Whether the view takes whatever space it's offered along an axis.
- (BOOL)sui_flexible:(BOOL)vertical;
@end

static const void *SUIFixedSizeKey = &SUIFixedSizeKey;
static const void *SUIFlexibleKey = &SUIFlexibleKey;

/// The size from `frame(width:height:)`; -1 where none was set.
static CGSize SUIFixedSize(UIView *view) {
    NSValue *value = objc_getAssociatedObject(view, SUIFixedSizeKey);
    return value ? value.CGSizeValue : CGSizeMake(-1, -1);
}

/// Lets `view` take whatever space it is offered in both directions.
static void SUIMakeFlexible(UIView *view) {
    objc_setAssociatedObject(view, SUIFlexibleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL SUIFlexible(UIView *view, BOOL vertical) {
    CGSize fixed = SUIFixedSize(view);
    if ((vertical ? fixed.height : fixed.width) >= 0) return NO;
    if (objc_getAssociatedObject(view, SUIFlexibleKey)) return YES;
    if ([view conformsToProtocol:@protocol(SUILayout)]) return [(id<SUILayout>)view sui_flexible:vertical];
    return NO;
}

static CGSize SUIMeasure(UIView *view, CGSize proposal) {
    CGSize fixed = SUIFixedSize(view);
    if (fixed.width >= 0) proposal.width = fixed.width;
    if (fixed.height >= 0) proposal.height = fixed.height;

    CGSize size;
    if ([view conformsToProtocol:@protocol(SUILayout)]) {
        size = [(id<SUILayout>)view sui_measure:proposal];
    } else if (objc_getAssociatedObject(view, SUIFlexibleKey)) {
        size = CGSizeMake(0, 0);
    } else {
        // Labels wrap to the proposed width; controls have a natural size.
        size = [view sizeThatFits:CGSizeMake(proposal.width, SUIUnbounded)];
        size.width = MIN(size.width, proposal.width);
    }
    if (fixed.width >= 0) size.width = fixed.width;
    if (fixed.height >= 0) size.height = fixed.height;
    return CGSizeMake(ceilf(size.width), ceilf(size.height));
}

#pragma mark - Containers

/// One child, inset by padding, optionally on a background color.
@interface SUIContainerView : UIView <SUILayout>
@property (nonatomic, strong) UIView *content;
@property (nonatomic) UIEdgeInsets insets;
@end

static CGSize SUIContainerMeasure(UIView *content, UIEdgeInsets insets, CGSize proposal) {
    CGSize inner = CGSizeMake(MAX(0, proposal.width - insets.left - insets.right),
                              MAX(0, proposal.height - insets.top - insets.bottom));
    CGSize size = SUIMeasure(content, inner);
    return CGSizeMake(size.width + insets.left + insets.right, size.height + insets.top + insets.bottom);
}

@implementation SUIContainerView
- (CGSize)sui_measure:(CGSize)proposal {
    return SUIContainerMeasure(self.content, self.insets, proposal);
}

- (BOOL)sui_flexible:(BOOL)vertical {
    return SUIFlexible(self.content, vertical);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.content.frame = UIEdgeInsetsInsetRect(self.bounds, self.insets);
}
@end

static SUIContainerView *SUIContainerMake(UIView *content, UIEdgeInsets insets) {
    SUIContainerView *container = [[SUIContainerView alloc] init];
    container.content = content;
    container.insets = insets;
    [container addSubview:content];
    return container;
}

#pragma mark - Stack

/// A stack of views along an axis, like SwiftUI's VStack and HStack.
@interface SUIStackView : UIView <SUILayout>
@property (nonatomic) BOOL vertical;
@property (nonatomic) CGFloat spacing;
@property (nonatomic) long alignment;
@property (nonatomic, strong) NSMutableArray *arrangedViews;
/// Indexes of children that fill the stack across its axis.
@property (nonatomic, strong) NSMutableIndexSet *stretched;
@end

@interface SUISpacerView : UIView <SUILayout>
@property (nonatomic) CGFloat minLength;
@end

@implementation SUISpacerView
- (CGSize)sui_measure:(CGSize)proposal {
    return CGSizeMake(self.minLength, self.minLength);
}

- (BOOL)sui_flexible:(BOOL)vertical {
    return YES;
}
@end

@implementation SUIStackView

- (instancetype)init {
    if ((self = [super init])) {
        _arrangedViews = [NSMutableArray array];
        _stretched = [NSMutableIndexSet indexSet];
    }
    return self;
}

- (void)addArrangedView:(UIView *)child stretch:(BOOL)stretch {
    if (stretch) [self.stretched addIndex:self.arrangedViews.count];
    [self.arrangedViews addObject:child];
    [self addSubview:child];
    [self setNeedsLayout];
}

static CGFloat SUIMain(CGSize size, BOOL vertical) { return vertical ? size.height : size.width; }
static CGFloat SUICross(CGSize size, BOOL vertical) { return vertical ? size.width : size.height; }
static CGSize SUISizeMake(CGFloat main, CGFloat cross, BOOL vertical) {
    return vertical ? CGSizeMake(cross, main) : CGSizeMake(main, cross);
}

/// Lays the children out in `size`, writing their frames to `frames` if it
/// isn't NULL. With `measuring`, flexible children get only their minimum
/// and the result is the stack's natural size.
- (CGSize)arrangeInSize:(CGSize)size frames:(CGRect *)frames measuring:(BOOL)measuring {
    BOOL vertical = self.vertical;
    NSUInteger count = self.arrangedViews.count;
    if (count == 0) return CGSizeMake(0, 0);

    CGFloat available = SUIMain(size, vertical);
    CGFloat crossAvailable = SUICross(size, vertical);
    CGSize sizes[count];
    BOOL flexible[count];
    CGFloat used = self.spacing * (count - 1);
    NSUInteger flexibleCount = 0;

    // Fixed children first, at their natural size.
    for (NSUInteger i = 0; i < count; i++) {
        UIView *child = self.arrangedViews[i];
        flexible[i] = SUIFlexible(child, vertical);
        sizes[i] = SUIMeasure(child, SUISizeMake(available, crossAvailable, vertical));
        used += SUIMain(sizes[i], vertical);
        if (flexible[i]) flexibleCount++;
    }

    // Too long: narrow the longest fixed child, so its text wraps.
    if (used > available && available < SUIUnbounded) {
        NSUInteger longest = NSNotFound;
        for (NSUInteger i = 0; i < count; i++) {
            if (flexible[i]) continue;
            if (longest == NSNotFound || SUIMain(sizes[i], vertical) > SUIMain(sizes[longest], vertical)) longest = i;
        }
        if (longest != NSNotFound) {
            CGFloat length = MAX(0, SUIMain(sizes[longest], vertical) - (used - available));
            CGSize narrowed = SUIMeasure(self.arrangedViews[longest], SUISizeMake(length, crossAvailable, vertical));
            used -= SUIMain(sizes[longest], vertical) - length;
            sizes[longest] = SUISizeMake(length, SUICross(narrowed, vertical), vertical);
        }
    }

    // Flexible children share what's left.
    CGFloat extra = measuring || flexibleCount == 0 ? 0 : MAX(0, available - used) / flexibleCount;

    CGFloat crossLength = 0;
    for (NSUInteger i = 0; i < count; i++) {
        if ([self.arrangedViews[i] isKindOfClass:[SUISpacerView class]]) continue;
        crossLength = MAX(crossLength, SUICross(sizes[i], vertical));
    }
    if (!measuring) crossLength = crossAvailable;

    CGFloat position = 0;
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat main = SUIMain(sizes[i], vertical) + (flexible[i] ? extra : 0);
        BOOL fills = [self.stretched containsIndex:i] || SUIFlexible(self.arrangedViews[i], !vertical);
        CGFloat cross = fills ? crossLength : MIN(SUICross(sizes[i], vertical), crossLength);
        CGFloat offset;
        switch (self.alignment) {
            case SUIAlignmentLeading: offset = 0; break;
            case SUIAlignmentTrailing: offset = crossLength - cross; break;
            default: offset = floorf((crossLength - cross) / 2); break;
        }
        if (frames) {
            frames[i] = vertical ? CGRectMake(offset, position, cross, main)
                                 : CGRectMake(position, offset, main, cross);
        }
        position += main + (i + 1 < count ? self.spacing : 0);
    }
    return SUISizeMake(position, crossLength, vertical);
}

- (CGSize)sui_measure:(CGSize)proposal {
    return [self arrangeInSize:proposal frames:NULL measuring:YES];
}

- (BOOL)sui_flexible:(BOOL)vertical {
    for (UIView *child in self.arrangedViews) {
        // A Spacer stretches a stack along its axis only.
        if (vertical != self.vertical && [child isKindOfClass:[SUISpacerView class]]) continue;
        if (SUIFlexible(child, vertical)) return YES;
    }
    return NO;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    NSUInteger count = self.arrangedViews.count;
    if (count == 0) return;
    CGRect frames[count];
    [self arrangeInSize:self.bounds.size frames:frames measuring:NO];
    for (NSUInteger i = 0; i < count; i++) {
        ((UIView *)self.arrangedViews[i]).frame = frames[i];
    }
}

@end

#pragma mark - Host

/// A screen's content: fills the screen in a dimension, or is centered in it.
/// Resized with its controller's view by autoresizing.
@interface SUIHostView : UIView
@property (nonatomic, strong) UIView *content;
@property (nonatomic) BOOL fillWidth;
@property (nonatomic) BOOL fillHeight;
@end

@implementation SUIHostView
- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize bounds = self.bounds.size;
    CGSize size = SUIMeasure(self.content, bounds);
    CGFloat width = self.fillWidth ? bounds.width : MIN(size.width, bounds.width);
    CGFloat height = self.fillHeight ? bounds.height : MIN(size.height, bounds.height);
    self.content.frame = CGRectMake(floorf((bounds.width - width) / 2), floorf((bounds.height - height) / 2), width, height);
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
@interface SUITappable : UIControl <SUILayout>
@property (nonatomic, strong) UIView *content;
@end

@implementation SUITappable
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.4 : 1.0;
}

- (CGSize)sui_measure:(CGSize)proposal {
    return SUIMeasure(self.content, proposal);
}

- (BOOL)sui_flexible:(BOOL)vertical {
    return SUIFlexible(self.content, vertical);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.content.frame = self.bounds;
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

/// Whether the user is dragging a list on screen, or it is still decelerating.
static BOOL SUIScrolling(void) {
    for (NSNumber *key in SUILiveLists) {
        UIScrollView *list = [SUILiveLists objectForKey:key];
        if (list.window && (list.tracking || list.dragging || list.decelerating)) return YES;
    }
    return NO;
}

void sui_schedule_render(void) {
    if (SUIRenderScheduled) return;
    SUIRenderScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        SUIRenderScheduled = NO;
        // A render replaces the list being scrolled, which ends the gesture
        // and stalls the scroll. Wait until it settles.
        if (SUIScrolling()) {
            SUIRenderDeferred = YES;
            return;
        }
        if (SUIRender) SUIRender(NULL);
    });
}

/// Runs a render that waited for scrolling to stop. Checked on the next run
/// loop turn, once the scroll view has updated its dragging state.
static void SUIScrollingEnded(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!SUIRenderDeferred || SUIScrolling()) return;
        SUIRenderDeferred = NO;
        sui_schedule_render();
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

/// Replaces `controller`'s content with `root`, filling or centered in each
/// dimension. On iOS 6 a controller's view already starts below the status
/// and navigation bars.
static void SUIInstall(UIViewController *controller, UIView *root, long fillWidth, long fillHeight) {
    UIView *view = controller.view;
    // A navigation controller's view is the same in every pass; leave it be.
    if (root.superview && root.superview.superview == view) return;
    for (UIView *subview in [view.subviews copy]) {
        [subview removeFromSuperview];
    }
    SUIHostView *host = [[SUIHostView alloc] initWithFrame:view.bounds];
    host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    host.content = root;
    host.fillWidth = fillWidth || SUIFlexible(root, NO);
    host.fillHeight = fillHeight || SUIFlexible(root, YES);
    [host addSubview:root];
    [view addSubview:host];
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

/// Reports a switch's new value to Swift.
@interface SUISwitchTarget : NSObject
@property (nonatomic) SUIIndexCallback changed;
@property (nonatomic) void *context;
@end

@implementation SUISwitchTarget
- (void)changed:(UISwitch *)sender {
    if (self.changed) self.changed(self.context, sender.on ? 1 : 0);
}
@end

SUIViewRef sui_switch_create(long on, SUIIndexCallback changed, void *context) {
    UISwitch *control = [[UISwitch alloc] init];
    control.on = on != 0;
    SUISwitchTarget *target = [[SUISwitchTarget alloc] init];
    target.changed = changed;
    target.context = context;
    [control addTarget:target action:@selector(changed:) forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(control, SUIActionTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return SUIKeep(control);
}

SUIViewRef sui_tappable_create(SUIViewRef contentRef, SUICallback action, void *context) {
    SUITappable *control = [[SUITappable alloc] init];
    UIView *content = SUIView(contentRef);
    content.userInteractionEnabled = NO;
    control.content = content;
    [control addSubview:content];
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

SUIViewRef sui_color_view_create(unsigned long rgba) {
    UIView *view = [[UIView alloc] init];
    view.backgroundColor = SUIColorFromRGBA(rgba);
    SUIMakeFlexible(view);
    return SUIKeep(view);
}

SUIViewRef sui_spacer_create(long minLength) {
    SUISpacerView *spacer = [[SUISpacerView alloc] init];
    spacer.minLength = minLength;
    return SUIKeep(spacer);
}

SUIViewRef sui_padding_create(SUIViewRef child, long top, long leading, long bottom, long trailing) {
    return SUIKeep(SUIContainerMake(SUIView(child), UIEdgeInsetsMake(top, leading, bottom, trailing)));
}

SUIViewRef sui_background_create(SUIViewRef child, unsigned long rgba) {
    SUIContainerView *container = SUIContainerMake(SUIView(child), UIEdgeInsetsZero);
    container.backgroundColor = SUIColorFromRGBA(rgba);
    return SUIKeep(container);
}

void sui_view_set_size(SUIViewRef ref, long width, long height) {
    objc_setAssociatedObject(SUIView(ref), SUIFixedSizeKey, [NSValue valueWithCGSize:CGSizeMake(width, height)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - List

/// A right-pointing chevron, like UITableViewCell's disclosure indicator.
@interface SUIChevronView : UIView
@end

@implementation SUIChevronView
- (instancetype)init {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 8, 13)])) {
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

/// A table-style row: content at the leading edge, at least 44 points tall,
/// with a separator and an optional chevron. Rows with an action turn gray
/// while touched.
@interface SUIListRow : UIControl <SUILayout>
@property (nonatomic, strong) UIView *content;
@property (nonatomic, strong) UIView *chevron;
@property (nonatomic, strong) UIView *separator;
@property (nonatomic) BOOL highlights;
@end

static const CGFloat SUIRowInset = 16;

@implementation SUIListRow

- (CGFloat)contentWidthIn:(CGFloat)width {
    return MAX(0, width - SUIRowInset - (self.chevron ? SUIRowInset + 8 + 12 : SUIRowInset));
}

- (CGSize)sui_measure:(CGSize)proposal {
    CGSize content = SUIMeasure(self.content, CGSizeMake([self contentWidthIn:proposal.width], SUIUnbounded));
    return CGSizeMake(proposal.width, MAX(44, content.height + 22));
}

- (BOOL)sui_flexible:(BOOL)vertical {
    return !vertical;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize bounds = self.bounds.size;
    CGFloat available = [self contentWidthIn:bounds.width];
    CGSize size = SUIMeasure(self.content, CGSizeMake(available, SUIUnbounded));
    // Flexible content (a Spacer or Toggle) reaches the trailing edge.
    CGFloat width = SUIFlexible(self.content, NO) ? available : MIN(size.width, available);
    self.content.frame = CGRectMake(SUIRowInset, floorf((bounds.height - size.height) / 2), width, size.height);
    if (self.chevron) {
        self.chevron.frame = CGRectMake(bounds.width - SUIRowInset - 8, floorf((bounds.height - 13) / 2), 8, 13);
    }
    CGFloat line = 1.0 / [UIScreen mainScreen].scale;
    self.separator.frame = CGRectMake(SUIRowInset, bounds.height - line, bounds.width - SUIRowInset, line);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    if (self.highlights) {
        self.backgroundColor = highlighted ? [UIColor colorWithWhite:0.85 alpha:1] : [UIColor whiteColor];
    }
}

@end

/// A vertically scrolling list of rows. It is its own delegate, to run
/// renders that waited for scrolling to stop.
@interface SUIListView : UIScrollView <UIScrollViewDelegate>
@property (nonatomic, strong) SUIStackView *rows;
@property (nonatomic) CGFloat laidOutWidth;
@end

@implementation SUIListView

- (void)layoutSubviews {
    [super layoutSubviews];
    // Scrolling calls this every frame; only relayout rows for a new width.
    CGFloat width = self.bounds.size.width;
    if (width == self.laidOutWidth) return;
    self.laidOutWidth = width;
    CGFloat height = SUIMeasure(self.rows, CGSizeMake(width, SUIUnbounded)).height;
    self.rows.frame = CGRectMake(0, 0, width, height);
    self.contentSize = CGSizeMake(width, height);
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) SUIScrollingEnded();
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    SUIScrollingEnded();
}

@end

SUIViewRef sui_list_create(unsigned long key) {
    SUIListView *list = [[SUIListView alloc] init];
    list.delegate = list;
    list.alwaysBounceVertical = YES;
    list.backgroundColor = [UIColor whiteColor];
    SUIMakeFlexible(list);

    list.rows = [[SUIStackView alloc] init];
    list.rows.vertical = YES;
    [list addSubview:list.rows];

    NSNumber *listKey = @(key);
    objc_setAssociatedObject(list, &SUIListOffsets, listKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [SUILiveLists setObject:list forKey:listKey];
    [SUIPassLists addObject:list];
    return SUIKeep(list);
}

void sui_list_add_row(SUIViewRef listRef, SUIViewRef contentRef, long disclosure, SUICallback action, void *context) {
    SUIListView *list = (SUIListView *)SUIView(listRef);
    UIView *content = SUIView(contentRef);

    SUIListRow *row = [[SUIListRow alloc] init];
    row.backgroundColor = [UIColor whiteColor];
    row.highlights = action != NULL;
    row.content = content;
    content.userInteractionEnabled = action == NULL;
    [row addSubview:content];

    if (disclosure) {
        row.chevron = [[SUIChevronView alloc] init];
        [row addSubview:row.chevron];
    }
    row.separator = [[UIView alloc] init];
    row.separator.backgroundColor = [UIColor colorWithRed:0.78 green:0.78 blue:0.8 alpha:1];
    [row addSubview:row.separator];

    if (action) SUIAttachAction(row, action, context);
    [list.rows addArrangedView:row stretch:YES];
    list.laidOutWidth = 0;
    [list setNeedsLayout];
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

/// Tells Swift when the user pops levels with the back button, and keeps
/// renders from pushing or popping while a transition is animating: on iOS 6
/// that corrupts the navigation bar.
@interface SUINavigationState : NSObject <UINavigationControllerDelegate>
@property (nonatomic, strong) NSMutableArray<SUILevelController *> *levels;
@property (nonatomic) NSInteger count;
@property (nonatomic) SUIIndexCallback didPop;
@property (nonatomic) void *context;
@property (nonatomic) BOOL transitioning;
/// A render asked for a different stack during a transition.
@property (nonatomic) BOOL needsCommit;
@end

@implementation SUINavigationState
- (void)navigationController:(UINavigationController *)navigationController
      willShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    self.transitioning = YES;
    // The back button has already removed the level; tell Swift now, not
    // when the animation ends, so a render in between doesn't push it back.
    NSInteger count = navigationController.viewControllers.count;
    if (count < self.count) {
        self.count = count;
        if (self.didPop) self.didPop(self.context, count);
    }
}

- (void)navigationController:(UINavigationController *)navigationController
       didShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    self.transitioning = NO;
    if (self.needsCommit) {
        self.needsCommit = NO;
        sui_schedule_render();
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
        CGSize size = SUIMeasure(item, CGSizeMake(160, 44));
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
    if (state.transitioning) {
        state.needsCommit = YES;
        return;
    }

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
