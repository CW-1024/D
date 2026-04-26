#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <substrate.h>

#pragma mark - 全局状态

static NSString *g_tempFile = nil;
static BOOL g_isSoundEnabled = YES;
static BOOL g_isLoop = YES;
static int g_rotation = 90;

static AudioStreamBasicDescription g_micASBD = {0};
static BOOL g_hasProbedMicFormat = NO;

static AVAssetReader *g_videoReader = nil;
static AVAssetReaderTrackOutput *g_videoOutput = nil;
static AVAssetReader *g_audioReader = nil;
static AVAssetReaderTrackOutput *g_audioOutput = nil;

static NSLock *g_mediaLock = nil;
static NSFileManager *g_fileManager = nil;

static OSStatus (*orig_AudioUnitRender)(
    void *,
    AudioUnitRenderActionFlags *,
    const AudioTimeStamp *,
    UInt32,
    UInt32,
    AudioBufferList *
) = NULL;

#pragma mark - 工具

static NSString *DocPath(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

static void SaveCfg(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setInteger:g_rotation forKey:@"vcam_rotation"];
    [d setBool:g_isSoundEnabled forKey:@"vcam_sound"];
    [d setBool:g_isLoop forKey:@"vcam_loop"];
}

static void LoadCfg(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d objectForKey:@"vcam_rotation"]) g_rotation = (int)[d integerForKey:@"vcam_rotation"];
    if ([d objectForKey:@"vcam_sound"]) g_isSoundEnabled = [d boolForKey:@"vcam_sound"];
    if ([d objectForKey:@"vcam_loop"]) g_isLoop = [d boolForKey:@"vcam_loop"];
}

#pragma mark - 视频读取

static void SetupVideoReader(NSString *path) {
    [g_mediaLock lock];
    if (g_videoReader) {
        [g_videoReader cancelReading];
        g_videoReader = nil;
    }
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:path]];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) { [g_mediaLock unlock]; return; }

    NSError *err = nil;
    g_videoReader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (err) { [g_mediaLock unlock]; return; }

    g_videoOutput = [[AVAssetReaderTrackOutput alloc]
        initWithTrack:track
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
    g_videoOutput.alwaysCopiesSampleData = NO;
    [g_videoReader addOutput:g_videoOutput];
    [g_videoReader startReading];
    [g_mediaLock unlock];
}

static CVPixelBufferRef ReadVideoFrame(void) {
    [g_mediaLock lock];
    CMSampleBufferRef s = [g_videoOutput copyNextSampleBuffer];
    if (!s && g_isLoop && g_tempFile) {
        [g_mediaLock unlock];
        SetupVideoReader(g_tempFile);
        [g_mediaLock lock];
        s = [g_videoOutput copyNextSampleBuffer];
    }
    CVPixelBufferRef pb = s ? CMSampleBufferGetImageBuffer(s) : NULL;
    if (pb) CVPixelBufferRetain(pb);
    if (s) CFRelease(s);
    [g_mediaLock unlock];
    return pb;
}

#pragma mark - 音频读取（严格对齐原始 VCAM）

static void SetupAudioReader(NSString *path) {
    [g_mediaLock lock];
    if (g_audioReader) {
        [g_audioReader cancelReading];
        g_audioReader = nil;
    }
    if (!g_hasProbedMicFormat) {
        [g_mediaLock unlock];
        return;
    }
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:path]];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!track) { [g_mediaLock unlock]; return; }

    NSDictionary *cfg = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(g_micASBD.mSampleRate),
        AVNumberOfChannelsKey: @(g_micASBD.mChannelsPerFrame),
        AVLinearPCMBitDepthKey: @(g_micASBD.mBitsPerChannel),
        AVLinearPCMIsFloatKey: @((g_micASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0),
        AVLinearPCMIsBigEndianKey: @((g_micASBD.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0),
        AVLinearPCMIsNonInterleaved: @((g_micASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0)
    };

    NSError *err = nil;
    g_audioReader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    g_audioOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:cfg];
    [g_audioReader addOutput:g_audioOutput];
    [g_audioReader startReading];
    [g_mediaLock unlock];
}

static NSData *PullAudioData(UInt32 need) {
    NSMutableData *d = [NSMutableData data];
    [g_mediaLock lock];
    while (d.length < need) {
        if (!g_audioReader || g_audioReader.status != AVAssetReaderStatusReading) {
            if (g_isLoop && g_tempFile) {
                [g_mediaLock unlock];
                SetupAudioReader(g_tempFile);
                [g_mediaLock lock];
                continue;
            }
            break;
        }
        CMSampleBufferRef s = [g_audioOutput copyNextSampleBuffer];
        if (!s) break;
        CMBlockBufferRef b = CMSampleBufferGetDataBuffer(s);
        size_t l = 0;
        CMBlockBufferGetDataPointer(b, 0, NULL, &l, NULL);
        if (l > 0) {
            uint8_t *p = malloc(l);
            CMBlockBufferCopyDataBytes(b, 0, l, p);
            [d appendBytes:p length:l];
            free(p);
        }
        CFRelease(s);
    }
    [g_mediaLock unlock];
    if (d.length < need) {
        [d increaseLengthBy:need - d.length];
    }
    return d;
}

#pragma mark - AudioUnitRender Hook（✅ 完全对齐原始 VCAM）

static OSStatus hooked_AudioUnitRender(
    void *inRefCon,
    AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *ts,
    UInt32 bus,
    UInt32 frames,
    AudioBufferList *io
) {
    if (bus != 1) {
        return orig_AudioUnitRender(inRefCon, flags, ts, bus, frames, io);
    }

    if (!g_hasProbedMicFormat) {
        AudioUnit au = (AudioUnit)inRefCon;
        UInt32 sz = sizeof(g_micASBD);
        if (AudioUnitGetProperty(au,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input, // ✅ 原始 VCAM 关键点
                                 1,
                                 &g_micASBD,
                                 &sz) == noErr) {
            g_hasProbedMicFormat = YES;
            if (g_tempFile) SetupAudioReader(g_tempFile);
        }
    }

    OSStatus ret = orig_AudioUnitRender(inRefCon, flags, ts, bus, frames, io);
    if (!g_isSoundEnabled || !g_audioReader) return ret;

    UInt32 bytesPerFrame = g_micASBD.mBytesPerFrame ?: g_micASBD.mChannelsPerFrame * (g_micASBD.mBitsPerChannel / 8);
    UInt32 need = frames * bytesPerFrame;

    NSData *data = PullAudioData(need);
    BOOL nonInt = (g_micASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved);

    if (nonInt) {
        UInt32 per = need / io->mNumberBuffers;
        for (UInt32 i = 0; i < io->mNumberBuffers; i++) {
            memcpy(io->mBuffers[i].mData, data.bytes + i * per, per);
        }
    } else {
        memcpy(io->mBuffers[0].mData, data.bytes, need);
    }

    return noErr;
}

#pragma mark - 视频注入

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(dispatch_queue_t)q {
    %orig;
    MSHookFunction((void *)AudioUnitRender, (void *)hooked_AudioUnitRender, (void **)&orig_AudioUnitRender);
}
%end

%ctor {
    g_fileManager = NSFileManager.defaultManager;
    g_mediaLock = [[NSLock alloc] init];
    LoadCfg();
    g_tempFile = [DocPath() stringByAppendingPathComponent:@"bear_vcam_temp.mov"];
    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
        SetupVideoReader(g_tempFile);
    }
}
