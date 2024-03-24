#import "AnchoredMetalDocumentLayer.h"
#import <algorithm>
#import <cmath>

static simd::float4x4 _Scale(float x, float y, float z) {
    return {
        simd::float4{ x,   0.f, 0.f, 0.f },
        simd::float4{ 0.f, y,   0.f, 0.f },
        simd::float4{ 0.f, 0.f, z,   0.f },
        simd::float4{ 0.f, 0.f, 0.f, 1.f },
    };
}

static simd::float4x4 _Translate(float x, float y, float z) {
    return {
        simd::float4{ 1.f, 0.f, 0.f, 0.f },
        simd::float4{ 0.f, 1.f, 0.f, 0.f },
        simd::float4{ 0.f, 0.f, 1.f, 0.f },
        simd::float4{   x,   y,   z, 1.f },
    };
}

@implementation AnchoredMetalDocumentLayer {
@private
    CGPoint _translation;
    CGFloat _magnification;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    [self setOpaque:true];
    [self setNeedsDisplayOnBoundsChange:true];
    [self setAllowsNextDrawableTimeout:false];
    [self setPresentsWithTransaction:true];
    return self;
}

- (void)display {
    const CGRect frame = [self frame];
    const CGFloat contentsScale = [self contentsScale];
    const size_t drawableWidth = std::max(1., std::round(frame.size.width*_magnification*contentsScale));
    const size_t drawableHeight = std::max(1., std::round(frame.size.height*_magnification*contentsScale));
    [self setDrawableSize:{(CGFloat)drawableWidth, (CGFloat)drawableHeight}];
}

- (CGPoint)anchoredTranslation {
    return _translation;
}

- (CGFloat)anchoredMagnification {
    return _magnification;
}

- (simd_float4x4)anchoredTransform {
    const CGRect frame = [self frame];
    // We expect our superlayer's size to be the full content size
    const CGSize contentSize = [[self superlayer] bounds].size;
    const int flip = [self isGeometryFlipped] ? -1 : 1;
    const simd::float4x4 transform =
        _Translate(-1, -1*flip, 1)                          *
        _Scale(2, 2*flip, 1)                                *
        _Scale(1/frame.size.width, 1/frame.size.height, 1)  *
        _Translate(-_translation.x, -_translation.y, 0)     *
        _Scale(contentSize.width, contentSize.height, 1)    ;
    
    return transform;
}

// MARK: - CALayer Overrides

- (void)setContentsScale:(CGFloat)scale {
    [super setContentsScale:scale];
    [self setNeedsDisplay];
}

// Disable implicit animation
- (id<CAAction>)actionForKey:(NSString*)event {
    return nil;
}

// MARK: - AnchoredScrollViewDocument Protocol

- (void)anchoredTranslationChanged:(CGPoint)t magnification:(CGFloat)m {
    _translation = t;
    _magnification = m;
    [self setNeedsDisplay];
}

- (bool)anchoredFlipped {
    return false;
}

@end
