#pragma once
#import <simd/simd.h>
#import "Grid.h"

struct RenderContext {
    Grid grid;
    uint32_t idx = 0;
    simd::float2 viewSize = {};
    simd::float4x4 transform = {};
};
