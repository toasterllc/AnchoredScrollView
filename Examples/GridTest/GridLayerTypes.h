#pragma once
#import <simd/simd.h>
#import "Lib/Toastbox/Mac/Grid.h"

struct RenderContext {
    Toastbox::Grid grid;
    uint32_t idx = 0;
    simd::float2 viewSize = {};
    simd::float4x4 transform = {};
};
