// Implementation of SystemInfo.h.
//
// libMobileGestalt and IOKit have no headers or stubs in the iOS SDK, so
// their functions are looked up with dlsym.

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <time.h>
#include "SystemInfo.h"

static long SIClamp(unsigned long long value) {
    return value > 0x7FFFFFFF ? 0x7FFFFFFF : (long)value;
}

long si_sysctl_string(const char *name, char *buffer, long size) {
    size_t length = size;
    if (size <= 0 || sysctlbyname(name, buffer, &length, NULL, 0) != 0) return -1;
    if (length >= (size_t)size) length = size - 1;
    buffer[length] = 0;
    return (long)strlen(buffer);
}

long si_sysctl_number(const char *name) {
    unsigned char value[8] = {0};
    size_t length = sizeof value;
    if (sysctlbyname(name, value, &length, NULL, 0) != 0) return -1;
    if (length == 4) {
        unsigned int number;
        memcpy(&number, value, 4);
        return SIClamp(number);
    }
    unsigned long long number = 0;
    memcpy(&number, value, length < 8 ? length : 8);
    return SIClamp(number);
}

#pragma mark - MobileGestalt

static CFTypeRef (*MGCopyAnswer)(CFStringRef key);

long si_gestalt_string(const char *key, char *buffer, long size) {
    if (!MGCopyAnswer) {
        void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
        if (handle) *(void **)&MGCopyAnswer = dlsym(handle, "MGCopyAnswer");
        if (!MGCopyAnswer) return -1;
    }
    if (size <= 0) return -1;
    CFStringRef keyString = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFTypeRef answer = MGCopyAnswer(keyString);
    CFRelease(keyString);
    if (!answer) return -1;

    long result = -1;
    CFTypeID type = CFGetTypeID(answer);
    if (type == CFStringGetTypeID()) {
        if (CFStringGetCString(answer, buffer, size, kCFStringEncodingUTF8)) result = (long)strlen(buffer);
    } else if (type == CFBooleanGetTypeID()) {
        result = snprintf(buffer, size, "%d", CFBooleanGetValue(answer) ? 1 : 0);
    } else if (type == CFNumberGetTypeID()) {
        if (CFNumberIsFloatType(answer)) {
            double number;
            CFNumberGetValue(answer, kCFNumberDoubleType, &number);
            result = snprintf(buffer, size, "%g", number);
        } else {
            long long number;
            CFNumberGetValue(answer, kCFNumberLongLongType, &number);
            result = snprintf(buffer, size, "%lld", number);
        }
    }
    CFRelease(answer);
    return result;
}

#pragma mark - Memory, CPU, storage

long si_memory(SIMemory *memory) {
    vm_size_t pageSize = 0;
    host_page_size(mach_host_self(), &pageSize);
    vm_statistics_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_VM_INFO, (host_info_t)&vm, &count) != KERN_SUCCESS) return 1;
    long pageKB = (long)(pageSize / 1024);
    memory->pageSize = (long)pageSize;
    memory->totalKB = si_sysctl_number("hw.physmem") / 1024;
    memory->freeKB = vm.free_count * pageKB;
    memory->activeKB = vm.active_count * pageKB;
    memory->inactiveKB = vm.inactive_count * pageKB;
    memory->wiredKB = vm.wire_count * pageKB;
    return 0;
}

long si_cpu_ticks(SICPUTicks *ticks) {
    host_cpu_load_info_data_t load;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&load, &count) != KERN_SUCCESS) return 1;
    ticks->user = load.cpu_ticks[CPU_STATE_USER];
    ticks->system = load.cpu_ticks[CPU_STATE_SYSTEM];
    ticks->idle = load.cpu_ticks[CPU_STATE_IDLE];
    ticks->nice = load.cpu_ticks[CPU_STATE_NICE];
    return 0;
}

long si_disk(const char *path, SIDisk *disk) {
    struct statfs fs;
    if (statfs(path, &fs) != 0) return 1;
    unsigned long long block = fs.f_bsize;
    disk->totalMB = SIClamp(fs.f_blocks * block / (1024 * 1024));
    disk->freeMB = SIClamp(fs.f_bavail * block / (1024 * 1024));
    return 0;
}

#pragma mark - Battery

typedef mach_port_t io_object_t;

static long SINumber(CFDictionaryRef properties, const char *key) {
    CFStringRef keyString = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFTypeRef value = CFDictionaryGetValue(properties, keyString);
    CFRelease(keyString);
    if (!value) return -1;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) return CFBooleanGetValue(value) ? 1 : 0;
    long number = -1;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberLongType, &number);
    return number;
}

long si_battery(SIBattery *battery) {
    static mach_port_t *masterPort;
    static CFMutableDictionaryRef (*IOServiceMatching)(const char *name);
    static io_object_t (*IOServiceGetMatchingService)(mach_port_t master, CFDictionaryRef matching);
    static kern_return_t (*IORegistryEntryCreateCFProperties)(io_object_t entry, CFMutableDictionaryRef *properties,
                                                             CFAllocatorRef allocator, uint32_t options);
    static kern_return_t (*IOObjectRelease)(io_object_t object);
    if (!IOServiceMatching) {
        void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!handle) return 1;
        masterPort = dlsym(handle, "kIOMasterPortDefault");
        *(void **)&IOServiceGetMatchingService = dlsym(handle, "IOServiceGetMatchingService");
        *(void **)&IORegistryEntryCreateCFProperties = dlsym(handle, "IORegistryEntryCreateCFProperties");
        *(void **)&IOObjectRelease = dlsym(handle, "IOObjectRelease");
        *(void **)&IOServiceMatching = dlsym(handle, "IOServiceMatching");
        if (!masterPort || !IOServiceGetMatchingService || !IORegistryEntryCreateCFProperties || !IOObjectRelease || !IOServiceMatching) {
            IOServiceMatching = NULL;
            return 2;
        }
    }

    // The matching dictionary is consumed by IOServiceGetMatchingService.
    io_object_t service = IOServiceGetMatchingService(*masterPort, IOServiceMatching("IOPMPowerSource"));
    if (!service) return 3;
    CFMutableDictionaryRef properties = NULL;
    kern_return_t error = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    if (error != KERN_SUCCESS || !properties) return 4;

    battery->currentCapacity = SINumber(properties, "CurrentCapacity");
    battery->maxCapacity = SINumber(properties, "MaxCapacity");
    battery->designCapacity = SINumber(properties, "DesignCapacity");
    battery->cycleCount = SINumber(properties, "CycleCount");
    battery->voltage = SINumber(properties, "Voltage");
    battery->amperage = SINumber(properties, "InstantAmperage");
    if (battery->amperage == -1) battery->amperage = SINumber(properties, "Amperage");
    battery->temperature = SINumber(properties, "Temperature");
    battery->isCharging = SINumber(properties, "IsCharging");
    battery->externalConnected = SINumber(properties, "ExternalConnected");
    battery->fullyCharged = SINumber(properties, "FullyCharged");
    CFRelease(properties);
    return 0;
}

#pragma mark - Time and processes

long si_now(void) {
    return (long)time(NULL);
}

long si_boot_time(void) {
    struct timeval boot;
    size_t length = sizeof boot;
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &boot, &length, NULL, 0) != 0) return -1;
    return (long)boot.tv_sec;
}

long si_processes(SIProcessCallback callback, void *context) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t length = 0;
    if (sysctl(mib, 4, NULL, &length, NULL, 0) != 0) return 0;
    // Room for processes started between the two calls.
    length += length / 8;
    struct kinfo_proc *processes = malloc(length);
    if (!processes) return 0;
    if (sysctl(mib, 4, processes, &length, NULL, 0) != 0) {
        free(processes);
        return 0;
    }
    long count = (long)(length / sizeof *processes);
    for (long i = 0; i < count; i++) {
        struct kinfo_proc *process = &processes[i];
        callback(context, process->kp_proc.p_pid, process->kp_eproc.e_ppid, process->kp_eproc.e_ucred.cr_uid,
                 process->kp_proc.p_comm, (long)process->kp_proc.p_starttime.tv_sec);
    }
    free(processes);
    return count;
}
