# SwiftUI on iOS 6

A port of [SwiftUI-iOS9](https://github.com/colemancda/SwiftUI-iOS9) to iOS 6:
a SwiftUI-compatible UI library in Embedded Swift, running on a jailbroken
iPod touch (4th gen, armv7, iOS 6.1.6).

<p>
<img src="Screenshots/Counter.png" width="160" alt="Counter">
<img src="Screenshots/Planets.png" width="160" alt="Planets list">
<img src="Screenshots/Moons.png" width="160" alt="Pushed Moons screen">
<img src="Screenshots/Devices.png" width="160" alt="Devices list">
</p>

The module is named `SwiftUI`, so app code keeps `import SwiftUI`:

```swift
import SwiftUI

@main
struct PlanetsApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                PlanetList()
            }
        }
    }
}

struct PlanetList: View {
    var body: some View {
        List(planets) { planet in
            NavigationLink(destination: PlanetDetail(planet: planet)) {
                Text(planet.name)
            }
        }
        .navigationTitle("Planets")
    }
}
```

## Examples

```bash
make                          # build Examples/Counter
make EXAMPLE=Planets install  # copy to the iPod
make EXAMPLE=Planets run      # launch it (the iPod must be unlocked)
```

- **Counter:** `@State`, buttons and stacks.
- **Planets:** `NavigationStack` and `List`, three screens deep (planets, then a
  planet's facts, then its moons).
- **Devices:** `NavigationView`, `List`, `@EnvironmentObject`, and an async
  `task` that updates the list every second.

`make -C .. screenshot` saves the iPod's screen to `../build/screenshot.png`.

The SDK, SSH config and app launcher come from the parent directory (see
[../README.md](../README.md)).

## What's supported

The same as SwiftUI-iOS9 (`Text`, `Button`, stacks, `Spacer`, `ForEach`,
`List`, `NavigationView`, `NavigationLink`, `@State`, `ObservableObject`,
`@EnvironmentObject`, `task`, `async`/`await` and more), plus `NavigationStack`.
`NavigationStack` renders like `NavigationView` and has no `path` binding or
`navigationDestination`.

## How the UI is wrapped

```
App code (Embedded Swift)
  └─ SwiftUI module (Embedded Swift)        Sources/SwiftUI          unchanged
       └─ C API                              SwiftUIBackend.h         unchanged
            └─ UIKit backend (Objective-C)   Backend.m                rewritten for iOS 6
```

- A `NavigationStack` or `NavigationView` is one `UINavigationController`,
  kept across renders. Each screen in it is a `UIViewController`
  (`SUILevelController`). A `NavigationLink` pushes one, and the system back
  button pops it.
- A `List` is a `UIScrollView` of rows. A `NavigationLink` row highlights when
  touched and shows a chevron.
- Each render installs a screen's content in a new host view inside that
  screen's view controller.

## What changed from SwiftUI-iOS9

The Swift code is the same apart from `NavigationStack` and the `Image` glyphs.
The changes are in the backend and the build:

- **Layout:** iOS 6 has Auto Layout, but not layout anchors, `activateConstraints:`
  or `UIStackView`. The backend uses `constraintWithItem:…` and installs each
  constraint on its views' nearest common ancestor. Stacks are `SUIStackView`,
  a small constraint-based stack with the same fill and alignment behavior.
- **Content host views:** iOS 6 checks constraints on a view outside a window
  only when the view joins a window, such as when a screen is pushed. By then,
  constraints left over from replaced content point at views that are gone,
  and UIKit throws (this crashed the second push). Content now goes in a fresh
  host view each render, so its constraints are discarded along with it.
- **iOS 7–8 APIs:** fonts are regular or bold (no `UIFontWeight`). Buttons
  are custom buttons tinted blue (no `UIButtonTypeSystem` or `tintColor`).
  Layout guides aren't needed, because iOS 6 places views below the bars.
- **`memset_s`:** the concurrency runtime calls it, but iOS 6 has no `memset_s`
  (it arrived in iOS 7), so dyld refused to launch the app.
  `Sources/CSwiftUIBackend/Compat.c` defines it.
- **r9:** Embedded Swift targets bare-metal armv7, where callees must preserve
  `r9`. On iOS, any function may overwrite it. Our Swift and C code avoids
  `r9` (`-ffixed-r9`), but the prebuilt `libswift_Concurrency.a` keeps values
  in it. iOS 6's `malloc` returns with `r9 = 0xffffffff`, which crashed the
  first `Task`. `tools/r9wrap.py` runs at link time:
  - It finds every function that bare-metal code (Swift objects, executor,
    runtime archives) calls in iOS code: libSystem and the `sui_*` backend.
  - It writes a trampoline for each one that saves and restores `r9`.
  - It renames the references in copies of those objects with `llvm-objcopy`.
  - It reads the stack-argument counts for the `sui_*` functions from the header.
- **Symbols:** `Image(systemName:)` maps to characters iOS 6's fonts have
  (`thermometer` is ℃, for example). Characters newer than Unicode 6.1 have no
  glyph on iOS 6.

## Limits

The same as SwiftUI-iOS9, and also:

- iOS 6 appearance: glossy navigation bars and back buttons. There's no
  swipe-to-go-back, which arrived in iOS 7.
- Only regular and bold system fonts.
