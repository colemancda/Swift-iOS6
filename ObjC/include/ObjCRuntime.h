// The Objective-C runtime, for Embedded Swift (see ../Sources/ObjC.swift).
//
// Embedded Swift has no Objective-C interop, so messages are sent through
// these functions. Every argument and result is passed as 32-bit words: on
// armv7 iOS, floats travel in integer registers, and 64-bit values and
// structs as consecutive words, so one function can call objc_msgSend with
// any signature. Functions take at most four arguments, so calls from Swift
// fit the r9 trampolines without stack arguments.

#ifndef OBJC_RUNTIME_H
#define OBJC_RUNTIME_H

enum {
    /// Words of arguments a message can carry.
    ObjCRTMaxWords = 16,
    /// Arguments a method can take, after self and _cmd.
    ObjCRTMaxArguments = 12,
};

/// A message to send.
typedef struct {
    void *receiver;
    void *selector;
    /// For a message to super: the class whose superclass implements it. NULL otherwise.
    void *superclass;
    const unsigned long *words;
    long wordCount;
    /// For struct results larger than 4 bytes, where to write them
    /// (sent with objc_msgSend_stret). NULL otherwise.
    void *structResult;
    /// The result: r0 and r1 (a pointer, integer or float in the first word;
    /// a 64-bit integer or double in both).
    unsigned long result[2];
} ObjCRTMessage;

/// A method's types, from its type encoding. Each type is the encoding's
/// first character after qualifiers: '@' object, '#' class, ':' selector,
/// 'v' void, 'c' char/BOOL, 'i' int, 'f' float, 'd' double, 'q' long long,
/// '{' struct, '^' pointer, '*' C string, and so on.
typedef struct {
    char returnType;
    long returnSize;
    long argumentCount;
    char argumentTypes[ObjCRTMaxArguments];
    long argumentSizes[ObjCRTMaxArguments];
} ObjCRTSignature;

/// Sends `message`, filling in its result. Returns 0, or 1 if it has too many words.
long objcrt_send(ObjCRTMessage *message);

/// The types of the method `receiver` runs for `selector`. Returns 0, or 1
/// if the receiver doesn't respond to it.
long objcrt_signature(void *receiver, void *selector, ObjCRTSignature *signature);

/// objc_getClass; NULL if there's no such class.
void *objcrt_class(const char *name);
/// sel_registerName
void *objcrt_selector(const char *name);
/// The name of a selector.
const char *objcrt_selector_name(void *selector);
/// The name of an object's class.
const char *objcrt_class_name(void *object);
/// Whether `object` is an instance of `cls` or a subclass.
long objcrt_is_kind(void *object, void *cls);

void *objcrt_retain(void *object);
void objcrt_release(void *object);
void objcrt_autorelease(void *object);
void *objcrt_pool_push(void);
void objcrt_pool_pop(void *pool);

/// An autoreleased NSString from UTF-8.
void *objcrt_string(const char *utf8);
/// An NSString's UTF-8, valid while the string is.
const char *objcrt_utf8(void *string);

/// The class of an object.
void *objcrt_object_class(void *object);
/// A class's superclass.
void *objcrt_superclass(void *cls);

#pragma mark - Defining classes

/// Runs every method of every class defined from Swift. `words` holds the
/// arguments after self and _cmd; the method's result goes in `result` (r0
/// and r1), or in `structResult` for struct results larger than 4 bytes.
typedef void (*ObjCRTHandler)(void *self, void *selector, const unsigned long *words, unsigned long *result,
                              void *structResult);

void objcrt_set_handler(ObjCRTHandler handler);

/// A new class (not yet registered), or the existing class of that name.
/// Returns NULL if `superclass` is NULL.
void *objcrt_allocate_class(const char *name, void *superclass);
void objcrt_register_class(void *cls);
/// Adds `selector` to `cls` with type encoding `types`, run by the handler;
/// replaces it if `cls` already has it. Returns 0 on success.
long objcrt_add_method(void *cls, void *selector, const char *types);
/// Declares that `cls` adopts the protocol. Returns 0 if the protocol exists.
long objcrt_add_protocol(void *cls, const char *protocol);
/// The type encoding of `selector` on instances of `cls` (inherited ones
/// included), or NULL.
const char *objcrt_method_types(void *cls, void *selector);
/// The type encoding of `selector` in a protocol (required or optional), or NULL.
const char *objcrt_protocol_method_types(const char *protocol, void *selector);

/// objc_setAssociatedObject with OBJC_ASSOCIATION_RETAIN_NONATOMIC, and its getter.
void objcrt_set_associated(void *object, const void *key, void *value);
void *objcrt_get_associated(void *object, const void *key);

#pragma mark - Main queue and app

typedef void (*ObjCRTFunction)(void *context);
/// Calls `function` on the main queue, on a later turn of the run loop.
void objcrt_async(ObjCRTFunction function, void *context);
/// Calls `function` on the main queue after `milliseconds`.
void objcrt_after(unsigned long milliseconds, ObjCRTFunction function, void *context);
/// UIApplicationMain with the process's arguments and the named app delegate
/// class. Doesn't return.
long objcrt_application_main(const char *delegateClass);

/// Loads a framework or library, such as
/// "/System/Library/Frameworks/UIKit.framework/UIKit". Returns 0 on success.
long objcrt_load(const char *path);

#endif
