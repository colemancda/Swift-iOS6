import CSwiftUIBackend

// Text fields, sliders, steppers, progress views and alerts, on UIKit's
// UITextField, UISlider, UIStepper, UIProgressView, UIActivityIndicatorView
// and UIAlertView. Like Toggle, each control is set from its binding only when
// the bound value changes from what the last render showed.

/// A text field, like SwiftUI's: `TextField("Title", text: $title)`.
public struct TextField: View {
    let title: String
    let text: Binding<String>
    let onCommit: (() -> Void)?
    let secure: Bool

    public init(_ title: String, text: Binding<String>) {
        self.init(title, text: text, onCommit: nil, secure: false)
    }

    /// Calls `onCommit` when the user presses Return.
    public init(_ title: String, text: Binding<String>, onCommit: @escaping () -> Void) {
        self.init(title, text: text, onCommit: onCommit, secure: false)
    }

    init(_ title: String, text: Binding<String>, onCommit: (() -> Void)?, secure: Bool) {
        self.title = title
        self.text = text
        self.onCommit = onCommit
        self.secure = secure
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let text = self.text
        let submit = onCommit ?? context.onSubmit
        let field = sui_text_field_create(text.wrappedValue, placeholder: title, secure: secure,
                                          onChange: { text.wrappedValue = $0 }, onSubmit: submit)!
        nodes.append(_Node(view: field, flexibleWidth: true))
    }
}

/// A text field that hides what's typed.
public struct SecureField: View {
    let field: TextField

    public init(_ title: String, text: Binding<String>) {
        field = TextField(title, text: text, onCommit: nil, secure: true)
    }

    public init(_ title: String, text: Binding<String>, onCommit: @escaping () -> Void) {
        field = TextField(title, text: text, onCommit: onCommit, secure: true)
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        field._render(into: &nodes, context: context)
    }
}

extension View {
    /// Runs `action` when the user presses Return in a text field inside this view.
    public func onSubmit(_ action: @escaping () -> Void) -> some View {
        _EnvironmentModifier(content: self) { $0.onSubmit = action }
    }
}

/// A slider over a range, like SwiftUI's: `Slider(value: $volume, in: 0...10)`.
public struct Slider: View {
    let value: Binding<Double>
    let bounds: ClosedRange<Double>
    let step: Double?

    public init(value: Binding<Double>, in bounds: ClosedRange<Double> = 0...1) {
        self.value = value
        self.bounds = bounds
        self.step = nil
    }

    /// Values snap to multiples of `step` from the lower bound.
    public init(value: Binding<Double>, in bounds: ClosedRange<Double>, step: Double) {
        self.value = value
        self.bounds = bounds
        self.step = step
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let value = self.value, bounds = self.bounds, step = self.step
        let slider = sui_slider_create(value.wrappedValue, minimum: bounds.lowerBound, maximum: bounds.upperBound) { new in
            var snapped = new
            if let step, step > 0 {
                let steps = ((new - bounds.lowerBound) / step).rounded()
                snapped = min(bounds.upperBound, bounds.lowerBound + steps * step)
            }
            if snapped != value.wrappedValue { value.wrappedValue = snapped }
        }!
        nodes.append(_Node(view: slider, flexibleWidth: true))
    }
}

/// A label with − and + buttons, like SwiftUI's: `Stepper("Count: \(n)", value: $n, in: 0...10)`.
public struct Stepper<Label: View>: View {
    let value: Binding<Int>
    let bounds: ClosedRange<Int>
    let step: Int
    let label: Label

    public init(value: Binding<Int>, in bounds: ClosedRange<Int>, step: Int = 1, @ViewBuilder label: () -> Label) {
        self.value = value
        self.bounds = bounds
        self.step = step
        self.label = label()
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let value = self.value
        let stepper = sui_stepper_create(Double(value.wrappedValue), minimum: Double(bounds.lowerBound),
                                         maximum: Double(bounds.upperBound), step: Double(step)) { new in
            let rounded = Int(new.rounded())
            if rounded != value.wrappedValue { value.wrappedValue = rounded }
        }!

        // Laid out like Toggle: the label leading, the control trailing.
        var content: [_Node] = []
        label._render(into: &content, context: context)
        let labelNode = _Node.stacked(content, axis: .vertical)
        let row = sui_stack_create(Int(SUIAxisHorizontal), 8, Int(SUIAlignmentCenter))!
        sui_stack_add(row, labelNode.view, 0)
        sui_stack_add(row, sui_spacer_create(8), 0)
        sui_stack_add(row, stepper, 0)
        nodes.append(_Node(view: row, flexibleWidth: true))
    }
}

extension Stepper where Label == Text {
    public init(_ title: String, value: Binding<Int>, in bounds: ClosedRange<Int>, step: Int = 1) {
        self.init(value: value, in: bounds, step: step) { Text(title) }
    }
}

/// A progress bar, or a spinning indicator when there's no value.
public struct ProgressView: View {
    let fraction: Double?

    /// A spinning indicator.
    public init() {
        fraction = nil
    }

    public init(value: Double, total: Double = 1) {
        fraction = total > 0 ? min(1, max(0, value / total)) : 0
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let view = sui_progress_create(fraction)!
        nodes.append(_Node(view: view, flexibleWidth: fraction != nil))
    }
}

// MARK: - Alerts

/// An alert, like SwiftUI's `Alert`, shown with `.alert(isPresented:content:)`.
public struct Alert {
    let title: String
    let message: String?
    let buttons: [Button]

    public struct Button {
        let label: String
        let isCancel: Bool
        let action: (() -> Void)?

        public static func `default`(_ label: Text, action: (() -> Void)? = nil) -> Button {
            Button(label: label.content, isCancel: false, action: action)
        }

        /// UIAlertView has no destructive style; it's an ordinary button.
        public static func destructive(_ label: Text, action: (() -> Void)? = nil) -> Button {
            Button(label: label.content, isCancel: false, action: action)
        }

        public static func cancel(_ label: Text, action: (() -> Void)? = nil) -> Button {
            Button(label: label.content, isCancel: true, action: action)
        }

        public static func cancel(_ action: (() -> Void)? = nil) -> Button {
            Button(label: "Cancel", isCancel: true, action: action)
        }
    }

    /// An alert with one button (OK if none is given).
    public init(title: Text, message: Text? = nil, dismissButton: Button? = nil) {
        self.title = title.content
        self.message = message?.content
        buttons = [dismissButton ?? .default(Text("OK"))]
    }

    /// An alert with two buttons. A cancel button goes on the left, as on iOS 6.
    public init(title: Text, message: Text? = nil, primaryButton: Button, secondaryButton: Button) {
        self.title = title.content
        self.message = message?.content
        buttons = primaryButton.isCancel ? [primaryButton, secondaryButton] : [secondaryButton, primaryButton]
    }
}

extension View {
    /// Shows the alert while `isPresented` is true; tapping a button sets it
    /// back to false and runs the button's action.
    public func alert(isPresented: Binding<Bool>, content: @escaping () -> Alert) -> some View {
        _AlertModifier(content: self, isPresented: isPresented, alert: content)
    }
}

public struct _AlertModifier<Content: View>: View {
    let content: Content
    let isPresented: Binding<Bool>
    let alert: () -> Alert

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        content._render(into: &nodes, context: context)
        let key = context.renderer.makeKey(0x414c_4552_5400_0000)
        let isPresented = self.isPresented
        let presented = isPresented.wrappedValue
        let shown = presented ? alert() : nil
        var cancelIndex = -1
        var buttons: [(String, (() -> Void)?)] = []
        for (index, button) in (shown?.buttons ?? []).enumerated() {
            if button.isCancel { cancelIndex = index }
            buttons.append((button.label, button.action))
        }
        sui_alert_update(key, presented: presented, title: shown?.title ?? "", message: shown?.message,
                         buttons: buttons, cancelIndex: cancelIndex) {
            isPresented.wrappedValue = false
        }
    }
}
