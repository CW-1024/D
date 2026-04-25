#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

// ============================================================
// 全局变量（对齐原版）
// ============================================================
static NSFileManager *g_fileManager = nil;
static NSString *g_tempFile = nil;                // Documents/bear_vcam_temp.mov
static BOOL g_isPresentingMenu = NO;

static int g_rotation = 0;                        // 旋转角度
static BOOL g_isSoundEnabled = YES;               // 声音开关
static BOOL g_isLoop = YES;                       // 循环播放开关

// 麦克风音频格式（动态探测）
static AudioStreamBasicDescription g_micASBD = {0};
static BOOL g_hasProbedMicFormat = NO;

// 视频 / 音频读取器（共用锁，与原版 g_mediaLock 一致）
static AVAssetReader *g_videoReader = nil;
static AVAssetReaderTrackOutput *g_videoOutput = nil;
static AVAssetReader *g_audioReader = nil;
static AVAssetReaderTrackOutput *g_audioOutput = nil;
static NSLock *g_mediaLock = nil;

// Hook 原始指针
static OSStatus (*orig_AudioUnitRender)(void *, AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *, UInt32,
                                        UInt32, AudioBufferList *) = NULL;

// ============================================================
// 沙盒路径（原版 Documents/bear_vcam_temp.mov）
// ============================================================
static NSString* GetDocumentPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

// ============================================================
// 视频读取器设置
// ============================================================
static void SetupVideoReader(NSString *filePath) {
    [g_mediaLock lock];
    if (g_videoReader) {
        [g_videoReader cancelReading];
        g_videoReader = nil;
        g_videoOutput = nil;
    }
    if (![g_fileManager fileExistsAtPath:filePath]) {
        [g_mediaLock unlock];
        return;
    }
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:filePath]];
    NSError *error = nil;
    g_videoReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (error) { [g_mediaLock unlock]; return; }
    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count == 0) { [g_mediaLock unlock]; return; }
    AVAssetTrack *videoTrack = videoTracks[0];
    NSDictionary *settings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    g_videoOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:settings];
    g_videoOutput.alwaysCopiesSampleData = NO;
    [g_videoReader addOutput:g_videoOutput];
    [g_videoReader startReading];
    [g_mediaLock unlock];
}

// ============================================================
// 音频读取器设置（根据麦克风实际格式）
// ============================================================
static void SetupAudioReader(NSString *filePath) {
    [g_mediaLock lock];
    if (g_audioReader) {
        [g_audioReader cancelReading];
        g_audioReader = nil;
        g_audioOutput = nil;
    }
    if (!g_hasProbedMicFormat) {
        [g_mediaLock unlock];
        return;
    }
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:filePath]];
    NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) {
        [g_mediaLock unlock];
        return;
    }
    AVAssetTrack *track = audioTracks[0];
    AudioStreamBasicDescription asbd = g_micASBD;
    NSDictionary *settings = @{
        AVFormatIDKey            : @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey   : @(asbd.mBitsPerChannel),
        AVLinearPCMIsFloatKey    : @((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0),
        AVLinearPCMIsBigEndianKey: @((asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0),
        AVNumberOfChannelsKey    : @(asbd.mChannelsPerFrame),
        AVSampleRateKey          : @(asbd.mSampleRate)
    };
    g_audioOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    g_audioReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    [g_audioReader addOutput:g_audioOutput];
    [g_audioReader startReading];
    [g_mediaLock unlock];
}

// ============================================================
// 获取下一视频帧（避免死锁：解锁后重置）
// ============================================================
static CVPixelBufferRef GetNextVideoPixelBuffer(void) {
    [g_mediaLock lock];
    CMSampleBufferRef sample = [g_videoOutput copyNextSampleBuffer];
    if (!sample && g_isLoop && g_tempFile) {
        [g_mediaLock unlock];
        SetupVideoReader(g_tempFile);
        [g_mediaLock lock];
        sample = [g_videoOutput copyNextSampleBuffer];
    }
    CVPixelBufferRef pixel = NULL;
    if (sample) {
        pixel = CMSampleBufferGetImageBuffer(sample);
        if (pixel) CVPixelBufferRetain(pixel);
        CFRelease(sample);
    }
    [g_mediaLock unlock];
    return pixel;
}

// ============================================================
// 音频数据拉取（避免死锁：解锁后重置）
// ============================================================
static NSData* PullAudioData(NSUInteger needBytes) {
    NSMutableData *data = [NSMutableData dataWithCapacity:needBytes];
    [g_mediaLock lock];
    while (data.length < needBytes) {
        BOOL shouldReset = NO;
        if (!g_audioReader || g_audioReader.status != AVAssetReaderStatusReading) {
            if (g_isLoop && g_tempFile) shouldReset = YES;
            else break;
        }
        CMSampleBufferRef sample = nil;
        if (!shouldReset) {
            sample = [g_audioOutput copyNextSampleBuffer];
            if (!sample && g_isLoop && g_tempFile) shouldReset = YES;
        }
        if (shouldReset) {
            [g_mediaLock unlock];
            SetupAudioReader(g_tempFile);
            [g_mediaLock lock];
            continue;
        }
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        size_t totalSize = 0;
        CMBlockBufferGetDataPointer(block, 0, NULL, &totalSize, NULL);
        NSUInteger remaining = needBytes - data.length;
        NSUInteger copyLen = MIN(totalSize, remaining);
        void *ptr = malloc(copyLen);
        CMBlockBufferCopyDataBytes(block, 0, copyLen, ptr);
        [data appendBytes:ptr length:copyLen];
        free(ptr);
        CFRelease(sample);
    }
    [g_mediaLock unlock];
    return data;
}

// ============================================================
// 旋转 + 缩放
// ============================================================
static CVPixelBufferRef RotateAndScalePixelBuffer(CVPixelBufferRef src, int degrees, size_t targetWidth, size_t targetHeight) {
    CIImage *image = [CIImage imageWithCVPixelBuffer:src];
    if (!image) return NULL;
    CGAffineTransform t = CGAffineTransformIdentity;
    CGRect extent = image.extent;
    if (degrees == 90) {
        t = CGAffineTransformMakeTranslation(extent.size.height, 0);
        t = CGAffineTransformRotate(t, M_PI_2);
    } else if (degrees == 180) {
        t = CGAffineTransformMakeTranslation(extent.size.width, extent.size.height);
        t = CGAffineTransformRotate(t, M_PI);
    } else if (degrees == 270) {
        t = CGAffineTransformMakeTranslation(0, extent.size.width);
        t = CGAffineTransformRotate(t, 3 * M_PI_2);
    }
    CIImage *rotated = [image imageByApplyingTransform:t];
    CGRect rotatedExtent = rotated.extent;
    CGFloat scale = MAX(targetWidth / rotatedExtent.size.width, targetHeight / rotatedExtent.size.height);
    CIImage *scaled = [rotated imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect scaledExtent = scaled.extent;
    CIImage *final = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(
        (targetWidth - scaledExtent.size.width) / 2.0,
        (targetHeight - scaledExtent.size.height) / 2.0)];
    NSDictionary *attrs = @{
        (id)kCVPixelBufferWidthKey: @(targetWidth),
        (id)kCVPixelBufferHeightKey: @(targetHeight),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    CVPixelBufferRef outBuffer = NULL;
    CVPixelBufferCreate(NULL, targetWidth, targetHeight, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &outBuffer);
    if (!outBuffer) return NULL;
    static CIContext *ctx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB()}];
    });
    [ctx render:final toCVPixelBuffer:outBuffer];
    return outBuffer;
}

// ============================================================
// 视频代理（含热重载检测）
// ============================================================
@interface VCamProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
- (void)setOriginalDelegate:(id)delegate queue:(dispatch_queue_t)queue;
@end
@implementation VCamProxy {
    __weak id _orig;
    dispatch_queue_t _queue;
}
- (void)setOriginalDelegate:(id)delegate queue:(dispatch_queue_t)queue { _orig = delegate; _queue = queue; }

- (void)captureOutput:(AVCaptureOutput *)output
   didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
          fromConnection:(AVCaptureConnection *)connection {
    // 热重载检测（无需锁，只做标记检查）
    if (g_tempFile) {
        NSString *newMark = [g_tempFile stringByAppendingString:@".new"];
        if ([g_fileManager fileExistsAtPath:newMark]) {
            [g_fileManager removeItemAtPath:newMark error:nil];
            SetupVideoReader(g_tempFile);
            SetupAudioReader(g_tempFile);
        }
    }

    CMFormatDescriptionRef origFormat = CMSampleBufferGetFormatDescription(sampleBuffer);
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(origFormat);
    CVPixelBufferRef newBuf = GetNextVideoPixelBuffer();
    if (newBuf) {
        CVPixelBufferRef processed = RotateAndScalePixelBuffer(newBuf, g_rotation, dims.width, dims.height);
        CVPixelBufferRelease(newBuf);
        if (processed) {
            CMSampleTimingInfo timing;
            CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timing);
            CMVideoFormatDescriptionRef fmtDesc = NULL;
            CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, processed, &fmtDesc);
            if (fmtDesc) {
                CMSampleBufferRef newSample = NULL;
                CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, processed, true, NULL, NULL, fmtDesc, &timing, &newSample);
                if (newSample) sampleBuffer = newSample;
                CFRelease(fmtDesc);
            }
            CVPixelBufferRelease(processed);
        }
    }
    if (_orig && [_orig respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        dispatch_async(_queue, ^{
            [_orig captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        });
    }
}
@end

static VCamProxy *g_proxy = nil;
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (!g_proxy) g_proxy = [[VCamProxy alloc] init];
    [g_proxy setOriginalDelegate:delegate queue:queue];
    %orig(g_proxy, queue);
}
%end

// ============================================================
// 音频 Hook（动态探测格式）
// ============================================================
static OSStatus hooked_AudioUnitRender(void *inRefCon,
                                       AudioUnitRenderActionFlags *ioActionFlags,
                                       const AudioTimeStamp *inTimeStamp,
                                       UInt32 inBusNumber,
                                       UInt32 inNumberFrames,
                                       AudioBufferList *ioData) {
    if (!g_hasProbedMicFormat) {
        AudioUnit au = (AudioUnit)inRefCon;
        UInt32 size = sizeof(g_micASBD);
        if (AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &g_micASBD, &size) == noErr) {
            g_hasProbedMicFormat = YES;
            if (g_tempFile && [g_fileManager fileExistsAtPath:g_tempFile]) SetupAudioReader(g_tempFile);
        }
    }
    OSStatus ret = orig_AudioUnitRender(inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    if (!g_isSoundEnabled || !ioData || ioData->mNumberBuffers == 0) return ret;
    AudioBuffer *buf = &ioData->mBuffers[0];
    NSUInteger sampleSize = g_micASBD.mBitsPerChannel / 8;
    NSUInteger channels = g_micASBD.mChannelsPerFrame;
    NSUInteger needBytes = inNumberFrames * sampleSize * channels;
    NSData *audioData = PullAudioData(needBytes);
    if (audioData.length > 0) memcpy(buf->mData, audioData.bytes, MIN(audioData.length, buf->mDataByteSize));
    return ret;
}

static void InstallAudioHook() {
    MSHookFunction((void *)AudioUnitRender, (void *)hooked_AudioUnitRender, (void **)&orig_AudioUnitRender);
}

// ============================================================
// 窗口与菜单
// ============================================================
static UIWindow* GetCurrentKeyWindow(void) {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) if (w.isKeyWindow) return w;
            return scene.windows.firstObject;
        }
    }
    return nil;
}

static void ShowVCamMenu(void) {
    if (g_isPresentingMenu) return;
    g_isPresentingMenu = YES;
    UIWindow *keyWindow = GetCurrentKeyWindow();
    if (!keyWindow) { g_isPresentingMenu = NO; return; }

    void (^selectVideo)(void) = ^{
        g_isPresentingMenu = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *win = GetCurrentKeyWindow();
            UIViewController *rootVC = win.rootViewController;
            while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
            static id pickerDelegate = nil;
            if (!pickerDelegate) {
                Class cls = objc_allocateClassPair([NSObject class], "VCamPDelegate", 0);
                class_addProtocol(cls, @protocol(UIImagePickerControllerDelegate));
                class_addProtocol(cls, @protocol(UINavigationControllerDelegate));
                IMP imp = imp_implementationWithBlock(^(id self, UIImagePickerController *picker, NSDictionary *info) {
                    [picker dismissViewControllerAnimated:YES completion:nil];
                    NSURL *videoURL = info[UIImagePickerControllerMediaURL];
                    if (videoURL) {
                        NSString *src = videoURL.path;
                        if ([g_fileManager fileExistsAtPath:g_tempFile]) [g_fileManager removeItemAtPath:g_tempFile error:nil];
                        if ([g_fileManager copyItemAtPath:src toPath:g_tempFile error:nil]) {
                            [@"1" writeToFile:[g_tempFile stringByAppendingString:@".new"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                        }
                    }
                });
                class_addMethod(cls, @selector(imagePickerController:didFinishPickingMediaWithInfo:), imp, "v@:@@");
                imp = imp_implementationWithBlock(^(id self, UIImagePickerController *picker) {
                    [picker dismissViewControllerAnimated:YES completion:nil];
                });
                class_addMethod(cls, @selector(imagePickerControllerDidCancel:), imp, "v@:@");
                pickerDelegate = [cls new];
            }
            UIImagePickerController *picker = [[UIImagePickerController alloc] init];
            picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
            picker.mediaTypes = @[@"public.movie"];
            picker.delegate = pickerDelegate;
            [rootVC presentViewController:picker animated:YES completion:nil];
        });
    };

    void (^rotate)(void) = ^{ g_isPresentingMenu = NO; g_rotation = (g_rotation + 90) % 360; };
    void (^toggleSound)(void) = ^{ g_isPresentingMenu = NO; g_isSoundEnabled = !g_isSoundEnabled; };
    void (^toggleLoop)(void) = ^{ g_isPresentingMenu = NO; g_isLoop = !g_isLoop; };
    void (^disable)(void) = ^{
        g_isPresentingMenu = NO;
        if ([g_fileManager fileExistsAtPath:g_tempFile]) [g_fileManager removeItemAtPath:g_tempFile error:nil];
        [g_mediaLock lock];
        [g_videoReader cancelReading]; g_videoReader = nil; g_videoOutput = nil;
        [g_audioReader cancelReading]; g_audioReader = nil; g_audioOutput = nil;
        [g_mediaLock unlock];
    };

    Class WCActionSheet = NSClassFromString(@"WCActionSheet");
    id sheet = ((id (*)(id, SEL, NSString*))objc_msgSend)([WCActionSheet alloc], NSSelectorFromString(@"initWithTitle:"), @"VCAM 控制");
    SEL addBtn = NSSelectorFromString(@"addButtonWithTitle:eventAction:");
    ((void (*)(id, SEL, NSString*, void*))objc_msgSend)(sheet, addBtn, @"选择视频", (__bridge void *)selectVideo);
    ((void (*)(id, SEL, NSString*, void*))objc_msgSend)(sheet, addBtn, [NSString stringWithFormat:@"旋转画面 (%d°)", g_rotation], (__bridge void *)rotate);
    ((void (*)(id, SEL, NSString*, void*))objc_msgSend)(sheet, addBtn, g_isSoundEnabled ? @"声音：关闭" : @"声音：开启", (__bridge void *)toggleSound);
    ((void (*)(id, SEL, NSString*, void*))objc_msgSend)(sheet, addBtn, g_isLoop ? @"循环播放：关闭" : @"循环播放：开启", (__bridge void *)toggleLoop);
    ((void (*)(id, SEL, NSString*, void*))objc_msgSend)(sheet, addBtn, @"禁用替换", (__bridge void *)disable);
    ((void (*)(id, SEL, UIView*))objc_msgSend)(sheet, NSSelectorFromString(@"showInView:"), keyWindow);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ g_isPresentingMenu = NO; });
}

// ============================================================
// 手势注入
// ============================================================
@interface UIWindow (VCam)
- (void)vcam_handleTwoFingerDoubleTap:(UITapGestureRecognizer *)tap;
@end
@implementation UIWindow (VCam)
- (void)vcam_handleTwoFingerDoubleTap:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateRecognized) ShowVCamMenu();
}
@end
static void AddGestureToWindow(UIWindow *window) {
    static NSMapTable<UIWindow*, NSNumber*> *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMapTable weakToStrongObjectsMapTable]; });
    if ([map objectForKey:window]) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:window action:@selector(vcam_handleTwoFingerDoubleTap:)];
    tap.numberOfTouchesRequired = 2;
    tap.numberOfTapsRequired = 2;
    tap.cancelsTouchesInView = NO;
    [window addGestureRecognizer:tap];
    [map setObject:@YES forKey:window];
}
%hook UIWindow
- (void)makeKeyAndVisible { %orig; dispatch_async(dispatch_get_main_queue(), ^{ AddGestureToWindow(self); }); }
- (id)initWithFrame:(CGRect)frame { self = %orig; dispatch_async(dispatch_get_main_queue(), ^{ AddGestureToWindow(self); }); return self; }
%end

// ============================================================
// 构造 & 析构
// ============================================================
%ctor {
    g_fileManager = [NSFileManager defaultManager];
    g_mediaLock = [[NSLock alloc] init];
    g_tempFile = [[GetDocumentPath() stringByAppendingPathComponent:@"bear_vcam_temp.mov"] copy];
    if ([g_fileManager fileExistsAtPath:g_tempFile]) SetupVideoReader(g_tempFile);
    InstallAudioHook();
}
%dtor {
    [g_mediaLock lock];
    if (g_videoReader) [g_videoReader cancelReading];
    if (g_audioReader) [g_audioReader cancelReading];
    g_videoReader = nil; g_audioReader = nil;
    g_videoOutput = nil; g_audioOutput = nil;
    [g_mediaLock unlock];
    g_fileManager = nil;
}