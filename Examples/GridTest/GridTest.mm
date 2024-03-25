#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <simd/simd.h>
#import "AnchoredScrollView.h"
#import "AnchoredDocumentView.h"
#import "AnchoredMetalDocumentLayer.h"
#import "Grid.h"
#import "GridLayerTypes.h"

static constexpr MTLPixelFormat _PixelFormat = MTLPixelFormatRGBA8Unorm;

@interface GridLayer : AnchoredMetalDocumentLayer
@end

static CGColorSpaceRef _LinearSRGBColorSpace() {
    static CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
    return cs;
}

@implementation GridLayer {
@private
    id<MTLDevice> _device;
    id<MTLLibrary> _library;
    id<MTLCommandQueue> _commandQueue;
    id<MTLTexture> _imageTexture;
    
    id<MTLFunction> _vertexShader;
    id<MTLFunction> _fragmentShader;
    id<MTLRenderPipelineState> _pipelineState;
    
    CGFloat _containerWidth;
    Grid _grid;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    
    [self setPresentsWithTransaction:true];
    
    _device = [self preferredDevice];
    assert(_device);
    
    [self setDevice:[self preferredDevice]];
    [self setPixelFormat:_PixelFormat];
    [self setColorspace:_LinearSRGBColorSpace()];
    
    _library = [_device newDefaultLibrary];
    _commandQueue = [_device newCommandQueue];
    
    _vertexShader = [_library newFunctionWithName:@"VertexShader"];
    assert(_vertexShader);
    
    _fragmentShader = [_library newFunctionWithName:@"FragmentShader"];
    assert(_fragmentShader);
    
    MTLRenderPipelineDescriptor* pipelineDescriptor = [MTLRenderPipelineDescriptor new];
    [pipelineDescriptor setVertexFunction:_vertexShader];
    [pipelineDescriptor setFragmentFunction:_fragmentShader];
    
    [[pipelineDescriptor colorAttachments][0] setPixelFormat:_PixelFormat];
    [[pipelineDescriptor colorAttachments][0] setBlendingEnabled:true];
    
    [[pipelineDescriptor colorAttachments][0] setAlphaBlendOperation:MTLBlendOperationAdd];
    [[pipelineDescriptor colorAttachments][0] setSourceAlphaBlendFactor:MTLBlendFactorSourceAlpha];
    [[pipelineDescriptor colorAttachments][0] setDestinationAlphaBlendFactor:MTLBlendFactorOneMinusSourceAlpha];

    [[pipelineDescriptor colorAttachments][0] setRgbBlendOperation:MTLBlendOperationAdd];
    [[pipelineDescriptor colorAttachments][0] setSourceRGBBlendFactor:MTLBlendFactorSourceAlpha];
    [[pipelineDescriptor colorAttachments][0] setDestinationRGBBlendFactor:MTLBlendFactorOneMinusSourceAlpha];
    
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:nil];
    assert(_pipelineState);
    
    _grid.setCellSize({160, 90});
    _grid.setCellSpacing({6, 6});
    
    _grid.setBorderSize({
        .left   = 10,
        .right  = 10,
        .top    = 10,
        .bottom = 10,
    });
    
    _grid.setElementCount(100);
    
    return self;
}

static Grid::Rect _GridRectFromCGRect(CGRect rect, CGFloat scale) {
    const CGRect irect = CGRectIntegral({
        rect.origin.x*scale,
        rect.origin.y*scale,
        rect.size.width*scale,
        rect.size.height*scale,
    });
    
    return Grid::Rect{
        .point = {(int32_t)irect.origin.x, (int32_t)irect.origin.y},
        .size = {(int32_t)irect.size.width, (int32_t)irect.size.height},
    };
}

static Grid::IndexRange _VisibleIndexRange(Grid& grid, CGRect frame, CGFloat scale) {
    return grid.indexRangeForIndexRect(grid.indexRectForRect(_GridRectFromCGRect(frame, scale)));
}

- (void)display {
    [super display];
    
    id<CAMetalDrawable> drawable = [self nextDrawable];
    assert(drawable);
    id<MTLTexture> drawableTxt = [drawable texture];
    assert(drawableTxt);
    
//    [self frame].size.width*contentsScale
//    [[self enclosingScrollView] bounds].size.width
//    [_imageGridLayer setContainerWidth:[drawableTxt width]];
    
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    
    {
        MTLRenderPassDescriptor* renderPassDescriptor = [MTLRenderPassDescriptor new];
        [[renderPassDescriptor colorAttachments][0] setTexture:drawableTxt];
        [[renderPassDescriptor colorAttachments][0] setLoadAction:MTLLoadActionClear];
        [[renderPassDescriptor colorAttachments][0] setClearColor:{0,0,0,1}];
        [[renderPassDescriptor colorAttachments][0] setStoreAction:MTLStoreActionStore];
        
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        [renderEncoder setRenderPipelineState:_pipelineState];
        [renderEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [renderEncoder setCullMode:MTLCullModeNone];
        [renderEncoder endEncoding];
    }
    
    {
        const CGRect frame = [self frame];
        const CGFloat contentsScale = [self contentsScale];
        const CGSize superlayerSize = [[self superlayer] bounds].size;
        const CGSize viewSize = {superlayerSize.width*contentsScale, superlayerSize.height*contentsScale};
        const Grid::IndexRange visibleIndexRange = _VisibleIndexRange(_grid, frame, contentsScale);
        if (!visibleIndexRange.count) return;
        
        MTLRenderPassDescriptor* renderPassDescriptor = [MTLRenderPassDescriptor new];
        [[renderPassDescriptor colorAttachments][0] setTexture:drawableTxt];
        [[renderPassDescriptor colorAttachments][0] setLoadAction:MTLLoadActionLoad];
        [[renderPassDescriptor colorAttachments][0] setStoreAction:MTLStoreActionStore];
        
//        const uintptr_t imageRefsBegin = (uintptr_t)&*_imageLibrary->begin();
//        const uintptr_t imageRefsEnd = (uintptr_t)&*_imageLibrary->end();
//        id<MTLBuffer> imageRefs = [_device newBufferWithBytes:(void*)imageRefsBegin
//            length:imageRefsEnd-imageRefsBegin options:MTLResourceCPUCacheModeDefaultCache|MTLResourceStorageModeShared];
//        
//        const auto begin = ImageLibrary::BeginSorted(*_imageLibrary, _sortNewestFirst);
//        const auto [visibleBegin, visibleEnd] = _VisibleRange(visibleIndexRange, *_imageLibrary, _sortNewestFirst);
//        
//        // Update stale _ChunkTexture slices from the ImageRecord's thumbnail data, if needed. (We know whether a
//        // _ChunkTexture slice is stale by using ImageRecord's loadCount.)
//        const auto chunkBegin = it;
//        _ChunkTexture& ct = [self _getChunkTexture:it];
//        for (; it!=visibleEnd && it->chunk==chunkBegin->chunk; it++) {
//            _ChunkTextureUpdateSlice(ct, *it);
//        }
//        const auto chunkEnd = it;
//        
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        [renderEncoder setRenderPipelineState:_pipelineState];
        [renderEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [renderEncoder setCullMode:MTLCullModeNone];
        
        const RenderContext ctx = {
            .grid = _grid,
            .viewSize = {(float)viewSize.width, (float)viewSize.height},
            .transform = [self anchoredTransform],
        };
        
        [renderEncoder setVertexBytes:&ctx length:sizeof(ctx) atIndex:0];
//        [renderEncoder setVertexBuffer:imageRefs offset:0 atIndex:1];
        
        [renderEncoder setFragmentBytes:&ctx length:sizeof(ctx) atIndex:0];
//        [renderEncoder setFragmentBytes:&ct.loadCounts length:sizeof(ct.loadCounts) atIndex:1];
//        [renderEncoder setFragmentTexture:ct.txt atIndex:0];
        
        [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
            vertexCount:6 instanceCount:_grid.elementCount()];
        
        [renderEncoder endEncoding];
    }
    
    
    
    
    
    
    
    
    
//    {
//        MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor new];
//        [[desc colorAttachments][0] setTexture:drawableTxt];
//        [[desc colorAttachments][0] setClearColor:{0,0,0,1}];
//        [[desc colorAttachments][0] setLoadAction:MTLLoadActionLoad];
//        [[desc colorAttachments][0] setStoreAction:MTLStoreActionStore];
//        id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:desc];
//        
//        [enc setRenderPipelineState:_pipelineState];
//        [enc setFrontFacingWinding:MTLWindingCounterClockwise];
//        [enc setCullMode:MTLCullModeNone];
//        
//        const simd_float4x4 transform = [self anchoredTransform];
//        [enc setVertexBytes:&transform length:sizeof(transform) atIndex:0];
//        [enc setFragmentTexture:_imageTexture atIndex:0];
//        
//        [enc drawPrimitives:MTLPrimitiveTypeTriangle
//            vertexStart:0
//            vertexCount:6
//            instanceCount:1];
//        
//        [enc endEncoding];
//    }
    
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    [drawable present];
}

- (bool)anchoredFlipped {
    return true;
}

- (CGSize)preferredFrameSize {
    return {640, 480};
}

- (void)setContainerWidth:(CGFloat)x {
    _containerWidth = x;
    _grid.setContainerWidth((int32_t)lround(_containerWidth * [self contentsScale]));
}

- (CGFloat)containerHeight {
    return _grid.containerHeight() / [self contentsScale];
}

@end

@interface GridView : AnchoredDocumentView
@end

@implementation GridView {
    GridLayer* _layer;
    NSLayoutConstraint* _docHeight;
}

- (instancetype)init {
    _layer = [GridLayer new];
    if (!(self = [super initWithAnchoredLayer:_layer])) return nil;
    
    [self setTranslatesAutoresizingMaskIntoConstraints:false];
    return self;
}

- (void)_updateDocumentHeight {
    [_layer setContainerWidth:[[self enclosingScrollView] bounds].size.width];
    [_docHeight setConstant:[_layer containerHeight]];
}

// MARK: - AnchoredScrollView

- (void)anchoredCreateConstraintsForContainer:(NSView*)container {
    NSView*const containerSuperview = [container superview];
    if (!containerSuperview) return;
    
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[container]|"
        options:0 metrics:nil views:NSDictionaryOfVariableBindings(container)]];
    
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[container]"
        options:0 metrics:nil views:NSDictionaryOfVariableBindings(container)]];
    
    NSLayoutConstraint* docHeightMin = [NSLayoutConstraint constraintWithItem:container attribute:NSLayoutAttributeHeight
        relatedBy:NSLayoutRelationGreaterThanOrEqual toItem:containerSuperview attribute:NSLayoutAttributeHeight
        multiplier:1 constant:0];
    [docHeightMin setActive:true];
    
    _docHeight = [NSLayoutConstraint constraintWithItem:container attribute:NSLayoutAttributeHeight
        relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute
        multiplier:1 constant:0];
    // _docHeight isn't Required because `docHeightMin` needs to override it
    // We're priority==Low instead of High, because using High affects our
    // window size for some reason.
    [_docHeight setPriority:NSLayoutPriorityDefaultLow];
    [_docHeight setActive:true];
}

@end

@interface ScrollView : AnchoredScrollView
@end

@implementation ScrollView

- (instancetype)init {
    if (!(self = [super initWithAnchoredDocument:[GridView new]])) return nil;
    return self;
}

- (void)layout {
    [super layout];
    GridView*const gridView = (GridView*)[self document];
    [gridView _updateDocumentHeight];
}

@end

@interface MainView : NSView
@end

@implementation MainView

static void _Init(MainView* self) {
    ScrollView* sv = [ScrollView new];
    [self addSubview:sv];
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[sv]|"
        options:0 metrics:nil views:NSDictionaryOfVariableBindings(sv)]];
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[sv]|"
        options:0 metrics:nil views:NSDictionaryOfVariableBindings(sv)]];
}

- (instancetype)initWithCoder:(NSCoder*)coder {
    if (!(self = [super initWithCoder:coder])) return nil;
    _Init(self);
    return self;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _Init(self);
    return self;
}

@end

int main(int argc, const char* argv[]) {
    return NSApplicationMain(argc, argv);
}
