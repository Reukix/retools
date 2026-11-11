#import "RTNative.h"
// LiveContainer 的工具头含 Objective-C 专用语法；这里仅声明其已实现的宿主访问方法。
@interface NSUserDefaults (RetoolsHostBundleAccess)
+ (NSBundle *)lcMainBundle;
@end
extern "C" {
#import "worse_query.h"
}
#include <TargetConditionals.h>
#include <sys/stat.h>
#include <mutex>
#include <atomic>
#include <dlfcn.h>

static std::mutex accessMutex;
static std::atomic<bool> releaseFailed(false);
static NSNumber *accessFailure(NSError **error, NSString *message, NSInteger code = 1) {
    if (error) *error = [NSError errorWithDomain:@"RetoolsLocalFiles" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
    return nil;
}

@implementation RTNative (LocalFileAccess)
+ (NSNumber *)acquireLocalFileAccess:(NSString *)container group:(NSString *)group error:(NSError **)error {
#if TARGET_OS_SIMULATOR
    return accessFailure(error, @"模拟器不运行 worse_query，请在支持的真机系统上使用。");
#else
    std::lock_guard<std::mutex> lock(accessMutex);
    if (releaseFailed.load()) return accessFailure(error, @"上次目录权限未能释放，请完全退出 Retools 后重新打开。");
    if (!dlsym(RTLD_DEFAULT, "sandbox_extension_release")) return accessFailure(error, @"系统缺少释放目录权限的接口，未启动访问。");
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    if ((os.majorVersion != 26 && os.majorVersion != 27) ||
        (os.majorVersion == 26 && (os.minorVersion > 7 || (os.minorVersion == 7 && os.patchVersion > 2))) ||
        (os.majorVersion == 27 && (os.minorVersion > 2 || (os.minorVersion == 2 && os.patchVersion > 0))))
        return accessFailure(error, @"当前系统超出 worse_query 上游标注的版本范围。");

    // 这是工作流保护，不是对同进程 guest 的安全隔离。
    NSBundle *host = NSUserDefaults.lcMainBundle ?: NSBundle.mainBundle;
    if (![host.bundlePath isEqualToString:NSBundle.mainBundle.bundlePath])
        return accessFailure(error, @"请返回 Retools 工作台后使用本机文件访问。");
    NSDictionary *entitlements = [self entitlementsOfExecutable:host.executablePath error:error];
    if (!entitlements) return nil;
    NSString *team = entitlements[@"com.apple.developer.team-identifier"];
    NSString *base = host.infoDictionary[@"RetoolsFileToolsAppGroup"];
    NSArray *groups = entitlements[@"com.apple.security.application-groups"];
    if (![base isKindOfClass:NSString.class] || ![team isKindOfClass:NSString.class] ||
        ![groups isKindOfClass:NSArray.class] || ![groups containsObject:group] ||
        (![group isEqualToString:base] && ![group isEqualToString:[base stringByAppendingFormat:@".%@", team]]))
        return accessFailure(error, @"当前签名没有授权文件工具专用 App Group，请先准备并安装带组的开发签名包。");

    BOOL validContainer = NO;
    BOOL bundleProbe = NO;
    for (NSString *prefix in @[@"/private/var/mobile/Containers/Data/Application/", @"/private/var/mobile/Containers/Data/PluginKitPlugin/", @"/private/var/mobile/Containers/Data/InternalDaemon/", @"/private/var/mobile/Containers/Shared/AppGroup/"]) {
        if ([container hasPrefix:prefix]) {
            NSString *uuid = [container substringFromIndex:prefix.length];
            validContainer = [[NSUUID alloc] initWithUUIDString:uuid] != nil;
            break;
        }
    }
    BOOL systemArea = [container isEqualToString:@"/private/var/containers/Data/System"];
    NSString *systemPrefix = @"/private/var/containers/Shared/SystemGroup/";
    if ([container hasPrefix:systemPrefix]) {
        NSString *name = [container substringFromIndex:systemPrefix.length];
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
        systemArea = [name hasPrefix:@"systemgroup."] && name.length > 12 && [name rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
    }
    BOOL appGroupParent = [container isEqualToString:@"/private/var/mobile/Containers/Shared/AppGroup"];
    if (appGroupParent && os.majorVersion < 27) return accessFailure(error, @"App Group 总目录仅支持在兼容的 iOS 27 上访问。");
    if (systemArea && os.majorVersion < 27) return accessFailure(error, @"当前系统不支持本机访问系统容器。");
    validContainer = validContainer || systemArea || appGroupParent;
    // A specific installed app bundle can be probed for the decryption workflow.
    // This is outside the upstream's documented roots: success is never assumed.
    // The browser accepts only the documented data and system container roots.
    NSString *bundlePrefix = @"/private/var/containers/Bundle/Application/";
    if ([container hasPrefix:bundlePrefix]) {
        NSArray<NSString *> *parts = [[container substringFromIndex:bundlePrefix.length] componentsSeparatedByString:@"/"];
        bundleProbe = parts.count == 2 && [[NSUUID alloc] initWithUUIDString:parts.firstObject] != nil &&
            [parts.lastObject.pathExtension isEqualToString:@"app"] && parts.lastObject.length > 4 &&
            ![parts.lastObject isEqualToString:@"."] && ![parts.lastObject isEqualToString:@".."];
        validContainer = bundleProbe;
    }
    if (!validContainer) return accessFailure(error, @"请选择一个受支持的容器目录。");
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *groupRoot = [files containerURLForSecurityApplicationGroupIdentifier:group];
    if (!groupRoot) return accessFailure(error, @"系统未提供 App Group 容器，请先检测组的读写权限。");
    NSURL *library = [groupRoot URLByAppendingPathComponent:@"Library" isDirectory:YES];
    struct stat info;
    if (lstat(library.fileSystemRepresentation, &info) == 0 && (!S_ISDIR(info.st_mode) || S_ISLNK(info.st_mode)))
        return accessFailure(error, @"专用组的 Library 不是普通目录，未修改其内容。");
    if (![files createDirectoryAtURL:library withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSURL *caches = [library URLByAppendingPathComponent:@"Caches" isDirectory:YES];
    if (lstat(caches.fileSystemRepresentation, &info) == 0) {
        if (!S_ISDIR(info.st_mode) || S_ISLNK(info.st_mode))
            return accessFailure(error, @"专用组缓存目录状态异常，未修改其内容。");
        NSArray *contents = [files contentsOfDirectoryAtURL:caches includingPropertiesForKeys:nil options:0 error:error];
        if (!contents) return nil;
        if (contents.count) return accessFailure(error, @"专用组缓存目录非空，为保留已有数据未启动访问。");
    }

    BOOL alternate = os.majorVersion == 26 && [container hasPrefix:@"/private/var/mobile/Containers/Shared/AppGroup/"];
    // create_dir only skips the PoC's pre-query lstat; it creates no target files.
    int64_t handle = worse_query(container, group, alternate, bundleProbe || systemArea || appGroupParent);
    if (handle < 0) {
        NSDictionary *messages = @{@(-1): @"无法访问专用 App Group。", @(-2): @"系统缺少所需的容器接口。",
            @(-3): @"无法创建容器查询。", @(-4): @"无法准备专用组的临时缓存入口。",
            @(-5): @"系统拒绝了容器查询，当前版本或签名可能不兼容。", @(-6): @"系统拒绝授予目录访问权限。",
            @(-255): @"找不到目标容器，或系统不允许确认该路径。"};
        return accessFailure(error, messages[@(handle)] ?: @"获取目录权限失败。", (NSInteger)handle);
    }
    return @(handle);
#endif
}
+ (BOOL)releaseLocalFileAccess:(int64_t)handle {
#if TARGET_OS_SIMULATOR
    return YES;
#else
    if (handle < 0) return YES;
    std::lock_guard<std::mutex> lock(accessMutex);
    typedef int (*release_fn)(int64_t);
    release_fn release = (release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    BOOL released = release && release(handle) == 0;
    if (!released) releaseFailed.store(true);
    return released;
#endif
}
+ (BOOL)localFileAccessRequiresRestart { return releaseFailed.load(); }
@end
