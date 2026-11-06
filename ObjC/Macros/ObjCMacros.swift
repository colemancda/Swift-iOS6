// Macros for ObjCInterop, in the spirit of swift-java's @JavaClass,
// @JavaMethod and @JavaImplementation. Built as a compiler plugin library
// for the host (see ../Makefile) against the toolchain's own swift-syntax.
//
// - @ObjC("UILabel") on a struct: a typed wrapper around an Objective-C object.
// - @ObjCMethod on a function or initializer without a body: sends the message.
//   On a method with a body inside an @ObjCImplementation class: exports it.
// - @ObjCProperty on a var: getter and setter messages.
// - @ObjCImplementation("Name", superclass: "UIView") on a class: defines the
//   Objective-C class, whose methods run the class's @ObjCMethod methods.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct MacroError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Arguments and names

/// A string literal argument, by label ("" for the first unlabeled one).
func stringArgument(_ node: AttributeSyntax, _ label: String) -> String? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
    for argument in arguments where (argument.label?.text ?? "") == label {
        return argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
    }
    return nil
}

/// An array of string literals argument, by label.
func stringArrayArgument(_ node: AttributeSyntax, _ label: String) -> [String] {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return [] }
    for argument in arguments where argument.label?.text == label {
        guard let array = argument.expression.as(ArrayExprSyntax.self) else { return [] }
        return array.elements.compactMap { $0.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue }
    }
    return []
}

func boolArgument(_ node: AttributeSyntax, _ label: String) -> Bool {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return false }
    for argument in arguments where argument.label?.text == label {
        return argument.expression.as(BooleanLiteralExprSyntax.self)?.literal.tokenKind == .keyword(.true)
    }
    return false
}

func capitalized(_ name: String) -> String {
    guard let first = name.first else { return name }
    return first.uppercased() + name.dropFirst()
}

func hasAttribute(_ attributes: AttributeListSyntax, _ name: String) -> Bool {
    attributes.contains { element in
        element.as(AttributeSyntax.self)?.attributeName.trimmedDescription == name
    }
}

func attribute(_ attributes: AttributeListSyntax, _ name: String) -> AttributeSyntax? {
    for element in attributes {
        if let attribute = element.as(AttributeSyntax.self), attribute.attributeName.trimmedDescription == name {
            return attribute
        }
    }
    return nil
}

/// The selector for a method: its name, then for the first parameter its label
/// capitalized (nothing for `_`) and a colon, then "label:" for each other
/// parameter. `setTitle(_:forState:)` is `setTitle:forState:`, and
/// `scrollRect(toVisible:animated:)` is `scrollRectToVisible:animated:`.
func selector(name: String, parameters: FunctionParameterListSyntax) -> String {
    var selector = name
    for (index, parameter) in parameters.enumerated() {
        let label = parameter.firstName.text
        if index == 0 {
            selector += (label == "_" ? "" : capitalized(label)) + ":"
        } else {
            selector += (label == "_" ? "" : label) + ":"
        }
    }
    return selector
}

/// The selector for an initializer: `init()` is `init`, `init(frame:)` is
/// `initWithFrame:`, `init(title:style:)` is `initWithTitle:style:`.
func initSelector(parameters: FunctionParameterListSyntax) -> String {
    var selector = "init"
    for (index, parameter) in parameters.enumerated() {
        let label = parameter.firstName.text
        if index == 0 {
            selector += (label == "_" ? "" : "With" + capitalized(label)) + ":"
        } else {
            selector += (label == "_" ? "" : label) + ":"
        }
    }
    return selector
}

/// The names the body refers to each parameter by.
func argumentNames(_ parameters: FunctionParameterListSyntax) -> [String] {
    parameters.map { ($0.secondName ?? $0.firstName).text }
}

func isVoid(_ type: TypeSyntax?) -> Bool {
    guard let type else { return true }
    let text = type.trimmedDescription
    return text == "Void" || text == "()"
}

/// The Objective-C type encoding of a Swift type, for methods defined from
/// Swift. Objects (wrappers, strings, ObjCValue, optionals) are '@'.
func encoding(_ type: TypeSyntax?) -> String {
    guard let type else { return "v" }
    switch type.trimmedDescription {
    case "Void", "()": return "v"
    case "Int", "Int32": return "i"
    case "UInt", "UInt32": return "I"
    case "Int64": return "q"
    case "UInt64": return "Q"
    case "Bool": return "c"
    case "Double": return "d"
    case "Float": return "f"
    case "CGPoint": return "{CGPoint=ff}"
    case "CGSize": return "{CGSize=ff}"
    case "CGRect": return "{CGRect={CGPoint=ff}{CGSize=ff}}"
    case "NSRange": return "{_NSRange=II}"
    default: return "@"
    }
}

func accessModifier(_ modifiers: DeclModifierListSyntax) -> String {
    for modifier in modifiers {
        switch modifier.name.tokenKind {
        case .keyword(.public): return "public "
        case .keyword(.open): return "public "
        case .keyword(.package): return "package "
        default: continue
        }
    }
    return ""
}

func isStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }
}

// MARK: - @ObjC

/// `@ObjC("UILabel") struct UILabel { … }`: the wrapped object, an
/// initializer from it, the class, and ObjCWrapper conformance (so the type
/// is a message argument and result).
public struct ObjCClassMacro: MemberMacro, ExtensionMacro {
    public static func expansion(of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax,
                                 conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        guard let type = declaration.as(StructDeclSyntax.self) else {
            throw MacroError("@ObjC applies to a struct that wraps an Objective-C object")
        }
        let className = stringArgument(node, "") ?? type.name.text
        let access = accessModifier(type.modifiers)
        return [
            "/// The Objective-C object.\n\(raw: access)let object: ObjCValue",
            "\(raw: access)init(_ object: ObjCValue) { self.object = object }",
            "/// The Objective-C class, \(raw: className).\n\(raw: access)static var objcClass: ObjCValue { ObjC.classNamed(\(literal: className)) }",
        ]
    }

    public static func expansion(of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax,
                                 providingExtensionsOf type: some TypeSyntaxProtocol, conformingTo protocols: [TypeSyntax],
                                 in context: some MacroExpansionContext) throws -> [ExtensionDeclSyntax] {
        [try ExtensionDeclSyntax("extension \(type.trimmed): ObjCWrapper {}")]
    }
}

// MARK: - @ObjCMethod

/// On a function or initializer without a body: a body that sends the
/// message and converts the result. With a body (in an @ObjCImplementation
/// class), the body is kept, and the class exports the method.
public struct ObjCMethodMacro: BodyMacro {
    public static func expansion(of node: AttributeSyntax, providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
                                 in context: some MacroExpansionContext) throws -> [CodeBlockItemSyntax] {
        if let body = declaration.body {
            return Array(body.statements)
        }
        let explicit = stringArgument(node, "")

        if let initializer = declaration.as(InitializerDeclSyntax.self) {
            let parameters = initializer.signature.parameterClause.parameters
            let selector = explicit ?? initSelector(parameters: parameters)
            let arguments = argumentNames(parameters).map { ", \($0)" }.joined()
            return ["self.init(Self.objcClass.alloc().send(\(literal: selector)\(raw: arguments)))"]
        }

        guard let function = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroError("@ObjCMethod applies to functions and initializers")
        }
        let parameters = function.signature.parameterClause.parameters
        let selector = explicit ?? selector(name: function.name.text, parameters: parameters)
        // self.object: a parameter may be named `object` too.
        let receiver = isStatic(function.modifiers) ? "Self.objcClass" : "self.object"
        let arguments = argumentNames(parameters).map { ", \($0)" }.joined()
        let send = "\(receiver).send(\"\(selector)\"\(arguments))"
        if isVoid(function.signature.returnClause?.type) {
            return ["_ = \(raw: send)"]
        }
        return ["return objcResult(\(raw: send))"]
    }
}

// MARK: - @ObjCProperty

/// `@ObjCProperty var text: String?`: sends `text` and `setText:`. Options:
/// `getter:` and `setter:` selectors, and `readonly: true`.
public struct ObjCPropertyMacro: AccessorMacro {
    public static func expansion(of node: AttributeSyntax, providingAccessorsOf declaration: some DeclSyntaxProtocol,
                                 in context: some MacroExpansionContext) throws -> [AccessorDeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              let binding = variable.bindings.first,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
            throw MacroError("@ObjCProperty applies to a var")
        }
        let receiver = isStatic(variable.modifiers) ? "Self.objcClass" : "self.object"
        let getter = stringArgument(node, "getter") ?? name
        let setter = stringArgument(node, "setter") ?? "set\(capitalized(name)):"
        var accessors: [AccessorDeclSyntax] = [
            "get { objcResult(\(raw: receiver).send(\(literal: getter))) }",
        ]
        if !boolArgument(node, "readonly") {
            accessors.append("nonmutating set { _ = \(raw: receiver).send(\(literal: setter), newValue) }")
        }
        return accessors
    }
}

// MARK: - Exported methods

/// The `cls.method`/`cls.function` registrations of the @ObjCMethod methods
/// with bodies among `members`, and whether one is dealloc (and an override).
func methodRegistrations(_ members: MemberBlockItemListSyntax, typeName: String)
    -> (methods: [String], dealloc: Bool, deallocOverrides: Bool) {
    var methods: [String] = []
    var dealloc = false
    var deallocOverrides = false
    for member in members {
        guard let function = member.decl.as(FunctionDeclSyntax.self),
              let marker = attribute(function.attributes, "ObjCMethod") else { continue }
        let parameters = function.signature.parameterClause.parameters
        let selector = stringArgument(marker, "") ?? selector(name: function.name.text, parameters: parameters)
        if selector == "dealloc" {
            dealloc = true
            deallocOverrides = function.modifiers.contains { $0.name.tokenKind == .keyword(.override) }
            continue
        }
        let returnType = function.signature.returnClause?.type
        var types = encoding(returnType) + "@:"
        for parameter in parameters { types += encoding(parameter.type) }

        var call = "instance.\(function.name.text)("
        for (index, parameter) in parameters.enumerated() {
            let label = parameter.firstName.text
            call += (index > 0 ? ", " : "") + (label == "_" ? "" : label + ": ") + "objcResult(call[\(index)])"
        }
        call += ")"
        let lookup = "ObjCImplementations.instance(\(typeName).self, for: call.this)"
        if isVoid(returnType) {
            methods.append("""
                cls.method(\"\(selector)\", fallbackTypes: \"\(types)\") { call in
                    guard let instance = \(lookup) else { return }
                    \(call)
                }
            """)
        } else {
            methods.append("""
                cls.function(\"\(selector)\", fallbackTypes: \"\(types)\") { call in
                    guard let instance = \(lookup) else { return nil }
                    return \(call).objcValue
                }
            """)
        }
    }
    return (methods, dealloc, deallocOverrides)
}

// MARK: - @ObjCExtension

/// `@ObjCExtension("DataSource") extension X: … { @ObjCMethod func … }`:
/// exports the extension's @ObjCMethod methods too, through
/// `objcMethodsDataSource(_:)`, which X's class definition calls when X's
/// @ObjCImplementation lists the tag: `extensions: ["DataSource"]`.
public struct ObjCExtensionMacro: MemberMacro {
    public static func expansion(of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax,
                                 conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        guard let type = declaration.as(ExtensionDeclSyntax.self) else {
            throw MacroError("@ObjCExtension applies to an extension of an @ObjCImplementation class")
        }
        guard let tag = stringArgument(node, "") else {
            throw MacroError("@ObjCExtension needs a tag: @ObjCExtension(\"DataSource\")")
        }
        let typeName = type.extendedType.trimmedDescription
        let registered = methodRegistrations(type.memberBlock.members, typeName: typeName)
        if registered.dealloc {
            throw MacroError("dealloc goes in the class, not an extension")
        }
        return ["""
            /// Adds this extension's @ObjCMethod methods to the Objective-C class.
            static func objcMethods\(raw: tag)(_ cls: ObjCClassBuilder) {
            \(raw: registered.methods.joined(separator: "\n"))
            }
            """]
    }
}

// MARK: - @ObjCImplementation

/// `@ObjCImplementation("Name", superclass: "UIView") class X { … }`:
/// defines the Objective-C class (`objcClass`), with a method for each
/// @ObjCMethod method of X. Each Objective-C instance is tied to a Swift
/// instance: create one with `X(…)` then `attach(to:)` an object of
/// `objcClass`, or, if X has an `init()`, Objective-C can create it
/// (alloc/init from UIKit). The tie ends when the object is deallocated.
///
/// `@ObjCImplementation class Y: X { … }` (no `superclass:`) on a Swift
/// subclass of such a class defines a subclass of X's Objective-C class.
/// Swift's own dispatch runs overrides, so Y only adds its new methods, and
/// an object of Y's class gets a Y. `callSuper` from any class of the
/// hierarchy reaches the Objective-C superclass of the root's class.
public struct ObjCImplementationMacro: MemberMacro, ExtensionMacro {
    public static func expansion(of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax,
                                 conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        guard let type = declaration.as(ClassDeclSyntax.self) else {
            throw MacroError("@ObjCImplementation applies to a class")
        }
        let typeName = type.name.text
        let className = stringArgument(node, "") ?? typeName
        var explicitSuperclass = stringArgument(node, "superclass")
        // The first inherited type is a Swift superclass, unless `superclass:`
        // names the Objective-C one, or it's a wrapper's protocol (UIViewMethods):
        // then the class gets the wrapper's instance members, and its
        // Objective-C class is a subclass of the wrapped class (UIView).
        var swiftSuperclass = explicitSuperclass == nil
            ? type.inheritanceClause?.inheritedTypes.first?.type.trimmedDescription : nil
        if let inherited = swiftSuperclass, inherited.hasSuffix("Methods"), inherited != "Methods" {
            explicitSuperclass = String(inherited.dropLast("Methods".count))
            swiftSuperclass = nil
        }
        let access = accessModifier(type.modifiers)
        let isOpen = type.modifiers.contains { $0.name.tokenKind == .keyword(.open) }
        let overridable = isOpen ? "open " : access
        let storage = "_objcClass\(typeName)"

        var hasDefaultInit = false
        var hasInitializers = false
        // Adopted first, so methods take their types from the protocols.
        var methods: [String] = stringArrayArgument(node, "protocols").map { "    cls.conform(to: \"\($0)\")" }
        for member in type.memberBlock.members {
            if let initializer = member.decl.as(InitializerDeclSyntax.self) {
                hasInitializers = true
                if initializer.signature.parameterClause.parameters.isEmpty { hasDefaultInit = true }
            }
        }
        let registered = methodRegistrations(type.memberBlock.members, typeName: typeName)
        methods += registered.methods
        let userDealloc = registered.dealloc
        let deallocOverrides = registered.deallocOverrides
        // Methods in extensions marked @ObjCExtension("Tag")
        for tag in stringArrayArgument(node, "extensions") {
            methods.append("    \(typeName).objcMethods\(tag)(cls)")
        }

        // A class with no initializers has the implicit init(), or inherits
        // its superclass's.
        if hasDefaultInit || !hasInitializers {
            methods.append("""
                ObjCImplementations.setFactory({ object in
                    ObjCImplementations.pendingObject = object
                    let instance = \(typeName)()
                    ObjCImplementations.pendingObject = nil
                    if instance.objcPointer == nil { instance.attach(to: object) }
                    return instance
                }, for: cls)
            """)
        }

        let existing = "ObjCImplementations.instance(\(typeName).self, for: call.this, create: false)"
        if swiftSuperclass == nil {
            methods.append("""
                cls.method("dealloc") { call in
                    \(userDealloc ? "\(existing)?.dealloc()" : "")
                    ObjCImplementations.detach(call.this)
                    call.callSuper()
                }
            """)
        } else if userDealloc && !deallocOverrides {
            // An override runs from the superclass's dealloc, through Swift.
            methods.append("""
                cls.method("dealloc") { call in
                    \(existing)?.dealloc()
                    call.callSuper()
                }
            """)
        }

        let superclassArgument = swiftSuperclass.map { "\($0).objcClass" }
            ?? "\"\(explicitSuperclass ?? "NSObject")\""
        var members: [DeclSyntax] = [
            """
            /// The Objective-C class \(raw: className), defined on first use.
            static let \(raw: storage): ObjCValue = ObjC.defineClass(\(literal: className), superclass: \(raw: superclassArgument)) { cls in
            \(raw: methods.joined(separator: "\n"))
            }
            """,
        ]
        // Embedded Swift can't cast to a dynamic Self: each class looks up its own type.
        let lookup = """
            /// The Swift instance for an object of `objcClass` (or of a subclass's).
            \(overridable)\(swiftSuperclass == nil ? "" : "override ")class func objcInstance(for object: ObjCValue) -> \(typeName)? {
                ObjCImplementations.instance(\(typeName).self, for: object)
            }
            """
        if let swiftSuperclass {
            members.append("""
                /// The Objective-C class \(raw: className), a subclass of \(raw: swiftSuperclass)'s.
                \(raw: overridable)override class var objcClass: ObjCValue { \(raw: storage) }
                """)
            members.append("\(raw: lookup)")
            return members
        }
        members += [
            """
            /// The Objective-C class \(raw: className).
            \(raw: overridable)class var objcClass: ObjCValue { \(raw: storage) }
            """,
            "/// The Objective-C object this instance implements (not retained: the object owns this instance).\n\(raw: access)var objcPointer: UnsafeMutableRawPointer? = nil",
            "/// The Objective-C object this instance implements.\n\(raw: access)var object: ObjCValue { ObjCValue(object: objcPointer) }",
            "/// The object of an instance Swift created (objcInit), which the instance keeps.\n\(raw: access)var objcOwnedObject: ObjCValue? = nil",
            """
            /// Creates the Objective-C object for an instance Swift created, with
            /// an init… message (`objcInit("initWithFrame:", frame)`) to a new
            /// object of the instance's class, in place of `super.init(…)`. The
            /// object is tied first, so methods init… sends reach this instance.
            /// The instance keeps the object, and the object the instance.
            @discardableResult
            \(raw: access)func objcInit(_ selector: String = "init", _ arguments: any ObjCConvertible...) -> ObjCValue {
                if let pending = ObjCImplementations.pendingObject {
                    // Objective-C is creating this instance for its object.
                    ObjCImplementations.pendingObject = nil
                    attach(to: pending)
                    return pending
                }
                let allocated = type(of: self).objcClass.alloc()
                attach(to: allocated)
                let initialized = allocated.send(selector, arguments: arguments)
                if initialized.asObject?.pointer != objcPointer {
                    ObjCImplementations.detach(allocated)
                    attach(to: initialized)
                }
                objcOwnedObject = initialized
                return initialized
            }
            """,
            """
            /// Ties this instance to `object`, an instance of `objcClass`, which keeps it alive.
            \(raw: access)func attach(to object: ObjCValue) {
                objcPointer = object.asObject?.pointer
                ObjCImplementations.attach(self, to: object)
            }
            """,
            "\(raw: lookup)",
            """
            /// Sends `selector` to the Objective-C superclass's implementation, from a method of this class or a subclass.
            @discardableResult
            \(raw: access)func callSuper(_ selector: String, _ arguments: any ObjCConvertible...) -> ObjCValue {
                self.object.sendSuper(selector, from: \(raw: typeName).\(raw: storage), arguments)
            }
            """,
            """
            /// callSuper, with the result as a Swift type: `callSuper("sizeThatFits:", size) as CGSize`.
            @discardableResult
            \(raw: access)func callSuper<Result: ObjCResult>(_ selector: String, _ arguments: any ObjCConvertible...) -> Result {
                objcResult(self.object.sendSuper(selector, from: \(raw: typeName).\(raw: storage), arguments))
            }
            """,
        ]
        return members
    }

    public static func expansion(of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax,
                                 providingExtensionsOf type: some TypeSyntaxProtocol, conformingTo protocols: [TypeSyntax],
                                 in context: some MacroExpansionContext) throws -> [ExtensionDeclSyntax] {
        // A subclass already conforms, through its superclass, and so does a
        // class with a wrapper's protocol, to ObjCConvertible.
        let names = Set(protocols.map { $0.trimmedDescription.split(separator: ".").last.map(String.init) ?? "" })
        var extensions: [ExtensionDeclSyntax] = []
        if names.contains("ObjCConvertible") {
            extensions.append(try ExtensionDeclSyntax("extension \(type.trimmed): ObjCConvertible { public var objcValue: ObjCValue { object } }"))
        }
        if names.contains("ObjCImplementationResult") {
            extensions.append(try ExtensionDeclSyntax("""
                extension \(type.trimmed): ObjCImplementationResult {
                    /// The Swift instance of an object of this class (or a subclass's: that subclass's instance).
                    public static func objcImplementation(for value: ObjCValue) -> Self? {
                        guard let instance = ObjCImplementations.instance(\(type.trimmed).self, for: value) else { return nil }
                        return unsafeBitCast(instance, to: Self.self)
                    }
                }
                """))
        }
        return extensions
    }
}
