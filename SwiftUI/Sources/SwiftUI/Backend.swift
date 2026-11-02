import CObjCRuntime
import CSwiftUIBackend
import ObjCInterop

// The UIKit backend, in Swift: the `sui_*` functions the rest of the module
// renders through, talking to UIKit with ObjCInterop's Objective-C messages.
//
// Renders reuse UIKit views: each view the renderer asks for has a key, from
// its position in the view tree (as @State's are), and the view made for that
// key in the last render is updated in place when it's of the same kind. Only
// properties that changed are set, and containers keep the subviews they
// still have. So controls keep their touches and animations, lists their
// scroll position, and a render costs a fraction of building views anew.
//
// Layout uses frames, not Auto Layout, which took seconds per render on an
// A4. Each render builds layout nodes (cheap Swift objects) around the reused
// views; a node measures its view (its natural size for a proposed size) and
// places its children:
//
// - LeafNode: a label, button or switch, measured with sizeThatFits:.
// - StackNode: children along an axis, with spacing; leftover space goes to
//   flexible children (a Spacer, a List, a color), and a child that doesn't
//   fit is narrowed (text wraps).
// - ContainerNode: one child inset by padding, optionally on a color.
// - ListNode / RowNode: a scroll view of table-style rows.
//
// A screen's content goes in a host view, a UIView subclass defined here
// whose layoutSubviews lays out the node tree.

// MARK: - Geometry

struct LayoutSize: Equatable {
    var width: Float
    var height: Float
}

/// A proposed length with no limit.
let unbounded: Float = 100000

func roundUp(_ value: Float) -> Float { value.rounded(.up) }
func roundDown(_ value: Float) -> Float { value.rounded(.down) }

func size(of value: ObjCValue) -> LayoutSize {
    let words = value.asStruct
    return LayoutSize(width: words?.float(at: 0) ?? 0, height: words?.float(at: 1) ?? 0)
}

func boundsSize(_ view: ObjCValue) -> LayoutSize {
    let words = view.bounds().asStruct
    return LayoutSize(width: words?.float(at: 2) ?? 0, height: words?.float(at: 3) ?? 0)
}

func address(_ value: ObjCValue) -> UInt {
    UInt(bitPattern: value.asObject?.pointer)
}

// MARK: - Layout nodes

class LayoutNode {
    let view: ObjCValue
    /// From frame(width:height:); -1 where none was set.
    var fixedWidth: Float = -1
    var fixedHeight: Float = -1

    init(view: ObjCValue) {
        self.view = view
    }

    /// The natural size within `proposal`.
    func naturalSize(_ proposal: LayoutSize) -> LayoutSize {
        LayoutSize(width: 0, height: 0)
    }

    /// Whether this takes whatever space it's offered along an axis.
    func isFlexible(vertical: Bool) -> Bool {
        false
    }

    /// A Spacer, which stretches a stack along its axis only. (A stored flag:
    /// the backend avoids dynamic casts, which proved unreliable in Embedded
    /// Swift here.)
    var isSpacer: Bool { false }

    /// Places the children in this view's bounds, of `size`.
    func layoutChildren(_ size: LayoutSize) {}

    final func flexible(vertical: Bool) -> Bool {
        if (vertical ? fixedHeight : fixedWidth) >= 0 { return false }
        return isFlexible(vertical: vertical)
    }

    final func measure(_ proposed: LayoutSize) -> LayoutSize {
        var proposal = proposed
        if fixedWidth >= 0 { proposal.width = fixedWidth }
        if fixedHeight >= 0 { proposal.height = fixedHeight }
        var size = naturalSize(proposal)
        if fixedWidth >= 0 { size.width = fixedWidth }
        if fixedHeight >= 0 { size.height = fixedHeight }
        return LayoutSize(width: roundUp(size.width), height: roundUp(size.height))
    }

    /// Sets this view's frame and lays out its children.
    final func place(x: Float, y: Float, width: Float, height: Float) {
        view.setFrame(.rect(x: x, y: y, width: width, height: height))
        layoutChildren(LayoutSize(width: width, height: height))
    }
}

/// A label, button or switch, which knows its own size.
final class LeafNode: LayoutNode {
    private var lastProposal: LayoutSize?
    private var lastSize = LayoutSize(width: 0, height: 0)
    let retained: Retained?

    init(view: ObjCValue, retained: Retained? = nil) {
        self.retained = retained
        super.init(view: view)
    }

    override func naturalSize(_ proposal: LayoutSize) -> LayoutSize {
        // A font or color set after the view was made changes its size.
        retained?.applyPending()
        // Stacks and rows measure a child more than once per layout.
        if proposal == lastProposal { return lastSize }
        // Labels wrap to the proposed width; controls have a natural size.
        var fitted = size(of: view.sizeThatFits(.size(width: proposal.width, height: unbounded)))
        fitted.width = min(fitted.width, proposal.width)
        lastProposal = proposal
        lastSize = fitted
        return fitted
    }
}

/// A color, a list or a navigation controller: takes any space offered.
class FlexibleNode: LayoutNode {
    override func isFlexible(vertical: Bool) -> Bool { true }
}

/// One child, inset by padding (and in a padding, background or tappable view).
final class ContainerNode: LayoutNode {
    let content: LayoutNode
    let top: Float, leading: Float, bottom: Float, trailing: Float

    init(view: ObjCValue, content: LayoutNode, top: Float = 0, leading: Float = 0, bottom: Float = 0, trailing: Float = 0) {
        self.content = content
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
        super.init(view: view)
    }

    override func naturalSize(_ proposal: LayoutSize) -> LayoutSize {
        let inner = content.measure(LayoutSize(width: max(0, proposal.width - leading - trailing),
                                               height: max(0, proposal.height - top - bottom)))
        return LayoutSize(width: inner.width + leading + trailing, height: inner.height + top + bottom)
    }

    override func isFlexible(vertical: Bool) -> Bool {
        content.flexible(vertical: vertical)
    }

    override func layoutChildren(_ size: LayoutSize) {
        content.place(x: leading, y: top, width: max(0, size.width - leading - trailing),
                      height: max(0, size.height - top - bottom))
    }
}

final class SpacerNode: LayoutNode {
    let minLength: Float

    init(view: ObjCValue, minLength: Float) {
        self.minLength = minLength
        super.init(view: view)
    }

    override func naturalSize(_ proposal: LayoutSize) -> LayoutSize {
        LayoutSize(width: minLength, height: minLength)
    }

    override func isFlexible(vertical: Bool) -> Bool { true }

    override var isSpacer: Bool { true }
}

/// A stack of views along an axis, like SwiftUI's VStack and HStack.
final class StackNode: LayoutNode {
    let vertical: Bool
    let spacing: Float
    let alignment: Int
    var children: [LayoutNode] = []
    /// Children that fill the stack across its axis.
    var stretched: [Bool] = []

    init(view: ObjCValue, vertical: Bool, spacing: Float, alignment: Int) {
        self.vertical = vertical
        self.spacing = spacing
        self.alignment = alignment
        super.init(view: view)
    }

    func add(_ child: LayoutNode, stretch: Bool) {
        children.append(child)
        stretched.append(stretch)
        want(child.view, in: view)
    }

    func main(_ size: LayoutSize) -> Float { vertical ? size.height : size.width }
    func cross(_ size: LayoutSize) -> Float { vertical ? size.width : size.height }
    func make(main: Float, cross: Float) -> LayoutSize {
        vertical ? LayoutSize(width: cross, height: main) : LayoutSize(width: main, height: cross)
    }

    /// Lays the children out in `size`, returning their frames (x, y, width,
    /// height). With `measuring`, flexible children get only their minimum,
    /// and the size is the stack's natural size.
    func arrange(_ size: LayoutSize, measuring: Bool) -> (size: LayoutSize, frames: [(Float, Float, Float, Float)]) {
        let count = children.count
        if count == 0 { return (LayoutSize(width: 0, height: 0), []) }
        let available = main(size)
        let crossAvailable = cross(size)
        var sizes: [LayoutSize] = []
        var flexible: [Bool] = []
        var used = spacing * Float(count - 1)
        var flexibleCount = 0

        // Every child at its natural size first.
        for child in children {
            let isFlexible = child.flexible(vertical: vertical)
            let measured = child.measure(make(main: available, cross: crossAvailable))
            sizes.append(measured)
            flexible.append(isFlexible)
            used += main(measured)
            if isFlexible { flexibleCount += 1 }
        }

        // Too long: narrow the longest fixed child, so its text wraps.
        if used > available && available < unbounded {
            var longest = -1
            for index in 0..<count where !flexible[index] {
                if longest < 0 || main(sizes[index]) > main(sizes[longest]) { longest = index }
            }
            if longest >= 0 {
                let length = max(0, main(sizes[longest]) - (used - available))
                let narrowed = children[longest].measure(make(main: length, cross: crossAvailable))
                used -= main(sizes[longest]) - length
                sizes[longest] = make(main: length, cross: cross(narrowed))
            }
        }

        // Flexible children share what's left.
        let extra = measuring || flexibleCount == 0 ? 0 : max(0, available - used) / Float(flexibleCount)

        var crossLength: Float = 0
        for index in 0..<count where !children[index].isSpacer {
            crossLength = max(crossLength, cross(sizes[index]))
        }
        if !measuring { crossLength = crossAvailable }

        var frames: [(Float, Float, Float, Float)] = []
        var position: Float = 0
        for index in 0..<count {
            let mainLength = main(sizes[index]) + (flexible[index] ? extra : 0)
            let fills = stretched[index] || children[index].flexible(vertical: !vertical)
            let crossSize = fills ? crossLength : min(cross(sizes[index]), crossLength)
            let offset: Float
            switch alignment {
            case Int(SUIAlignmentLeading): offset = 0
            case Int(SUIAlignmentTrailing): offset = crossLength - crossSize
            default: offset = roundDown((crossLength - crossSize) / 2)
            }
            frames.append(vertical ? (offset, position, crossSize, mainLength) : (position, offset, mainLength, crossSize))
            position += mainLength + (index + 1 < count ? spacing : 0)
        }
        return (make(main: position, cross: crossLength), frames)
    }

    override func naturalSize(_ proposal: LayoutSize) -> LayoutSize {
        arrange(proposal, measuring: true).size
    }

    override func isFlexible(vertical axis: Bool) -> Bool {
        for child in children {
            // A Spacer stretches a stack along its axis only.
            if axis != vertical && child.isSpacer { continue }
            if child.flexible(vertical: axis) { return true }
        }
        return false
    }

    override func layoutChildren(_ size: LayoutSize) {
        let frames = arrange(size, measuring: false).frames
        for (child, frame) in zip(children, frames) {
            child.place(x: frame.0, y: frame.1, width: frame.2, height: frame.3)
        }
    }
}

let rowInset: Float = 16

/// A table-style row: content at the leading edge, at least 44 points tall,
/// with a separator and an optional chevron.
final class RowNode: LayoutNode {
    let content: LayoutNode
    let chevron: ObjCValue?
    let separator: ObjCValue

    init(view: ObjCValue, content: LayoutNode, chevron: ObjCValue?, separator: ObjCValue) {
        self.content = content
        self.chevron = chevron
        self.separator = separator
        super.init(view: view)
    }

    func contentWidth(_ width: Float) -> Float {
        max(0, width - rowInset - (chevron != nil ? rowInset + 8 + 12 : rowInset))
    }

    override func naturalSize(_ proposal: LayoutSize) -> LayoutSize {
        let measured = content.measure(LayoutSize(width: contentWidth(proposal.width), height: unbounded))
        return LayoutSize(width: proposal.width, height: max(44, measured.height + 22))
    }

    override func isFlexible(vertical: Bool) -> Bool { !vertical }

    override func layoutChildren(_ size: LayoutSize) {
        let available = contentWidth(size.width)
        let measured = content.measure(LayoutSize(width: available, height: unbounded))
        // Flexible content (a Spacer or Toggle) reaches the trailing edge.
        let width = content.flexible(vertical: false) ? available : min(measured.width, available)
        content.place(x: rowInset, y: roundDown((size.height - measured.height) / 2), width: width, height: measured.height)
        chevron?.setFrame(.rect(x: size.width - rowInset - 8, y: roundDown((size.height - 13) / 2), width: 8, height: 13))
        let line = Float(1 / (ObjC.UIScreen.mainScreen().scale().asDouble ?? 1))
        separator.setFrame(.rect(x: rowInset, y: size.height - line, width: size.width - rowInset, height: line))
    }
}

/// A vertically scrolling list of rows.
final class ListNode: FlexibleNode {
    let key: UInt
    let rows: StackNode
    /// A new scroll view, which starts where the last one for this key was.
    let isNew: Bool

    init(view: ObjCValue, key: UInt, rows: StackNode, isNew: Bool) {
        self.key = key
        self.rows = rows
        self.isNew = isNew
        super.init(view: view)
    }

    override func layoutChildren(_ size: LayoutSize) {
        let height = rows.measure(LayoutSize(width: size.width, height: unbounded)).height
        rows.place(x: 0, y: 0, width: size.width, height: height)
        view.setContentSize(.size(width: size.width, height: height))
    }
}

// MARK: - Reused views

enum ViewKind: Equatable {
    case label, button, toggle, tappable, stack, color, spacer, padding, background, list, listRows, row
}

/// A UIKit view kept from render to render, with the values last set on it.
final class Retained {
    let kind: ViewKind
    let view: ObjCValue
    /// Made in this render, rather than reused.
    var isNew = true

    /// For containers: the subviews this one manages, as of the last render,
    /// and those wanted in this one (nil for views without managed children).
    var children: [ObjCValue] = []
    var wanted: [ObjCValue]?

    // The last values set, so unchanged ones aren't set again.
    var text: String?
    var font = -1
    var color: UInt?
    var isOn = false
    var insets: [Int] = []
    /// Set during a render and applied before measuring (and at commit), so a
    /// font or color set right after the view is made doesn't apply the
    /// default first.
    var pendingFont = -1
    var pendingColor: UInt?

    // Parts of rows and lists.
    var chevron: ObjCValue?
    var separator: ObjCValue?
    var rows: Retained?

    init(kind: ViewKind, view: ObjCValue) {
        self.kind = kind
        self.view = view
    }

    func applyPending() {
        if pendingFont >= 0 && pendingFont != font {
            font = pendingFont
            let value = fontFromKey(pendingFont)
            if kind == .button { view.titleLabel().setFont(value) } else { view.setFont(value) }
        }
        if let pendingColor, pendingColor != color {
            color = pendingColor
            if kind == .button { setButtonColor(view, pendingColor) } else { view.setTextColor(rgbaColor(pendingColor)) }
        }
    }
}

/// The views from the last render and this one, by key.
var liveViews: [UInt64: Retained] = [:]
var passViews: [UInt64: Retained] = [:]
/// Every view retained in this render (a duplicate key's too), and by view
/// address, to find a container's record from its node.
var passRetained: [Retained] = []
var passRetainedByView: [UInt: Retained] = [:]

/// The view for the next key in the render: last render's, if it's of the
/// same kind, or a new one from `make`.
func reuse(_ kind: ViewKind, _ salt: UInt64, container: Bool = false, make: () -> ObjCValue) -> Retained {
    let key = currentRenderer?.makeKey(salt) ?? 0
    let retained: Retained
    if passViews[key] == nil, let existing = liveViews[key], existing.kind == kind {
        retained = existing
        retained.isNew = false
    } else {
        retained = Retained(kind: kind, view: make())
    }
    if passViews[key] == nil { passViews[key] = retained }
    retained.wanted = container ? [] : nil
    passRetained.append(retained)
    passRetainedByView[address(retained.view)] = retained
    return retained
}

/// Records that `child` is a subview of the container `parent` in this render.
func want(_ child: ObjCValue, in parent: ObjCValue) {
    if let retained = passRetainedByView[address(parent)], retained.wanted != nil {
        retained.wanted!.append(child)
    } else if address(child.superview()) != address(parent) {
        parent.addSubview(child)
    }
}

/// Gives a container the subviews it wants: adds the new ones and removes
/// the ones it no longer has, leaving the rest where they are.
func syncChildren(_ retained: Retained) {
    guard let wanted = retained.wanted else { return }
    let container = address(retained.view)
    var keep = Set<UInt>()
    for child in wanted {
        keep.insert(address(child))
        if address(child.superview()) != container { retained.view.addSubview(child) }
    }
    for child in retained.children where !keep.contains(address(child)) && address(child.superview()) == container {
        child.removeFromSuperview()
    }
    retained.children = wanted
    retained.wanted = nil
}

// MARK: - State

var renderLaunch: SUICallback?
var renderCallback: SUICallback?
var renderScheduled = false
/// A render was asked for while a list was scrolling; it runs when scrolling stops.
var renderDeferred = false
var appWindow: ObjCValue = nil
var rootController: ObjCValue = nil

/// The nodes of the views made in the current render pass, by view address,
/// and the stacks and lists among them (kept by type rather than found with
/// dynamic casts).
var passNodes: [UInt: LayoutNode] = [:]
var passStacks: [UInt: StackNode] = [:]
var passListNodes: [UInt: ListNode] = [:]
/// Lists made in the current pass, and the lists on screen from the last one.
var passLists: [ListNode] = []
var liveLists: [UInt: ObjCValue] = [:]
/// The last scroll offset of each list, by list key.
var listOffsets: [UInt: Float] = [:]

/// What each host view lays out, by host address. Removed when the host is deallocated.
var hosts: [UInt: HostState] = [:]

final class HostState {
    let root: LayoutNode
    let fillWidth: Bool
    let fillHeight: Bool

    init(root: LayoutNode, fillWidth: Bool, fillHeight: Bool) {
        self.root = root
        self.fillWidth = fillWidth
        self.fillHeight = fillHeight
    }

    /// Fills the host in a dimension, or centers the content in it.
    func layout(_ bounds: LayoutSize) {
        let size = root.measure(bounds)
        let width = fillWidth ? bounds.width : min(size.width, bounds.width)
        let height = fillHeight ? bounds.height : min(size.height, bounds.height)
        root.place(x: roundDown((bounds.width - width) / 2), y: roundDown((bounds.height - height) / 2),
                   width: width, height: height)
    }
}

/// What an action target does, by target address. Removed when the target is deallocated.
var targets: [UInt: TargetState] = [:]
let actionTargetKey = ObjCAssociationKey()

enum Highlight {
    /// A button highlights itself.
    case none
    /// Dims the control, like a SwiftUI plain button.
    case dim
    /// Turns the row gray, like a selected table cell.
    case gray
}

final class TargetState {
    let action: SUICallback?
    let changed: SUIIndexCallback?
    let context: UnsafeMutableRawPointer?
    let highlight: Highlight

    init(action: SUICallback?, changed: SUIIndexCallback?, context: UnsafeMutableRawPointer?, highlight: Highlight) {
        self.action = action
        self.changed = changed
        self.context = context
        self.highlight = highlight
    }
}

/// Navigation controllers by key (they outlive render passes), and by their view's address.
var navigations: [UInt: NavigationState] = [:]
var navigationsByView: [UInt: NavigationState] = [:]
var navigationsByDelegate: [UInt: NavigationState] = [:]

final class NavigationState {
    let controller: ObjCValue
    let delegate: ObjCValue
    var levels: [ObjCValue]
    var count = 1
    var didPop: SUIIndexCallback?
    var context: UnsafeMutableRawPointer?
    var transitioning = false
    /// A render asked for a different stack during a transition.
    var needsCommit = false

    init(controller: ObjCValue, delegate: ObjCValue, root: ObjCValue) {
        self.controller = controller
        self.delegate = delegate
        levels = [root]
    }
}

// MARK: - Classes

/// Defines the Objective-C classes the backend needs, once.
func defineBackendClasses() {
    // A screen's content, laid out by its HostState.
    ObjC.defineClass("SUIHostView", superclass: "UIView") { cls in
        cls.method("layoutSubviews") { call in
            call.callSuper()
            hosts[address(call.this)]?.layout(boundsSize(call.this))
        }
        cls.method("dealloc") { call in
            hosts[address(call.this)] = nil
            call.callSuper()
        }
    }

    // Target-action for controls, and highlighting while touched.
    ObjC.defineClass("SUIActionTarget") { cls in
        cls.method("fire:") { call in
            guard let state = targets[address(call.this)] else { return }
            setHighlighted(call[0], state.highlight, false)
            state.action?(state.context)
        }
        cls.method("highlight:") { call in
            guard let state = targets[address(call.this)] else { return }
            setHighlighted(call[0], state.highlight, true)
        }
        cls.method("unhighlight:") { call in
            guard let state = targets[address(call.this)] else { return }
            setHighlighted(call[0], state.highlight, false)
        }
        cls.method("changed:") { call in
            guard let state = targets[address(call.this)] else { return }
            state.changed?(state.context, call[0].isOn().asBool == true ? 1 : 0)
        }
        cls.method("dealloc") { call in
            targets[address(call.this)] = nil
            call.callSuper()
        }
    }

    // Delegate methods have explicit types: a protocol only exists at run
    // time if loaded code refers to it.

    // Tells Swift when the user pops levels with the back button, and keeps
    // renders from pushing or popping while a transition is animating: on
    // iOS 6 that corrupts the navigation bar.
    ObjC.defineClass("SUINavigationDelegate") { cls in
        cls.conform(to: "UINavigationControllerDelegate")
        cls.method("navigationController:willShowViewController:animated:", types: "v@:@@c") { call in
            guard let state = navigationsByDelegate[address(call.this)] else { return }
            state.transitioning = true
            // The back button has already removed the level; tell Swift now,
            // not when the animation ends, so a render in between doesn't
            // push it back.
            let count = call[0].viewControllers().count().asInt ?? 0
            if count < state.count {
                state.count = count
                state.didPop?(state.context, count)
            }
        }
        cls.method("navigationController:didShowViewController:animated:", types: "v@:@@c") { call in
            guard let state = navigationsByDelegate[address(call.this)] else { return }
            state.transitioning = false
            if state.needsCommit {
                state.needsCommit = false
                sui_schedule_render()
            }
        }
    }

    // Runs renders that waited for scrolling to stop.
    ObjC.defineClass("SUIScrollDelegate") { cls in
        cls.conform(to: "UIScrollViewDelegate")
        cls.method("scrollViewDidEndDragging:willDecelerate:", types: "v@:@c") { call in
            if call[1].asBool != true { scrollingEnded() }
        }
        cls.method("scrollViewDidEndDecelerating:", types: "v@:@") { _ in
            scrollingEnded()
        }
    }

    ObjC.defineClass("SUIAppDelegate", superclass: "UIResponder") { cls in
        cls.conform(to: "UIApplicationDelegate")
        cls.function("application:didFinishLaunchingWithOptions:", types: "c@:@@") { _ in
            appWindow = ObjC.UIWindow.alloc().initWithFrame(ObjC.UIScreen.mainScreen().bounds())
            rootController = ObjC.UIViewController.new()
            rootController.view().setBackgroundColor(ObjC.UIColor.whiteColor())
            appWindow.setRootViewController(rootController)
            appWindow.makeKeyAndVisible()
            renderLaunch?(nil)
            renderCallback?(nil)
            return true
        }
    }
}

let scrollDelegate: ObjCValue = ObjC.SUIScrollDelegate.new()

func setHighlighted(_ control: ObjCValue, _ highlight: Highlight, _ on: Bool) {
    switch highlight {
    case .none:
        break
    case .dim:
        control.setAlpha(on ? 0.4 : 1.0)
    case .gray:
        control.setBackgroundColor(on ? ObjC.UIColor.colorWithWhite(0.85, alpha: 1) : ObjC.UIColor.whiteColor())
    }
}

// UIControlEvents
let touchDown = 1 << 0
let touchDragEnter = 1 << 4
let touchDragExit = 1 << 5
let touchUpInside = 1 << 6
let touchUpOutside = 1 << 7
let touchCancel = 1 << 8
let valueChanged = 1 << 12

/// Calls `action` when `control` is tapped, highlighting it while touched.
/// A reused control keeps its target, which gets this render's action.
func attachAction(_ control: ObjCValue, _ action: SUICallback?, _ context: UnsafeMutableRawPointer?, highlight: Highlight) {
    let existing = control.associated(actionTargetKey)
    if !existing.isNil {
        targets[address(existing)] = TargetState(action: action, changed: nil, context: context, highlight: highlight)
        return
    }
    let target = ObjC.SUIActionTarget.new()
    targets[address(target)] = TargetState(action: action, changed: nil, context: context, highlight: highlight)
    control.addTarget(target, action: ObjC.selector("fire:"), forControlEvents: touchUpInside)
    if highlight != .none {
        control.addTarget(target, action: ObjC.selector("highlight:"), forControlEvents: touchDown | touchDragEnter)
        control.addTarget(target, action: ObjC.selector("unhighlight:"),
                          forControlEvents: touchDragExit | touchUpOutside | touchCancel)
    }
    // UIControl holds targets weakly; the control keeps its target.
    control.setAssociated(target, for: actionTargetKey)
}

// MARK: - Fonts and colors

var fonts: [Int: ObjCValue] = [:]
var colors: [UInt: ObjCValue] = [:]

/// iOS 6 only has regular and bold system fonts.
func font(size: Int, weight: Int) -> ObjCValue {
    let bold = weight == Int(SUIFontWeightSemibold) || weight == Int(SUIFontWeightBold)
    let key = size * 2 + (bold ? 1 : 0)
    if let font = fonts[key] { return font }
    let font = bold ? ObjC.UIFont.boldSystemFontOfSize(size) : ObjC.UIFont.systemFontOfSize(size)
    fonts[key] = font
    return font
}

func fontKey(size: Int, weight: Int) -> Int {
    let bold = weight == Int(SUIFontWeightSemibold) || weight == Int(SUIFontWeightBold)
    return size * 2 + (bold ? 1 : 0)
}

func fontFromKey(_ key: Int) -> ObjCValue {
    font(size: key / 2, weight: key % 2 == 1 ? Int(SUIFontWeightBold) : Int(SUIFontWeightRegular))
}

func rgbaColor(_ rgba: UInt) -> ObjCValue {
    color(rgba)
}

func color(_ rgba: UInt) -> ObjCValue {
    if let color = colors[rgba] { return color }
    let color = ObjC.UIColor.colorWithRed(Double((rgba >> 24) & 0xFF) / 255, green: Double((rgba >> 16) & 0xFF) / 255,
                                          blue: Double((rgba >> 8) & 0xFF) / 255, alpha: Double(rgba & 0xFF) / 255)
    colors[rgba] = color
    return color
}

let separatorColor: UInt = 0xC7C7CCFF

// MARK: - Running

/// Keeps `node` until the pass is committed, and returns its view's address.
func keep(_ node: LayoutNode) -> SUIViewRef? {
    let reference = node.view.asObject?.pointer
    passNodes[UInt(bitPattern: reference)] = node
    return reference
}

func node(_ reference: SUIViewRef?) -> LayoutNode? {
    passNodes[UInt(bitPattern: reference)]
}

func sui_run(_ launch: SUICallback?, _ render: SUICallback?) {
    renderLaunch = launch
    renderCallback = render
    defineBackendClasses()
    _ = objcrt_application_main("SUIAppDelegate")
}

/// Whether the user is dragging a list on screen, or it is still decelerating.
func isScrolling() -> Bool {
    for (_, list) in liveLists where !list.window().isNil {
        if list.isTracking().asBool == true || list.isDragging().asBool == true || list.isDecelerating().asBool == true {
            return true
        }
    }
    return false
}

func sui_schedule_render() {
    if renderScheduled { return }
    renderScheduled = true
    objcrt_async({ _ in
        renderScheduled = false
        // A render lays out the list being scrolled, whose content may move
        // under the finger. Wait until it settles.
        if isScrolling() {
            renderDeferred = true
            return
        }
        renderCallback?(nil)
    }, nil)
}

/// Runs a render that waited for scrolling to stop. Checked on the next run
/// loop turn, once the scroll view has updated its dragging state.
func scrollingEnded() {
    objcrt_async({ _ in
        if !renderDeferred || isScrolling() { return }
        renderDeferred = false
        sui_schedule_render()
    }, nil)
}

func sui_dispatch_main(_ callback: SUICallback?, _ context: UnsafeMutableRawPointer?) {
    objcrt_async(callback, context)
}

func sui_dispatch_main_after(_ milliseconds: UInt, _ callback: SUICallback?, _ context: UnsafeMutableRawPointer?) {
    objcrt_after(milliseconds, callback, context)
}

// MARK: - Render pass

func sui_render_begin() {
    passNodes = [:]
    passStacks = [:]
    passListNodes = [:]
    passLists = []
    passViews = [:]
    passRetained = []
    passRetainedByView = [:]
    // The lists on screen are about to be replaced; remember where they were.
    for (key, list) in liveLists where !list.window().isNil {
        listOffsets[key] = list.contentOffset().asStruct?.float(at: 1) ?? 0
    }
}

/// Each controller's host view, by controller address: kept from render to render.
var controllerHosts: [UInt: ObjCValue] = [:]

/// Makes `root` `controller`'s content, filling or centered in each
/// dimension. On iOS 6 a controller's view already starts below the status
/// and navigation bars.
func install(_ controller: ObjCValue, _ root: LayoutNode, fillWidth: Bool, fillHeight: Bool) {
    let view = controller.view()
    let state = HostState(root: root, fillWidth: fillWidth || root.flexible(vertical: false),
                          fillHeight: fillHeight || root.flexible(vertical: true))
    // The host from the last render: lay out the new tree in it.
    if let host = controllerHosts[address(controller)], address(host.superview()) == address(view) {
        hosts[address(host)] = state
        if address(root.view.superview()) != address(host) {
            let subviews = host.subviews()
            for index in 0..<(subviews.count().asInt ?? 0) { subviews.objectAtIndex(index).removeFromSuperview() }
            host.addSubview(root.view)
        }
        host.setNeedsLayout()
        return
    }
    let subviews = view.subviews()
    let count = subviews.count().asInt ?? 0
    for index in 0..<count {
        subviews.objectAtIndex(index).removeFromSuperview()
    }
    let host = ObjC.SUIHostView.alloc().initWithFrame(view.bounds())
    host.setAutoresizingMask(2 | 16) // flexible width and height
    hosts[address(host)] = state
    host.addSubview(root.view)
    view.addSubview(host)
    controllerHosts[address(controller)] = host
}

/// Scrolls each new list back to where its predecessor was. (A reused list
/// is still where it was.)
func restoreListOffsets() {
    for list in passLists where list.isNew {
        guard let saved = listOffsets[list.key] else { continue }
        var top = list.view
        while true {
            let parent = top.superview()
            if parent.isNil { break }
            top = parent
        }
        top.layoutIfNeeded()
        let contentHeight = list.view.contentSize().asStruct?.float(at: 1) ?? 0
        let maxY = max(0, contentHeight - boundsSize(list.view).height)
        list.view.setContentOffset(.point(x: 0, y: min(saved, maxY)))
    }
}

func sui_render_commit(_ rootReference: SUIViewRef?, _ fillWidth: Int, _ fillHeight: Int) {
    for retained in passRetained {
        syncChildren(retained)
        retained.applyPending()
    }
    if let root = node(rootReference) {
        install(rootController, root, fillWidth: fillWidth != 0, fillHeight: fillHeight != 0)
    }
    restoreListOffsets()
    var lists: [UInt: ObjCValue] = [:]
    for list in passLists { lists[list.key] = list.view }
    liveLists = lists
    // Views not used in this render go (their containers have dropped them).
    liveViews = passViews
    passViews = [:]
    passRetained = []
    passRetainedByView = [:]
    passLists = []
    passNodes = [:]
    passStacks = [:]
    passListNodes = [:]
}

// MARK: - Views

// Each kind of view has its own salt, mixed into its key.
let labelSalt: UInt64 = 0x4c41_4245_4c00_0000
let buttonSalt: UInt64 = 0x4255_5454_4f4e_0000
let switchSalt: UInt64 = 0x5357_4954_4348_0000
let tappableSalt: UInt64 = 0x5441_5050_0000_0000
let stackSalt: UInt64 = 0x5354_4143_4b00_0000
let colorSalt: UInt64 = 0x434f_4c4f_5200_0000
let spacerSalt: UInt64 = 0x5350_4143_4500_0000
let paddingSalt: UInt64 = 0x5041_4444_0000_0000
let backgroundSalt: UInt64 = 0x4247_0000_0000_0000
let listSalt: UInt64 = 0x4c49_5354_5649_4557
let rowSalt: UInt64 = 0x524f_5700_0000_0000

func sui_label_create(_ utf8: UnsafePointer<CChar>?) -> SUIViewRef? {
    let retained = reuse(.label, labelSalt) {
        let label = ObjC.UILabel.new()
        label.setNumberOfLines(0)
        // iOS 6 labels are opaque white by default.
        label.setBackgroundColor(ObjC.UIColor.clearColor())
        return label
    }
    let text = String(cString: utf8!)
    if retained.text != text {
        retained.text = text
        retained.view.setText(ObjC.NSString.stringWithUTF8String(text))
    }
    retained.pendingFont = fontKey(size: 17, weight: Int(SUIFontWeightRegular))
    retained.pendingColor = 0x0000_00FF
    return keep(LeafNode(view: retained.view, retained: retained))
}

func sui_label_set_font(_ label: SUIViewRef?, _ size: Int, _ weight: Int) {
    passRetainedByView[UInt(bitPattern: label)]?.pendingFont = fontKey(size: size, weight: weight)
}

func sui_label_set_color(_ label: SUIViewRef?, _ rgba: UInt) {
    passRetainedByView[UInt(bitPattern: label)]?.pendingColor = rgba
}

/// iOS 6 has no borderless system button, so text buttons are custom buttons
/// that dim while touched. The default color is SwiftUI's accent blue.
func setButtonColor(_ button: ObjCValue, _ rgba: UInt) {
    button.setTitleColor(color(rgba), forState: 0)
    button.setTitleColor(color(rgba).colorWithAlphaComponent(0.3), forState: 1) // highlighted
}

func sui_button_create(_ title: UnsafePointer<CChar>?, _ action: SUICallback?, _ context: UnsafeMutableRawPointer?) -> SUIViewRef? {
    let retained = reuse(.button, buttonSalt) { ObjC.UIButton.buttonWithType(0) } // custom
    let text = String(cString: title!)
    if retained.text != text {
        retained.text = text
        retained.view.setTitle(text, forState: 0)
    }
    retained.pendingFont = fontKey(size: 17, weight: Int(SUIFontWeightRegular))
    retained.pendingColor = 0x007A_FFFF
    attachAction(retained.view, action, context, highlight: .none)
    return keep(LeafNode(view: retained.view, retained: retained))
}

func sui_button_set_font(_ button: SUIViewRef?, _ size: Int, _ weight: Int) {
    passRetainedByView[UInt(bitPattern: button)]?.pendingFont = fontKey(size: size, weight: weight)
}

func sui_button_set_color(_ button: SUIViewRef?, _ rgba: UInt) {
    passRetainedByView[UInt(bitPattern: button)]?.pendingColor = rgba
}

func sui_switch_create(_ on: Int, _ changed: SUIIndexCallback?, _ context: UnsafeMutableRawPointer?) -> SUIViewRef? {
    let retained = reuse(.toggle, switchSalt) {
        let control = ObjC.UISwitch.new()
        let target = ObjC.SUIActionTarget.new()
        control.addTarget(target, action: ObjC.selector("changed:"), forControlEvents: valueChanged)
        control.setAssociated(target, for: actionTargetKey)
        return control
    }
    let control = retained.view
    // Set the switch only when the state changes from what the last render
    // showed, never because the switch differs from the state: a tapped
    // switch turns itself over and animates before it sends its event, and
    // a render in between must leave it be (it would flip back).
    if retained.isNew {
        control.setOn(on != 0)
    } else if retained.isOn != (on != 0) {
        control.setOn(on != 0, animated: true)
    }
    retained.isOn = on != 0
    // The action belongs to this render.
    targets[address(control.associated(actionTargetKey))] = TargetState(action: nil, changed: changed, context: context,
                                                                         highlight: .none)
    return keep(LeafNode(view: control, retained: retained))
}

func sui_tappable_create(_ contentReference: SUIViewRef?, _ action: SUICallback?, _ context: UnsafeMutableRawPointer?) -> SUIViewRef? {
    guard let content = node(contentReference) else { return nil }
    let retained = reuse(.tappable, tappableSalt, container: true) { ObjC.UIControl.new() }
    content.view.setUserInteractionEnabled(false)
    want(content.view, in: retained.view)
    attachAction(retained.view, action, context, highlight: .dim)
    return keep(ContainerNode(view: retained.view, content: content))
}

func sui_stack_create(_ axis: Int, _ spacing: Int, _ alignment: Int) -> SUIViewRef? {
    let retained = reuse(.stack, stackSalt, container: true) { ObjC.UIView.new() }
    let stack = StackNode(view: retained.view, vertical: axis == Int(SUIAxisVertical), spacing: Float(spacing),
                          alignment: alignment)
    let reference = keep(stack)
    passStacks[UInt(bitPattern: reference)] = stack
    return reference
}

func sui_stack_add(_ stack: SUIViewRef?, _ child: SUIViewRef?, _ stretchCrossAxis: Int) {
    guard let stack = passStacks[UInt(bitPattern: stack)], let child = node(child) else { return }
    stack.add(child, stretch: stretchCrossAxis != 0)
}

/// Sets a plain view's background color if it changed.
func setBackground(_ retained: Retained, _ rgba: UInt) {
    if retained.color != rgba {
        retained.color = rgba
        retained.view.setBackgroundColor(color(rgba))
    }
}

func sui_color_view_create(_ rgba: UInt) -> SUIViewRef? {
    let retained = reuse(.color, colorSalt) { ObjC.UIView.new() }
    setBackground(retained, rgba)
    return keep(FlexibleNode(view: retained.view))
}

func sui_spacer_create(_ minLength: Int) -> SUIViewRef? {
    let retained = reuse(.spacer, spacerSalt) { ObjC.UIView.new() }
    return keep(SpacerNode(view: retained.view, minLength: Float(minLength)))
}

func sui_padding_create(_ child: SUIViewRef?, _ top: Int, _ leading: Int, _ bottom: Int, _ trailing: Int) -> SUIViewRef? {
    guard let content = node(child) else { return nil }
    let retained = reuse(.padding, paddingSalt, container: true) { ObjC.UIView.new() }
    want(content.view, in: retained.view)
    return keep(ContainerNode(view: retained.view, content: content, top: Float(top), leading: Float(leading),
                              bottom: Float(bottom), trailing: Float(trailing)))
}

func sui_background_create(_ child: SUIViewRef?, _ rgba: UInt) -> SUIViewRef? {
    guard let content = node(child) else { return nil }
    let retained = reuse(.background, backgroundSalt, container: true) { ObjC.UIView.new() }
    setBackground(retained, rgba)
    want(content.view, in: retained.view)
    return keep(ContainerNode(view: retained.view, content: content))
}

func sui_view_set_size(_ reference: SUIViewRef?, _ width: Int, _ height: Int) {
    guard let node = node(reference) else { return }
    node.fixedWidth = Float(width)
    node.fixedHeight = Float(height)
}

// MARK: - List

/// A right-pointing chevron, like UITableViewCell's disclosure indicator.
func makeChevron() -> ObjCValue {
    let view = ObjC.UIView.new()
    let path = ObjC.UIBezierPath.bezierPath()
    path.moveToPoint(.point(x: 1.5, y: 1.5))
    path.addLineToPoint(.point(x: 6.5, y: 6.5))
    path.addLineToPoint(.point(x: 1.5, y: 11.5))
    let shape = ObjC.CAShapeLayer.layer()
    shape.setFrame(.rect(x: 0, y: 0, width: 8, height: 13))
    shape.setPath(path.CGPath())
    shape.setStrokeColor(color(separatorColor).CGColor())
    shape.setFillColor(ObjC.nil)
    shape.setLineWidth(2)
    shape.setLineCap("round")
    shape.setLineJoin("round")
    view.layer().addSublayer(shape)
    return view
}

func sui_list_create(_ key: UInt) -> SUIViewRef? {
    let retained = reuse(.list, listSalt, container: true) {
        let list = ObjC.UIScrollView.new()
        list.setAlwaysBounceVertical(true)
        list.setBackgroundColor(ObjC.UIColor.whiteColor())
        list.setDelegate(scrollDelegate)
        return list
    }
    // The rows' container, kept with the list.
    if retained.rows == nil { retained.rows = Retained(kind: .listRows, view: ObjC.UIView.new()) }
    let rowsRetained = retained.rows!
    rowsRetained.wanted = []
    passRetained.append(rowsRetained)
    passRetainedByView[address(rowsRetained.view)] = rowsRetained
    want(rowsRetained.view, in: retained.view)

    let rows = StackNode(view: rowsRetained.view, vertical: true, spacing: 0, alignment: Int(SUIAlignmentCenter))
    let node = ListNode(view: retained.view, key: key, rows: rows, isNew: retained.isNew)
    passLists.append(node)
    let reference = keep(node)
    passListNodes[UInt(bitPattern: reference)] = node
    return reference
}

func sui_list_add_row(_ listReference: SUIViewRef?, _ contentReference: SUIViewRef?, _ disclosure: Int,
                      _ action: SUICallback?, _ context: UnsafeMutableRawPointer?) {
    guard let list = passListNodes[UInt(bitPattern: listReference)], let content = node(contentReference) else { return }
    let retained = reuse(.row, rowSalt, container: true) {
        let row = ObjC.UIControl.new()
        row.setBackgroundColor(ObjC.UIColor.whiteColor())
        return row
    }
    let row = retained.view
    content.view.setUserInteractionEnabled(action == nil)
    want(content.view, in: row)

    if disclosure != 0 && retained.chevron == nil { retained.chevron = makeChevron() }
    let chevron: ObjCValue? = disclosure != 0 ? retained.chevron : nil
    if let chevron { want(chevron, in: row) }
    if retained.separator == nil {
        let separator = ObjC.UIView.new()
        separator.setBackgroundColor(color(separatorColor))
        retained.separator = separator
    }
    want(retained.separator!, in: row)

    // A row that was tappable keeps its target, which then does nothing.
    if action != nil || !row.associated(actionTargetKey).isNil {
        attachAction(row, action, context, highlight: action != nil ? .gray : .none)
    }
    list.rows.add(RowNode(view: row, content: content, chevron: chevron, separator: retained.separator!), stretch: true)
}

// MARK: - Navigation

func sui_navigation_create(_ key: UInt) -> SUIViewRef? {
    if navigations[key] == nil {
        let root = ObjC.UIViewController.new()
        root.view().setBackgroundColor(ObjC.UIColor.whiteColor())
        let controller = ObjC.UINavigationController.alloc().initWithRootViewController(root)
        let delegate = ObjC.SUINavigationDelegate.new()
        let state = NavigationState(controller: controller, delegate: delegate, root: root)
        controller.setDelegate(delegate)
        rootController.addChildViewController(controller)
        controller.didMoveToParentViewController(rootController)
        navigations[key] = state
        navigationsByView[address(controller.view())] = state
        navigationsByDelegate[address(delegate)] = state
    }
    return keep(FlexibleNode(view: navigations[key]!.controller.view()))
}

func sui_navigation_set_level(_ navigationReference: SUIViewRef?, _ index: Int, _ contentReference: SUIViewRef?,
                              _ fillWidth: Int, _ fillHeight: Int, _ title: UnsafePointer<CChar>?,
                              _ trailingReference: SUIViewRef?) {
    guard let state = navigationsByView[UInt(bitPattern: navigationReference)], let content = node(contentReference) else {
        return
    }
    while state.levels.count <= index {
        let level = ObjC.UIViewController.new()
        level.view().setBackgroundColor(ObjC.UIColor.whiteColor())
        state.levels.append(level)
    }
    let level = state.levels[index]
    install(level, content, fillWidth: fillWidth != 0, fillHeight: fillHeight != 0)
    let item = level.navigationItem()
    if let title {
        item.setTitle(String(cString: title))
    } else {
        item.setTitle(ObjC.nil)
    }

    if let trailing = node(trailingReference) {
        let size = trailing.measure(LayoutSize(width: 160, height: 44))
        trailing.place(x: 0, y: 0, width: size.width, height: size.height)
        if address(item.rightBarButtonItem().customView()) != address(trailing.view) {
            item.setRightBarButtonItem(ObjC.UIBarButtonItem.alloc().initWithCustomView(trailing.view))
        }
    } else {
        item.setRightBarButtonItem(ObjC.nil)
    }
}

func sui_navigation_commit(_ navigationReference: SUIViewRef?, _ count: Int, _ didPop: SUIIndexCallback?,
                           _ context: UnsafeMutableRawPointer?) {
    guard let state = navigationsByView[UInt(bitPattern: navigationReference)] else { return }
    state.didPop = didPop
    state.context = context
    state.count = count
    if count < state.levels.count {
        for level in state.levels[count...] { controllerHosts[address(level)] = nil }
        state.levels.removeLast(state.levels.count - count)
    }

    let controller = state.controller
    let currentArray = controller.viewControllers()
    var current: [UInt] = []
    for index in 0..<(currentArray.count().asInt ?? 0) {
        current.append(address(currentArray.objectAtIndex(index)))
    }
    var desired: [UInt] = []
    for level in state.levels { desired.append(address(level)) }
    if current == desired { return }
    if state.transitioning {
        state.needsCommit = true
        return
    }

    let isPush = desired.count == current.count + 1 && Array(desired.prefix(current.count)) == current
    let isPop = desired.count < current.count && Array(current.prefix(desired.count)) == desired
    if isPush {
        controller.pushViewController(state.levels[state.levels.count - 1], animated: true)
    } else if isPop {
        controller.popToViewController(state.levels[state.levels.count - 1], animated: true)
    } else {
        let array = ObjC.NSMutableArray.array()
        for level in state.levels { array.addObject(level) }
        controller.setViewControllers(array, animated: false)
    }
}
