import CSwiftUIBackend

/// A switch with a label, backed by a `UISwitch`. Laid out like SwiftUI's:
/// the label on the leading side, the switch on the trailing side, filling
/// the width it is offered.
public struct Toggle<Label: View>: View {
    let isOn: Binding<Bool>
    let label: Label

    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.isOn = isOn
        self.label = label()
    }

    public var body: Never { fatalError() }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let isOn = self.isOn
        let (changed, changedContext) = _IndexActionBox { value in
            isOn.wrappedValue = value != 0
        }.register(with: context.renderer)
        let control = sui_switch_create(isOn.wrappedValue ? 1 : 0, changed, changedContext)!

        var content: [_Node] = []
        label._render(into: &content, context: context)
        let labelNode = _Node.stacked(content, axis: .vertical)

        let row = sui_stack_create(SUIAxisHorizontal, 8, SUIAlignmentCenter)!
        sui_stack_add(row, labelNode.view, 0)
        sui_stack_add(row, sui_spacer_create(8), 0)
        sui_stack_add(row, control, 0)
        nodes.append(_Node(view: row, flexibleWidth: true))
    }
}

extension Toggle where Label == Text {
    public init(_ title: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(title) }
    }
}
