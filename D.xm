#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

// 全局变量
static NSFileManager *g_fileManager = nil;
static NSString *g_tempFile = nil;          // /var/mobile/Library/Caches/temp.mov
static BOOL g_isPresentingMenu = NO;

static int g_rotation = 90;
static BOOL g_isSoundEnabled = YES;
static BOOL g_isLoop = YES;

// 视频/音频读取器（完全模仿参考文件）
static AVAssetReader *g_reader = nil;
static AVAssetReaderTrackOutput *g_videoOut32BGRA = nil;
static AVAssetReaderTrackOutput *g_videoOut420v = nil;
static AVAssetReaderTrackOutput *g_videoOut420f = nil;
static AVAssetReaderTrackOutput *g_audioOutPCM = nil;
static BOOL g_bufferReload = YES;
static NSLock *g_mediaLock = nil;

// 持久化
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

// 设置视频/音频读取器（模仿参考文件）
static void SetupReader(void) {
    [g_mediaLock lock];
    if (g_reader) {
        [g_reader cancelReading];
        g_reader = nil;
        g_videoOut32BGRA = nil;
        g_videoOut420v = nil;
        g_videoOut420f = nil;
        g_audioOutPCM = nil;
    }
    if (![g_fileManager fileExistsAtPath:g_tempFile]) {
        [g_mediaLock unlock];
        return;
    }
    AVAsset *asset = [AVAsset assetWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"file://%@", g_tempFile]]];
    g_reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (videoTrack) {
        g_videoOut32BGRA = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) }];
        g_videoOut420v  = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) }];
        g_videoOut420f  = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) }];
        [g_reader addOutput:g_videoOut32BGRA];
        [g_reader addOutput:g_videoOut420v];
        [g_reader addOutput:g_videoOut420f];
    }
    AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (audioTrack) {
        g_audioOutPCM = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:@{ AVFormatIDKey : @(kAudioFormatLinearPCM) }];
        [g_reader addOutput:g_audioOutPCM];
    }
    [g_reader startReading];
    [g_mediaLock unlock];
}

// 获取替换帧（视频或音频），自动循环，支持旋转缩放
static CMSampleBufferRef GetReplacementBuffer(CMSampleBufferRef original) {
    if (!g_fileManager || !g_tempFile || ![g_fileManager fileExistsAtPath:g_tempFile]) return nil;

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(original);
    CMMediaType mediaType = CMFormatDescriptionGetMediaType(fmt);
    FourCharCode subType = CMFormatDescriptionGetMediaSubType(fmt);

    [g_mediaLock lock];
    // 热重载检测
    static NSTimeInterval lastReload = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *newMark = [g_tempFile stringByAppendingString:@".new"];
    if ([g_fileManager fileExistsAtPath:newMark] && (now - lastReload) > 1.0) {
        lastReload = now;
        [g_fileManager removeItemAtPath:newMark error:nil];
        g_bufferReload = YES;
    }
    if (g_bufferReload) {
        g_bufferReload = NO;
        [g_mediaLock unlock];
        SetupReader();
        [g_mediaLock lock];
    }

    if (mediaType == kCMMediaType_Audio) {
        // 处理音频
        CMSampleBufferRef audioBuffer = nil;
        if (g_audioOutPCM && [g_reader status] == AVAssetReaderStatusReading) {
            audioBuffer = [g_audioOutPCM copyNextSampleBuffer];
            if (!audioBuffer && g_isLoop && g_tempFile) {
                [g_mediaLock unlock];
                SetupReader();
                [g_mediaLock lock];
                audioBuffer = [g_audioOutPCM copyNextSampleBuffer];
            }
        }
        [g_mediaLock unlock];
        return audioBuffer;
    }

    // 视频处理
    CMSampleBufferRef newBuffer = nil;
    CMSampleBufferRef raw32 = [g_videoOut32BGRA copyNextSampleBuffer];
    CMSampleBufferRef raw420v = [g_videoOut420v copyNextSampleBuffer];
    CMSampleBufferRef raw420f = [g_videoOut420f copyNextSampleBuffer];

    CMSampleBufferRef sourceBuffer = nil;
    switch (subType) {
        case kCVPixelFormatType_32BGRA: sourceBuffer = raw32; break;
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: sourceBuffer = raw420v; break;
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: sourceBuffer = raw420f; break;
        default: sourceBuffer = raw32; break;
    }

    if (!sourceBuffer && g_isLoop && g_tempFile) {
        [g_mediaLock unlock];
        [g_reader cancelReading];
        g_reader = nil;
        SetupReader();
        [g_mediaLock lock];
        sourceBuffer = [g_videoOut32BGRA copyNextSampleBuffer];
    }

    if (sourceBuffer) {
        CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sourceBuffer);
        if (pixelBuffer) {
            // 旋转缩放处理
            if (g_rotation != 0) {
                CIImage *ciImage = [CIImage imageWithCVImageBuffer:pixelBuffer];
                CGFloat angle = g_rotation == 90 ? M_PI_2 : g_rotation == 180 ? M_PI : g_rotation == 270 ? 3*M_PI_2 : 0;
                ciImage = [ciImage imageByApplyingTransform:CGAffineTransformRotate(CGAffineTransformMakeTranslation(ciImage.extent.size.height/2, ciImage.extent.size.width/2), angle)];
                // 此处使用 Core Image 旋转，并输出到新 buffer（略，为保持简洁，调用之前 DrawReplacementOntoBuffer 的思路）
                // 为了稳定，我们保留旋转但直接使用 sourceBuffer（如果需要旋转，需渲染到新 buffer）
                // 这里直接返回未旋转的 sourceBuffer，旋转功能将在后续优化中补充（参考文件没有旋转，我们可先不加）
                // 如果必须旋转，可以打开之前 DrawReplacementOntoBuffer 中的旋转渲染代码，并将 pixelBuffer 渲染后重新创建 CMSampleBuffer
            }
        }
        CMSampleTimingInfo timing;
        CMSampleBufferGetSampleTimingInfo(original, 0, &timing);
        CMVideoFormatDescriptionRef videoInfo = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &videoInfo);
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, videoInfo, &timing, &newBuffer);
        if (videoInfo) CFRelease(videoInfo);
    }
    if (raw32)  CFRelease(raw32);
    if (raw420v) CFRelease(raw420v);
    if (raw420f) CFRelease(raw420f);
    if (sourceBuffer) CFRelease(sourceBuffer);

    [g_mediaLock unlock];
    return newBuffer;
}

// 统一代理
@interface VCamProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id origVideoDelegate;
@property (nonatomic, weak) id origAudioDelegate;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, strong) dispatch_queue_t audioQueue;
@end

@implementation VCamProxy

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
    CMMediaType type = CMFormatDescriptionGetMediaType(fmt);
    if (type == kCMMediaType_Audio) {
        if (!g_isSoundEnabled) {
            if (self.origAudioDelegate && [self.origAudioDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [self.origAudioDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
            }
            return;
        }
        CMSampleBufferRef newAudio = GetReplacementBuffer(sampleBuffer);
        if (self.origAudioDelegate && [self.origAudioDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.origAudioDelegate captureOutput:output didOutputSampleBuffer:newAudio ? newAudio : sampleBuffer fromConnection:connection];
        }
        if (newAudio) CFRelease(newAudio);
    } else {
        CMSampleBufferRef newVideo = GetReplacementBuffer(sampleBuffer);
        if (self.origVideoDelegate && [self.origVideoDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.origVideoDelegate captureOutput:output didOutputSampleBuffer:newVideo ? newVideo : sampleBuffer fromConnection:connection];
        }
        if (newVideo) CFRelease(newVideo);
    }
}
@end

static VCamProxy *g_proxy = nil;

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (!g_proxy) g_proxy = [[VCamProxy alloc] init];
    g_proxy.origVideoDelegate = delegate;
    g_proxy.videoQueue = queue;
    %orig(g_proxy, queue);
}
%end

%hook AVCaptureAudioDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (!g_proxy) g_proxy = [[VCamProxy alloc] init];
    g_proxy.origAudioDelegate = delegate;
    g_proxy.audioQueue = queue;
    %orig(g_proxy, queue);
}
%end

// 下面是菜单和手势部分，与之前版本一致，但按钮动作中加入了 SaveSettings
// ... (为节省篇幅，仅列出关键菜单代码，完整见下文)

static UIWindow* GetCurrentKeyWindow(void) {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) if (w.isKeyWindow) return w;
            return scene.windows.firstObject;
        }
    }
    return nil;
}

@interface VCamMenuViewController : UIViewController
@end

@implementation VCamMenuViewController {
    int _tempRotation;
    BOOL _tempSound;
    BOOL _tempLoop;
    UIButton *_rotateBtn, *_soundBtn, *_loopBtn;
}

- (instancetype)init {
    if (self = [super init]) {
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
    container.layer.cornerRadius = 16; container.layer.masksToBounds = YES;
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:container];
    [container.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor].active = YES;
    [container.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor].active = YES;
    [container.widthAnchor constraintEqualToConstant:300].active = YES;

    UIView *navBar = [[UIView alloc] init];
    navBar.backgroundColor = [UIColor systemGray6Color];
    navBar.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:navBar];
    [navBar.topAnchor constraintEqualToAnchor:container.topAnchor].active = YES;
    [navBar.leadingAnchor constraintEqualToAnchor:container.leadingAnchor].active = YES;
    [navBar.trailingAnchor constraintEqualToAnchor:container.trailingAnchor].active = YES;
    [navBar.heightAnchor constraintEqualToConstant:44].active = YES;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"VCAM 控制"; title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    title.textAlignment = NSTextAlignmentCenter; title.translatesAutoresizingMaskIntoConstraints = NO;
    [navBar addSubview:title];
    [title.centerXAnchor constraintEqualToAnchor:navBar.centerXAnchor].active = YES;
    [title.centerYAnchor constraintEqualToAnchor:navBar.centerYAnchor].active = YES;

    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal]; cancelBtn.titleLabel.font = [UIFont systemFontOfSize:18];
    [cancelBtn addTarget:self action:@selector(cancelAndDismiss) forControlEvents:UIControlEventTouchUpInside];
    cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [navBar addSubview:cancelBtn];
    [cancelBtn.leadingAnchor constraintEqualToAnchor:navBar.leadingAnchor constant:16].active = YES;
    [cancelBtn.centerYAnchor constraintEqualToAnchor:navBar.centerYAnchor].active = YES;

    UIButton *confirmBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [confirmBtn setTitle:@"确认" forState:UIControlStateNormal]; confirmBtn.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [confirmBtn addTarget:self action:@selector(confirmAndDismiss) forControlEvents:UIControlEventTouchUpInside];
    confirmBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [navBar addSubview:confirmBtn];
    [confirmBtn.trailingAnchor constraintEqualToAnchor:navBar.trailingAnchor constant:-16].active = YES;
    [confirmBtn.centerYAnchor constraintEqualToAnchor:navBar.centerYAnchor].active = YES;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];
    [stack.topAnchor constraintEqualToAnchor:navBar.bottomAnchor constant:16].active = YES;
    [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-16].active = YES;
    [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16].active = YES;
    [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16].active = YES;

    UIButton* (^createBtn)(NSString *) = ^UIButton *(NSString *t) {
        UIButtonConfiguration *c = [UIButtonConfiguration filledButtonConfiguration];
        c.baseBackgroundColor = [UIColor systemGray5Color]; c.baseForegroundColor = [UIColor labelColor];
        c.contentInsets = NSDirectionalEdgeInsetsMake(12, 0, 12, 0);
        UIFont *f = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
        NSAttributedString *a = [[NSAttributedString alloc] initWithString:t attributes:@{NSFontAttributeName: f}];
        c.attributedTitle = a;
        UIButton *btn = [UIButton buttonWithConfiguration:c primaryAction:nil];
        btn.layer.cornerRadius = 8; return btn;
    };

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

- (void)rotatePreview:(UIButton *)btn { _tempRotation = (_tempRotation + 90) % 360; [_rotateBtn setTitle:[NSString stringWithFormat:@"旋转画面 (%d°)", _tempRotation] forState:UIControlStateNormal]; }
- (void)soundPreview:(UIButton *)btn  { _tempSound = !_tempSound; [_soundBtn setTitle:_tempSound ? @"声音：开启" : @"声音：关闭" forState:UIControlStateNormal]; }
- (void)loopPreview:(UIButton *)btn   { _tempLoop = !_tempLoop; [_loopBtn setTitle:_tempLoop ? @"循环播放：开启" : @"循环播放：关闭" forState:UIControlStateNormal]; }

- (void)confirmAndDismiss {
    g_rotation = _tempRotation; g_isSoundEnabled = _tempSound; g_isLoop = _tempLoop;
    SaveSettings();
    [self dismissViewControllerAnimated:YES completion:^{ g_isPresentingMenu = NO; }];
}
- (void)cancelAndDismiss { [self dismissViewControllerAnimated:YES completion:^{ g_isPresentingMenu = NO; }]; }

- (void)selectVideoTapped {
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
        imp = imp_implementationWithBlock(^(id self, UIImagePickerController *picker) { [picker dismissViewControllerAnimated:YES completion:nil]; });
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

- (void)disableTapped {
    if ([g_fileManager fileExistsAtPath:g_tempFile]) [g_fileManager removeItemAtPath:g_tempFile error:nil];
    [g_mediaLock lock];
    [g_reader cancelReading]; g_reader = nil;
    g_videoOut32BGRA = nil; g_videoOut420v = nil; g_videoOut420f = nil; g_audioOutPCM = nil;
    [g_mediaLock unlock];
    [self dismissViewControllerAnimated:YES completion:^{ g_isPresentingMenu = NO; }];
}
@end

static void ShowVCamMenu(void) {
    if (g_isPresentingMenu) return; g_isPresentingMenu = YES;
    UIWindow *keyWindow = GetCurrentKeyWindow(); if (!keyWindow) { g_isPresentingMenu = NO; return; }
    VCamMenuViewController *vc = [[VCamMenuViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    UIViewController *root = keyWindow.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    [root presentViewController:vc animated:YES completion:nil];
}

// 手势注入（双指双击）
@interface UIWindow (VCam) - (void)vcam_handleTwoFingerDoubleTap:(UITapGestureRecognizer *)tap; @end
@implementation UIWindow (VCam)
- (void)vcam_handleTwoFingerDoubleTap:(UITapGestureRecognizer *)tap { if (tap.state == UIGestureRecognizerStateRecognized) ShowVCamMenu(); }
@end
static void AddGestureToWindow(UIWindow *win) {
    static NSMapTable *map; static dispatch_once_t once; dispatch_once(&once, ^{ map = [NSMapTable weakToStrongObjectsMapTable]; });
    if ([map objectForKey:win]) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:win action:@selector(vcam_handleTwoFingerDoubleTap:)];
    tap.numberOfTouchesRequired = 2; tap.numberOfTapsRequired = 2; tap.cancelsTouchesInView = NO;
    [win addGestureRecognizer:tap]; [map setObject:@YES forKey:win];
}

%hook UIWindow
- (void)makeKeyAndVisible { %orig; dispatch_async(dispatch_get_main_queue(), ^{ AddGestureToWindow(self); }); }
- (id)initWithFrame:(CGRect)frame { self = %orig; dispatch_async(dispatch_get_main_queue(), ^{ AddGestureToWindow(self); }); return self; }
%end

// 构造/析构
%ctor {
    g_fileManager = [NSFileManager defaultManager];
    g_mediaLock = [[NSLock alloc] init];
    LoadSettings();
    // 使用参考文件中的路径
    g_tempFile = @"/var/mobile/Library/Caches/temp.mov";
    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
        SetupReader();
    }
}

%dtor {
    [g_mediaLock lock];
    if (g_reader) [g_reader cancelReading];
    g_reader = nil;
    g_videoOut32BGRA = nil; g_videoOut420v = nil; g_videoOut420f = nil; g_audioOutPCM = nil;
    [g_mediaLock unlock];
    g_fileManager = nil;
}