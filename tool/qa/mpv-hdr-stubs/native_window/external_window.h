#pragma once
#include <stdint.h>
#include <native_buffer/buffer_common.h>
typedef struct NativeWindow OHNativeWindow;
#include "fixture-native-window-operation.h"
int32_t OH_NativeWindow_CreateNativeWindowFromSurfaceId(uint64_t, OHNativeWindow **);
void OH_NativeWindow_DestroyNativeWindow(OHNativeWindow *);
int32_t OH_NativeWindow_SetColorSpace(OHNativeWindow *, OH_NativeBuffer_ColorSpace);
int32_t OH_NativeWindow_GetColorSpace(OHNativeWindow *, OH_NativeBuffer_ColorSpace *);
int32_t OH_NativeWindow_SetMetadataValue(OHNativeWindow *, OH_NativeBuffer_MetadataKey, int32_t, uint8_t *);
int32_t OH_NativeWindow_NativeWindowHandleOpt(OHNativeWindow *, int, ...);
