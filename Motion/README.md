# Motion

The device's motion from Core Motion, on iOS 6. It's written in SwiftUI with
the CoreMotion module generated in [../Frameworks](../Frameworks/README.md).

- **Attitude:** roll, pitch and yaw, as angles and bars.
- **Gravity:** x, y and z, in g, with bars.
- **Movement:** the user's acceleration and the rotation rate.
- **Rate:** the number of updates and updates per second.

On the iPod touch 4 (accelerometer and gyroscope), device motion fuses the
two. On a device with only an accelerometer, the app shows its readings
instead.

```bash
make           # build build/Motion.app
make install   # copy it to the iPod
make run       # launch it (the iPod must be unlocked)
```

## How it works

- **Updates:** they arrive through `startDeviceMotionUpdatesToQueue:withHandler:`
  on the main queue. The handler is a Swift closure, which the generated
  method wraps in an Objective-C block.
- **Structs:** `CMAcceleration`, `CMRotationRate` and the attitude's angles
  come back as generated Swift structs and `Double`s.
- **Rate:** updates come 5 times a second. Each one re-renders the list,
  which with view reuse takes a few tens of milliseconds on the iPod.
- **Bars:** colored `Color` views in an `HStack`, sized from the value.
