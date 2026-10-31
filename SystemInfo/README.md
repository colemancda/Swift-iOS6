# System Info

System and hardware information for iOS 6, in the spirit of AIDA64, written
in SwiftUI with the library in [../SwiftUI](../SwiftUI/README.md) and running
on a jailbroken iPod touch (4th gen).

| Category | Shows |
|---|---|
| Device | Model, product type, model number, board, platform, color, serial number, UDID, Wi-Fi and Bluetooth addresses |
| Operating System | iOS version and build, Darwin kernel, uptime, process limits |
| CPU | Chip, core, architecture, cores, clock, caches, timebase, live usage (user, system, idle) |
| Memory | Total, used, free, active, inactive, wired, page size (live) |
| Storage | System and data volumes, free space |
| Battery | Level, state, charge, full charge, design capacity, health, cycle count, voltage, current, temperature (live) |
| Display | Resolution, scale, pixel density, size |
| Features | Wi-Fi, Bluetooth, cellular, GPS, motion sensors, cameras, microphone |
| Processes | Every running process: PID, parent, user, running time |

Each category's summary is on the first screen, such as "Apple A4 · 37% busy"
or "91% · Charging". Live values refresh every 2 seconds.

```bash
make           # build build/SystemInfo.app
make install   # copy it to the iPod
make run       # launch it (the iPod must be unlocked)
```

## Where the values come from

`SystemInfo.c` reads everything and passes plain numbers and C strings to
Swift through `include/SystemInfo.h`. `long` is 32 bits on armv7, so sizes
are in KB or MB. Formatting happens in Swift.

- **sysctl:**
  - `hw.machine`, `hw.model` (board, such as N81AP) and `hw.ncpu`.
  - Cache sizes, `hw.tbfrequency`, `hw.physmem`.
  - `kern.osrelease`, `kern.version`, `kern.boottime`, `kern.maxproc`.
  - The process table (`KERN_PROC_ALL`).
- **Mach:** `host_statistics` for memory pages (`HOST_VM_INFO`) and CPU ticks
  (`HOST_CPU_LOAD_INFO`). CPU usage is the change in ticks between refreshes.
- **statfs:** `/` (system) and `/private/var` (data).
- **libMobileGestalt** (private, looked up with `dlsym`):
  - `MGCopyAnswer` for product type, iOS version and build, model number and
    region.
  - Hardware platform, color, serial number, UDID, Wi-Fi and Bluetooth addresses.
  - Screen size, scale and pitch, and capability keys (`gyroscope`,
    `front-facing-camera`, `gps`…).
- **IOKit** (looked up with `dlsym`; the SDK has no IOKit headers): the
  `IOPMPowerSource` service's properties. Its keys include `CurrentCapacity`,
  `MaxCapacity`, `DesignCapacity`, `CycleCount`, `Voltage`, `Amperage`,
  `Temperature`, `IsCharging` and `ExternalConnected`.

## What iOS 6 doesn't report

These gaps were found by probing the iPod:

- **CPU clock:** there's no `hw.cpufrequency` (or bus frequency). The app shows
  the chip's nominal clock from a table by product type (800 MHz for this
  iPod's A4).
- **Device name:** apps running as `mobile` get only "iPod touch" from
  MobileGestalt's `DeviceName`. The name you set comes from `kern.hostname`.
- **Camera keys:** there's no `rear-facing-camera`, `camera-flash` or
  `auto-focus-camera` key. Features shows only the keys iOS 6 answers, plus
  `still-camera` as "Camera".
- **System CPU time:** `HOST_CPU_LOAD_INFO` reports 0 ticks for it, so CPU
  time shows as user and idle.
- **Per-process memory:** this would need `task_for_pid` and its entitlement,
  so the process list has no memory column.
