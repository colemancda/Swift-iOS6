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
void *objcrt_pool_push(void);
void objcrt_pool_pop(void *pool);

/// An autoreleased NSString from UTF-8.
void *objcrt_string(const char *utf8);
/// An NSString's UTF-8, valid while the string is.
const char *objcrt_utf8(void *string);

/// Loads a framework or library, such as
/// "/System/Library/Frameworks/UIKit.framework/UIKit". Returns 0 on success.
long objcrt_load(const char *path);

#endif
