// Types shared by the `SwiftUI` module and its UIKit backend (Backend.swift).
//
// The backend's `sui_*` functions are Swift now, written with ObjCInterop;
// these C types remain so the callbacks keep their C calling convention.
// Views are referred to by address (SUIViewRef), sizes are whole points and
// colors are packed 0xRRGGBBAA.

#ifndef SWIFTUI_BACKEND_H
#define SWIFTUI_BACKEND_H

typedef void *SUIViewRef;
typedef void (*SUICallback)(void *context);
typedef void (*SUIIndexCallback)(void *context, long index);

enum {
    SUIAxisHorizontal = 0,
    SUIAxisVertical = 1,
};

enum {
    SUIAlignmentCenter = 0,
    SUIAlignmentLeading = 1,
    SUIAlignmentTrailing = 2,
};

enum {
    SUIFontWeightRegular = 0,
    SUIFontWeightMedium = 1,
    SUIFontWeightSemibold = 2,
    SUIFontWeightBold = 3,
};

#endif
