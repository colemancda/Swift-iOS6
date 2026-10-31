// C interface to iOS's system and hardware information, for Embedded Swift:
// sysctl, Mach host statistics, statfs, the process table, the private
// libMobileGestalt and the IOKit battery.
//
// Only pointers and `long` cross this boundary (implemented in SystemInfo.c).
// `long` is 32 bits on armv7, so sizes are in KB or MB. Values iOS doesn't
// report are -1.

#ifndef SYSTEM_INFO_H
#define SYSTEM_INFO_H

/// Copies a string sysctl (such as "hw.model") into `buffer` as UTF-8.
/// Returns its length, or -1 if it doesn't exist.
long si_sysctl_string(const char *name, char *buffer, long size);

/// An integer sysctl (such as "hw.ncpu"), or -1. Values over 2^31 are clamped.
long si_sysctl_number(const char *name);

/// A MobileGestalt answer (such as "ProductType") as UTF-8: strings as they
/// are, numbers in decimal, booleans as "1" or "0". Returns its length, or -1
/// if the key has no answer on this device.
long si_gestalt_string(const char *key, char *buffer, long size);

typedef struct {
    long totalKB;
    long freeKB;
    long activeKB;
    long inactiveKB;
    long wiredKB;
    long pageSize;
} SIMemory;

/// Physical memory and how the kernel is using it. Returns 0 on success.
long si_memory(SIMemory *memory);

/// CPU time since boot, in ticks, summed over all cores.
typedef struct {
    long user;
    long system;
    long idle;
    long nice;
} SICPUTicks;

long si_cpu_ticks(SICPUTicks *ticks);

typedef struct {
    long totalMB;
    long freeMB;
} SIDisk;

/// Size and free space of the volume holding `path`. Returns 0 on success.
long si_disk(const char *path, SIDisk *disk);

typedef struct {
    /// mAh
    long currentCapacity;
    long maxCapacity;
    long designCapacity;
    long cycleCount;
    /// mV
    long voltage;
    /// mA; negative while discharging.
    long amperage;
    /// Hundredths of a degree Celsius.
    long temperature;
    long isCharging;
    long externalConnected;
    long fullyCharged;
} SIBattery;

/// The battery, from IOKit's IOPMPowerSource. Returns 0 on success.
long si_battery(SIBattery *battery);

/// Seconds since 1970 now, and when the kernel booted.
long si_now(void);
long si_boot_time(void);

/// One running process. `name` is only valid during the callback.
typedef void (*SIProcessCallback)(void *context, long pid, long parentPID, long uid,
                                  const char *name, long startTime);

/// Calls `callback` for each running process. Returns how many there were.
long si_processes(SIProcessCallback callback, void *context);

/// One installed app. The strings are only valid during the callback; ones
/// iOS doesn't report are empty. `type` is "System" (built in, or installed
/// in /Applications) or "User" (from the App Store or iTunes).
typedef void (*SIAppCallback)(void *context, const char *bundleID, const char *name, const char *version,
                              const char *build, const char *type, const char *path);

/// Calls `callback` for each installed app, from MobileInstallation. Returns
/// how many there were, or -1 if they couldn't be listed.
long si_apps(SIAppCallback callback, void *context);

#endif
