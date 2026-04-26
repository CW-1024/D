#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

// ======================== 全局变量 ========================
static NSFileManager *g_fileManager = nil;
static NSString *g_tempFile = nil;
static BOOL g_isPresentingMenu = NO;

static int g_rotation = 90;
static BOOL g_isSoundEnabled = YES;      // 声音替换总开关（对应原始 g_isSound）
static BOOL g_isLoop = YES;              // 循环播放

static AudioStreamBasicDescription g_micASBD = {0};  // 探测到的麦克风实际格式（对应 g_targetASBD）
static BOOL g_hasProbedMicFormat = NO;   // 对应 g_hasProbedASBD
static NSLock *g_mediaLock = nil;        // 多线程安全锁

static AVAssetReader *g_videoReader = nil;
static AVAssetReaderTrackOutput *g_videoOutput = nil;
static AVAssetReader *g_audioReader = nil;
static AVAssetReaderTrackOutput *g_audioOutput = nil;

// 原始 AudioUnitRender 函数指针
static OSStatus (*orig_AudioUnitRender)(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                                        UInt32 inNumberFrames, AudioBufferList *ioData) = NULL;

// ======================== 设置保存与加载 ========================
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

// ======================== 辅助函数 ========================
static NSString* GetDocumentPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

// ======================== 视频 / 音频读取器管理 ========================
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
    if (error || !g_videoReader) {
        [g_mediaLock unlock];
        return;
    }
    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count == 0) {
        [g_mediaLock unlock];
        return;
    }
    AVAssetTrack *videoTrack = videoTracks[0];
    NSDictionary *settings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    g_videoOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:settings];
    g_videoOutput.alwaysCopiesSampleData = NO;
    [g_videoReader addOutput:g_videoOutput];
    [g_videoReader startReading];
    [g_mediaLock unlock];
}

// 音频读取器：输出格式严格匹配探测到的麦克风格式
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
    NSError *error = nil;
    g_audioOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    g_audioReader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (g_audioReader && !error) {
        [g_audioReader addOutput:g_audioOutput];
        if (![g_audioReader startReading]) {
            g_audioReader = nil;
            g_audioOutput = nil;
        }
    }
    [g_mediaLock unlock];
}

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

// 从音频读取器拉取指定长度的 PCM 数据（支持循环）
static NSData* PullAudioData(NSUInteger needBytes) {
    NSMutableData *data = [NSMutableData dataWithCapacity:needBytes];
    [g_mediaLock lock];
    while (data.length < needBytes) {
        if (!g_audioReader || g_audioReader.status != AVAssetReaderStatusReading) {
            if (g_isLoop && g_tempFile) {
                [g_mediaLock unlock];
                SetupAudioReader(g_tempFile);
                [g_mediaLock lock];
                if (!g_audioReader || g_audioReader.status != AVAssetReaderStatusReading) break;
                continue;
            } else break;
        }
        CMSampleBufferRef sample = [g_audioOutput copyNextSampleBuffer];
        if (!sample) {
            if (g_isLoop && g_tempFile) {
                [g_mediaLock unlock];
                SetupAudioReader(g_tempFile);
                [g_mediaLock lock];
                if (!g_audioReader || g_audioReader.status != AVAssetReaderStatusReading) break;
                continue;
            } else break;
        }
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        size_t totalSize = 0;
        if (block) CMBlockBufferGetDataPointer(block, 0, NULL, &totalSize, NULL);
        if (totalSize > 0) {
            NSUInteger remaining = needBytes - data.length;
            NSUInteger copyLen = MIN(totalSize, remaining);
            void *ptr = malloc(copyLen);
            if (ptr) {
                if (CMBlockBufferCopyDataBytes(block, 0, copyLen, ptr) == kCMBlockBufferNoErr) {
                    [data appendBytes:ptr length:copyLen];
                }
                free(ptr);
            }
        }
        CFRelease(sample);
    }
    [g_mediaLock unlock];
    // 补足静音（避免播放器崩溃）
    if (data.length < needBytes) {
        [data increaseLengthBy:needBytes - data.length];
    }
    return data;
}

// ======================== 画面处理 ========================
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
    size_t targetWidth  = CVPixelBufferGetWidth(targetBuffer);
    size_t targetHeight = CVPixelBufferGetHeight(targetBuffer);
    CGRect rotatedExtent = rotated.extent;
    CGFloat scale = MAX(targetWidth / rotatedExtent.size.width, targetHeight / rotatedExtent.size.height);
    CIImage *scaled = [rotated imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect scaledExtent = scaled.extent;
    CIImage *final = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation((targetWidth - scaledExtent.size.width)/2.0,
                                                                                       (targetHeight - scaledExtent.size.height)/2.0)];
    static CIContext *ctx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB()}];
    });
    CVPixelBufferLockBaseAddress(targetBuffer, 0);
    [ctx render:final toCVPixelBuffer:targetBuffer];
    CVPixelBufferUnlockBaseAddress(targetBuffer, 0);
}

// ======================== 视频代理 ========================
@interface VCamVideoProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
- (void)setOriginalDelegate:(id)delegate queue:(dispatch_queue_t)queue;
@end
@implementation VCamVideoProxy {
    __weak id _originalDelegate;
    dispatch_queue_t _originalQueue;
}
- (void)setOriginalDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    _originalDelegate = delegate;
    _originalQueue = queue;
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    CVPixelBufferRef buf = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (buf) DrawReplacementOntoBuffer(buf);
    if (_originalDelegate && [_originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [_originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}
@end
static VCamVideoProxy *g_videoProxy = nil;

// ======================== 音频代理 ========================
@interface VCamAudioProxy : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
- (void)setOriginalDelegate:(id)delegate queue:(dispatch_queue_t)queue;
@end
@implementation VCamAudioProxy {
    __weak id _originalDelegate;
    dispatch_queue_t _originalQueue;
}
- (void)setOriginalDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    _originalDelegate = delegate;
    _originalQueue = queue;
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (g_isSoundEnabled) {
        // 获取原始音频数据的长度
        CMBlockBufferRef origBlock = CMSampleBufferGetDataBuffer(sampleBuffer);
        size_t totalLength = 0;
        if (origBlock) {
            CMBlockBufferGetDataPointer(origBlock, 0, NULL, &totalLength, NULL);
            if (totalLength > 0) {
                NSData *replacement = PullAudioData(totalLength);
                if (replacement.length > 0) {
                    // 创建新的 BlockBuffer 并替换
                    CMBlockBufferRef newBlock = NULL;
                    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, totalLength,
                                                                         kCFAllocatorDefault, NULL, 0, totalLength, 0, &newBlock);
                    if (status == kCMBlockBufferNoErr && newBlock) {
                        status = CMBlockBufferReplaceDataBytes(replacement.bytes, newBlock, 0, totalLength);
                        if (status == kCMBlockBufferNoErr) {
                            CMSampleBufferSetDataBuffer(sampleBuffer, newBlock);
                        }
                        CFRelease(newBlock);
                    }
                }
            }
        }
    }
    if (_originalDelegate && [_originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [_originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}
@end
static VCamAudioProxy *g_audioProxy = nil;

// ======================== Hook AVCaptureVideoDataOutput ========================
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (!g_videoProxy) g_videoProxy = [[VCamVideoProxy alloc] init];
    [g_videoProxy setOriginalDelegate:delegate queue:queue];
    %orig(g_videoProxy, queue);
}
%end

// ======================== Hook AVCaptureAudioDataOutput ========================
%hook AVCaptureAudioDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (!g_audioProxy) g_audioProxy = [[VCamAudioProxy alloc] init];
    [g_audioProxy setOriginalDelegate:delegate queue:queue];
    %orig(g_audioProxy, queue);
}
%end

// ======================== Hook AudioUnitRender 用于格式探测和备用替换 ========================
static OSStatus hooked_AudioUnitRender(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                                        UInt32 inNumberFrames, AudioBufferList *ioData) {
    // 探测麦克风实际格式（仅第一次）
    if (!g_hasProbedMicFormat) {
        AudioUnit au = (AudioUnit)inRefCon;
        UInt32 size = sizeof(g_micASBD);
        if (AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inBusNumber,
                                 &g_micASBD, &size) == noErr) {
            g_hasProbedMicFormat = YES;
            if (g_tempFile && [g_fileManager fileExistsAtPath:g_tempFile]) {
                SetupAudioReader(g_tempFile);
            }
        } else {
            // 回退默认格式（44.1kHz 16bit 双声道）
            memset(&g_micASBD, 0, sizeof(g_micASBD));
            g_micASBD.mSampleRate = 44100.0;
            g_micASBD.mFormatID = kAudioFormatLinearPCM;
            g_micASBD.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
            g_micASBD.mBytesPerPacket = 4;
            g_micASBD.mFramesPerPacket = 1;
            g_micASBD.mBytesPerFrame = 4;
            g_micASBD.mChannelsPerFrame = 2;
            g_micASBD.mBitsPerChannel = 16;
            g_hasProbedMicFormat = YES;
            if (g_tempFile && [g_fileManager fileExistsAtPath:g_tempFile]) {
                SetupAudioReader(g_tempFile);
            }
        }
    }

    OSStatus ret = orig_AudioUnitRender(inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    if (ret != noErr) return ret;

    // 替换音频数据（备用路径，确保某些情况下也能替换）
    if (g_isSoundEnabled && g_audioReader && g_audioReader.status == AVAssetReaderStatusReading) {
        UInt32 needBytes = inNumberFrames * g_micASBD.mBytesPerFrame;
        if (needBytes > 0 && ioData && ioData->mNumberBuffers > 0) {
            NSData *replacement = PullAudioData(needBytes);
            if (replacement.length >= needBytes) {
                const void *src = replacement.bytes;
                for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
                    AudioBuffer *buf = &ioData->mBuffers[i];
                    if (buf->mData && buf->mDataByteSize >= needBytes) {
                        memcpy(buf->mData, src, needBytes);
                    }
                }
            }
        }
    }
    return ret;
}

static void InstallAudioHook(void) {
    MSHookFunction((void *)AudioUnitRender, (void *)hooked_AudioUnitRender, (void **)&orig_AudioUnitRender);
}

// ======================== 悬浮菜单 UI（简化版，保持与原始一致） ========================
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
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];
    [stack.topAnchor constraintEqualToAnchor:navBar.bottomAnchor constant:16].active = YES;
    [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-16].active = YES;
    [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16].active = YES;
    [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16].active = YES;
    // 按钮辅助
    UIButton* (^createBtn)(NSString *) = ^UIButton *(NSString *t){
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:t forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
        b.backgroundColor = [UIColor systemGray5Color];
        b.layer.cornerRadius = 8;
        [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        [b.heightAnchor constraintEqualToConstant:48].active = YES;
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
- (void)rotatePreview:(UIButton*)b {
    _tempRotation = (_tempRotation + 90) % 360;
    [_rotateBtn setTitle:[NSString stringWithFormat:@"旋转画面 (%d°)", _tempRotation] forState:UIControlStateNormal];
}
- (void)soundPreview:(UIButton*)b {
    _tempSound = !_tempSound;
    [_soundBtn setTitle:_tempSound ? @"声音：开启" : @"声音：关闭" forState:UIControlStateNormal];
}
- (void)loopPreview:(UIButton*)b {
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
    static id delegateHolder;
    if (!delegateHolder) {
        Class cls = objc_allocateClassPair([NSObject class], "TempImagePickerDelegate", 0);
        class_addProtocol(cls, @protocol(UIImagePickerControllerDelegate));
        class_addProtocol(cls, @protocol(UINavigationControllerDelegate));
        IMP imp = imp_implementationWithBlock(^(id self, UIImagePickerController *picker, NSDictionary *info) {
            [picker dismissViewControllerAnimated:YES completion:nil];
            NSURL *url = info[UIImagePickerControllerMediaURL];
            if (url) {
                NSString *src = url.path;
                if ([g_fileManager fileExistsAtPath:g_tempFile])
                    [g_fileManager removeItemAtPath:g_tempFile error:nil];
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
        delegateHolder = [cls new];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[@"public.movie"];
        picker.delegate = delegateHolder;
        [self presentViewController:picker animated:YES completion:nil];
    });
}
- (void)disableTapped {
    if (g_fileManager && g_tempFile && [g_fileManager fileExistsAtPath:g_tempFile]) {
        [g_fileManager removeItemAtPath:g_tempFile error:nil];
    }
    [g_mediaLock lock];
    if (g_videoReader) [g_videoReader cancelReading];
    g_videoReader = nil; g_videoOutput = nil;
    if (g_audioReader) [g_audioReader cancelReading];
    g_audioReader = nil; g_audioOutput = nil;
    [g_mediaLock unlock];
    [self dismissViewControllerAnimated:YES completion:^{ g_isPresentingMenu = NO; }];
}
@end

static void ShowVCamMenu(void) {
    if (g_isPresentingMenu) return;
    g_isPresentingMenu = YES;
    UIWindow *key = GetCurrentKeyWindow();
    if (!key) { g_isPresentingMenu = NO; return; }
    VCamMenuViewController *vc = [[VCamMenuViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    UIViewController *root = key.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    [root presentViewController:vc animated:YES completion:nil];
}

// ======================== 手势呼出菜单 ========================
@interface UIWindow (VCam)
- (void)vcam_handleTwoFingerDoubleTap:(UITapGestureRecognizer *)tap;
@end
@implementation UIWindow (VCam)
- (void)vcam_handleTwoFingerDoubleTap:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateRecognized) ShowVCamMenu();
}
@end
static void AddGestureToWindow(UIWindow *win) {
    static NSMapTable *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ map = [NSMapTable weakToStrongObjectsMapTable]; });
    if ([map objectForKey:win]) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:win action:@selector(vcam_handleTwoFingerDoubleTap:)];
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

// ======================== 初始化与清理 ========================
%ctor {
    g_fileManager = [NSFileManager defaultManager];
    g_mediaLock = [[NSLock alloc] init];
    LoadSettings();
    g_tempFile = [[GetDocumentPath() stringByAppendingPathComponent:@"bear_vcam_temp.mov"] copy];
    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
        SetupVideoReader(g_tempFile);
        // 若已经探测过格式，则尝试建立音频读取器（但开始时可能还未探测，等待 AudioUnit 回调）
        if (g_hasProbedMicFormat) SetupAudioReader(g_tempFile);
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