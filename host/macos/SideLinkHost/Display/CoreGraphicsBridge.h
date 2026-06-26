#ifndef CoreGraphicsBridge_h
#define CoreGraphicsBridge_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>

@interface CGVirtualDisplayDescriptor : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) void (^terminationHandler)(id display, CGError error);

@end

@interface CGVirtualDisplayMode : NSObject

@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;
@property (nonatomic, readonly) double refreshRate;

- (nonnull instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;

@end

@interface CGVirtualDisplaySettings : NSObject

@property (nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) uint32_t hiDPI;

@end

@interface CGVirtualDisplay : NSObject

@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly, strong) CGVirtualDisplayDescriptor *descriptor;

- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;

@end

// Redeclare CGDisplayStream functions since Swift obsoletes them in macOS 15.
// In C, these are warnings, but in Swift they are hard errors.
// By wrapping them in static inline functions in the bridging header,
// Swift can call the wrappers natively.

static inline CGDisplayStreamRef _Nullable SLDisplayStreamCreate(
    CGDirectDisplayID display,
    size_t outputWidth,
    size_t outputHeight,
    int32_t pixelFormat,
    dispatch_queue_t _Nonnull queue,
    void (^ _Nonnull handler)(int32_t status, uint64_t displayTime, IOSurfaceRef _Nullable frameBuffer)
) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return CGDisplayStreamCreateWithDispatchQueue(display, outputWidth, outputHeight, pixelFormat, NULL, queue, ^(CGDisplayStreamFrameStatus status, uint64_t displayTime, IOSurfaceRef  _Nullable frameBuffer, CGDisplayStreamUpdateRef  _Nullable updateRef) {
        handler((int32_t)status, displayTime, frameBuffer);
    });
#pragma clang diagnostic pop
}

static inline CGError SLDisplayStreamStart(CGDisplayStreamRef _Nonnull stream) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return CGDisplayStreamStart(stream);
#pragma clang diagnostic pop
}

static inline CGError SLDisplayStreamStop(CGDisplayStreamRef _Nonnull stream) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return CGDisplayStreamStop(stream);
#pragma clang diagnostic pop
}

#endif /* CoreGraphicsBridge_h */
