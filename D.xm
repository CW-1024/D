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

static int g_rotation = 90;
static BOOL g_isSoundEnabled = YES;
static BOOL g_isLoop = YES;

static AudioStreamBasicDescription g_micASBD = {0};
static BOOL g_hasProbedMicFormat = NO;

static AVAssetReader *g_videoReader = nil;
static AVAssetReaderTrackOutput *g_videoOutput = nil;
static AVAssetReader *g_audioReader = nil;
static AVAssetReaderTrackOutput *g_audioOutput = nil;
static NSLock *g_mediaLock = nil;
static OSStatus (*orig_AudioUnitRender)(void *, AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *, UInt32,
                                        UInt32, AudioBufferList *) = NULL;

// ============================================================
// 持久化
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
    if ([defs objectForKey:@"vcam_rotation"]) g_rotation = (int)[defs integerForKey:@"vcam_rotation"];
    if ([defs objectForKey:@"vcam_sound"])   g_isSoundEnabled = [defs boolForKey:@"vcam_sound"];
    if ([defs objectForKey:@"vcam_loop"])    g_isLoop = [defs boolForKey:@"vcam_loop"];
}

// ============================================================
// 沙盒路径
// ============================================================
static NSString* GetDocumentPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

// ============================================================
// 视频读取器
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
// 音频读取器
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
    if (audioTracks.count == 0) { [g_mediaLock unlock]; return; }
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
// 获取下一视频帧
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
// 音频数据拉取
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
// 绘制替换帧
// ============================================================
static void DrawReplacementOntoBuffer(CVPixelBufferRef targetBuffer) {
    if (!g_fileManager || !g_tempFile || ![g_fileManager fileExistsAtPath:g_tempFile]) return;
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
@implementation VCamProxy { __weak id _originalDelegate; dispatch_queue_t _originalQueue; }
- (void)setOriginalDelegate:(id)delegate queue:(dispatch_queue_t)queue { _originalDelegate = delegate; _originalQueue = queue; }
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer) DrawReplacementOntoBuffer(pixelBuffer);
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
static OSStatus hooked_AudioUnitRender(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
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
// 获取 keyWindow
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
// 自定义菜单（“确认”才生效，“取消”丢弃修改）
// ============================================================
@interface VCamMenuViewController : UIViewController
@end

@implementation VCamMenuViewController {
    // 局部预览变量
    int _tempRotation;
    BOOL _tempSound;
    BOOL _tempLoop;

    UIButton *_rotateBtn;
    UIButton *_soundBtn;
    UIButton *_loopBtn;
}

- (instancetype)init {
    if (self = [super init]) {
        // 从全局拷贝初始值
        _tempRotation = g_rotation;
        _tempSound = g_isSoundEnabled;
        _tempLoop = g_isLoop;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];

    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor systemBackgroundColor];
    container.layer.cornerRadius = 16;
    container.layer.masksToBounds = YES;
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:container];
    [container.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor].active = YES;
    [container.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor].active = YES;
    [container.widthAnchor constraintEqualToConstant:300].active = YES;

    // 导航栏
    UIView *navBar = [[UIView alloc] init];
    navBar.backgroundColor = [UIColor systemGray6Color];
    navBar.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:navBar];
    [navBar.topAnchor constraintEqualToAnchor:container.topAnchor].active = YES;
    [navBar.leadingAnchor constraintEqualToAnchor:container.leadingAnchor].active = YES;
    [navBar.trailingAnchor constraintEqualToAnchor:container.trailingAnchor].active = YES;
    [navBar.heightAnchor constraintEqualToConstant:44].active = YES;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"VCAM 控制";
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [navBar addSubview:title];
    [title.centerXAnchor constraintEqualToAnchor:navBar.centerXAnchor].active = YES;
    [title.centerYAnchor constraintEqualToAnchor:navBar.centerYAnchor].active = YES;

    // 取消按钮 → 丢弃所有修改并关闭
    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont systemFontOfSize:18];
    [cancelBtn addTarget:self action:@selector(cancelAndDismiss) forControlEvents:UIControlEventTouchUpInside];
    cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [navBar addSubview:cancelBtn];
    [cancelBtn.leadingAnchor constraintEqualToAnchor:navBar.leadingAnchor constant:16].active = YES;
    [cancelBtn.centerYAnchor constraintEqualToAnchor:navBar.centerYAnchor].active = YES;

    // 确认按钮 → 应用修改并保存
    UIButton *confirmBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [confirmBtn setTitle:@"确认" forState:UIControlStateNormal];
    confirmBtn.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [confirmBtn addTarget:self action:@selector(confirmAndDismiss) forControlEvents:UIControlEventTouchUpInside];
    confirmBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [navBar addSubview:confirmBtn];
    [confirmBtn.trailingAnchor constraintEqualToAnchor:navBar.trailingAnchor constant:-16].active = YES;
    [confirmBtn.centerYAnchor constraintEqualToAnchor:navBar.centerYAnchor].active = YES;

    // 功能列表
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];
    [stack.topAnchor constraintEqualToAnchor:navBar.bottomAnchor constant:16].active = YES;
    [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-16].active = YES;
    [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16].active = YES;
    [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16].active = YES;

    UIButton* (^createBtn)(NSString *title) = ^UIButton *(NSString *title) {
        UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
        config.baseBackgroundColor = [UIColor systemGray5Color];
        config.baseForegroundColor = [UIColor labelColor];
        config.contentInsets = NSDirectionalEdgeInsetsMake(12, 0, 12, 0);
        UIFont *font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
        NSDictionary *attrs = @{NSFontAttributeName: font};
        NSAttributedString *attrTitle = [[NSAttributedString alloc] initWithString:title attributes:attrs];
        config.attributedTitle = attrTitle;
        UIButton *btn = [UIButton buttonWithConfiguration:config primaryAction:nil];
        btn.layer.cornerRadius = 8;
        return btn;
    };

    // 选择视频（仍然立即生效，因为需要触发热重载）
    UIButton *selectBtn = createBtn(@"选择视频");
    [selectBtn addTarget:self action:@selector(selectVideoTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:selectBtn];

    _rotateBtn = createBtn([NSString stringWithFormat:@"旋转画面 (%d°)", _tempRotation]);
    [_rotateBtn addTarget:self action:@selector(rotatePreview:) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:_rotateBtn];

    _soundBtn = createBtn(_tempSound ? @"声音：开启" : @"声音：关闭");
    [_soundBtn addTarget:self action:@selector(soundPreview:) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:_soundBtn];

    _loopBtn = createBtn(_tempLoop ? @"循环播放：开启" : @"循环播放：关闭");
    [_loopBtn addTarget:self action:@selector(loopPreview:) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:_loopBtn];

    UIButton *disableBtn = createBtn(@"禁用替换");
    [disableBtn addTarget:self action:@selector(disableTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:disableBtn];
}

// 预览按钮：只改变局部变量和标题
- (void)rotatePreview:(UIButton *)btn {
    _tempRotation = (_tempRotation + 90) % 360;
    [_rotateBtn setTitle:[NSString stringWithFormat:@"旋转画面 (%d°)", _tempRotation] forState:UIControlStateNormal];
}

- (void)soundPreview:(UIButton *)btn {
    _tempSound = !_tempSound;
    [_soundBtn setTitle:_tempSound ? @"声音：开启" : @"声音：关闭" forState:UIControlStateNormal];
}

- (void)loopPreview:(UIButton *)btn {
    _tempLoop = !_tempLoop;
    [_loopBtn setTitle:_tempLoop ? @"循环播放：开启" : @"循环播放：关闭" forState:UIControlStateNormal];
}

// 确认 → 应用修改并保存
- (void)confirmAndDismiss {
    g_rotation = _tempRotation;
    g_isSoundEnabled = _tempSound;
    g_isLoop = _tempLoop;
    SaveSettings();
    [self dismissViewControllerAnimated:YES completion:^{ g_isPresentingMenu = NO; }];
}

// 取消 → 什么也不改，直接关闭
- (void)cancelAndDismiss {
    [self dismissViewControllerAnimated:YES completion:^{ g_isPresentingMenu = NO; }];
}

// 禁用替换（此功能仍立即生效）
- (void)disableTapped {
    // 直接操作全局，但不立刻关闭，等用户确认/取消
    // 也可以立即生效并关闭，为方便起见保持原逻辑（立即生效）
    if (g_fileManager && g_tempFile) {
        if ([g_fileManager fileExistsAtPath:g_tempFile]) [g_fileManager removeItemAtPath:g_tempFile error:nil];
        [g_mediaLock lock];
        [g_videoReader cancelReading]; g_videoReader = nil; g_videoOutput = nil;
        [g_audioReader cancelReading]; g_audioReader = nil; g_audioOutput = nil;
        [g_mediaLock unlock];
    }
    [self dismissViewControllerAnimated:YES completion:^{ g_isPresentingMenu = NO; }];
}

// 选择视频按钮 → 保持不变，直接 present 相册
- (void)selectVideoTapped {
    // 复用原来的选择视频逻辑，但 present 在 self 上
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
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[@"public.movie"];
        picker.delegate = pickerDelegate;
        [self presentViewController:picker animated:YES completion:nil];
    });
}

@end

// ============================================================
// 显示菜单（不再需要回调，因为菜单内部自己处理）
// ============================================================
static void ShowVCamMenu(void) {
    if (g_isPresentingMenu) return;
    g_isPresentingMenu = YES;
    UIWindow *keyWindow = GetCurrentKeyWindow();
    if (!keyWindow) { g_isPresentingMenu = NO; return; }

    VCamMenuViewController *menuVC = [[VCamMenuViewController alloc] init];
    menuVC.modalPresentationStyle = UIModalPresentationOverFullScreen;
    menuVC.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

    UIViewController *rootVC = keyWindow.rootViewController;
    while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
    [rootVC presentViewController:menuVC animated:YES completion:nil];
}

// ============================================================
// 手势注入（不变）
// ============================================================
@interface UIWindow (VCam) - (void)vcam_handleTwoFingerDoubleTap:(UITapGestureRecognizer *)tap; @end
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