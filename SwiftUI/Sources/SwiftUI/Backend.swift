import CObjCRuntime
import CSwiftUIBackend
import ObjCInterop

// The UIKit backend, in Swift: the `sui_*` functions the rest of the module
// renders through, talking to UIKit with ObjCInterop's Objective-C messages.
//
// Every render builds new UIKit views. Layout uses frames, not Auto Layout,
// which took seconds per render on an A4. Each view has a layout node that
// measures it (its natural size for a proposed size) and places its children:
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

    override func naturalSize(_ proposal: LayoutSize) -> LayoutSize {
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
        view.addSubview(child.view)
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

    init(view: ObjCValue, key: UInt, rows: StackNode) {
        self.key = key
        self.rows = rows
        super.init(view: view)
    }

    override func layoutChildren(_ size: LayoutSize) {
        let height = rows.measure(LayoutSize(width: size.width, height: unbounded)).height
        rows.place(x: 0, y: 0, width: size.width, height: height)
        view.setContentSize(.size(width: size.width, height: height))
    }
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
func attachAction(_ control: ObjCValue, _ action: SUICallback?, _ context: UnsafeMutableRawPointer?, highlight: Highlight) {
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
        // A render replaces the list being scrolled, which ends the gesture
        // and stalls the scroll. Wait until it settles.
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
    // The lists on screen are about to be replaced; remember where they were.
    for (key, list) in liveLists where !list.window().isNil {
        listOffsets[key] = list.contentOffset().asStruct?.float(at: 1) ?? 0
    }
}

/// Replaces `controller`'s content with `root`, filling or centered in each
/// dimension. On iOS 6 a controller's view already starts below the status
/// and navigation bars.
func install(_ controller: ObjCValue, _ root: LayoutNode, fillWidth: Bool, fillHeight: Bool) {
    let view = controller.view()
    // A navigation controller's view is the same in every pass; leave it be.
    if address(root.view.superview().superview()) == address(view) && address(view) != 0 { return }
    let subviews = view.subviews()
    let count = subviews.count().asInt ?? 0
    for index in 0..<count {
        subviews.objectAtIndex(index).removeFromSuperview()
    }
    let host = ObjC.SUIHostView.alloc().initWithFrame(view.bounds())
    host.setAutoresizingMask(2 | 16) // flexible width and height
    hosts[address(host)] = HostState(root: root, fillWidth: fillWidth || root.flexible(vertical: false),
                                     fillHeight: fillHeight || root.flexible(vertical: true))
    host.addSubview(root.view)
    view.addSubview(host)
}

/// Scrolls each list made in this pass back to where its predecessor was.
func restoreListOffsets() {
    for list in passLists {
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
    if let root = node(rootReference) {
        install(rootController, root, fillWidth: fillWidth != 0, fillHeight: fillHeight != 0)
    }
    restoreListOffsets()
    var lists: [UInt: ObjCValue] = [:]
    for list in passLists { lists[list.key] = list.view }
    liveLists = lists
    passLists = []
    passNodes = [:]
    passStacks = [:]
    passListNodes = [:]
}

// MARK: - Views

func sui_label_create(_ utf8: UnsafePointer<CChar>?) -> SUIViewRef? {
    let label = ObjC.UILabel.new()
    label.setText(ObjC.NSString.stringWithUTF8String(String(cString: utf8!)))
    label.setNumberOfLines(0)
    label.setFont(font(size: 17, weight: Int(SUIFontWeightRegular)))
    // iOS 6 labels are opaque white by default.
    label.setBackgroundColor(ObjC.UIColor.clearColor())
    return keep(LeafNode(view: label))
}

func sui_label_set_font(_ label: SUIViewRef?, _ size: Int, _ weight: Int) {
    node(label)?.view.setFont(font(size: size, weight: weight))
}

func sui_label_set_color(_ label: SUIViewRef?, _ rgba: UInt) {
    node(label)?.view.setTextColor(color(rgba))
}

/// iOS 6 has no borderless system button, so text buttons are custom buttons
/// that dim while touched. The default color is SwiftUI's accent blue.
func setButtonColor(_ button: ObjCValue, _ rgba: UInt) {
    button.setTitleColor(color(rgba), forState: 0)
    button.setTitleColor(color(rgba).colorWithAlphaComponent(0.3), forState: 1) // highlighted
}

func sui_button_create(_ title: UnsafePointer<CChar>?, _ action: SUICallback?, _ context: UnsafeMutableRawPointer?) -> SUIViewRef? {
    let button = ObjC.UIButton.buttonWithType(0) // custom
    button.setTitle(String(cString: title!), forState: 0)
    button.titleLabel().setFont(font(size: 17, weight: Int(SUIFontWeightRegular)))
    setButtonColor(button, 0x007AFFFF)
    attachAction(button, action, context, highlight: .none)
    return keep(LeafNode(view: button))
}

func sui_button_set_font(_ button: SUIViewRef?, _ size: Int, _ weight: Int) {
    node(button)?.view.titleLabel().setFont(font(size: size, weight: weight))
}

func sui_button_set_color(_ button: SUIViewRef?, _ rgba: UInt) {
    if let button = node(button) { setButtonColor(button.view, rgba) }
}

func sui_switch_create(_ on: Int, _ changed: SUIIndexCallback?, _ context: UnsafeMutableRawPointer?) -> SUIViewRef? {
    let control = ObjC.UISwitch.new()
    control.setOn(on != 0)
    let target = ObjC.SUIActionTarget.new()
    targets[address(target)] = TargetState(action: nil, changed: changed, context: context, highlight: .none)
    control.addTarget(target, action: ObjC.selector("changed:"), forControlEvents: valueChanged)
    control.setAssociated(target, for: actionTargetKey)
    return keep(LeafNode(view: control))
}

func sui_tappable_create(_ contentReference: SUIViewRef?, _ action: SUICallback?, _ context: UnsafeMutableRawPointer?) -> SUIViewRef? {
    guard let content = node(contentReference) else { return nil }
    let control = ObjC.UIControl.new()
    content.view.setUserInteractionEnabled(false)
    control.addSubview(content.view)
    attachAction(control, action, context, highlight: .dim)
    return keep(ContainerNode(view: control, content: content))
}

func sui_stack_create(_ axis: Int, _ spacing: Int, _ alignment: Int) -> SUIViewRef? {
    let stack = StackNode(view: ObjC.UIView.new(), vertical: axis == Int(SUIAxisVertical), spacing: Float(spacing),
                          alignment: alignment)
    let reference = keep(stack)
    passStacks[UInt(bitPattern: reference)] = stack
    return reference
}

func sui_stack_add(_ stack: SUIViewRef?, _ child: SUIViewRef?, _ stretchCrossAxis: Int) {
    guard let stack = passStacks[UInt(bitPattern: stack)], let child = node(child) else { return }
    stack.add(child, stretch: stretchCrossAxis != 0)
}

func sui_color_view_create(_ rgba: UInt) -> SUIViewRef? {
    let view = ObjC.UIView.new()
    view.setBackgroundColor(color(rgba))
    return keep(FlexibleNode(view: view))
}

func sui_spacer_create(_ minLength: Int) -> SUIViewRef? {
    keep(SpacerNode(view: ObjC.UIView.new(), minLength: Float(minLength)))
}

func sui_padding_create(_ child: SUIViewRef?, _ top: Int, _ leading: Int, _ bottom: Int, _ trailing: Int) -> SUIViewRef? {
    guard let content = node(child) else { return nil }
    let view = ObjC.UIView.new()
    view.addSubview(content.view)
    return keep(ContainerNode(view: view, content: content, top: Float(top), leading: Float(leading),
                              bottom: Float(bottom), trailing: Float(trailing)))
}

func sui_background_create(_ child: SUIViewRef?, _ rgba: UInt) -> SUIViewRef? {
    guard let content = node(child) else { return nil }
    let view = ObjC.UIView.new()
    view.setBackgroundColor(color(rgba))
    view.addSubview(content.view)
    return keep(ContainerNode(view: view, content: content))
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
    let list = ObjC.UIScrollView.new()
    list.setAlwaysBounceVertical(true)
    list.setBackgroundColor(ObjC.UIColor.whiteColor())
    list.setDelegate(scrollDelegate)
    let rows = StackNode(view: ObjC.UIView.new(), vertical: true, spacing: 0, alignment: Int(SUIAlignmentCenter))
    list.addSubview(rows.view)
    let node = ListNode(view: list, key: key, rows: rows)
    passLists.append(node)
    let reference = keep(node)
    passListNodes[UInt(bitPattern: reference)] = node
    return reference
}

func sui_list_add_row(_ listReference: SUIViewRef?, _ contentReference: SUIViewRef?, _ disclosure: Int,
                      _ action: SUICallback?, _ context: UnsafeMutableRawPointer?) {
    guard let list = passListNodes[UInt(bitPattern: listReference)], let content = node(contentReference) else { return }
    let row = ObjC.UIControl.new()
    row.setBackgroundColor(ObjC.UIColor.whiteColor())
    content.view.setUserInteractionEnabled(action == nil)
    row.addSubview(content.view)

    let chevron: ObjCValue? = disclosure != 0 ? makeChevron() : nil
    if let chevron { row.addSubview(chevron) }
    let separator = ObjC.UIView.new()
    separator.setBackgroundColor(color(separatorColor))
    row.addSubview(separator)

    if action != nil { attachAction(row, action, context, highlight: .gray) }
    list.rows.add(RowNode(view: row, content: content, chevron: chevron, separator: separator), stretch: true)
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
        item.setRightBarButtonItem(ObjC.UIBarButtonItem.alloc().initWithCustomView(trailing.view))
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
