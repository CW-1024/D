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
static NSString *g_tempFile = nil;
static BOOL g_isPresentingMenu = NO;
static int g_rotation = 90;
static BOOL g_isSoundEnabled = YES;
static BOOL g_isLoop = YES;

static AVAssetReader *g_videoReader = nil;
static AVAssetReaderTrackOutput *g_videoOutput = nil;
static AVAssetReader *g_audioReader = nil;
static AVAssetReaderTrackOutput *g_audioOutput = nil;
static NSLock *g_mediaLock = nil;

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
    if ([defs objectForKey:@"vcam_sound"]) g_isSoundEnabled = [defs boolForKey:@"vcam_sound"];
    if ([defs objectForKey:@"vcam_loop"]) g_isLoop = [defs boolForKey:@"vcam_loop"];
}
static NSString* GetDocumentPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

// 视频读取器
static void SetupVideoReader(NSString *filePath) {
    [g_mediaLock lock];
    if (g_videoReader) { [g_videoReader cancelReading]; g_videoReader = nil; g_videoOutput = nil; }
    if (![g_fileManager fileExistsAtPath:filePath]) { [g_mediaLock unlock]; return; }
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:filePath]];
    g_videoReader = [[AVAssetReader alloc] initWithAsset:asset error:nil];
    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    AVAssetTrack *videoTrack = videoTracks.firstObject;
    if (videoTrack) {
        NSDictionary *settings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
        g_videoOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:settings];
        g_videoOutput.alwaysCopiesSampleData = NO;
        [g_videoReader addOutput:g_videoOutput];
        [g_videoReader startReading];
    }
    [g_mediaLock unlock];
}

// 音频读取器：输出 44100 Hz, 16-bit, 单声道 (兼容立体声→单声道)
static void SetupAudioReader(NSString *filePath) {
    [g_mediaLock lock];
    if (g_audioReader) { [g_audioReader cancelReading]; g_audioReader = nil; g_audioOutput = nil; }
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:filePath]];
    NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    AVAssetTrack *track = audioTracks.firstObject;
    if (track) {
        NSDictionary *settings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: @(16),
            AVLinearPCMIsFloatKey: @NO,
            AVLinearPCMIsBigEndianKey: @NO,
            AVNumberOfChannelsKey: @(1),         // 强制单声道
            AVSampleRateKey: @(44100)
        };
        g_audioOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
        g_audioReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
        if (g_audioReader) {
            [g_audioReader addOutput:g_audioOutput];
            [g_audioReader startReading];
        }
    }
    [g_mediaLock unlock];
}

// 获取视频帧
static CVPixelBufferRef GetNextVideoPixelBuffer(void) {
    [g_mediaLock lock];
    CMSampleBufferRef sample = [g_videoOutput copyNextSampleBuffer];
    if (!sample && g_isLoop && g_tempFile) {
        [g_mediaLock unlock]; SetupVideoReader(g_tempFile); [g_mediaLock lock];
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

// 获取音频数据 (循环、自动拼接)
static NSData* PullAudioData(NSUInteger needBytes) {
    NSMutableData *data = [NSMutableData dataWithCapacity:needBytes];
    [g_mediaLock lock];
    while (data.length < needBytes) {
        if (!g_audioReader || g_audioReader.status != AVAssetReaderStatusReading) {
            if (g_isLoop && g_tempFile) {
                [g_mediaLock unlock]; SetupAudioReader(g_tempFile); [g_mediaLock lock];
                if (!g_audioReader || g_audioReader.status != AVAssetReaderStatusReading) break;
                continue;
            } else break;
        }
        CMSampleBufferRef sample = [g_audioOutput copyNextSampleBuffer];
        if (!sample) {
            if (g_isLoop && g_tempFile) {
                [g_mediaLock unlock]; SetupAudioReader(g_tempFile); [g_mediaLock lock];
                if (!g_audioReader || g_audioReader.status != AVAssetReaderStatusReading) break;
                continue;
            } else break;
        }
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        size_t len = 0;
        CMBlockBufferGetDataLength(block, &len);
        NSUInteger remaining = needBytes - data.length;
        NSUInteger copyLen = MIN(len, remaining);
        void *buf = malloc(copyLen);
        CMBlockBufferCopyDataBytes(block, 0, copyLen, buf);
        [data appendBytes:buf length:copyLen];
        free(buf);
        CFRelease(sample);
    }
    [g_mediaLock unlock];
    return data;
}

// 绘制视频替换帧
static void DrawReplacementOntoBuffer(CVPixelBufferRef targetBuffer) {
    if (!g_tempFile || ![g_fileManager fileExistsAtPath:g_tempFile]) return;
    static NSTimeInterval last = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *newMark = [g_tempFile stringByAppendingString:@".new"];
    if ([g_fileManager fileExistsAtPath:newMark] && (now - last) > 1.0) {
        last = now; [g_fileManager removeItemAtPath:newMark error:nil];
        SetupVideoReader(g_tempFile); SetupAudioReader(g_tempFile);
    }
    CVPixelBufferRef src = GetNextVideoPixelBuffer();
    if (!src) return;
    CIImage *srcImg = [CIImage imageWithCVPixelBuffer:src];
    CVPixelBufferRelease(src);
    if (!srcImg) return;
    CGAffineTransform t = CGAffineTransformIdentity;
    CGRect extent = srcImg.extent;
    if (g_rotation == 90) {
        t = CGAffineTransformMakeTranslation(extent.size.height, 0);
        t = CGAffineTransformRotate(t, M_PI_2);
    } else if (g_rotation == 180) {
        t = CGAffineTransformMakeTranslation(extent.size.width, extent.size.height);
        t = CGAffineTransformRotate(t, M_PI);
    } else if (g_rotation == 270) {
        t = CGAffineTransformMakeTranslation(0, extent.size.width);
        t = CGAffineTransformRotate(t, 3 * M_PI_2);
    }
    CIImage *rotated = [srcImg imageByApplyingTransform:t];
    size_t tw = CVPixelBufferGetWidth(targetBuffer), th = CVPixelBufferGetHeight(targetBuffer);
    CGRect rext = rotated.extent;
    CGFloat scale = MAX(tw / rext.size.width, th / rext.size.height);
    CIImage *scaled = [rotated imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect sext = scaled.extent;
    CIImage *final = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation((tw - sext.size.width)/2, (th - sext.size.height)/2)];
    static CIContext *ctx = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB()}]; });
    CVPixelBufferLockBaseAddress(targetBuffer, 0);
    [ctx render:final toCVPixelBuffer:targetBuffer];
    CVPixelBufferUnlockBaseAddress(targetBuffer, 0);
}

// 视频代理
@interface VCamVideoProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
- (void)setOriginalDelegate:(id)delegate queue:(dispatch_queue_t)queue;
@end
@implementation VCamVideoProxy { __weak id _o; }
- (void)setOriginalDelegate:(id)d queue:(dispatch_queue_t)q { _o = d; }
- (void)captureOutput:(AVCaptureOutput *)out didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)conn {
    CVPixelBufferRef buf = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (buf) DrawReplacementOntoBuffer(buf);
    if (_o && [_o respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [_o captureOutput:out didOutputSampleBuffer:sampleBuffer fromConnection:conn];
    }
}
@end
static VCamVideoProxy *g_videoProxy = nil;
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (!g_videoProxy) g_videoProxy = [[VCamVideoProxy alloc] init];
    [g_videoProxy setOriginalDelegate:delegate queue:queue];
    %orig(g_videoProxy, queue);
}
%end

// 音频代理
@interface VCamAudioProxy : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
- (void)setOriginalDelegate:(id)delegate queue:(dispatch_queue_t)queue;
@end
@implementation VCamAudioProxy { __weak id _o; }
- (void)setOriginalDelegate:(id)d queue:(dispatch_queue_t)q { _o = d; }
- (void)captureOutput:(AVCaptureOutput *)out didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)conn {
    if (g_isSoundEnabled) {
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
        size_t len = 0;
        CMBlockBufferGetDataLength(block, &len);
        if (len > 0) {
            NSData *rep = PullAudioData(len);
            if (rep.length > 0) {
                CMBlockBufferRef newBlock = NULL;
                CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, len, kCFAllocatorDefault, NULL, 0, len, 0, &newBlock);
                if (newBlock) {
                    CMBlockBufferReplaceDataBytes(rep.bytes, newBlock, 0, len);
                    CMSampleBufferSetDataBuffer(sampleBuffer, newBlock);
                    CFRelease(newBlock);
                }
            }
        }
    }
    if (_o && [_o respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [_o captureOutput:out didOutputSampleBuffer:sampleBuffer fromConnection:conn];
    }
}
@end
static VCamAudioProxy *g_audioProxy = nil;
%hook AVCaptureAudioDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (!g_audioProxy) g_audioProxy = [[VCamAudioProxy alloc] init];
    [g_audioProxy setOriginalDelegate:delegate queue:queue];
    %orig(g_audioProxy, queue);
}
%end

// 获取 keyWindow
static UIWindow* GetCurrentKeyWindow(void) {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) if (w.isKeyWindow) return w;
            return scene.windows.firstObject;
        }
    }
    return nil;
}

// ===== 自定义菜单 (完整版，与之前相同) =====
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

    UILabel *title = [[UILabel alloc] init]; title.text = @"VCAM 控制";
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    title.textAlignment = NSTextAlignmentCenter; title.translatesAutoresizingMaskIntoConstraints = NO;
    [navBar addSubview:title];
    [title.centerXAnchor constraintEqualToAnchor:navBar.centerXAnchor].active = YES;
    [title.centerYAnchor constraintEqualToAnchor:navBar.centerYAnchor].active = YES;

    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont systemFontOfSize:18];
    [cancelBtn addTarget:self action:@selector(cancelAndDismiss) forControlEvents:UIControlEventTouchUpInside];
    cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [navBar addSubview:cancelBtn];
    [cancelBtn.leadingAnchor constraintEqualToAnchor:navBar.leadingAnchor constant:16].active = YES;
    [cancelBtn.centerYAnchor constraintEqualToAnchor:navBar.centerYAnchor].active = YES;

    UIButton *confirmBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [confirmBtn setTitle:@"确认" forState:UIControlStateNormal];
    confirmBtn.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
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

    UIButton* (^createBtn)(NSString *) = ^UIButton *(NSString *t){
        UIButtonConfiguration *c = [UIButtonConfiguration filledButtonConfiguration];
        c.baseBackgroundColor = [UIColor systemGray5Color]; c.baseForegroundColor = [UIColor labelColor];
        c.contentInsets = NSDirectionalEdgeInsetsMake(12, 0, 12, 0);
        UIFont *f = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
        NSAttributedString *a = [[NSAttributedString alloc] initWithString:t attributes:@{NSFontAttributeName: f}];
        c.attributedTitle = a;
        UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:nil];
        b.layer.cornerRadius = 8;
        return b;
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

- (void)rotatePreview:(UIButton*)b { _tempRotation = (_tempRotation + 90) % 360; [_rotateBtn setTitle:[NSString stringWithFormat:@"旋转画面 (%d°)", _tempRotation] forState:UIControlStateNormal]; }
- (void)soundPreview:(UIButton*)b  { _tempSound = !_tempSound; [_soundBtn setTitle:_tempSound ? @"声音：开启" : @"声音：关闭" forState:UIControlStateNormal]; }
- (void)loopPreview:(UIButton*)b   { _tempLoop = !_tempLoop; [_loopBtn setTitle:_tempLoop ? @"循环播放：开启" : @"循环播放：关闭" forState:UIControlStateNormal]; }

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
            NSURL *url = info[UIImagePickerControllerMediaURL];
            if (url) {
                NSString *src = url.path;
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

- (void)disableTapped {
    if (g_tempFile) { [g_fileManager removeItemAtPath:g_tempFile error:nil]; }
    [g_mediaLock lock];
    [g_videoReader cancelReading]; g_videoReader = nil; g_videoOutput = nil;
    [g_audioReader cancelReading]; g_audioReader = nil; g_audioOutput = nil;
    [g_mediaLock unlock];
    [self dismissViewControllerAnimated:YES completion:^{ g_isPresentingMenu = NO; }];
}
@end

static void ShowVCamMenu(void) {
    if (g_isPresentingMenu) return; g_isPresentingMenu = YES;
    UIWindow *key = GetCurrentKeyWindow();
    if (!key) { g_isPresentingMenu = NO; return; }
    VCamMenuViewController *vc = [[VCamMenuViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    UIViewController *root = key.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    [root presentViewController:vc animated:YES completion:nil];
}

// 手势注入
@interface UIWindow (VCam) - (void)vcam_handleTwoFingerDoubleTap:(UITapGestureRecognizer *)tap; @end
@implementation UIWindow (VCam)
- (void)vcam_handleTwoFingerDoubleTap:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateRecognized) ShowVCamMenu();
}
@end
static void AddGestureToWindow(UIWindow *win) {
    static NSMapTable *map; static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMapTable weakToStrongObjectsMapTable]; });
    if ([map objectForKey:win]) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:win action:@selector(vcam_handleTwoFingerDoubleTap:)];
    tap.numberOfTouchesRequired = 2; tap.numberOfTapsRequired = 2; tap.cancelsTouchesInView = NO;
    [win addGestureRecognizer:tap]; [map setObject:@YES forKey:win];
}
%hook UIWindow
- (void)makeKeyAndVisible { %orig; dispatch_async(dispatch_get_main_queue(), ^{ AddGestureToWindow(self); }); }
- (id)initWithFrame:(CGRect)frame { self = %orig; dispatch_async(dispatch_get_main_queue(), ^{ AddGestureToWindow(self); }); return self; }
%end

%ctor {
    g_fileManager = [NSFileManager defaultManager];
    g_mediaLock = [[NSLock alloc] init];
    LoadSettings();
    g_tempFile = [[GetDocumentPath() stringByAppendingPathComponent:@"bear_vcam_temp.mov"] copy];
    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
        SetupVideoReader(g_tempFile);
        SetupAudioReader(g_tempFile);  // 直接初始化音频读取器
    }
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