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
// 全局变量（默认值按需求调整）
// ============================================================
static NSFileManager *g_fileManager = nil;
static NSString *g_tempFile = nil;                // Documents/bear_vcam_temp.mov
static BOOL g_isPresentingMenu = NO;

static int g_rotation = 90;                       // 默认90度
static BOOL g_isSoundEnabled = YES;               // 声音默认开启
static BOOL g_isLoop = NO;                        // 循环播放默认开启（NO 表示循环）

// 麦克风音频格式（动态探测）
static AudioStreamBasicDescription g_micASBD = {0};
static BOOL g_hasProbedMicFormat = NO;

// 视频 / 音频读取器（共用锁）
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
// 持久化工具
// ============================================================
static void SaveSettings(void) {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    [defs setInteger:g_rotation forKey:@"vcam_rotation"];
    [defs setBool:g_isSoundEnabled forKey:@"vcam_sound"];
    [defs setBool:g_isLoop forKey:@"vcam_loop"];
    [defs synchronize];
}

static void LoadSettings(void) {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    if ([defs objectForKey:@"vcam_rotation"]) {
        g_rotation = (int)[defs integerForKey:@"vcam_rotation"];
    }
    if ([defs objectForKey:@"vcam_sound"]) {
        g_isSoundEnabled = [defs boolForKey:@"vcam_sound"];
    }
    if ([defs objectForKey:@"vcam_loop"]) {
        g_isLoop = [defs boolForKey:@"vcam_loop"];
    }
}

// ============================================================
// 沙盒路径
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
// 音频读取器设置
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
// 获取下一视频帧（循环条件：!g_isLoop）
// ============================================================
static CVPixelBufferRef GetNextVideoPixelBuffer(void) {
    [g_mediaLock lock];
    CMSampleBufferRef sample = [g_videoOutput copyNextSampleBuffer];
    if (!sample && !g_isLoop && g_tempFile) {
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
// 音频数据拉取（循环条件：!g_isLoop）
// ============================================================
static NSData* PullAudioData(NSUInteger needBytes) {
    NSMutableData *data = [NSMutableData dataWithCapacity:needBytes];
    [g_mediaLock lock];
    while (data.length < needBytes) {
        BOOL shouldReset = NO;
        if (!g_audioReader || g_audioReader.status != AVAssetReaderStatusReading) {
            if (!g_isLoop && g_tempFile) shouldReset = YES;
            else break;
        }
        CMSampleBufferRef sample = nil;
        if (!shouldReset) {
            sample = [g_audioOutput copyNextSampleBuffer];
            if (!sample && !g_isLoop && g_tempFile) shouldReset = YES;
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
// 将替换帧绘制到目标缓冲区
// ============================================================
static void DrawReplacementOntoBuffer(CVPixelBufferRef targetBuffer) {
    if (!g_fileManager || !g_tempFile || ![g_fileManager fileExistsAtPath:g_tempFile]) return;

    // 热重载检测
    static NSTimeInterval lastLoad = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *newMark = [g_tempFile stringByAppendingString:@".new"];
    if ([g_fileManager fileExistsAtPath:newMark] && (now - lastLoad) > 1.0) {
        lastLoad = now;
        [g_fileManager removeItemAtPath:newMark error:nil];
        SetupVideoReader(g_tempFile);
        SetupAudioReader(g_tempFile);
    }

    CVPixelBufferRef src = GetNextVideoPixelBuffer();
    if (!src) return;

    CIImage *srcImage = [CIImage imageWithCVPixelBuffer:src];
    CVPixelBufferRelease(src);
    if (!srcImage) return;

    // 旋转
    CGAffineTransform transform = CGAffineTransformIdentity;
    CGRect extent = srcImage.extent;
    if (g_rotation == 90) {
        transform = CGAffineTransformMakeTranslation(extent.size.height, 0);
        transform = CGAffineTransformRotate(transform, M_PI_2);
    } else if (g_rotation == 180) {
        transform = CGAffineTransformMakeTranslation(extent.size.width, extent.size.height);
        transform = CGAffineTransformRotate(transform, M_PI);
    } else if (g_rotation == 270) {
        transform = CGAffineTransformMakeTranslation(0, extent.size.width);
        transform = CGAffineTransformRotate(transform, 3 * M_PI_2);
    }
    CIImage *rotated = [srcImage imageByApplyingTransform:transform];

    // 缩放至目标尺寸
    size_t targetWidth  = CVPixelBufferGetWidth(targetBuffer);
    size_t targetHeight = CVPixelBufferGetHeight(targetBuffer);
    CGRect rotatedExtent = rotated.extent;
    CGFloat scale = MAX(targetWidth / rotatedExtent.size.width, targetHeight / rotatedExtent.size.height);
    CIImage *scaled = [rotated imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect scaledExtent = scaled.extent;
    CGFloat offsetX = (targetWidth  - scaledExtent.size.width)  / 2.0;
    CGFloat offsetY = (targetHeight - scaledExtent.size.height) / 2.0;
    CIImage *final = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(offsetX, offsetY)];

    static CIContext *ctx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB()}];
    });
    CVPixelBufferLockBaseAddress(targetBuffer, 0);
    [ctx render:final toCVPixelBuffer:targetBuffer];
    CVPixelBufferUnlockBaseAddress(targetBuffer, 0);
}

// ============================================================
// 视频代理
// ============================================================
@interface VCamProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
- (void)setOriginalDelegate:(id)delegate queue:(dispatch_queue_t)queue;
@end
@implementation VCamProxy {
    __weak id _originalDelegate;
    dispatch_queue_t _originalQueue;
}
- (void)setOriginalDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    _originalDelegate = delegate;
    _originalQueue = queue;
}
- (void)captureOutput:(AVCaptureOutput *)output
   didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
          fromConnection:(AVCaptureConnection *)connection {
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer) {
        DrawReplacementOntoBuffer(pixelBuffer);
    }
    if (_originalDelegate && [_originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [_originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
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
// 音频 Hook
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
// 窗口与菜单（持久化保存设置）
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

    void (^rotate)(void) = ^{
        g_isPresentingMenu = NO;
        g_rotation = (g_rotation + 90) % 360;
        SaveSettings();
    };

    void (^toggleSound)(void) = ^{
        g_isPresentingMenu = NO;
        g_isSoundEnabled = !g_isSoundEnabled;
        SaveSettings();
    };

    void (^toggleLoop)(void) = ^{
        g_isPresentingMenu = NO;
        g_isLoop = !g_isLoop;
        SaveSettings();
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
// 构造 & 析构（加载持久化设置）
// ============================================================
%ctor {
    g_fileManager = [NSFileManager defaultManager];
    g_mediaLock = [[NSLock alloc] init];
    // 加载之前保存的设置（如果存在）
    LoadSettings();
    g_tempFile = [[GetDocumentPath() stringByAppendingPathComponent:@"bear_vcam_temp.mov"] copy];
    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
        SetupVideoReader(g_tempFile);
    }
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