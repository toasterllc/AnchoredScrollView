#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <simd/simd.h>
#import <algorithm>
#import "AnchoredScrollView.h"
#import "AnchoredDocumentView.h"
#import "AnchoredMetalDocumentLayer.h"
#import "Grid.h"
#import "GridLayerTypes.h"

static constexpr MTLPixelFormat _PixelFormat = MTLPixelFormatRGBA8Unorm;

static constexpr CGSize _CellSizeDefault = { 160, 90 };
static constexpr CGSize _CellSpacingDefault = { 10, 10 };

@interface GridLayer : AnchoredMetalDocumentLayer
@end

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
    float _cellScale;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    
    [self setPresentsWithTransaction:true];
    
    _device = [self preferredDevice];
    assert(_device);
    
    [self setDevice:[self preferredDevice]];
    [self setPixelFormat:_PixelFormat];
    [self setColorspace:(__bridge CGColorSpaceRef)CFBridgingRelease(CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB))];
    
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
    
//    _grid.setCellSize({160, 90});
//    _grid.setCellSpacing({6, 6});
    
    _grid.setBorderSize({
        .left   = 10,
        .right  = 10,
        .top    = 10,
        .bottom = 10,
    });
    
    _grid.setElementCount(1000000);
//    _grid.setElementCount(10000);
    
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

- (void)setCellScale:(float)x {
    constexpr float CellScaleMin = 0.025;
    constexpr float CellScaleMax = 5.0;
    x *= CellScaleMax;
    x = std::max(CellScaleMin, x);
//    x = std::clamp(x, 0.025f, 1.0f);
    
    _grid.setCellSize({
        (int32_t)std::round(_CellSizeDefault.width*x),
        (int32_t)std::round(_CellSizeDefault.height*x)
    });
    
    _grid.setCellSpacing({
        (int32_t)std::round(_CellSpacingDefault.width*x),
        (int32_t)std::round(_CellSpacingDefault.height*x)
    });
    
    [self setNeedsDisplay];
    
//    _grid.setCellSize()
//    printf("setCellSize:\n");
}

- (void)display {
    [super display];
    
    id<CAMetalDrawable> drawable = [self nextDrawable];
    assert(drawable);
    id<MTLTexture> drawableTxt = [drawable texture];
    assert(drawableTxt);
    
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
        
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        [renderEncoder setRenderPipelineState:_pipelineState];
        [renderEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [renderEncoder setCullMode:MTLCullModeNone];
        
        const RenderContext ctx = {
            .grid = _grid,
            .idx = (uint32_t)visibleIndexRange.start,
            .viewSize = {(float)viewSize.width, (float)viewSize.height},
            .transform = [self anchoredTransform],
        };
        
        [renderEncoder setVertexBytes:&ctx length:sizeof(ctx) atIndex:0];
//        [renderEncoder setVertexBuffer:imageRefs offset:0 atIndex:1];
        
        [renderEncoder setFragmentBytes:&ctx length:sizeof(ctx) atIndex:0];
//        [renderEncoder setFragmentBytes:&ct.loadCounts length:sizeof(ct.loadCounts) atIndex:1];
//        [renderEncoder setFragmentTexture:ct.txt atIndex:0];
        
        [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
            vertexCount:6 instanceCount:visibleIndexRange.count];
        
        [renderEncoder endEncoding];
    }
    
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

@implementation MainView {
    IBOutlet NSSlider* _slider;
    ScrollView* _scrollView;
}

- (void)awakeFromNib {
    _scrollView = [ScrollView new];
    [self addSubview:_scrollView];
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[_scrollView]|"
        options:0 metrics:nil views:NSDictionaryOfVariableBindings(_scrollView)]];
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[_scrollView]|"
        options:0 metrics:nil views:NSDictionaryOfVariableBindings(_scrollView)]];
    
    [self _sliderAction:nil];
}

- (IBAction)_sliderAction:(id)sender {
    GridLayer*const layer = (GridLayer*)[[_scrollView document] layer];
    [layer setCellScale:[_slider floatValue]];
    [_scrollView setNeedsLayout:true];
}

@end

int main(int argc, const char* argv[]) {
    return NSApplicationMain(argc, argv);
}
