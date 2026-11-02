// Implementation of ObjCRuntime.h, built for iOS.

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdint.h>
#include <string.h>
#include "ObjCRuntime.h"

// From the ARC runtime (iOS 5 and later) and Foundation; not in public headers.
extern id objc_retain(id object);
extern void objc_release(id object);
extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *pool);
extern const char *NSGetSizeAndAlignment(const char *type, unsigned long *size, unsigned long *alignment);
extern int *_NSGetArgc(void);
extern char ***_NSGetArgv(void);

typedef unsigned long W;

long objcrt_send(ObjCRTMessage *m) {
    id r = m->receiver;
    SEL s = m->selector;
    const W *w = m->words;
    if (m->wordCount > ObjCRTMaxWords) return 1;

    if (m->superclass) {
        struct objc_super super = {r, class_getSuperclass(m->superclass)};
        if (m->structResult) {
            ((void (*)(void *, struct objc_super *, SEL, W, W, W, W, W, W, W, W, W, W, W, W, W, W, W, W))objc_msgSendSuper_stret)(
                m->structResult, &super, s, w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
            return 0;
        }
        uint64_t result = ((uint64_t (*)(struct objc_super *, SEL, W, W, W, W, W, W, W, W, W, W, W, W, W, W, W, W))objc_msgSendSuper)(
            &super, s, w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        m->result[0] = (W)result;
        m->result[1] = (W)(result >> 32);
        return 0;
    }
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

extern id objc_autorelease(id object);

void objcrt_autorelease(void *object) {
    if (object) objc_autorelease(object);
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

void *objcrt_object_class(void *object) {
    return object ? (void *)object_getClass(object) : NULL;
}

void *objcrt_superclass(void *cls) {
    return cls ? (void *)class_getSuperclass(cls) : NULL;
}

#pragma mark - Defining classes

static ObjCRTHandler ObjCRTCurrentHandler;

void objcrt_set_handler(ObjCRTHandler handler) {
    ObjCRTCurrentHandler = handler;
}

// The implementation of every method defined from Swift. It reads 16 words
// whatever the method takes: the ones past its real arguments are whatever
// lies above them on the caller's stack, and are ignored.
static uint64_t ObjCRTMethod(id self, SEL cmd, W w0, W w1, W w2, W w3, W w4, W w5, W w6, W w7,
                             W w8, W w9, W w10, W w11, W w12, W w13, W w14, W w15) {
    W words[ObjCRTMaxWords] = {w0, w1, w2, w3, w4, w5, w6, w7, w8, w9, w10, w11, w12, w13, w14, w15};
    W result[2] = {0, 0};
    if (ObjCRTCurrentHandler) ObjCRTCurrentHandler(self, cmd, words, result, NULL);
    return (uint64_t)result[1] << 32 | result[0];
}

// The same for methods returning a struct larger than 4 bytes, whose caller
// passes a pointer to the result first.
static void ObjCRTMethodStruct(void *structResult, id self, SEL cmd, W w0, W w1, W w2, W w3, W w4, W w5, W w6,
                               W w7, W w8, W w9, W w10, W w11, W w12, W w13, W w14, W w15) {
    W words[ObjCRTMaxWords] = {w0, w1, w2, w3, w4, w5, w6, w7, w8, w9, w10, w11, w12, w13, w14, w15};
    W result[2] = {0, 0};
    if (ObjCRTCurrentHandler) ObjCRTCurrentHandler(self, cmd, words, result, structResult);
}

void *objcrt_allocate_class(const char *name, void *superclass) {
    Class existing = objc_getClass(name);
    if (existing) return (void *)existing;
    if (!superclass) return NULL;
    return (void *)objc_allocateClassPair(superclass, name, 0);
}

void objcrt_register_class(void *cls) {
    objc_registerClassPair(cls);
}

long objcrt_add_method(void *cls, void *selector, const char *types) {
    char returnType[256];
    // The return type is the encoding's first type; struct results larger
    // than 4 bytes come back through a hidden pointer.
    const char *end = NSGetSizeAndAlignment(types, NULL, NULL);
    long length = end - types;
    if (length <= 0 || length >= (long)sizeof returnType) return 1;
    memcpy(returnType, types, length);
    returnType[length] = 0;
    unsigned long size = 0;
    NSGetSizeAndAlignment(returnType, &size, NULL);
    IMP imp = (returnType[0] == '{' && size > 4) ? (IMP)ObjCRTMethodStruct : (IMP)ObjCRTMethod;
    if (!class_addMethod(cls, selector, imp, types)) {
        Method method = class_getInstanceMethod(cls, selector);
        // Inherited: add an override on this class. Already here: replace it.
        if (!method) return 2;
        class_replaceMethod(cls, selector, imp, types);
    }
    return 0;
}

long objcrt_add_protocol(void *cls, const char *protocol) {
    Protocol *p = objc_getProtocol(protocol);
    if (!p) return 1;
    class_addProtocol(cls, p);
    return 0;
}

const char *objcrt_method_types(void *cls, void *selector) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    return method ? method_getTypeEncoding(method) : NULL;
}

const char *objcrt_protocol_method_types(const char *protocol, void *selector) {
    Protocol *p = objc_getProtocol(protocol);
    if (!p) return NULL;
    for (int required = 1; required >= 0; required--) {
        struct objc_method_description description = protocol_getMethodDescription(p, selector, required, YES);
        if (description.types) return description.types;
    }
    return NULL;
}

void objcrt_set_associated(void *object, const void *key, void *value) {
    objc_setAssociatedObject(object, key, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void *objcrt_get_associated(void *object, const void *key) {
    return (void *)objc_getAssociatedObject(object, key);
}

#pragma mark - Main queue and app

void objcrt_async(ObjCRTFunction function, void *context) {
    dispatch_async_f(dispatch_get_main_queue(), context, function);
}

void objcrt_after(unsigned long milliseconds, ObjCRTFunction function, void *context) {
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)milliseconds * NSEC_PER_MSEC),
                     dispatch_get_main_queue(), context, function);
}

long objcrt_application_main(const char *delegateClass) {
    int (*UIApplicationMain)(int, char **, void *, void *) = dlsym(RTLD_DEFAULT, "UIApplicationMain");
    if (!UIApplicationMain) return 1;
    void *pool = objc_autoreleasePoolPush();
    void *name = objcrt_string(delegateClass);
    int result = UIApplicationMain(*_NSGetArgc(), *_NSGetArgv(), NULL, name);
    objc_autoreleasePoolPop(pool);
    return result;
}
