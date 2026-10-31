// libc functions the Embedded Swift runtime needs that iOS 6 doesn't have.
// Defining them here means dyld never looks them up.
//
// Compiled for the bare-metal target, like Executor.c, because the Swift
// runtime is what calls them.

#include <stddef.h>

/// C11 Annex K `memset_s` (iOS 7 and later). The concurrency runtime uses it
/// to clear task memory. Writes through a volatile pointer so the stores stay.
int memset_s(void *s, size_t smax, int c, size_t n) {
    if (s == NULL) return 22; // EINVAL
    volatile unsigned char *p = s;
    size_t count = n < smax ? n : smax;
    for (size_t i = 0; i < count; i++) p[i] = (unsigned char)c;
    return n > smax ? 84 : 0; // EOVERFLOW
}
