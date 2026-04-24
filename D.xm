#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// 全局变量
// ============================================================
static NSFileManager *g_fileManager = nil;
static NSString *g_tempFile = nil; // 动态生成路径
static BOOL g_isPresentingMenu = NO;

// 视频替换
static NSMutableArray *g_videoFrames = nil;
static NSUInteger g_currentFrameIndex = 0;
static CIContext *g_ciContext = nil;
static NSLock *g_videoLock = nil;
static CGColorSpaceRef g_colorSpace = NULL;

// ============================================================
// 获取微信沙盒 Caches 目录
// ============================================================
static NSString* GetWeChatCachesPath(void) {
    // 通过 NSHomeDirectory() 获取当前 App 的沙盒根目录
    // 对于证书注入，当前进程就是微信，因此可直接使用
    NSString *homePath = NSHomeDirectory();
    NSString *cachesPath = [homePath stringByAppendingPathComponent:@"Library/Caches"];
    // 确保目录存在
    if (![g_fileManager fileExistsAtPath:cachesPath]) {
        [g_fileManager createDirectoryAtPath:cachesPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return [cachesPath stringByAppendingPathComponent:@"temp.mov"];
}

// ============================================================
// 视频帧加载
// ============================================================
static void LoadVideoFramesFromFile(NSString *filePath) {
    if (!g_videoLock) g_videoLock = [[NSLock alloc] init];
    [g_videoLock lock];

    if (g_videoFrames) {
        for (id obj in g_videoFrames) {
            CVPixelBufferRef buf = (__bridge CVPixelBufferRef)obj;
            CVPixelBufferRelease(buf);
        }
        [g_videoFrames removeAllObjects];
    } else {
        g_videoFrames = [NSMutableArray array];
    }
    g_currentFrameIndex = 0;

    if (![g_fileManager fileExistsAtPath:filePath]) {
        [g_videoLock unlock];
        return;
    }

    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:filePath]];
    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (error) { [g_videoLock unlock]; return; }

    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count == 0) { [g_videoLock unlock]; return; }

    AVAssetTrack *videoTrack = videoTracks[0];
    NSDictionary *settings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    [reader addOutput:output];
    [reader startReading];

    const int maxFrames = 90;
    while (reader.status == AVAssetReaderStatusReading && g_videoFrames.count < maxFrames) {
        CMSampleBufferRef sample = [output copyNextSampleBuffer];
        if (!sample) break;
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sample);
        if (pixelBuffer) {
            CVPixelBufferRetain(pixelBuffer);
            [g_videoFrames addObject:(__bridge id)pixelBuffer];
        }
        CFRelease(sample);
    }
    [reader cancelReading];
    [g_videoLock unlock];
}

static CVPixelBufferRef GetNextVideoFrame(void) {
    [g_videoLock lock];
    if (g_videoFrames.count == 0) {
        [g_videoLock unlock];
        return NULL;
    }
    CVPixelBufferRef frame = (__bridge CVPixelBufferRef)g_videoFrames[g_currentFrameIndex];
    g_currentFrameIndex = (g_currentFrameIndex + 1) % g_videoFrames.count;
    [g_videoLock unlock];
    return frame;
}

// ============================================================
// 绘制替换帧到目标 Buffer
// ============================================================
static void DrawReplacementOntoBuffer(CVPixelBufferRef targetBuffer) {
    if (!g_fileManager || !g_tempFile || ![g_fileManager fileExistsAtPath:g_tempFile]) return;

    static NSTimeInterval lastLoadTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *newMark = [g_tempFile stringByAppendingString:@".new"];

    if ([g_fileManager fileExistsAtPath:newMark] && (now - lastLoadTime) > 3.0) {
        lastLoadTime = now;
        LoadVideoFramesFromFile(g_tempFile);
        [g_fileManager removeItemAtPath:newMark error:nil];
    }

    if (!g_videoFrames || g_videoFrames.count == 0) {
        LoadVideoFramesFromFile(g_tempFile);
        if (!g_videoFrames || g_videoFrames.count == 0) return;
    }

    CVPixelBufferRef srcBuffer = GetNextVideoFrame();
    if (!srcBuffer) return;

    CIImage *srcImage = [CIImage imageWithCVPixelBuffer:srcBuffer];
    if (!srcImage) return;

    size_t targetWidth = CVPixelBufferGetWidth(targetBuffer);
    size_t targetHeight = CVPixelBufferGetHeight(targetBuffer);
    CGRect srcExtent = srcImage.extent;

    CGFloat scaleX = targetWidth / srcExtent.size.width;
    CGFloat scaleY = targetHeight / srcExtent.size.height;
    CGFloat scale = MAX(scaleX, scaleY);

    CIImage *scaledImage = [srcImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect scaledExtent = scaledImage.extent;
    CGFloat offsetX = (targetWidth - scaledExtent.size.width) / 2.0;
    CGFloat offsetY = (targetHeight - scaledExtent.size.height) / 2.0;
    CIImage *finalImage = [scaledImage imageByApplyingTransform:CGAffineTransformMakeTranslation(offsetX, offsetY)];

    if (!g_ciContext) {
        g_colorSpace = CGColorSpaceCreateDeviceRGB();
        g_ciContext = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: (__bridge id)g_colorSpace}];
    }

    CVPixelBufferLockBaseAddress(targetBuffer, 0);
    [g_ciContext render:finalImage toCVPixelBuffer:targetBuffer];
    CVPixelBufferUnlockBaseAddress(targetBuffer, 0);
}

// ============================================================
// 底层 Hook：BWNodeOutput（全局生效）
// ============================================================
%hook BWNodeOutput
- (void)emitSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    unsigned int mediaType = ((unsigned int (*)(id, SEL))objc_msgSend)(self, sel_registerName("mediaType"));
    if (mediaType != 'vide') {
        %orig(sampleBuffer);
        return;
    }

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer) {
        @try {
            DrawReplacementOntoBuffer(pixelBuffer);
        } @catch (NSException *e) {}
    }

    %orig(sampleBuffer);
}
%end

// ============================================================
// 手势菜单（适配沙盒路径）
// ============================================================
@interface GetFrame : NSObject
+ (UIWindow*)getKeyWindow;
@end

@implementation GetFrame
+ (UIWindow*)getKeyWindow {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *window in scene.windows) {
                if (window.isKeyWindow) return window;
            }
            return scene.windows.firstObject;
        }
    }
    return nil;
}
@end

static void ShowVCamMenu(void) {
    if (g_isPresentingMenu) return;
    g_isPresentingMenu = YES;

    UIWindow *keyWindow = [GetFrame getKeyWindow];
    if (!keyWindow) { g_isPresentingMenu = NO; return; }

    Class WCActionSheetClass = NSClassFromString(@"WCActionSheet");
    if (!WCActionSheetClass) { g_isPresentingMenu = NO; return; }

    id actionSheet = ((id (*)(id, SEL, NSString*))objc_msgSend)([WCActionSheetClass alloc], NSSelectorFromString(@"initWithTitle:"), @"VCAM 控制");
    if (!actionSheet) { g_isPresentingMenu = NO; return; }

    SEL addButtonSel = NSSelectorFromString(@"addButtonWithTitle:eventAction:");

    // 选择视频
    void (^selectVideoBlock)(void) = ^{
        g_isPresentingMenu = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *win = [GetFrame getKeyWindow];
            UIViewController *rootVC = win.rootViewController;
            while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;

            static id pickerDelegate = nil;
            if (!pickerDelegate) {
                Class cls = objc_allocateClassPair([NSObject class], "VCamImagePickerDelegate", 0);
                class_addProtocol(cls, @protocol(UIImagePickerControllerDelegate));
                class_addProtocol(cls, @protocol(UINavigationControllerDelegate));
                IMP imp = imp_implementationWithBlock(^(id self, UIImagePickerController *picker, NSDictionary *info) {
                    [picker dismissViewControllerAnimated:YES completion:nil];
                    NSURL *videoURL = info[UIImagePickerControllerMediaURL];
                    if (videoURL) {
                        NSString *srcPath = videoURL.path;
                        NSString *dstPath = g_tempFile;
                        if ([g_fileManager fileExistsAtPath:dstPath]) {
                            [g_fileManager removeItemAtPath:dstPath error:nil];
                        }
                        if ([g_fileManager copyItemAtPath:srcPath toPath:dstPath error:nil]) {
                            // 创建 .new 标记，触发重新加载
                            [g_fileManager createDirectoryAtPath:[dstPath stringByAppendingString:@".new"] withIntermediateDirectories:YES attributes:nil error:nil];
                            LoadVideoFramesFromFile(dstPath);
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
            picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
            picker.delegate = pickerDelegate;
            [rootVC presentViewController:picker animated:YES completion:nil];
        });
    };
    ((void (*)(id, SEL, NSString*, void*))objc_msgSend)(actionSheet, addButtonSel, @"选择视频", (__bridge void *)selectVideoBlock);

    // 禁用替换
    void (^disableBlock)(void) = ^{
        g_isPresentingMenu = NO;
        if ([g_fileManager fileExistsAtPath:g_tempFile]) {
            [g_fileManager removeItemAtPath:g_tempFile error:nil];
        }
        [g_videoLock lock];
        for (id obj in g_videoFrames) {
            CVPixelBufferRef buf = (__bridge CVPixelBufferRef)obj;
            CVPixelBufferRelease(buf);
        }
        [g_videoFrames removeAllObjects];
        [g_videoLock unlock];
    };
    ((void (*)(id, SEL, NSString*, void*))objc_msgSend)(actionSheet, addButtonSel, @"禁用替换", (__bridge void *)disableBlock);

    SEL showInViewSel = NSSelectorFromString(@"showInView:");
    ((void (*)(id, SEL, UIView*))objc_msgSend)(actionSheet, showInViewSel, keyWindow);

    // 修复取消后无法再次激活
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        g_isPresentingMenu = NO;
    });
}

// UIWindow 手势注入
@interface UIWindow (VCamGesture)
- (void)vcam_handleTwoFingerDoubleTap:(UITapGestureRecognizer *)tap;
@end
@implementation UIWindow (VCamGesture)
- (void)vcam_handleTwoFingerDoubleTap:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateRecognized) ShowVCamMenu();
}
@end

static void AddGestureToWindow(UIWindow *window) {
    static NSMapTable<UIWindow *, NSNumber *> *gestureAddedWindows = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gestureAddedWindows = [NSMapTable weakToStrongObjectsMapTable]; });
    if ([gestureAddedWindows objectForKey:window]) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:window action:@selector(vcam_handleTwoFingerDoubleTap:)];
    tap.numberOfTouchesRequired = 2;
    tap.numberOfTapsRequired = 2;
    tap.cancelsTouchesInView = NO;
    [window addGestureRecognizer:tap];
    [gestureAddedWindows setObject:@YES forKey:window];
}

%hook UIWindow
- (void)makeKeyAndVisible { %orig; dispatch_async(dispatch_get_main_queue(), ^{ AddGestureToWindow(self); }); }
- (id)initWithFrame:(CGRect)frame { self = %orig; dispatch_async(dispatch_get_main_queue(), ^{ AddGestureToWindow(self); }); return self; }
%end

// ============================================================
// 构造与析构
// ============================================================
%ctor {
    g_fileManager = [NSFileManager defaultManager];
    g_tempFile = [GetWeChatCachesPath() copy];
    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
        LoadVideoFramesFromFile(g_tempFile);
    }
}

%dtor {
    [g_videoLock lock];
    for (id obj in g_videoFrames) {
        CVPixelBufferRef buf = (__bridge CVPixelBufferRef)obj;
        CVPixelBufferRelease(buf);
    }
    [g_videoFrames removeAllObjects];
    [g_videoLock unlock];
    if (g_colorSpace) CGColorSpaceRelease(g_colorSpace);
    g_fileManager = nil;
}