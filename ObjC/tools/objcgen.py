#!/usr/bin/env python3
"""Generates typed Swift wrappers for Objective-C frameworks from the SDK's headers.

    objcgen.py --framework Foundation --framework UIKit --out ../Frameworks

writes ../Frameworks/Foundation/Sources/Foundation.swift and
../Frameworks/UIKit/Sources/UIKit.swift: one @ObjC struct per class, with its
methods and properties as @ObjCMethod and @ObjCProperty declarations (see
../README.md). Each class also gets a protocol, `<Class>Methods`, which
refines its superclass's and holds the members in an extension, so a UILabel
has UIView's and NSObject's members too.

How it works:

1. clang parses the umbrella headers (-ast-dump=json) with the iOS SDK.
2. Classes, categories, methods and properties declared in each framework's
   headers are collected. C types map to Swift ones; methods that take blocks,
   C arrays or variable arguments are left out.
3. Every member is checked against the minimum iOS version by compiling a probe
   file that uses each of them with -Werror=unguarded-availability; whatever
   clang rejects (newer API, or unavailable) is left out.
"""

import argparse
import collections
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

SWIFT_KEYWORDS = {
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
    "inout", "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public",
    "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue",
    "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw",
    "switch", "where", "while", "Any", "as", "await", "false", "is", "nil", "self", "Self", "super", "throws",
    "true", "try",
}
# Members that @ObjC and ObjCWrapper already declare, and names Swift won't take as members.
RESERVED_MEMBERS = {"object", "objcClass", "objcValue", "isNil", "as", "Type", "Protocol", "init", "self", "Self"}
# Labels Swift doesn't accept even in backticks.
BAD_LABELS = {"inout", "var", "let"}
# Classes that aren't wrapped: Protocol clashes with Swift's own meaning.
SKIPPED_CLASSES = {"Protocol"}

KNOWN_STRUCTS = {
    "CGPoint": "CGPoint", "struct CGPoint": "CGPoint",
    "CGSize": "CGSize", "struct CGSize": "CGSize",
    "CGRect": "CGRect", "struct CGRect": "CGRect",
    "NSRange": "NSRange", "struct _NSRange": "NSRange",
}
INTEGERS = {
    "char", "signed char", "unsigned char", "short", "unsigned short", "int", "unsigned int", "long",
    "unsigned long", "NSInteger", "NSUInteger",
}
LONG_LONGS = {"long long", "unsigned long long"}


def ident(name):
    """A Swift identifier, in backticks if it's a keyword."""
    return f"`{name}`" if name in SWIFT_KEYWORDS else name


# MARK: - Reading the AST


class Location:
    """clang's JSON locations only name the file when it changes, so the
    current file is tracked through the dump in order."""

    def __init__(self):
        self.file = None

    def visit(self, loc):
        if not isinstance(loc, dict):
            return
        for key in ("spellingLoc", "expansionLoc"):
            if key in loc:
                self.visit(loc[key])
        if "file" in loc:
            self.file = loc["file"]


def walk_locations(node, tracker, on_decl, depth=0):
    tracker.visit(node.get("loc"))
    file_at_decl = tracker.file
    rng = node.get("range")
    if isinstance(rng, dict):
        tracker.visit(rng.get("begin"))
        tracker.visit(rng.get("end"))
    if depth == 0:
        on_decl(node, file_at_decl)
    if depth == 0 or node.get("kind") in ("ObjCInterfaceDecl", "ObjCCategoryDecl", "ObjCProtocolDecl"):
        for child in node.get("inner", []):
            walk_locations(child, tracker, on_decl, depth + 1)
    else:
        for child in node.get("inner", []):
            walk_locations(child, tracker, lambda *_: None, depth + 1)


def framework_of(path):
    match = re.search(r"/([A-Za-z0-9_]+)\.framework/Headers/", path or "")
    return match.group(1) if match else None


class HeaderIndex:
    """Which framework declares each class and category, from the headers'
    @interface lines. (clang's JSON names a location's file only when it
    changes, which is too fragile to follow through macros.)"""

    def __init__(self, sdk, frameworks):
        self.frameworks = frameworks
        self.classes = {}
        self.categories = {}
        pattern = re.compile(r"@interface\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>]*>\s*)?(\(\s*([A-Za-z0-9_]*)\s*\)|:|$|\{)", re.M)
        # NSObject is declared by the Objective-C runtime's headers; it's wrapped with Foundation.
        directories = [("Foundation", os.path.join(sdk, "usr/include/objc"))] if "Foundation" in frameworks else []
        directories += [(f, os.path.join(sdk, "System/Library/Frameworks", f"{f}.framework", "Headers")) for f in frameworks]
        for framework, headers in directories:
            for name in sorted(os.listdir(headers)):
                if not name.endswith(".h"):
                    continue
                with open(os.path.join(headers, name), errors="replace") as handle:
                    text = handle.read()
                for match in pattern.finditer(text):
                    cls, category = match.group(1), match.group(3)
                    if match.group(2).startswith("("):
                        self.categories.setdefault((cls, category or ""), framework)
                    else:
                        self.classes.setdefault(cls, framework)


class Member:
    def __init__(self, kind, cls, selector, static, framework, node):
        self.kind = kind  # "method" or "property"
        self.cls = cls
        self.selector = selector
        self.static = static
        self.framework = framework
        self.node = node
        self.swift = None  # the declaration, once mapped
        self.probe = None  # an Objective-C statement that uses it


class Model:
    def __init__(self, index):
        self.index = index
        self.classes = {}  # name -> {"super", "framework", "members": [Member]}
        self.all_classes = set()

    def add_interface(self, node, file):
        name = node["name"]
        self.all_classes.add(name)
        framework = self.index.classes.get(name)
        entry = self.classes.setdefault(name, {"super": None, "framework": framework, "members": []})
        # A forward @class has no superclass or members (but may have attributes).
        defining = node.get("super", {}).get("name") or any(
            child.get("kind") in ("ObjCMethodDecl", "ObjCPropertyDecl", "ObjCIvarDecl") for child in node.get("inner", []))
        if defining:
            entry["super"] = node.get("super", {}).get("name")
            entry["framework"] = framework
            self.add_members(name, node, framework)

    def add_category(self, node, file):
        cls = node.get("interface", {}).get("name")
        if not cls:
            return
        self.classes.setdefault(cls, {"super": None, "framework": None, "members": []})
        framework = self.index.categories.get((cls, node.get("name", "")))
        if framework is None and node.get("name", "") == "":
            framework = self.index.classes.get(cls)  # a class extension
        self.add_members(cls, node, framework)

    def add_root_protocol(self, node):
        """The NSObject protocol's methods (isKindOfClass:, respondsToSelector:,
        description…), which every class has, as NSObject's."""
        if node.get("name") != "NSObject" or not node.get("inner") or "Foundation" not in self.index.frameworks:
            return
        if any(m.framework == "Foundation" and m.node is node.get("inner")[0] for m in self.classes.get("NSObject", {}).get("members", [])):
            return
        self.classes.setdefault("NSObject", {"super": None, "framework": "Foundation", "members": []})
        self.add_members("NSObject", node, "Foundation")

    def add_members(self, cls, node, framework):
        members = self.classes[cls]["members"]
        for child in node.get("inner", []):
            if child.get("isImplicit"):
                continue
            if any(attr.get("kind") == "UnavailableAttr" for attr in child.get("inner", [])):
                continue
            if child["kind"] == "ObjCMethodDecl":
                members.append(Member("method", cls, child["name"], not child.get("instance", True), framework, child))
            elif child["kind"] == "ObjCPropertyDecl" and not child.get("class"):
                members.append(Member("property", cls, child["name"], False, framework, child))


def parse_headers(frameworks, sdk, min_ios):
    source = "".join(f"#import <{name}/{name}.h>\n" for name in frameworks)
    with tempfile.NamedTemporaryFile("w", suffix=".m", delete=False) as handle:
        handle.write(source)
        path = handle.name
    try:
        result = subprocess.run(
            ["xcrun", "clang", "-x", "objective-c", "-arch", "armv7", "-isysroot", sdk,
             f"-miphoneos-version-min={min_ios}", "-fsyntax-only", "-Xclang", "-ast-dump=json", path],
            capture_output=True, check=True)
    finally:
        os.unlink(path)
    root = json.loads(result.stdout)
    model = Model(HeaderIndex(sdk, frameworks))
    tracker = Location()

    def on_decl(node, file):
        kind = node.get("kind")
        if kind == "ObjCInterfaceDecl":
            model.add_interface(node, file)
        elif kind == "ObjCCategoryDecl":
            model.add_category(node, file)
        elif kind == "ObjCProtocolDecl":
            model.add_root_protocol(node)

    for node in root.get("inner", []):
        walk_locations(node, tracker, on_decl)
    return model


# MARK: - Types


class Types:
    def __init__(self, model, wrapped):
        self.model = model
        self.wrapped = wrapped  # class name -> framework, for the classes being generated

    def swift(self, type_node, position, owner):
        """The Swift type for a C type, or None if it can't be passed.
        position is "param" or "return"."""
        qual = type_node.get("qualType", "")
        sugar = type_node.get("desugaredQualType", qual)
        nullable = "_Nullable" in qual or "_Null_unspecified" in qual or (
            "_Nonnull" not in qual and "*" in sugar)
        text = clean(qual)
        plain = clean(sugar)
        if "(^" in plain or "(*" in plain or "[" in plain or "..." in plain:
            return None
        if text == "instancetype" or plain == "instancetype":
            return "Self?" if "_Nullable" in qual else "Self"
        if text == "void" or plain == "void":
            return "Void" if position == "return" else None
        if text == "BOOL" or plain in ("_Bool", "bool"):
            return "Bool"
        if text in KNOWN_STRUCTS:
            return KNOWN_STRUCTS[text]
        if plain in KNOWN_STRUCTS:
            return KNOWN_STRUCTS[plain]
        if text in ("CGFloat", "float") or plain == "float":
            return "Float"
        if plain == "double":
            return "Double"
        if plain in LONG_LONGS:
            return "Int64"
        if plain in INTEGERS or plain.startswith("enum "):
            return "Int"
        if plain.startswith("struct ") and not plain.endswith("*"):
            return "ObjCValue"
        if plain in ("id", "SEL", "Class") or plain.startswith("id<"):
            return "ObjCValue"
        if plain.endswith("*"):
            pointee = plain[:-1].strip()
            if pointee in ("char", "const char"):
                return "String?" if position == "param" else "ObjCValue"
            name = re.match(r"[A-Za-z_][A-Za-z0-9_]*", pointee)
            if name and pointee.count("*") == 0 and name.group(0) in self.model.all_classes:
                cls = name.group(0)
                if cls == "NSString":
                    swift = "String"
                elif cls in self.wrapped:
                    swift = cls
                else:
                    return "ObjCValue"
                return swift + "?" if nullable else swift
            return "ObjCValue"
        return None


def clean(text):
    """A C type without nullability, ownership, __kindof, generics and availability macros."""
    text = re.sub(r"\b(_Nullable|_Nonnull|_Null_unspecified|__strong|__weak|__unsafe_unretained|"
                  r"__autoreleasing|__kindof|NS_AVAILABLE_IOS|NS_DEPRECATED_IOS|__nullable|__nonnull)\b", "", text)
    text = re.sub(r"\bconst\s+(?=[A-Za-z_]+\s*\*)", "const ", text)
    # Lightweight generics: NSArray<UIView *> * is an NSArray *.
    while True:
        stripped = re.sub(r"(\b[A-Z][A-Za-z0-9_]*)<[^<>]*>", r"\1", text)
        if stripped == text:
            break
        text = stripped
    text = re.sub(TYPE_PARAMETERS, "id", text)
    text = re.sub(r"\s*\*", " *", text)
    return re.sub(r"\s+", " ", text).strip()


# MARK: - Declarations


def lower_first(name):
    """frame for Frame, url for URL, urlString for URLString."""
    match = re.match(r"[A-Z]+", name)
    if not match:
        return name
    upper = match.group(0)
    if len(upper) > 1 and len(upper) < len(name):
        upper = upper[:-1]  # the last capital starts the next word
    return upper.lower() + name[len(upper):]


def param_type_text(param):
    t = param.get("type", {})
    return t.get("desugaredQualType", t.get("qualType", "id"))


# Lightweight generics' type parameters, which are objects (id).
TYPE_PARAMETERS = r"\b(ObjectType|KeyType|ValueType|ElementType|ContentType|SectionIdentifierType|ItemIdentifierType)\b"


def c_cast(type_text):
    """An expression of a C type, for the probe: *(T *)0."""
    return f"*({re.sub(TYPE_PARAMETERS, 'id', type_text)} *)0"


def declare_method(member, types):
    node = member.node
    if node.get("variadic"):
        return None
    selector = member.selector
    params = [c for c in node.get("inner", []) if c.get("kind") == "ParmVarDecl"]
    parts = selector.split(":")[:-1] if ":" in selector else [selector]
    if ":" in selector and len(parts) != len(params):
        return None
    returns = types.swift(node.get("returnType", {}), "return", member.cls)
    if returns is None:
        return None
    swift_params = []
    for param in params:
        swift = types.swift(param.get("type", {}), "param", member.cls)
        if swift is None or swift.startswith("Self"):
            return None
        # A wrapper parameter takes any subclass's wrapper: some NSArrayMethods.
        base = swift.rstrip("?")
        if base in types.wrapped:
            swift = f"(some {base}Methods)?" if swift.endswith("?") else f"some {base}Methods"
        swift_params.append(swift)

    receiver = member.cls if member.static else f"(({member.cls} *)0)"
    if ":" in selector:
        call = " ".join(f"{part}:{c_cast(param_type_text(param))}" for part, param in zip(parts, params))
    else:
        call = selector
    member.probe = f"(void)[{receiver} {call}];"

    is_init = (not member.static and selector.startswith("init") and
               (selector == "init" or selector[4:5].isupper()) and returns in ("Self", "Self?", "ObjCValue"))
    if is_init:
        if selector == "init":
            return "@ObjCMethod public init()"
        if not params:
            return None
        first = parts[0][4:]
        if first.startswith("With"):
            first = first[4:]
        label = lower_first(first)
        labels = [label] + parts[1:]
        if any(not l or l in BAD_LABELS for l in labels):
            return None
        args = ", ".join(f"{ident(l) if l in SWIFT_KEYWORDS else l} a{i}: {t}"
                         for i, (l, t) in enumerate(zip(labels, swift_params)))
        return f'@ObjCMethod("{selector}") public init({args})'

    name = parts[0]
    if name in RESERVED_MEMBERS or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
        return None
    if not member.static and (selector == "init" or (selector.startswith("init") and selector[4:5].isupper())):
        return None  # an init-family method that doesn't return this class
    args = []
    for i, swift in enumerate(swift_params):
        label = "_" if i == 0 else parts[i]
        if label in BAD_LABELS or (i > 0 and not label):
            return None
        args.append(f"{label} a{i}: {swift}")
    static = "static " if member.static else ""
    result = "" if returns == "Void" else f" -> {returns}"
    return f'@ObjCMethod("{selector}") public {static}func {ident(name)}({", ".join(args)}){result}'


def declare_property(member, types):
    node = member.node
    name = member.selector
    if name in RESERVED_MEMBERS:
        return None
    swift = types.swift(node.get("type", {}), "return", member.cls)
    if swift in (None, "Void", "Self", "Self?"):
        return None
    readonly = node.get("readonly") or not node.get("readwrite")
    getter = node.get("getter", {}).get("name", name)
    setter = node.get("setter", {}).get("name", f"set{name[:1].upper()}{name[1:]}:")
    options = []
    if getter != name:
        options.append(f'getter: "{getter}"')
    if not readonly and setter != f"set{name[:1].upper()}{name[1:]}:":
        options.append(f'setter: "{setter}"')
    if readonly:
        options.append("readonly: true")
    member.probe = f"(void)(({member.cls} *)0).{name};"
    attribute = "@ObjCProperty" + (f"({', '.join(options)})" if options else "")
    return f"{attribute} public var {ident(name)}: {swift}"


# MARK: - Availability


def check_availability(members, classes, sdk, frameworks, min_ios):
    """Compiles a probe that uses every member and class; returns the
    selectors (by member id) and classes clang rejects."""
    lines = [f"#import <{name}/{name}.h>" for name in frameworks] + ["void probe(void) {"]
    where = {}

    def add(statement, key):
        lines.append(statement)
        where[len(lines)] = key  # line numbers count from 1

    for cls in classes:
        add(f"(void)[{cls} class];", ("class", cls))
    for member in members:
        if member.probe:
            add(member.probe, ("member", id(member)))
    lines.append("}")
    with tempfile.NamedTemporaryFile("w", suffix=".m", delete=False) as handle:
        handle.write("\n".join(lines) + "\n")
        path = handle.name
    try:
        result = subprocess.run(
            ["xcrun", "clang", "-x", "objective-c", "-arch", "armv7", "-isysroot", sdk,
             f"-miphoneos-version-min={min_ios}", "-fsyntax-only", "-ferror-limit=0", "-Wno-null-dereference",
             "-Wno-deprecated-declarations", "-Wno-objc-method-access", "-Wno-unused-value",
             "-Werror=unguarded-availability", "-Werror=unguarded-availability-new", path],
            capture_output=True, text=True)
    finally:
        os.unlink(path)
    rejected_classes, rejected_members = set(), set()
    reasons = collections.Counter()
    for line in result.stderr.splitlines():
        match = re.match(r".*?\.m:(\d+):\d+: error: (.*)", line)
        if not match:
            continue
        kind, key = where.get(int(match.group(1)), (None, None))
        if kind == "class":
            rejected_classes.add(key)
        elif kind == "member":
            rejected_members.add(key)
        reasons["newer than iOS " + min_ios if "only available" in match.group(2) else "other"] += 1
        if "only available" not in match.group(2) and os.environ.get("OBJCGEN_DEBUG"):
            print(line, file=sys.stderr)
    return rejected_classes, rejected_members, reasons


# MARK: - Output


def generate(args):
    sdk = os.path.abspath(args.sdk)
    model = parse_headers(args.framework, sdk, args.min_ios)

    wrapped = {}
    for name, entry in model.classes.items():
        if entry["framework"] in args.framework and name not in SKIPPED_CLASSES and not name.startswith("_"):
            wrapped[name] = entry["framework"]
    types = Types(model, wrapped)

    # Members by class, declared, with ancestors' selectors taken first.
    def ancestors(name):
        chain = []
        current = model.classes.get(name, {}).get("super")
        while current:
            chain.append(current)
            current = model.classes.get(current, {}).get("super")
        return chain

    all_members = []
    for name in wrapped:
        for member in model.classes[name]["members"]:
            if member.framework not in args.framework:
                continue
            member.swift = (declare_method if member.kind == "method" else declare_property)(member, types)
            if member.swift:
                all_members.append(member)
    rejected_classes, rejected_members, reasons = check_availability(
        all_members, sorted(wrapped), sdk, args.framework, args.min_ios)
    for name in rejected_classes:
        wrapped.pop(name, None)

    kept = collections.defaultdict(list)
    for member in all_members:
        if id(member) in rejected_members or member.cls not in wrapped:
            continue
        kept[member.cls].append(member)

    # Property accessors and names, by class, to drop methods that duplicate them.
    def property_selectors(name):
        selectors, names = set(), set()
        for cls in [name] + ancestors(name):
            for member in kept.get(cls, []):
                if member.kind == "property":
                    node = member.node
                    selectors.add(node.get("getter", {}).get("name", member.selector))
                    selectors.add(node.get("setter", {}).get("name", f"set{member.selector[:1].upper()}{member.selector[1:]}:"))
                    names.add(member.selector)
        return selectors, names

    def ancestor_keys(name):
        keys = set()
        for cls in ancestors(name):
            for member in kept.get(cls, []):
                keys.add((member.kind, member.static, member.selector))
        return keys

    stats = collections.Counter()
    outputs = {framework: [] for framework in args.framework}
    for name in sorted(wrapped, key=lambda n: (len(ancestors(n)), n)):
        framework = wrapped[name]
        parent = model.classes[name].get("super")
        refines = f"{parent}Methods" if parent in wrapped else "ObjCWrapper"
        accessors, property_names = property_selectors(name)
        inherited = ancestor_keys(name)
        seen_swift, seen_keys = set(), set()
        # Members by the framework that declares them: a category in UIKit on
        # NSString goes in UIKit's file, as an extension of NSStringMethods.
        bodies = collections.defaultdict(list)
        for member in kept.get(name, []):
            key = (member.kind, member.static, member.selector)
            if key in inherited or key in seen_keys:
                continue
            if member.kind == "method":
                if member.selector in accessors:
                    continue
                if ":" not in member.selector and member.selector in property_names:
                    continue
            if member.swift in seen_swift:
                continue
            seen_keys.add(key)
            seen_swift.add(member.swift)
            bodies[member.framework].append(f"    {member.swift}")
            stats[member.kind] += 1
        stats["class"] += 1
        lines = [f"/// The Objective-C class {name}" + (f", a subclass of {parent}." if parent else "."),
                 f"public protocol {name}Methods: {refines} {{}}",
                 f"@ObjC public struct {name}: {name}Methods {{}}"]
        if bodies[framework]:
            lines += [f"extension {name}Methods {{"] + bodies[framework] + ["}"]
        outputs[framework].append("\n".join(lines))
        for other, body in bodies.items():
            if other != framework:
                outputs[other].append("\n".join([f"/// {other} additions to {name}.",
                                                 f"extension {name}Methods {{"] + body + ["}"]))

    for framework in args.framework:
        directory = os.path.join(args.out, framework, "Sources")
        os.makedirs(directory, exist_ok=True)
        imports = ["import ObjCInterop"] + [f"import {f}" for f in args.framework[:args.framework.index(framework)]]
        header = (f"// {framework} for Embedded Swift on iOS {args.min_ios}, generated by ObjC/tools/objcgen.py\n"
                  f"// from the iOS SDK's headers. Don't edit: regenerate with `make frameworks` in ObjC/.\n\n")
        with open(os.path.join(directory, f"{framework}.swift"), "w") as handle:
            handle.write(header + "\n".join(imports) + "\n\n" + "\n\n".join(outputs[framework]) + "\n")

    print(f"{stats['class']} classes, {stats['method']} methods, {stats['property']} properties; "
          f"left out by availability: {len(rejected_classes)} classes, {len(rejected_members)} members "
          f"({dict(reasons)})", file=sys.stderr)


def main():
    sys.setrecursionlimit(100000)
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--framework", action="append", required=True,
                        help="a framework to wrap, such as Foundation; give dependencies first")
    parser.add_argument("--out", default=os.path.join(REPO, "Frameworks"))
    parser.add_argument("--sdk", default=os.path.join(REPO, "sdk", "iPhoneOS9.3.sdk"))
    parser.add_argument("--min-ios", default="6.0")
    generate(parser.parse_args())


if __name__ == "__main__":
    main()
