# XML Browser

Browses XML files as trees on iOS 6. It's written in SwiftUI with the library
in [../SwiftUI](../SwiftUI/README.md) and the [../XML](../XML/README.md)
module.

- **Samples:** bundled with the app. An RSS feed with a namespace and CDATA,
  a book catalog with attributes, comments, entities and non-Latin text, and
  an SVG.
- **On this device:** the XML plists the app finds:
  - `SystemVersion.plist`.
  - The launch daemons in `/System/Library/LaunchDaemons`.
  - The `Info.plist` of apps in `/Applications`.

  Binary plists are skipped.

Opening a file parses it and shows the element count and the time taken.
Each element shows its attributes, then its children. Tapping a child
element opens it. A row shows a summary: the element's text, its `title` or
`name` child, an identifying attribute, or how many elements it holds. A
plist `<dict>` is shown as its keys and values.

```bash
make           # build build/XMLBrowser.app
make install   # copy it to the iPod
make run       # launch it (the iPod must be unlocked)
```

## Notes

- **Typed wrappers:** `Foundation.swift` declares the NSFileManager,
  NSFileHandle, NSBundle and NSDate API the app uses, with ObjCInterop's
  macros.
- **No `.task`:** parsing and the file search run in `onAppear`, not
  `.task`. Releasing a finished `Task` currently crashes on armv7 (see
  [../SwiftUI](../SwiftUI/README.md#limits)).
- **Long lists** are cut at 150 rows, since every row is a view that's laid
  out on each render.
