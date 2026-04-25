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
// 全局变量
// ============================================================
static NSFileManager *g_fileManager = nil;
static NSString *g_tempFile = nil;
static BOOL g_isPresentingMenu = NO;

// 画面旋转角度 (0/90/180/270)
static int g_rotation = 0;

// ---- 视频实时读取 ----
static AVAssetReader *g_videoReader = nil;
static AVAssetReaderTrackOutput *g_videoOutput = nil;
static NSLock *g_videoLock = nil;

// ---- 音频实时读取 ----
static AVAssetReader *g_audioReader = nil;
static AVAssetReaderTrackOutput *g_audioOutput = nil;
static NSLock *g_audioLock = nil;
static BOOL g_audioLooping = NO;

// ---- Hook 原始指针 ----
static OSStatus (*orig_AudioUnitRender)(void *,
                                        AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *,
                                        UInt32,
                                        UInt32,
                                        AudioBufferList *) = NULL;

// ============================================================
// 路径工具
// ============================================================
static NSString* GetCachesPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
}

// ============================================================
// 视频读取器设置 (原版 setupVideoReaderIfNeeded)
// ============================================================
static void SetupVideoReader(NSString *filePath) {
    [g_videoLock lock];

    if (g_videoReader) {
        [g_videoReader cancelReading];
        g_videoReader = nil;
        g_videoOutput = nil;
    }

    if (![g_fileManager fileExistsAtPath:filePath]) {
        [g_videoLock unlock];
        return;
    }

    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:filePath]];
    NSError *error = nil;
    g_videoReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (error) { [g_videoLock unlock]; return; }

    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count == 0) { [g_videoLock unlock]; return; }
    AVAssetTrack *videoTrack = videoTracks[0];

    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    g_videoOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:settings];
    g_videoOutput.alwaysCopiesSampleData = NO;
    [g_videoReader addOutput:g_videoOutput];
    [g_videoReader startReading];

    [g_videoLock unlock];
}

// ============================================================
// 音频读取器设置 (原版 setupAudioReaderIfNeeded)
// ============================================================
static void SetupAudioReader(NSString *filePath) {
    [g_audioLock lock];

    if (g_audioReader) {
        [g_audioReader cancelReading];
        g_audioReader = nil;
        g_audioOutput = nil;
    }

    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:filePath]];
    NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) {
        [g_audioLock unlock];
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

    [g_audioLock unlock];
}

// ============================================================
// 获取下一视频帧像素缓冲 (原版 getVideoFrame: 派生)
// 返回 CVPixelBufferRef，调用方需调用 CVPixelBufferRelease 释放
// ============================================================
static CVPixelBufferRef GetNextVideoPixelBuffer(void) {
    [g_videoLock lock];
    CMSampleBufferRef sample = [g_videoOutput copyNextSampleBuffer];
    if (!sample) {
        // 循环播放：重置 reader
        if (g_tempFile) {
            SetupVideoReader(g_tempFile);
            sample = [g_videoOutput copyNextSampleBuffer];
        }
    }
    CVPixelBufferRef pixelBuffer = NULL;
    if (sample) {
        pixelBuffer = CMSampleBufferGetImageBuffer(sample);
        if (pixelBuffer) {
            CVPixelBufferRetain(pixelBuffer);
        }
        CFRelease(sample);
    }
    [g_videoLock unlock];
    return pixelBuffer;
}

// ============================================================
// 音频数据拉取 (原版 pullAudioData:length:)
// ============================================================
static NSData* PullAudioData(NSUInteger needBytes) {
    NSMutableData *resultData = [NSMutableData dataWithCapacity:needBytes];
    [g_audioLock lock];

    while (resultData.length < needBytes) {
        if (!g_audioReader || g_audioReader.status != AVAssetReaderStatusReading) {
            if (!g_audioLooping && g_tempFile) {
                SetupAudioReader(g_tempFile);
                g_audioLooping = YES;
            } else {
                break;
            }
        }
        CMSampleBufferRef sample = [g_audioOutput copyNextSampleBuffer];
        if (!sample) {
            SetupAudioReader(g_tempFile);
            g_audioLooping = YES;
            continue;
        }
        CMBlockBufferRef blockBuf = CMSampleBufferGetDataBuffer(sample);
        size_t totalSize = 0;
        CMBlockBufferGetDataPointer(blockBuf, 0, NULL, &totalSize, NULL);
        NSUInteger remaining = needBytes - resultData.length;
        NSUInteger copyLen = MIN(totalSize, remaining);
        void *ptr = malloc(copyLen);
        CMBlockBufferCopyDataBytes(blockBuf, 0, copyLen, ptr);
        [resultData appendBytes:ptr length:copyLen];
        free(ptr);
        CFRelease(sample);
    }

    [g_audioLock unlock];
    return resultData;
}

// ============================================================
// 画面旋转处理
// ============================================================
static CIImage* RotatedCIImageFromBuffer(CVPixelBufferRef src, int degrees) {
    CIImage *srcImage = [CIImage imageWithCVPixelBuffer:src];
    if (degrees == 0 || !srcImage) return srcImage;

    CGAffineTransform transform = CGAffineTransformIdentity;
    CGRect extent = srcImage.extent;

    if (degrees == 90) {
        transform = CGAffineTransformMakeTranslation(extent.size.height, 0);
        transform = CGAffineTransformRotate(transform, M_PI_2);
    } else if (degrees == 180) {
        transform = CGAffineTransformMakeTranslation(extent.size.width, extent.size.height);
        transform = CGAffineTransformRotate(transform, M_PI);
    } else if (degrees == 270) {
        transform = CGAffineTransformMakeTranslation(0, extent.size.width);
        transform = CGAffineTransformRotate(transform, 3 * M_PI_2);
    }

    return [srcImage imageByApplyingTransform:transform];
}

// ============================================================
// 将替换帧绘制到目标缓冲区 (直接修改，不替换 CMSampleBuffer)
// ============================================================
static void DrawReplacementOntoBuffer(CVPixelBufferRef targetBuffer) {
    if (!g_fileManager || !g_tempFile || ![g_fileManager fileExistsAtPath:g_tempFile]) return;

    // 检查是否有新视频标记 (.new 文件)，如果有则重新加载
    static NSTimeInterval lastLoadTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *newMark = [g_tempFile stringByAppendingString:@".new"];

    if ([g_fileManager fileExistsAtPath:newMark] && (now - lastLoadTime) > 3.0) {
        lastLoadTime = now;
        SetupVideoReader(g_tempFile);
        SetupAudioReader(g_tempFile);
        [g_fileManager removeItemAtPath:newMark error:nil];
    }

    CVPixelBufferRef srcBuffer = GetNextVideoPixelBuffer();
    if (!srcBuffer) return;

    CIImage *finalImage = RotatedCIImageFromBuffer(srcBuffer, g_rotation);
    if (!finalImage) {
        CVPixelBufferRelease(srcBuffer);
        return;
    }

    size_t targetWidth  = CVPixelBufferGetWidth(targetBuffer);
    size_t targetHeight = CVPixelBufferGetHeight(targetBuffer);
    CGRect srcExtent = finalImage.extent;

    // 等比缩放并居中
    CGFloat scaleX = targetWidth  / srcExtent.size.width;
    CGFloat scaleY = targetHeight / srcExtent.size.height;
    CGFloat scale  = MAX(scaleX, scaleY);

    CIImage *scaledImage = [finalImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect scaledExtent = scaledImage.extent;
    CGFloat offsetX = (targetWidth  - scaledExtent.size.width)  / 2.0;
    CGFloat offsetY = (targetHeight - scaledExtent.size.height) / 2.0;
    CIImage *centerImage = [scaledImage imageByApplyingTransform:CGAffineTransformMakeTranslation(offsetX, offsetY)];

    static CIContext *ciContext = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ciContext = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB()}];
    });

    CVPixelBufferLockBaseAddress(targetBuffer, 0);
    [ciContext render:centerImage toCVPixelBuffer:targetBuffer];
    CVPixelBufferUnlockBaseAddress(targetBuffer, 0);

    CVPixelBufferRelease(srcBuffer);
}

// ============================================================
// 视频代理劫持 (原版：直接修改缓冲内容)
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
    @try {
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (pixelBuffer) {
            DrawReplacementOntoBuffer(pixelBuffer);
        }
    } @catch (NSException *e) {}

    // 转发给原始代理
    if (_originalDelegate && [_originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        dispatch_async(_originalQueue, ^{
            [_originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
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
// 音频 Hook (原版 AudioUnitRender)
// ============================================================
static OSStatus hooked_AudioUnitRender(void *inRefCon,
                                       AudioUnitRenderActionFlags *ioActionFlags,
                                       const AudioTimeStamp *inTimeStamp,
                                       UInt32 inBusNumber,
                                       UInt32 inNumberFrames,
                                       AudioBufferList *ioData) {
    OSStatus ret = orig_AudioUnitRender(inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    if (ioData && ioData->mNumberBuffers > 0) {
        AudioBuffer *buf = &ioData->mBuffers[0];
        int sampleSize = 2;
        int channels = 1;
        NSUInteger needBytes = inNumberFrames * sampleSize * channels;
        NSData *audioData = PullAudioData(needBytes);
        if (audioData.length > 0) {
            memcpy(buf->mData, audioData.bytes, MIN(audioData.length, buf->mDataByteSize));
        }
    }
    return ret;
}

static void InstallAudioHook() {
    MSHookFunction((void *)AudioUnitRender, (void *)hooked_AudioUnitRender, (void **)&orig_AudioUnitRender);
}

// ============================================================
// 辅助函数：获取当前 key window (兼容多场景)
// ============================================================
static UIWindow* GetCurrentKeyWindow(void) {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w.isKeyWindow) return w;
            }
            return scene.windows.firstObject;
        }
    }
    return nil;
}

// ============================================================
// 菜单 (WCActionSheet)
// ============================================================
static void ShowVCamMenu(void) {
    if (g_isPresentingMenu) return;
    g_isPresentingMenu = YES;

    UIWindow *keyWindow = GetCurrentKeyWindow();
    if (!keyWindow) { g_isPresentingMenu = NO; return; }

    void (^selectVideoAction)(void) = ^{
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
                        NSString *srcPath = videoURL.path;
                        if ([g_fileManager fileExistsAtPath:g_tempFile]) {
                            [g_fileManager removeItemAtPath:g_tempFile error:nil];
                        }
                        if ([g_fileManager copyItemAtPath:srcPath toPath:g_tempFile error:nil]) {
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

    void (^rotateAction)(void) = ^{
        g_isPresentingMenu = NO;
        g_rotation = (g_rotation + 90) % 360;
    };

    void (^disableAction)(void) = ^{
        g_isPresentingMenu = NO;
        if ([g_fileManager fileExistsAtPath:g_tempFile]) {
            [g_fileManager removeItemAtPath:g_tempFile error:nil];
        }
        [g_videoLock lock];
        [g_videoReader cancelReading];
        g_videoReader = nil;
        g_videoOutput = nil;
        [g_videoLock unlock];
        [g_audioLock lock];
        [g_audioReader cancelReading];
        g_audioReader = nil;
        g_audioOutput = nil;
        [g_audioLock unlock];
    };

    Class WCActionSheetClass = NSClassFromString(@"WCActionSheet");
    id sheet = ((id (*)(id, SEL, NSString*))objc_msgSend)([WCActionSheetClass alloc], NSSelectorFromString(@"initWithTitle:"), @"VCAM 控制");
    SEL addBtn = NSSelectorFromString(@"addButtonWithTitle:eventAction:");

    ((void (*)(id, SEL, NSString*, void*))objc_msgSend)(sheet, addBtn, @"选择视频", (__bridge void *)selectVideoAction);
    ((void (*)(id, SEL, NSString*, void*))objc_msgSend)(sheet, addBtn,
        [NSString stringWithFormat:@"旋转画面 (%d°)", g_rotation], (__bridge void *)rotateAction);
    ((void (*)(id, SEL, NSString*, void*))objc_msgSend)(sheet, addBtn, @"禁用替换", (__bridge void *)disableAction);

    SEL show = NSSelectorFromString(@"showInView:");
    ((void (*)(id, SEL, UIView*))objc_msgSend)(sheet, show, keyWindow);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        g_isPresentingMenu = NO;
    });
}

// ============================================================
// UIWindow 手势注入
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
    static NSMapTable<UIWindow*, NSNumber*> *gestureMap = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gestureMap = [NSMapTable weakToStrongObjectsMapTable]; });
    if ([gestureMap objectForKey:window]) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:window action:@selector(vcam_handleTwoFingerDoubleTap:)];
    tap.numberOfTouchesRequired = 2;
    tap.numberOfTapsRequired = 2;
    tap.cancelsTouchesInView = NO;
    [window addGestureRecognizer:tap];
    [gestureMap setObject:@YES forKey:window];
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
    g_videoLock = [[NSLock alloc] init];
    g_audioLock = [[NSLock alloc] init];
    g_tempFile = [[GetCachesPath() stringByAppendingPathComponent:@"temp.mov"] copy];
    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
        SetupVideoReader(g_tempFile);
        SetupAudioReader(g_tempFile);
    }
    InstallAudioHook();
}

%dtor {
    [g_videoLock lock];
    if (g_videoReader) [g_videoReader cancelReading];
    g_videoReader = nil;
    g_videoOutput = nil;
    [g_videoLock unlock];
    [g_audioLock lock];
    if (g_audioReader) [g_audioReader cancelReading];
    g_audioReader = nil;
    g_audioOutput = nil;
    [g_audioLock unlock];
    g_fileManager = nil;
}