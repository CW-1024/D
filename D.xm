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
static NSString *g_tempFile = nil;            // Documents/bear_vcam_temp.mov
static BOOL g_isPresentingMenu = NO;

static int g_rotation = 0;                    // 旋转角度
static BOOL g_isSoundEnabled = YES;           // 声音开关

// 视频 & 音频读取器（共用锁，与原版 g_mediaLock 一致）
static AVAssetReader *g_videoReader = nil;
static AVAssetReaderTrackOutput *g_videoOutput = nil;
static AVAssetReader *g_audioReader = nil;
static AVAssetReaderTrackOutput *g_audioOutput = nil;
static NSLock *g_mediaLock = nil;
static BOOL g_audioLooping = NO;

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
// 视频读取器设置（原版 setupVideoReaderIfNeeded）
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
// 音频读取器设置（原版 setupAudioReaderIfNeeded）
// ============================================================
static void SetupAudioReader(NSString *filePath) {
    [g_mediaLock lock];
    if (g_audioReader) {
        [g_audioReader cancelReading];
        g_audioReader = nil;
        g_audioOutput = nil;
    }
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:filePath]];
    NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) {
        [g_mediaLock unlock];
        return;
    }
    AVAssetTrack *track = audioTracks[0];
    NSDictionary *settings = @{
        AVFormatIDKey            : @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey   : @(16),
        AVLinearPCMIsFloatKey    : @NO,
        AVLinearPCMIsBigEndianKey: @NO,
        AVNumberOfChannelsKey    : @(1),
        AVSampleRateKey          : @(44100)
    };
    g_audioOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    g_audioReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    [g_audioReader addOutput:g_audioOutput];
    [g_audioReader startReading];
    g_audioLooping = NO;
    [g_mediaLock unlock];
}

// ============================================================
// 获取下一视频帧像素缓冲（调用方负责释放）
// ============================================================
static CVPixelBufferRef GetNextVideoPixelBuffer(void) {
    [g_mediaLock lock];
    CMSampleBufferRef sample = [g_videoOutput copyNextSampleBuffer];
    if (!sample) {
        if (g_tempFile) {
            SetupVideoReader(g_tempFile);
            sample = [g_videoOutput copyNextSampleBuffer];
        }
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
// 音频数据拉取（原版 pullAudioData:length:）
// ============================================================
static NSData* PullAudioData(NSUInteger needBytes) {
    NSMutableData *data = [NSMutableData dataWithCapacity:needBytes];
    [g_mediaLock lock];
    while (data.length < needBytes) {
        if (!g_audioReader || g_audioReader.status != AVAssetReaderStatusReading) {
            if (!g_audioLooping && g_tempFile) {
                SetupAudioReader(g_tempFile);
                g_audioLooping = YES;
            } else break;
        }
        CMSampleBufferRef sample = [g_audioOutput copyNextSampleBuffer];
        if (!sample) {
            SetupAudioReader(g_tempFile);
            g_audioLooping = YES;
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
// 画面旋转（CIImage 处理，返回自动释放对象）
// ============================================================
static CIImage* RotatedCIImageFromBuffer(CVPixelBufferRef src, int degrees) {
    CIImage *image = [CIImage imageWithCVPixelBuffer:src];
    if (degrees == 0 || !image) return image;
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
    return [image imageByApplyingTransform:t];
}

// ============================================================
// 将替换帧绘制到目标缓冲（直接修改，不创建新 CMSampleBuffer）
// ============================================================
static void DrawReplacementOntoBuffer(CVPixelBufferRef targetBuffer) {
    if (!g_fileManager || !g_tempFile || ![g_fileManager fileExistsAtPath:g_tempFile]) return;

    // 热重载检测 .new 文件
    static NSTimeInterval lastLoad = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *newMark = [g_tempFile stringByAppendingString:@".new"];
    if ([g_fileManager fileExistsAtPath:newMark] && (now - lastLoad) > 3.0) {
        lastLoad = now;
        SetupVideoReader(g_tempFile);
        SetupAudioReader(g_tempFile);
        [g_fileManager removeItemAtPath:newMark error:nil];
    }

    CVPixelBufferRef src = GetNextVideoPixelBuffer();
    if (!src) return;
    CIImage *final = RotatedCIImageFromBuffer(src, g_rotation);
    if (!final) { CVPixelBufferRelease(src); return; }

    size_t tw = CVPixelBufferGetWidth(targetBuffer);
    size_t th = CVPixelBufferGetHeight(targetBuffer);
    CGRect srcExt = final.extent;
    CGFloat scale = MAX(tw / srcExt.size.width, th / srcExt.size.height);
    CIImage *scaled = [final imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect scExt = scaled.extent;
    CIImage *centered = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(
        (tw - scExt.size.width) / 2.0, (th - scExt.size.height) / 2.0)];

    static CIContext *ctx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB()}];
    });

    CVPixelBufferLockBaseAddress(targetBuffer, 0);
    [ctx render:centered toCVPixelBuffer:targetBuffer];
    CVPixelBufferUnlockBaseAddress(targetBuffer, 0);
    CVPixelBufferRelease(src);
}

// ============================================================
// 视频代理劫持（直接修改原始 buffer）
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
    @try {
        CVPixelBufferRef buf = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (buf) DrawReplacementOntoBuffer(buf);
    } @catch (NSException *e) {}
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
// 音频 Hook（整合声音开关）
// ============================================================
static OSStatus hooked_AudioUnitRender(void *inRefCon,
                                       AudioUnitRenderActionFlags *ioActionFlags,
                                       const AudioTimeStamp *inTimeStamp,
                                       UInt32 inBusNumber,
                                       UInt32 inNumberFrames,
                                       AudioBufferList *ioData) {
    OSStatus ret = orig_AudioUnitRender(inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    if (!g_isSoundEnabled || !ioData || ioData->mNumberBuffers == 0) return ret;
    AudioBuffer *buf = &ioData->mBuffers[0];
    int sampleSize = 2, channels = 1;
    NSUInteger needBytes = inNumberFrames * sampleSize * channels;
    NSData *audioData = PullAudioData(needBytes);
    if (audioData.length > 0)
        memcpy(buf->mData, audioData.bytes, MIN(audioData.length, buf->mDataByteSize));
    return ret;
}

static void InstallAudioHook() {
    MSHookFunction((void *)AudioUnitRender, (void *)hooked_AudioUnitRender, (void **)&orig_AudioUnitRender);
}

// ============================================================
// 获取当前 key window（兼容多场景，废弃 API 替换）
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

// ============================================================
// 菜单（微信原生 WCActionSheet，包含声音开关）
// ============================================================
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
                            SetupVideoReader(g_tempFile);
                            SetupAudioReader(g_tempFile);
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

    void (^rotate)(void) = ^{
        g_isPresentingMenu = NO;
        g_rotation = (g_rotation + 90) % 360;
    };

    void (^toggleSound)(void) = ^{
        g_isPresentingMenu = NO;
        g_isSoundEnabled = !g_isSoundEnabled;
    };

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
    ((void (*)(id, SEL, NSString*, void*))objc_msgSend)(sheet, addBtn, @"禁用替换", (__bridge void *)disable);
    ((void (*)(id, SEL, UIView*))objc_msgSend)(sheet, NSSelectorFromString(@"showInView:"), keyWindow);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        g_isPresentingMenu = NO;
    });
}

// ============================================================
// UIWindow 手势注入（双指双击）
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
// 构造 & 析构（对齐原版初始化/清理顺序）
// ============================================================
%ctor {
    g_fileManager = [NSFileManager defaultManager];
    g_mediaLock = [[NSLock alloc] init];
    g_tempFile = [[GetDocumentPath() stringByAppendingPathComponent:@"bear_vcam_temp.mov"] copy];
    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
        SetupVideoReader(g_tempFile);
        SetupAudioReader(g_tempFile);
    }
    InstallAudioHook();
}

%dtor {
    [g_mediaLock lock];
    if (g_videoReader) [g_videoReader cancelReading];
    if (g_audioReader) [g_audioReader cancelReading];
    g_videoReader = nil;
    g_audioReader = nil;
    g_videoOutput = nil;
    g_audioOutput = nil;
    [g_mediaLock unlock];
    g_fileManager = nil;
}