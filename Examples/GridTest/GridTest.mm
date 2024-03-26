#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <simd/simd.h>
#import <algorithm>
#import <thread>
#import <filesystem>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <AppleTextureEncoder.h>
#import "AnchoredScrollView.h"
#import "AnchoredDocumentView.h"
#import "AnchoredMetalDocumentLayer.h"
#import "Grid.h"
#import "GridLayerTypes.h"
#import "Lib/Toastbox/Util.h"
#import "Lib/Toastbox/Mac/Renderer.h"
#import "Lib/Toastbox/Mmap.h"
#import "Lib/Toastbox/LRU.h"
namespace fs = std::filesystem;

struct _TextureArray {
    static constexpr size_t Count = 128;
    id<MTLTexture> txt = nil;
};

static constexpr size_t _ImageWidth = 160;
static constexpr size_t _ImageHeight = 90;
static constexpr size_t _ImageCount = 1<<18;
// _ImageCount must be an even multiple of _TextureArray::Count
static_assert(!(_ImageCount % _TextureArray::Count));

using _ImageStorage = std::array<uint8_t, _ImageWidth*_ImageHeight*4>;
using _ImageStoragePtr = std::unique_ptr<_ImageStorage>;
using _ImageCompressedStorage = std::array<uint8_t, _ImageWidth*_ImageHeight>;
using _ImageCompressedStoragePtr = std::unique_ptr<_ImageCompressedStorage>;

static constexpr MTLPixelFormat _PixelFormat = MTLPixelFormatRGBA8Unorm;

#if defined(__aarch64__)
    static constexpr MTLPixelFormat _PixelFormatCompressed = MTLPixelFormatASTC_4x4_LDR;
#elif defined(__x86_64__)
    static constexpr MTLPixelFormat _PixelFormatCompressed = MTLPixelFormatBC7_RGBAUnorm;
#else
    #error Unknown platform
#endif

static constexpr CGSize _CellSizeDefault = { _ImageWidth, _ImageHeight };
static constexpr CGSize _CellSpacingDefault = { 10, 10 };

static Toastbox::Mmap _ImagesMmap;

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
    
    Toastbox::LRU<uint32_t,_TextureArray,8> _txts;
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
    
    _grid.setElementCount(_ImageCount);
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
    
    _grid.setCellSize({
        (int32_t)std::round(_CellSizeDefault.width*x),
        (int32_t)std::round(_CellSizeDefault.height*x)
    });
    
    _grid.setCellSpacing({
        (int32_t)std::round(_CellSpacingDefault.width*x),
        (int32_t)std::round(_CellSpacingDefault.height*x)
    });
    
    [self setNeedsDisplay];
}

static MTLTextureDescriptor* _TextureDescriptor() {
    MTLTextureDescriptor* desc = [MTLTextureDescriptor new];
    [desc setTextureType:MTLTextureType2DArray];
    [desc setPixelFormat:_PixelFormatCompressed];
    [desc setWidth:_ImageWidth];
    [desc setHeight:_ImageHeight];
    [desc setArrayLength:_TextureArray::Count];
    return desc;
}

- (_TextureArray&)_getTextureArray:(uint32_t)idx {
    assert(!(idx % _TextureArray::Count));
    
    // If we already have a _TextureArray for `idx`, return it.
    // Otherwise we need to create it.
    const auto it = _txts.find(idx);
    if (it != _txts.end()) {
        return it->val;
    }
    
    auto startTime = std::chrono::steady_clock::now();
    
    static MTLTextureDescriptor* txtDesc = _TextureDescriptor();
    id<MTLTexture> txt = [_device newTextureWithDescriptor:txtDesc];
    assert(txt);
    
    _TextureArray& ta = _txts[idx];
    ta.txt = txt;
    
    for (size_t i=0; i<_TextureArray::Count; i++) {
        const uint8_t* b = _ImagesMmap.data((idx+i)*sizeof(_ImageCompressedStorage), sizeof(_ImageCompressedStorage));
//        printf("generating texture @ %zu\n", idx+i);
        [txt replaceRegion:MTLRegionMake2D(0,0,_ImageWidth,_ImageHeight) mipmapLevel:0
            slice:i withBytes:b bytesPerRow:_ImageWidth*4 bytesPerImage:0];
    }
    
    auto durationMs = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-startTime).count();
    printf("Texture creation took %ju ms\n", (uintmax_t)durationMs);
    
    return ta;
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
//        id<MTLBuffer> imagesBuf = [_device newBufferWithBytes:(void*)_ImagesMmap.data()
//            length:_ImagesMmap.len() options:MTLResourceCPUCacheModeDefaultCache|MTLResourceStorageModeShared];
//        
//        MTLTextureDescriptor* desc = [MTLTextureDescriptor new];
//        [desc setTextureType:MTLTextureType2DArray];
//        [desc setPixelFormat:_PixelFormat];
//        [desc setWidth:_ImageWidth];
//        [desc setHeight:_ImageHeight];
//        [desc setArrayLength:10];
//        
//        id<MTLTexture> imagesTxt = [imagesBuf newTextureWithDescriptor:desc offset:0 bytesPerRow:_ImageWidth*4];
        
        const CGRect frame = [self frame];
        const CGFloat contentsScale = [self contentsScale];
        const CGSize superlayerSize = [[self superlayer] bounds].size;
        const CGSize viewSize = {superlayerSize.width*contentsScale, superlayerSize.height*contentsScale};
        const Grid::IndexRange visibleIndexRange = _VisibleIndexRange(_grid, frame, contentsScale);
        if (!visibleIndexRange.count) return;
        
        uint32_t i = (visibleIndexRange.start / _TextureArray::Count) * _TextureArray::Count;
        for (; i<visibleIndexRange.start+visibleIndexRange.count; i+=_TextureArray::Count) {
            MTLRenderPassDescriptor* renderPassDescriptor = [MTLRenderPassDescriptor new];
            [[renderPassDescriptor colorAttachments][0] setTexture:drawableTxt];
            [[renderPassDescriptor colorAttachments][0] setLoadAction:MTLLoadActionLoad];
            [[renderPassDescriptor colorAttachments][0] setStoreAction:MTLStoreActionStore];
            
    //        id<MTLTexture>* textures = nil;
            
            id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
            [renderEncoder setRenderPipelineState:_pipelineState];
            [renderEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
            [renderEncoder setCullMode:MTLCullModeNone];
            
            const RenderContext ctx = {
                .grid = _grid,
                .idx = (uint32_t)i,
                .viewSize = {(float)viewSize.width, (float)viewSize.height},
                .transform = [self anchoredTransform],
            };
            
            [renderEncoder setVertexBytes:&ctx length:sizeof(ctx) atIndex:0];
    //        [renderEncoder setVertexBuffer:imageRefs offset:0 atIndex:1];
            
    //        [ct.txt replaceRegion:MTLRegionMake2D(0,0,ImageThumb::ThumbWidth,ImageThumb::ThumbHeight) mipmapLevel:0
    //            slice:ref.idx withBytes:b bytesPerRow:ImageThumb::ThumbWidth*4 bytesPerImage:0];
            
//            id<MTLTexture> txt = [_device newTextureWithDescriptor:_TextureDescriptor()];
//            for (auto i=visibleIndexRange.start; i<visibleIndexRange.start+visibleIndexRange.count; i++) {
//                const uint8_t* b = _ImagesMmap.data() + i*sizeof(_ImageCompressedStorage);
//    //            const uint8_t* b = _ImagesMmap.data();
//                [txt replaceRegion:MTLRegionMake2D(0,0,_ImageWidth,_ImageHeight) mipmapLevel:0
//                    slice:i withBytes:b bytesPerRow:_ImageWidth*4 bytesPerImage:0];
//            }
            
    //        [ct.txt replaceRegion:MTLRegionMake2D(0,0,ImageThumb::ThumbWidth,ImageThumb::ThumbHeight) mipmapLevel:0
    //            slice:ref.idx withBytes:b bytesPerRow:ImageThumb::ThumbWidth*4 bytesPerImage:0];
            
            _TextureArray& ta = [self _getTextureArray:i];
            
            [renderEncoder setFragmentBytes:&ctx length:sizeof(ctx) atIndex:0];
    //        [renderEncoder setFragmentBytes:&ct.loadCounts length:sizeof(ct.loadCounts) atIndex:1];
            [renderEncoder setFragmentTexture:ta.txt atIndex:1];
    //        [renderEncoder setFragmentBuffer:imagesBuf offset:0 atIndex:1];
            
            [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                vertexCount:6 instanceCount:_TextureArray::Count];
            
            [renderEncoder endEncoding];

        }
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

static bool _IsImageFile(const fs::path& path) {
    return fs::is_regular_file(path) && (path.extension() == ".jpg" || path.extension() == ".png");
}

template<MTLPixelFormat T_Format>
static constexpr at_block_format_t _ATBlockFormatForMTLPixelFormat() {
// For compilation on macOS 10.15
#if MAC_OS_X_VERSION_MAX_ALLOWED <= MAC_OS_X_VERSION_10_15_1
    return at_block_format_bc7;
#else
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    if constexpr (T_Format == MTLPixelFormatASTC_4x4_LDR) {
        return at_block_format_astc_4x4_ldr;
    } else if constexpr (T_Format == MTLPixelFormatBC7_RGBAUnorm) {
        return at_block_format_bc7;
    } else {
        static_assert(Toastbox::AlwaysFalse_v<T_Format>);
    }
#pragma clang diagnostic pop
#endif
}

//static size_t _SamplesPerPixel(MTLPixelFormat fmt) {
//    switch (fmt) {
//    case MTLPixelFormatR8Unorm:         return 1;
//    case MTLPixelFormatR16Unorm:        return 1;
//    case MTLPixelFormatR32Float:        return 1;
//    case MTLPixelFormatRGBA8Unorm:      return 4;
//    case MTLPixelFormatRGBA8Unorm_sRGB: return 4;
//    case MTLPixelFormatBGRA8Unorm:      return 4;
//    case MTLPixelFormatBGRA8Unorm_sRGB: return 4;
//    case MTLPixelFormatRGBA16Unorm:     return 4;
//    case MTLPixelFormatRGBA16Float:     return 4;
//    case MTLPixelFormatRGBA32Float:     return 4;
//    default:                            throw std::runtime_error("invalid pixel format");
//    }
//}
//
//static size_t _BytesPerSample(MTLPixelFormat fmt) {
//    switch (fmt) {
//    case MTLPixelFormatR8Unorm:         return 1;
//    case MTLPixelFormatR16Unorm:        return 2;
//    case MTLPixelFormatR32Float:        return 4;
//    case MTLPixelFormatRGBA8Unorm:      return 1;
//    case MTLPixelFormatRGBA8Unorm_sRGB: return 1;
//    case MTLPixelFormatBGRA8Unorm:      return 1;
//    case MTLPixelFormatBGRA8Unorm_sRGB: return 1;
//    case MTLPixelFormatRGBA16Unorm:     return 2;
//    case MTLPixelFormatRGBA16Float:     return 2;
//    case MTLPixelFormatRGBA32Float:     return 4;
//    default:                            throw std::runtime_error("invalid pixel format");
//    }
//}
//
//static size_t _BytesPerPixel(MTLPixelFormat fmt) {
//    return _SamplesPerPixel(fmt)*_BytesPerSample(fmt);
//}
//
//static id /* CGColorSpaceRef */ _LinearGrayColorSpace() {
//    static id /* CGColorSpaceRef */ cs = CFBridgingRelease(CGColorSpaceCreateWithName(kCGColorSpaceLinearGray));
//    return cs;
//}
//
//static id /* CGColorSpaceRef */ _SRGBColorSpace() {
//    static id /* CGColorSpaceRef */ cs = CFBridgingRelease(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
//    return cs;
//}
//
//static id /* CGColorSpaceRef */ _LinearSRGBColorSpace() {
//    static id /* CGColorSpaceRef */ cs = CFBridgingRelease(CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB));
//    return cs;
//}
//
//id<MTLTexture> _TextureCreate(
//    id<MTLDevice> dev,
//    MTLPixelFormat fmt,
//    size_t width, size_t height,
//    MTLTextureUsage usage=(MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead)
//) {
//    // We don't have a cached texture matching the criteria, so create a new one
//    MTLTextureDescriptor* desc = [MTLTextureDescriptor new];
//    [desc setTextureType:MTLTextureType2D];
//    [desc setWidth:width];
//    [desc setHeight:height];
//    [desc setPixelFormat:fmt];
//    [desc setUsage:usage];
//    return [dev newTextureWithDescriptor:desc];
//}
//
//// Read samples from a texture
//template <typename T>
//std::vector<T> _TextureRead(id<MTLTexture> txt) {
//    const size_t w = [txt width];
//    const size_t h = [txt height];
//    const MTLPixelFormat fmt = [txt pixelFormat];
//    const size_t samplesPerPixel = _SamplesPerPixel(fmt);
//    const size_t len = samplesPerPixel*w*h;
//    std::vector<T> r;
//    r.resize(len);
//    textureRead(txt, r.data(), len, MTLRegionMake2D(0,0,w,h));
//    return r;
//}
//
//// Read samples from a texture
//template <typename T>
//void _TextureRead(id<MTLTexture> txt, T* samples, size_t cap) {
//    const size_t w = [txt width];
//    const size_t h = [txt height];
//    _TextureRead(txt, samples, cap, MTLRegionMake2D(0,0,w,h));
//}
//
//// Read samples from a texture
//template <typename T>
//void _TextureRead(id<MTLTexture> txt, T* samples, size_t cap, MTLRegion region) {
//    const MTLPixelFormat fmt = [txt pixelFormat];
//    const size_t samplesPerPixel = _SamplesPerPixel(fmt);
//    assert(cap >= samplesPerPixel*region.size.width*region.size.height);
//    const size_t bytesPerSample = _BytesPerSample(fmt);
//    assert(bytesPerSample == sizeof(T));
//    const size_t bytesPerRow = samplesPerPixel*bytesPerSample*region.size.width;
//    [txt getBytes:samples bytesPerRow:bytesPerRow fromRegion:region mipmapLevel:0];
//}
//
//// Create a CGImage from a texture
//id /* CGImageRef */ _ImageCreate(id<MTLDevice> dev, id<MTLTexture> txt) {
//    const size_t w = [txt width];
//    const size_t h = [txt height];
//    const MTLPixelFormat fmt = [txt pixelFormat];
//    const size_t samplesPerPixel = _SamplesPerPixel(fmt);
//    const size_t bytesPerSample = _BytesPerSample(fmt);
//    const size_t sampleCount = samplesPerPixel*w*h;
//    const size_t bytesPerRow = samplesPerPixel*bytesPerSample*w;
//    uint32_t opts = 0;
//    
//    // Add support for more pixel formats as needed...
//    bool premulAlpha = false;
//    bool srgbGammaApplied = false;
//    switch (fmt) {
//    // Gray
//    case MTLPixelFormatR8Unorm:
//        opts = 0;
//        break;
//    case MTLPixelFormatR16Unorm:
//        opts = kCGBitmapByteOrder16Host;
//        break;
//    case MTLPixelFormatR16Float:
//        opts = kCGBitmapFloatComponents|kCGBitmapByteOrder16Host;
//        break;
//    case MTLPixelFormatR32Float:
//        opts = kCGBitmapFloatComponents|kCGBitmapByteOrder32Host;
//        break;
//    
//    // Color
//    case MTLPixelFormatRGBA8Unorm:
//        opts = kCGImageAlphaPremultipliedLast;
//        premulAlpha = true;
//        break;
//    case MTLPixelFormatRGBA8Unorm_sRGB:
//        opts = kCGImageAlphaPremultipliedLast;
//        premulAlpha = true;
//        srgbGammaApplied = true;
//        break;
//    case MTLPixelFormatRGBA16Unorm:
//        opts = kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder16Host;
//        premulAlpha = true;
//        break;
//    case MTLPixelFormatRGBA16Float:
//        opts = kCGImageAlphaPremultipliedLast|kCGBitmapFloatComponents|kCGBitmapByteOrder16Host;
//        premulAlpha = true;
//        break;
//    case MTLPixelFormatRGBA32Float:
//        opts = kCGImageAlphaPremultipliedLast|kCGBitmapFloatComponents|kCGBitmapByteOrder32Host;
//        premulAlpha = true;
//        break;
//    default:
//        throw std::runtime_error("invalid texture format");
//    }
//    
//    if (premulAlpha) {
//        // Load pixel data into `txt`
//        id<MTLTexture> tmp = _TextureCreate(dev, fmt, w, h);
//        render(tmp, BlendType::None,
//            FragmentShader(
//                _ShaderNamespace "PremulAlpha",
//                // Texture args
//                txt
//            )
//        );
//        _Sync(tmp);
//        _CommitAndWait(cmdBuf);
//        txt = tmp;
//    }
//    
//    // Choose a colorspace if one wasn't supplied
//    id /* CGColorSpaceRef */ colorSpace = nil;
//    if (samplesPerPixel == 1) {
//        colorSpace = _LinearGrayColorSpace();
//    } else if (samplesPerPixel == 4) {
//        if (srgbGammaApplied) {
//            colorSpace = _SRGBColorSpace();
//        } else {
//            colorSpace = _LinearSRGBColorSpace();
//        }
//    } else {
//        throw std::runtime_error("invalid texture format");
//    }
//    
//    id ctx = CFBridgingRelease(CGBitmapContextCreate(nullptr, w, h, bytesPerSample*8,
//        bytesPerRow, (CGColorSpaceRef)colorSpace, opts));
//    
//    if (!ctx) throw std::runtime_error("CGBitmapContextCreate returned nil");
//    
//    void* data = CGBitmapContextGetData((CGContextRef)ctx);
//    if (bytesPerSample == 1)        _TextureRead(txt, (uint8_t*)data, sampleCount);
//    else if (bytesPerSample == 2)   _TextureRead(txt, (uint16_t*)data, sampleCount);
//    else if (bytesPerSample == 4)   _TextureRead(txt, (uint32_t*)data, sampleCount);
//    else                            throw std::runtime_error("invalid bytesPerSample");
//    return CFBridgingRelease(CGBitmapContextCreateImage((CGContextRef)ctx));
//}
//
//static void _CommitAndWait(id<MTLCommandBuffer> cmdBuf) {
//    if (!cmdBuf) return;
//    [cmdBuf commit];
//    [cmdBuf waitUntilCompleted];
//}
//
//static void _Sync(id<MTLCommandBuffer> cmdBuf, id<MTLResource> rsrc) {
//    id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
//    [blit synchronizeResource:rsrc];
//    [blit endEncoding];
//}
//
//static void _DebugTextureShow(id<MTLCommandBuffer> cmdBuf, id<MTLTexture> txt) {
//    const char* outputPath = "/tmp/tempimage.png";
//    
//    _Sync(cmdBuf, txt);
//    _CommitAndWait(cmdBuf);
//    
//    id img = imageCreate(txt);
//    assert(img);
//    NSURL* outputURL = [NSURL fileURLWithPath:@(outputPath)];
//    CGImageDestinationRef imageDest = CGImageDestinationCreateWithURL((CFURLRef)outputURL, kUTTypePNG, 1, nullptr);
//    CGImageDestinationAddImage(imageDest, (__bridge CGImageRef)img, nullptr);
//    CGImageDestinationFinalize(imageDest);
//    system((std::string("open ") + outputPath).c_str());
//}

int main(int argc, const char* argv[]) {
    std::mutex imagesLock;
    std::vector<_ImageCompressedStoragePtr> images;
    
    printf("Loading source images...\n");
    {
        std::vector<fs::path> imagePaths;
        const fs::path imagesDir = "/Users/dave/Desktop/TestImages-5k";
//        const fs::path imagesDir = "/Users/dave/repos/AnchoredScrollView/Examples/GridTest/images";
        for (const fs::path& p : fs::recursive_directory_iterator(imagesDir)) @autoreleasepool {
            if (!_IsImageFile(p)) continue;
            imagePaths.push_back(p);
        }
        
        std::atomic<size_t> pathIdx = 0;
        std::vector<std::thread> workers;
        const uint32_t threadCount = std::max(1,(int)std::thread::hardware_concurrency());
        for (uint32_t i=0; i<threadCount; i++) {
            workers.emplace_back([&](){
                id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
                Toastbox::Renderer renderer(dev, [dev newDefaultLibrary], [dev newCommandQueue]);
                MTKTextureLoader* txtLoader = [[MTKTextureLoader alloc] initWithDevice:dev];
                for (;;) @autoreleasepool {
                    const auto idx = pathIdx.fetch_add(1);
                    if (idx >= imagePaths.size()) break;
                    
                    const fs::path path = imagePaths.at(idx);
                    
                    constexpr MTLTextureUsage TxtUsage = MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
                    auto txt = renderer.textureCreate(MTLPixelFormatRGBA8Unorm, _ImageWidth, _ImageHeight, TxtUsage);
                    
                    {
                        NSURL* url = [NSURL fileURLWithPath:@(path.c_str())];
                        id<MTLTexture> src = [txtLoader newTextureWithContentsOfURL:url options:nil error:nil];
                        
                        // Calculate transform to fit source image in thumbnail aspect ratio
                        MPSScaleTransform transform;
                        {
                            const float srcAspect = (float)[src width] / [src height];
                            const float dstAspect = (float)_ImageWidth / _ImageHeight;
                            const float scale = (srcAspect<dstAspect ? ((float)_ImageWidth/[src width]) : ((float)_ImageHeight/[src height]));
                            transform = {
                                .scaleX = scale,
                                .scaleY = scale,
                                .translateX = 0,
                                .translateY = 0,
                            };
                        }
                        
                        // Scale image
                        {
                            MPSImageLanczosScale* filter = [[MPSImageLanczosScale alloc] initWithDevice:dev];
                            [filter setScaleTransform:&transform];
                            [filter encodeToCommandBuffer:renderer.cmdBuf() sourceTexture:src destinationTexture:txt];
                        }
                        renderer.commitAndWait();
                    }
                    
                    // Compress thumbnail into `imageCompressed`
                    _ImageCompressedStoragePtr imageCompressed = std::make_unique<_ImageCompressedStorage>();
                    {
                        _ImageStoragePtr image = std::make_unique<_ImageStorage>();
                        
            //            constexpr float CompressErrorThreshold = 0.0009765625;    // Fast
                        constexpr float CompressErrorThreshold = 0.00003051757812;  // High quality
                        
                        [txt getBytes:image.get() bytesPerRow:_ImageWidth*4
                            fromRegion:MTLRegionMake2D(0,0,_ImageWidth,_ImageHeight) mipmapLevel:0];
                        
                        const at_texel_region_t srcTexels = {
                            .texels = image.get(),
                            .validSize = {
                                .x = _ImageWidth,
                                .y = _ImageHeight,
                                .z = 1,
                            },
                            .rowBytes = _ImageWidth*4,
                            .sliceBytes = 0,
                        };
                        
                        const at_block_buffer_t dstBuffer = {
                            .blocks = imageCompressed.get(),
                            .rowBytes = _ImageWidth*4,
                            .sliceBytes = 0,
                        };
                        
                        at_encoder_t compressor = at_encoder_create(
                            at_texel_format_rgba8_unorm,
                            at_alpha_opaque,
                            _ATBlockFormatForMTLPixelFormat<_PixelFormatCompressed>(),
                            at_alpha_opaque,
                            nullptr
                        );
                        
                        const float cr = at_encoder_compress_texels(
                            compressor,
                            &srcTexels,
                            &dstBuffer,
                            CompressErrorThreshold,
                    //        at_flags_default
                            at_flags_print_debug_info
                        );
                        
                        if (cr < 0) abort();
                    }
                    
                    {
                        auto lock = std::unique_lock(imagesLock);
                        images.push_back(std::move(imageCompressed));
                    }
                }
            });
        }
        
        // Wait for workers to complete
        for (std::thread& t : workers) t.join();
    }
    printf("-> Done\n\n");
    
    
    
//    // Load thumbnail from `url`, store in txtRgba32
//    Renderer::Txt txtRgba32;
//    {
//        NSDictionary*const loadOpts = @{
//            MTKTextureLoaderOptionSRGB: @YES,
//        };
//        id<MTLTexture> src = [txtLoader newTextureWithContentsOfURL:url options:loadOpts error:nil];
//        
//        // Calculate transform to fit source image in thumbnail aspect ratio
//        MPSScaleTransform transform;
//        {
//            const float srcAspect = (float)[src width] / [src height];
//            const float dstAspect = (float)ImageThumb::ThumbWidth / _ImageHeight;
//            const float scale = (srcAspect<dstAspect ? ((float)ImageThumb::ThumbWidth / [src width]) : ((float)_ImageHeight / [src height]));
//            transform = {
//                .scaleX = scale,
//                .scaleY = scale,
//                .translateX = 0,
//                .translateY = 0,
//            };
//        }
//        
//        // Scale image
//        constexpr MTLTextureUsage DstUsage = MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
//        txtRgba32 = renderer.textureCreate(MTLPixelFormatRGBA32Float, ImageThumb::ThumbWidth, _ImageHeight, DstUsage);
//        {
//            MPSImageLanczosScale* filter = [[MPSImageLanczosScale alloc] initWithDevice:renderer.dev];
//            [filter setScaleTransform:&transform];
//            [filter encodeToCommandBuffer:renderer.cmdBuf() sourceTexture:src destinationTexture:txtRgba32];
//        }
//    }
//    
//    // Process image, store in txtRgba8
//    const Renderer::Txt txtRgba8 = renderer.textureCreate(txtRgba32, MTLPixelFormatRGBA8Unorm);
//    {
//        const ImageOptions& imageOpts = rec.options;
//        // colorMatrix: converts colorspace from LSRGB.D65 -> ProPhotoRGB.D50, which Pipeline::Process expects
//        const ColorMatrix colorMatrix = {
//           0.5293458, 0.3300728, 0.1405813,
//           0.0983744, 0.8734610, 0.0281647,
//           0.0168832, 0.1176725, 0.8654443,
//        };
//        const Pipeline::Options popts = {
//            .colorMatrix = colorMatrix,
//            .exposure = (float)imageOpts.exposure,
//            .saturation = (float)imageOpts.saturation,
//            .brightness = (float)imageOpts.brightness,
//            .contrast = (float)imageOpts.contrast,
//            .localContrast = {
//                .en = (imageOpts.localContrast.amount!=0 && imageOpts.localContrast.radius!=0),
//                .amount = (float)imageOpts.localContrast.amount,
//                .radius = (float)imageOpts.localContrast.radius,
//            },
//        };
//        
//        Pipeline::Run(renderer, popts, txtRgba32, txtRgba8);
//        renderer.sync(txtRgba8);
//    }
//    
//    // Compress thumbnail, store in rec.thumb.data
//    {
//        renderer.commitAndWait();
//        
//        [txtRgba8 getBytes:tmpStorage.data() bytesPerRow:ImageThumb::ThumbWidth*4
//            fromRegion:MTLRegionMake2D(0,0,ImageThumb::ThumbWidth,_ImageHeight) mipmapLevel:0];
//        
//        compressor.encode(tmpStorage.data(), rec.thumb.data);
//    }
    
    const size_t MmapLen = sizeof(_ImageCompressedStorage) * (_ImageCount + 1);
    const size_t MmapCap = Toastbox::Mmap::PageCeil(MmapLen);
    
    _ImagesMmap = Toastbox::Mmap("/Users/dave/Desktop/images.mmap", MmapCap, O_CREAT|O_RDWR);
    _ImagesMmap.len(MmapLen);
    
    // Scatter `images` into our `_ImagesMmap` mmap
    std::atomic<uint32_t> workIdx = 0;
    {
        std::vector<std::thread> workers;
        const uint32_t threadCount = std::max(1,(int)std::thread::hardware_concurrency());
        for (uint32_t i=0; i<threadCount; i++) {
            workers.emplace_back([&](){
                for (;;) @autoreleasepool {
                    const auto dstIdx = workIdx.fetch_add(1);
                    if (dstIdx >= _ImageCount) break;
                    
                    const uint32_t srcIdx = arc4random_uniform((uint32_t)images.size());
                    const uint8_t* src = &images.at(srcIdx)->at(0);
                    uint8_t* dst = _ImagesMmap.data(dstIdx * sizeof(_ImageCompressedStorage), sizeof(_ImageCompressedStorage));
                    memcpy(dst, src, sizeof(_ImageCompressedStorage));
                }
            });
        }
        
        // Wait for workers to complete
        for (std::thread& t : workers) t.join();
    }
    
    
    
    return NSApplicationMain(argc, argv);
}
