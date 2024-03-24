#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <simd/simd.h>
#import "AnchoredScrollView.h"
#import "AnchoredDocumentView.h"
#import "AnchoredMetalDocumentLayer.h"

static constexpr MTLPixelFormat _PixelFormat = MTLPixelFormatRGBA8Unorm;

@interface MyDocLayer : AnchoredMetalDocumentLayer
@end

static CGColorSpaceRef _LinearSRGBColorSpace() {
    static CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
    return cs;
}

@implementation MyDocLayer {
@private
    id<MTLDevice> _device;
    id<MTLLibrary> _library;
    id<MTLCommandQueue> _commandQueue;
    id<MTLTexture> _imageTexture;
    
    id<MTLFunction> _vertexShader;
    id<MTLFunction> _fragmentShader;
    id<MTLRenderPipelineState> _pipelineState;
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
    
    MTKTextureLoader* loader = [[MTKTextureLoader alloc] initWithDevice:_device];
    _imageTexture = [loader newTextureWithContentsOfURL:[[NSBundle mainBundle] URLForImageResource:@"TestImage"] options:nil error:nil];
    assert(_imageTexture);
    
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
    
    return self;
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
        [[renderPassDescriptor colorAttachments][0] setClearColor:{}];
        [[renderPassDescriptor colorAttachments][0] setStoreAction:MTLStoreActionStore];
        
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        [renderEncoder setRenderPipelineState:_pipelineState];
        [renderEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [renderEncoder setCullMode:MTLCullModeNone];
        [renderEncoder endEncoding];
    }
    
    {
        MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor new];
        [[desc colorAttachments][0] setTexture:drawableTxt];
        [[desc colorAttachments][0] setClearColor:{0,0,0,1}];
        [[desc colorAttachments][0] setLoadAction:MTLLoadActionLoad];
        [[desc colorAttachments][0] setStoreAction:MTLStoreActionStore];
        id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:desc];
        
        [enc setRenderPipelineState:_pipelineState];
        [enc setFrontFacingWinding:MTLWindingCounterClockwise];
        [enc setCullMode:MTLCullModeNone];
        
        const simd_float4x4 transform = [self anchoredTransform];
        [enc setVertexBytes:&transform length:sizeof(transform) atIndex:0];
        [enc setFragmentTexture:_imageTexture atIndex:0];
        
        [enc drawPrimitives:MTLPrimitiveTypeTriangle
            vertexStart:0
            vertexCount:6
            instanceCount:1];
        
        [enc endEncoding];
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

@end

@interface MyDocView : AnchoredDocumentView
@end

@implementation MyDocView

- (NSRect)rectForSmartMagnificationAtPoint:(NSPoint)point inRect:(NSRect)rect {
    const bool fit = [(AnchoredScrollView*)[self enclosingScrollView] magnifyToFit];
    if (fit) {
        return CGRectInset({point, {0,0}}, -20, -20);
    } else {
        return [[self superview] bounds];
    }
}

@end

@interface MyScrollView : AnchoredScrollView
@end

@implementation MyScrollView

- (instancetype)init {
    AnchoredDocumentView* anchoredDocView = [[MyDocView alloc] initWithAnchoredLayer:[MyDocLayer new]];
    if (!(self = [super initWithAnchoredDocument:anchoredDocView])) return nil;
    return self;
}

@end

@interface MainView : NSView
@end

@implementation MainView

static void _Init(MainView* self) {
    MyScrollView* sv = [MyScrollView new];
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
