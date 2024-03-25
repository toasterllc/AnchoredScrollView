#import <metal_stdlib>
#import "GridLayerTypes.h"
using namespace metal;

struct VertexOutput {
    uint idx;
    float4 posView [[position]];
    float2 posNorm;
    float2 posPx;
};

static constexpr constant float2 _Verts[6] = {
    {0, 0},
    {0, 1},
    {1, 0},
    {1, 0},
    {0, 1},
    {1, 1},
};

vertex VertexOutput VertexShader(
    constant RenderContext& ctx [[buffer(0)]],
    uint vidx [[vertex_id]],
    uint iidx [[instance_id]]
) {
    // idxGrid: absolute index in grid
    const uint idxGrid = ctx.idx + iidx;
    const Toastbox::Grid::Rect rect = ctx.grid.rectForCellIndex(idxGrid);
    const int2 voff = int2(rect.size.x, rect.size.y) * int2(_Verts[vidx]);
    const int2 vabs = int2(rect.point.x, rect.point.y) + voff;
    const float2 vnorm = float2(vabs) / ctx.viewSize;
    
    return VertexOutput{
        .idx = iidx,
        .posView = ctx.transform * float4(vnorm, 0, 1),
        .posNorm = _Verts[vidx],
        .posPx = float2(voff),
    };
}

fragment float4 FragmentShader(
    constant RenderContext& ctx [[buffer(0)]],
    texture2d_array<float> txt [[texture(1)]],
    VertexOutput in [[stage_in]]
) {
    return txt.sample({}, in.posNorm, in.idx);
//    const uint2 pos = uint2(in.posPx);
//    return txt.read(pos, in.idx);
//    return float4(1,1,1,1);
//    const uint2 pos = uint2(in.posPx);
//    float3 c = txt.read(pos, in.idx).rgb;
//    return float4(c, 1);
}
