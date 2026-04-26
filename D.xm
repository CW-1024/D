#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

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

static NSMutableData *g_audioCache = nil;
static NSUInteger g_audioOffset = 0;

static NSLock *g_lock = nil;

static OSStatus (*orig_AudioUnitRender)(
    void *,
    AudioUnitRenderActionFlags *,
    const AudioTimeStamp *,
    UInt32,
    UInt32,
    AudioBufferList *
) = NULL;

#pragma mark - 设置

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

static NSString* DocPath(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

#pragma mark - 视频读取

static void SetupVideo(NSString *path) {
    [g_lock lock];
    if (g_videoReader) {
        [g_videoReader cancelReading];
        g_videoReader = nil;
        g_videoOutput = nil;
    }
    if (![g_fileManager fileExistsAtPath:path]) {
        [g_lock unlock];
        return;
    }
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:path]];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) {
        [g_lock unlock];
        return;
    }
    NSError *err = nil;
    g_videoReader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (err) {
        [g_lock unlock];
        return;
    }
    g_videoOutput = [[AVAssetReaderTrackOutput alloc]
        initWithTrack:track
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
    g_videoOutput.alwaysCopiesSampleData = NO;
    [g_videoReader addOutput:g_videoOutput];
    [g_videoReader startReading];
    [g_lock unlock];
}

static CVPixelBufferRef ReadVideoFrame(void) {
    [g_lock lock];
    CMSampleBufferRef s = [g_videoOutput copyNextSampleBuffer];
    if (!s && g_isLoop && g_tempFile) {
        [g_lock unlock];
        SetupVideo(g_tempFile);
        [g_lock lock];
        s = [g_videoOutput copyNextSampleBuffer];
    }
    CVPixelBufferRef p = s ? CMSampleBufferGetImageBuffer(s) : NULL;
    if (p) CVPixelBufferRetain(p);
    if (s) CFRelease(s);
    [g_lock unlock];
    return p;
}

#pragma mark - ✅ 原始 VCAM 音频处理

static void LoadAudio(NSString *path, AudioStreamBasicDescription asbd) {
    [g_lock lock];
    g_audioCache = nil;
    g_audioOffset = 0;

    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:path]];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!track) {
        [g_lock unlock];
        return;
    }

    NSError *err = nil;
    AVAssetReader *r = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (err) {
        [g_lock unlock];
        return;
    }

    NSDictionary *cfg = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(asbd.mSampleRate),
        AVNumberOfChannelsKey: @(asbd.mChannelsPerFrame),
        AVLinearPCMBitDepthKey: @(asbd.mBitsPerChannel),
        AVLinearPCMIsFloatKey: @((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0),
        AVLinearPCMIsBigEndianKey: @((asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0),
        AVLinearPCMIsNonInterleaved: @((asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0)
    };

    AVAssetReaderTrackOutput *out = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:cfg];
    [r addOutput:out];
    [r startReading];

    NSMutableData *data = [NSMutableData data];
    while (r.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef s = [out copyNextSampleBuffer];
        if (!s) break;
        CMBlockBufferRef b = CMSampleBufferGetDataBuffer(s);
        size_t len = 0;
        CMBlockBufferGetDataPointer(b, 0, NULL, &len, NULL);
        if (len > 0) {
            uint8_t *p = (uint8_t *)malloc(len);
            CMBlockBufferCopyDataBytes(b, 0, len, p);
            [data appendBytes:p length:len];
            free(p);
        }
        CFRelease(s);
    }

    if (r.status == AVAssetReaderStatusCompleted) {
        g_audioCache = data;
    }

    [g_lock unlock];
}

static NSData *ReadAudio(UInt32 need) {
    [g_lock lock];
    if (!g_audioCache || g_audioCache.length == 0) {
        [g_lock unlock];
        return [NSMutableData dataWithLength:need];
    }

    NSMutableData *d = [NSMutableData data];
    while (d.length < need) {
        if (g_audioOffset >= g_audioCache.length) {
            if (g_isLoop) g_audioOffset = 0;
            else break;
        }
        NSUInteger left = need - d.length;
        NSUInteger avail = g_audioCache.length - g_audioOffset;
        NSUInteger cp = MIN(left, avail);
        [d appendBytes:((uint8_t *)g_audioCache.bytes + g_audioOffset) length:cp];
        g_audioOffset += cp;
    }

    if (d.length < need) {
        [d increaseLengthBy:need - d.length];
    }

    [g_lock unlock];
    return d;
}

#pragma mark - AudioUnitRender（✅ 原始 VCAM 行为）

static OSStatus hooked_AudioUnitRender(
    void *rc,
    AudioUnitRenderActionFlags *f,
    const AudioTimeStamp *ts,
    UInt32 bus,
    UInt32 frames,
    AudioBufferList *io
) {
    if (bus != 0 && bus != 1) {
        return orig_AudioUnitRender(rc, f, ts, bus, frames, io);
    }

    if (!g_hasProbedMicFormat) {
        AudioUnit au = (AudioUnit)rc;
        UInt32 sz = sizeof(g_micASBD);
        if (AudioUnitGetProperty(au,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input,
                                 bus,
                                 &g_micASBD,
                                 &sz) == noErr) {
            g_hasProbedMicFormat = YES;
            if (g_tempFile) LoadAudio(g_tempFile, g_micASBD);
        } else {
            memset(&g_micASBD, 0, sizeof(g_micASBD));
            g_micASBD.mSampleRate = 44100;
            g_micASBD.mFormatID = kAudioFormatLinearPCM;
            g_micASBD.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
            g_micASBD.mBytesPerPacket = 4;
            g_micASBD.mFramesPerPacket = 1;
            g_micASBD.mBytesPerFrame = 4;
            g_micASBD.mChannelsPerFrame = 2;
            g_micASBD.mBitsPerChannel = 16;
            g_hasProbedMicFormat = YES;
            if (g_tempFile) LoadAudio(g_tempFile, g_micASBD);
        }
    }

    OSStatus ret = orig_AudioUnitRender(rc, f, ts, bus, frames, io);
    if (ret != noErr) return ret;

    if (!g_isSoundEnabled || !g_audioCache) return ret;

    UInt32 bpf = g_micASBD.mBytesPerFrame ?: g_micASBD.mChannelsPerFrame * (g_micASBD.mBitsPerChannel / 8);
    UInt32 need = frames * bpf;

    NSData *d = ReadAudio(need);
    if (d.length < need) return ret;

    BOOL ni = (g_micASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved);

    if (ni) {
        UInt32 per = need / io->mNumberBuffers;
        for (UInt32 i = 0; i < io->mNumberBuffers; i++) {
            memcpy(io->mBuffers[i].mData,
                   (uint8_t *)d.bytes + i * per,
                   per);
        }
    } else {
        memcpy(io->mBuffers[0].mData, d.bytes, need);
    }

    return ret;
}

#pragma mark - 视频代理

@interface VCamVideoProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation VCamVideoProxy {
    __weak id _orig;
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    CVPixelBufferRef buf = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!buf) return;

    static NSTimeInterval last = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSString *mark = [g_tempFile stringByAppendingString:@".new"];
    if ([g_fileManager fileExistsAtPath:mark] && now - last > 1.0) {
        last = now;
        [g_fileManager removeItemAtPath:mark error:nil];
        SetupVideo(g_tempFile);
        if (g_hasProbedMicFormat) LoadAudio(g_tempFile, g_micASBD);
    }

    CVPixelBufferRef src = ReadVideoFrame();
    if (!src) return;

    CIImage *img = [CIImage imageWithCVPixelBuffer:src];
    CVPixelBufferRelease(src);
    if (!img) return;

    CGAffineTransform t = CGAffineTransformIdentity;
    CGRect e = img.extent;
    if (g_rotation == 90) {
        t = CGAffineTransformMakeTranslation(e.size.height, 0);
        t = CGAffineTransformRotate(t, M_PI_2);
    } else if (g_rotation == 180) {
        t = CGAffineTransformMakeTranslation(e.size.width, e.size.height);
        t = CGAffineTransformRotate(t, M_PI);
    } else if (g_rotation == 270) {
        t = CGAffineTransformMakeTranslation(0, e.size.width);
        t = CGAffineTransformRotate(t, 3 * M_PI_2);
    }

    CIImage *r = [img imageByApplyingTransform:t];
    CGFloat scale = MAX(CVPixelBufferGetWidth(buf) / r.extent.size.width,
                        CVPixelBufferGetHeight(buf) / r.extent.size.height);
    CIImage *s = [r imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CIImage *f = [s imageByApplyingTransform:
        CGAffineTransformMakeTranslation(
            (CVPixelBufferGetWidth(buf) - s.extent.size.width)/2,
            (CVPixelBufferGetHeight(buf) - s.extent.size.height)/2)];

    static CIContext *ctx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });

    CVPixelBufferLockBaseAddress(buf, 0);
    [ctx render:f toCVPixelBuffer:buf];
    CVPixelBufferUnlockBaseAddress(buf, 0);

    if (_orig && [_orig respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [_orig captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

@end

static VCamVideoProxy *g_proxy = nil;

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (!g_proxy) g_proxy = [VCamVideoProxy new];
    ((VCamVideoProxy *)g_proxy)->_orig = delegate;
    %orig(g_proxy, queue);
}
%end

#pragma mark - 菜单（✅ 原样保留）

static UIWindow* GetKeyWindow(void) {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows)
                if (w.isKeyWindow) return w;
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
    container.layer.cornerRadius = 16;
    container.clipsToBounds = YES;
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:container];

    [NSLayoutConstraint activateConstraints:@[
        [container.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [container.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [container.widthAnchor constraintEqualToConstant:300]
    ]];

    UIView *navBar = [[UIView alloc] init];
    navBar.backgroundColor = [UIColor systemGray6Color];
    navBar.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:navBar];

    [NSLayoutConstraint activateConstraints:@[
        [navBar.topAnchor constraintEqualToAnchor:container.topAnchor],
        [navBar.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [navBar.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [navBar.heightAnchor constraintEqualToConstant:44]
    ]];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"VCAM 控制";
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [navBar addSubview:title];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:navBar.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:navBar.centerYAnchor]
    ]];

    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont systemFontOfSize:18];
    [cancelBtn addTarget:self action:@selector(cancelAndDismiss) forControlEvents:UIControlEventTouchUpInside];
    cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [navBar addSubview:cancelBtn];

    [NSLayoutConstraint activateConstraints:@[
        [cancelBtn.leadingAnchor constraintEqualToAnchor:navBar.leadingAnchor constant:16],
        [cancelBtn.centerYAnchor constraintEqualToAnchor:navBar.centerYAnchor]
    ]];

    UIButton *confirmBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [confirmBtn setTitle:@"确认" forState:UIControlStateNormal];
    confirmBtn.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [confirmBtn addTarget:self action:@selector(confirmAndDismiss) forControlEvents:UIControlEventTouchUpInside];
    confirmBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [navBar addSubview:confirmBtn];

    [NSLayoutConstraint activateConstraints:@[
        [confirmBtn.trailingAnchor constraintEqualToAnchor:navBar.trailingAnchor constant:-16],
        [confirmBtn.centerYAnchor constraintEqualToAnchor:navBar.centerYAnchor]
    ]];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:navBar.bottomAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16]
    ]];

    UIButton* (^btn)(NSString *) = ^UIButton*(NSString *t){
        UIButtonConfiguration *c = [UIButtonConfiguration filledButtonConfiguration];
        c.baseBackgroundColor = [UIColor systemGray5Color];
        c.baseForegroundColor = [UIColor labelColor];
        c.contentInsets = NSDirectionalEdgeInsetsMake(12, 0, 12, 0);
        c.attributedTitle = [[NSAttributedString alloc] initWithString:t
                                                           attributes:@{NSFontAttributeName:[UIFont systemFontOfSize:18 weight:UIFontWeightMedium]}];
        UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:nil];
        b.layer.cornerRadius = 8;
        return b;
    };

    UIButton *selectBtn = btn(@"选择视频");
    [selectBtn addTarget:self action:@selector(selectVideoTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:selectBtn];

    _rotateBtn = btn([NSString stringWithFormat:@"旋转画面 (%d°)", _tempRotation]);
    [_rotateBtn addTarget:self action:@selector(rotatePreview:) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:_rotateBtn];

    _soundBtn = btn(_tempSound ? @"声音：开启" : @"声音：关闭");
    [_soundBtn addTarget:self action:@selector(soundPreview:) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:_soundBtn];

    _loopBtn = btn(_tempLoop ? @"循环播放：开启" : @"循环播放：关闭");
    [_loopBtn addTarget:self action:@selector(loopPreview:) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:_loopBtn];

    UIButton *disableBtn = btn(@"禁用替换");
    [disableBtn addTarget:self action:@selector(disableTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:disableBtn];
}

- (void)rotatePreview:(UIButton*)btn {
    _tempRotation = (_tempRotation + 90) % 360;
    [_rotateBtn setTitle:[NSString stringWithFormat:@"旋转画面 (%d°)", _tempRotation] forState:UIControlStateNormal];
}

- (void)soundPreview:(UIButton*)btn {
    _tempSound = !_tempSound;
    [_soundBtn setTitle:_tempSound ? @"声音：开启" : @"声音：关闭" forState:UIControlStateNormal];
}

- (void)loopPreview:(UIButton*)btn {
    _tempLoop = !_tempLoop;
    [_loopBtn setTitle:_tempLoop ? @"循环播放：开启" : @"循环播放：关闭" forState:UIControlStateNormal];
}

- (void)confirmAndDismiss {
    g_rotation = _tempRotation;
    g_isSoundEnabled = _tempSound;
    g_isLoop = _tempLoop;
    SaveSettings();
    [self dismissViewControllerAnimated:YES completion:^{ g_isPresentingMenu = NO; }];
}

- (void)cancelAndDismiss {
    [self dismissViewControllerAnimated:YES completion:^{ g_isPresentingMenu = NO; }];
}

- (void)selectVideoTapped {
    static id delegate = nil;
    if (!delegate) {
        Class cls = objc_allocateClassPair(NSObject.class, "VCamPickerDelegate", 0);
        objc_registerClassPair(cls);
        class_addProtocol(cls, @protocol(UIImagePickerControllerDelegate));
        class_addProtocol(cls, @protocol(UINavigationControllerDelegate));

        IMP imp = imp_implementationWithBlock(^(id s, UIImagePickerController *picker, NSDictionary *info) {
            [picker dismissViewControllerAnimated:YES completion:nil];
            NSURL *url = info[UIImagePickerControllerMediaURL];
            if (url) {
                if ([g_fileManager fileExistsAtPath:g_tempFile])
                    [g_fileManager removeItemAtPath:g_tempFile error:nil];
                if ([g_fileManager copyItemAtPath:url.path toPath:g_tempFile error:nil]) {
                    [@"1" writeToFile:[g_tempFile stringByAppendingString:@".new"]
                           atomically:YES
                             encoding:NSUTF8StringEncoding
                                error:nil];
                }
            }
        });
        class_addMethod(cls, @selector(imagePickerController:didFinishPickingMediaWithInfo:), imp, "v@:@@");

        imp = imp_implementationWithBlock(^(id s, UIImagePickerController *picker) {
            [picker dismissViewControllerAnimated:YES completion:nil];
        });
        class_addMethod(cls, @selector(imagePickerControllerDidCancel:), imp, "v@:@");

        delegate = [cls new];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[@"public.movie"];
        picker.delegate = delegate;
        [self presentViewController:picker animated:YES completion:nil];
    });
}

- (void)disableTapped {
    if ([g_fileManager fileExistsAtPath:g_tempFile])
        [g_fileManager removeItemAtPath:g_tempFile error:nil];
    [g_lock lock];
    if (g_videoReader) [g_videoReader cancelReading];
    g_videoReader = nil;
    g_audioCache = nil;
    g_audioOffset = 0;
    [g_lock unlock];
    [self dismissViewControllerAnimated:YES completion:^{ g_isPresentingMenu = NO; }];
}

@end

static void ShowVCamMenu(void) {
    if (g_isPresentingMenu) return;
    g_isPresentingMenu = YES;
    UIWindow *key = GetKeyWindow();
    if (!key) { g_isPresentingMenu = NO; return; }
    VCamMenuViewController *vc = [[VCamMenuViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    UIViewController *root = key.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    [root presentViewController:vc animated:YES completion:nil];
}

@interface UIWindow (VCam)
@end
@implementation UIWindow (VCam)
- (void)vcam_handleTwoFingerDoubleTap:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateRecognized) ShowVCamMenu();
}
@end

static void AddGestureToWindow(UIWindow *win) {
    static NSMapTable *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMapTable weakToStrongObjectsMapTable]; });
    if ([map objectForKey:win]) return;
    UITapGestureRecognizer *tap =
    [[UITapGestureRecognizer alloc] initWithTarget:win action:@selector(vcam_handleTwoFingerDoubleTap:)];
    tap.numberOfTouchesRequired = 2;
    tap.numberOfTapsRequired = 2;
    tap.cancelsTouchesInView = NO;
    [win addGestureRecognizer:tap];
    [map setObject:@YES forKey:win];
}

%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ AddGestureToWindow(self); });
}
- (id)initWithFrame:(CGRect)frame {
    self = %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ AddGestureToWindow(self); });
    return self;
}
%end

#pragma mark - 构造

%ctor {
    g_fileManager = NSFileManager.defaultManager;
    g_lock = [[NSLock alloc] init];
    LoadSettings();
    g_tempFile = [[DocPath() stringByAppendingPathComponent:@"bear_vcam_temp.mov"] copy];

    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
        SetupVideo(g_tempFile);
    }

    MSHookFunction((void *)AudioUnitRender,
                   (void *)hooked_AudioUnitRender,
                   (void **)&orig_AudioUnitRender);
}
