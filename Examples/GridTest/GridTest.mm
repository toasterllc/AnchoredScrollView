#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <simd/simd.h>
#import <algorithm>
#import <thread>
#import <filesystem>
#import <array>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <AppleTextureEncoder.h>
#import "AnchoredScrollView.h"
#import "AnchoredDocumentView.h"
#import "AnchoredMetalDocumentLayer.h"
#import "GridLayerTypes.h"
#import "Lib/Toastbox/Util.h"
#import "Lib/Toastbox/Mac/Renderer.h"
#import "Lib/Toastbox/Mac/Grid.h"
#import "Lib/Toastbox/Mmap.h"
#import "Lib/Toastbox/LRU.h"
#import "Lib/Toastbox/Math.h"
namespace fs = std::filesystem;

struct _TextureArray {
    static constexpr size_t Count = 2048;
    id<MTLTexture> txt = nil;
};

static constexpr size_t _ImageWidth = 160;
static constexpr size_t _ImageHeight = 90;
static constexpr size_t _ImageCompressedBlockSize = 4;
//static constexpr size_t _ImageCount = 1<<16; // 65,536
//static constexpr size_t _ImageCount = 1<<18; // 262,144
static constexpr size_t _ImageCount = 1<<20; // 1,048,576
// _ImageCount must be an even multiple of _TextureArray::Count
static_assert(!(_ImageCount % _TextureArray::Count));



using _ImageStorage = std::array<uint8_t, _ImageWidth*_ImageHeight*4>;
using _ImageStoragePtr = std::unique_ptr<_ImageStorage>;
using _ImageCompressedStorage = std::array<uint8_t,
    Toastbox::Ceil((size_t)_ImageCompressedBlockSize,_ImageWidth)* // Ceil _ImageWidth to ASTC block size
    Toastbox::Ceil((size_t)_ImageCompressedBlockSize,_ImageHeight) // Ceil _ImageHeight to ASTC block size
>;

using _ImageCompressedStoragePtr = std::unique_ptr<_ImageCompressedStorage>;

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
    Toastbox::Grid _grid;
    float _cellScale;
    
    Toastbox::LRU<uint32_t,_TextureArray,8> _txts;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    
    [self setPresentsWithTransaction:true];
    
    _device = [self preferredDevice];
    assert(_device);
    
    [self setDevice:[self preferredDevice]];
    [self setColorspace:(__bridge CGColorSpaceRef)CFBridgingRelease(CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB))];
    [self setOpaque:false];
    
    _library = [_device newDefaultLibrary];
    _commandQueue = [_device newCommandQueue];
    
    _vertexShader = [_library newFunctionWithName:@"VertexShader"];
    assert(_vertexShader);
    
    _fragmentShader = [_library newFunctionWithName:@"FragmentShader"];
    assert(_fragmentShader);
    
    MTLRenderPipelineDescriptor* pipelineDescriptor = [MTLRenderPipelineDescriptor new];
    [pipelineDescriptor setVertexFunction:_vertexShader];
    [pipelineDescriptor setFragmentFunction:_fragmentShader];
    
    [[pipelineDescriptor colorAttachments][0] setPixelFormat:[self pixelFormat]];
    
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

static Toastbox::Grid::Rect _GridRectFromCGRect(CGRect rect, CGFloat scale) {
    const CGRect irect = CGRectIntegral({
        rect.origin.x*scale,
        rect.origin.y*scale,
        rect.size.width*scale,
        rect.size.height*scale,
    });
    
    return Toastbox::Grid::Rect{
        .point = {(int32_t)irect.origin.x, (int32_t)irect.origin.y},
        .size = {(int32_t)irect.size.width, (int32_t)irect.size.height},
    };
}

static Toastbox::Grid::IndexRange _VisibleIndexRange(Toastbox::Grid& grid, CGRect frame, CGFloat scale) {
    return grid.indexRangeForIndexRect(grid.indexRectForRect(_GridRectFromCGRect(frame, scale)));
}

- (void)setCellScale:(float)x {
    constexpr float CellScaleMin = 0.1;
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
        [[renderPassDescriptor colorAttachments][0] setClearColor:{}];
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
        const Toastbox::Grid::IndexRange visibleIndexRange = _VisibleIndexRange(_grid, frame, contentsScale);
        if (!visibleIndexRange.count) return;
        
        uint32_t i = (visibleIndexRange.start / _TextureArray::Count) * _TextureArray::Count;
        for (; i<visibleIndexRange.start+visibleIndexRange.count; i+=_TextureArray::Count) {
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
                .idx = (uint32_t)i,
                .viewSize = {(float)viewSize.width, (float)viewSize.height},
                .transform = [self anchoredTransform],
            };
            
            [renderEncoder setVertexBytes:&ctx length:sizeof(ctx) atIndex:0];
            
            _TextureArray& ta = [self _getTextureArray:i];
            
            [renderEncoder setFragmentBytes:&ctx length:sizeof(ctx) atIndex:0];
            [renderEncoder setFragmentTexture:ta.txt atIndex:1];
            
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

static Toastbox::Mmap _ImagesCreate(const fs::path& mmapPath, size_t imageCount) {
    const size_t MmapLen = sizeof(_ImageCompressedStorage) * imageCount;
    const size_t MmapCap = Toastbox::Mmap::PageCeil(MmapLen);
    Toastbox::Mmap mmap = Toastbox::Mmap(mmapPath, MmapCap, O_CREAT|O_RDWR, 0644);
    
    // Short-circuit if the file already exists and its length is the length we're about to generate.
    // In that case we'll assume the file's already been created and re-use it.
    if (mmap.len() == MmapLen) return mmap;
    
    // Set the file size
    mmap.len(MmapLen);
    
    std::vector<fs::path> imagePaths;
    
    struct {
        std::mutex lock;
        std::vector<_ImageCompressedStoragePtr> vector;
    } images;
    
    {
        const uint32_t ThreadCount = std::max(1,(int)std::thread::hardware_concurrency());
        printf("Loading source images (on %ju threads)...\n", (uintmax_t)ThreadCount);
        {
            const fs::path resources = [[[NSBundle mainBundle] resourcePath] UTF8String];
            const fs::path imagesDir = resources / "Test-Images";
            for (const fs::path& p : fs::recursive_directory_iterator(imagesDir)) @autoreleasepool {
                if (!_IsImageFile(p)) continue;
                imagePaths.push_back(p);
            }
            
            std::atomic<size_t> pathIdx = 0;
            std::vector<std::thread> workers;
            for (uint32_t i=0; i<ThreadCount; i++) {
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
                            
                            renderer.sync(txt);
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
                            auto lock = std::unique_lock(images.lock);
                            images.vector.push_back(std::move(imageCompressed));
                        }
                    }
                });
            }
            
            // Wait for workers to complete
            for (std::thread& t : workers) t.join();
        }
        printf("-> Done\n\n");
    }
    
    // Generate `imageCount` images by scatting random elements of `images` into `mmap`
    {
        // This process is IO bound (RAM->flash), and is much faster with a single thread than multiple threads
        const uint32_t ThreadCount = 1;
        printf("Generating %ju images (from %ju source images, on %ju threads)\n",
            (uintmax_t)imageCount, (uintmax_t)images.vector.size(), (uintmax_t)ThreadCount);
        
        auto startTime = std::chrono::steady_clock::now();
        {
            // Scatter `images` into our `mmap` mmap
            std::atomic<uint32_t> workIdx = 0;
            {
                std::vector<std::thread> workers;
                for (uint32_t i=0; i<ThreadCount; i++) {
                    workers.emplace_back([&](){
                        for (;;) @autoreleasepool {
                            const auto dstIdx = workIdx.fetch_add(1);
                            if (dstIdx >= imageCount) break;
                            
                            const uint32_t srcIdx = arc4random_uniform((uint32_t)images.vector.size());
                            const uint8_t* src = &images.vector.at(srcIdx)->at(0);
                            uint8_t* dst = mmap.data(dstIdx * sizeof(_ImageCompressedStorage), sizeof(_ImageCompressedStorage));
    //                        printf("[%p] Copying\n", [NSThread currentThread]);
                            memcpy(dst, src, sizeof(_ImageCompressedStorage));
                        }
                    });
                }
                
                // Wait for workers to complete
                for (std::thread& t : workers) t.join();
            }
        }
        auto durationMs = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-startTime);
        printf("-> Done (took %ju ms)\n\n", (uintmax_t)durationMs.count());
    }
    
    return mmap;
}

int main(int argc, const char* argv[]) {
    const fs::path bundleDir = fs::path([[[NSBundle mainBundle] bundlePath] UTF8String]).parent_path();
    const fs::path mmapPath = bundleDir / "images.mmap";
    _ImagesMmap = _ImagesCreate(mmapPath, _ImageCount);
    printf("%zu\n", sizeof(_ImageCompressedStorage));
    return NSApplicationMain(argc, argv);
}
