// Implementation of ObjCRuntime.h, built for iOS.

#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdint.h>
#include "ObjCRuntime.h"

// From the ARC runtime (iOS 5 and later) and Foundation; not in public headers.
extern id objc_retain(id object);
extern void objc_release(id object);
extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *pool);
extern const char *NSGetSizeAndAlignment(const char *type, unsigned long *size, unsigned long *alignment);

typedef unsigned long W;

long objcrt_send(ObjCRTMessage *m) {
    id r = m->receiver;
    SEL s = m->selector;
    const W *w = m->words;
    if (m->wordCount > ObjCRTMaxWords) return 1;

    if (m->structResult) {
        void *p = m->structResult;
        // Pass all 16 words: the callee reads only the ones it takes, and the
        // rest are harmless extra stack arguments.
        ((void (*)(void *, id, SEL, W, W, W, W, W, W, W, W, W, W, W, W, W, W, W, W))objc_msgSend_stret)(
            p, r, s, w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        return 0;
    }
    uint64_t result = ((uint64_t (*)(id, SEL, W, W, W, W, W, W, W, W, W, W, W, W, W, W, W, W))objc_msgSend)(
        r, s, w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
    m->result[0] = (W)result;
    m->result[1] = (W)(result >> 32);
    return 0;
}

/// The kind character of a type encoding, skipping qualifiers (const, in, out…).
static char ObjCRTKind(const char *type) {
    for (;; type++) {
        switch (*type) {
            case 'r': case 'n': case 'N': case 'o': case 'O': case 'R': case 'V':
                continue;
            default:
                return *type;
        }
    }
}

static long ObjCRTSize(const char *type) {
    unsigned long size = 0, alignment = 0;
    NSGetSizeAndAlignment(type, &size, &alignment);
    return (long)size;
}

long objcrt_signature(void *receiver, void *selector, ObjCRTSignature *signature) {
    if (!receiver) return 1;
    Method method = class_getInstanceMethod(object_getClass(receiver), selector);
    if (!method) return 1;
    char type[256];
    method_getReturnType(method, type, sizeof type);
    signature->returnType = ObjCRTKind(type);
    signature->returnSize = ObjCRTSize(type);
    unsigned count = method_getNumberOfArguments(method);
    signature->argumentCount = count >= 2 ? count - 2 : 0;
    if (signature->argumentCount > ObjCRTMaxArguments) signature->argumentCount = ObjCRTMaxArguments;
    for (long i = 0; i < signature->argumentCount; i++) {
        method_getArgumentType(method, (unsigned)i + 2, type, sizeof type);
        signature->argumentTypes[i] = ObjCRTKind(type);
        signature->argumentSizes[i] = ObjCRTSize(type);
    }
    return 0;
}

void *objcrt_class(const char *name) {
    return (void *)objc_getClass(name);
}

void *objcrt_selector(const char *name) {
    return sel_registerName(name);
}

const char *objcrt_selector_name(void *selector) {
    return sel_getName(selector);
}

const char *objcrt_class_name(void *object) {
    return object ? object_getClassName(object) : "nil";
}

long objcrt_is_kind(void *object, void *cls) {
    for (Class c = object ? object_getClass(object) : Nil; c; c = class_getSuperclass(c)) {
        if ((void *)c == cls) return 1;
    }
    return 0;
}

void *objcrt_retain(void *object) {
    return object ? (void *)objc_retain(object) : NULL;
}

void objcrt_release(void *object) {
    if (object) objc_release(object);
}

void *objcrt_pool_push(void) {
    return objc_autoreleasePoolPush();
}

void objcrt_pool_pop(void *pool) {
    objc_autoreleasePoolPop(pool);
}

void *objcrt_string(const char *utf8) {
    return ((void *(*)(Class, SEL, const char *))objc_msgSend)(objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), utf8);
}

const char *objcrt_utf8(void *string) {
    return string ? ((const char *(*)(id, SEL))objc_msgSend)(string, sel_registerName("UTF8String")) : "";
}

long objcrt_load(const char *path) {
    return dlopen(path, RTLD_LAZY) ? 0 : 1;
}
