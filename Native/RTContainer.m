#import "RTNative.h"
#import "LCMachOUtils.h"
#import "LCSharedUtils.h"
#import "utils.h"
#import <TargetConditionals.h>
#import <dlfcn.h>

static BOOL fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"Retools" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
@implementation RTNative (Container)
+ (BOOL)usesPrivateSandbox {
    NSBundle *host = NSUserDefaults.lcMainBundle ?: NSBundle.mainBundle;
    return [host.infoDictionary[@"RetoolsPrivateSandbox"] boolValue] && LCSharedUtils.appGroupPath == nil && NSUserDefaults.lcSharedDefaults == NSUserDefaults.standardUserDefaults;
}
+ (BOOL)prepareContainer:(NSString *)path error:(NSError **)error {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *name = info[@"CFBundleExecutable"];
    if (!name.length || ![name isEqualToString:name.lastPathComponent]) return fail(error, @"应用缺少有效的可执行文件。");
    NSString *exec = [path stringByAppendingPathComponent:name];
    __block BOOL encrypted = NO, arm64 = NO;
    NSString *issue = LCParseMachO(exec.UTF8String, false, ^(const char *file, struct mach_header_64 *header, int fd, void *base) {
        encrypted |= LCIsMachOEncrypted(header);
        if (header->cputype == CPU_TYPE_ARM64) { arm64 = YES; if (!encrypted) LCPatchExecSlice(file, header, false); }
    });
    if (issue) return fail(error, issue);
    if (encrypted) return fail(error, @"这个 IPA 的可执行文件已加密，无法用于容器。");
    if (!arm64) return fail(error, @"容器目前需要包含 arm64 可执行文件的 iOS 应用。");
    LCPatchAppBundleFixupARM64eSlice([NSURL fileURLWithPath:path]);
    return YES;
}
+ (BOOL)isSignatureTrusted:(NSString *)path {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    return checkCodeSignature(path.UTF8String);
#endif
}
+ (NSString *)hostTeamIdentifier {
#if TARGET_OS_SIMULATOR
    return nil;
#else
    return LCSharedUtils.teamIdentifier;
#endif
}
+ (BOOL)isJITEnabled {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    int flags = 0;
    return csops(getpid(), 0, &flags, sizeof(flags)) == 0 && (flags & CS_DEBUGGED) != 0;
#endif
}
+ (BOOL)hostAllowsDebugging {
    NSString *xml = getExecutableEntitlementXML(NSBundle.mainBundle.executablePath);
    NSDictionary *values = [NSPropertyListSerialization propertyListWithData:[xml dataUsingEncoding:NSUTF8StringEncoding] options:0 format:nil error:nil];
    return [values[@"get-task-allow"] boolValue];
}
+ (BOOL)launchGuest:(NSString *)folder container:(NSString *)container jit:(BOOL)jit error:(NSError **)error {
#if TARGET_OS_SIMULATOR
    return fail(error, @"容器运行需要已签名的 iPhone 或 iPad；模拟器可测试导入和数据管理。");
#else
    if (self.localFileAccessRequiresRestart)
        return fail(error, @"本机文件访问的权限未能释放，请完全退出 Retools 后重新打开，再启动容器。");
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:folder forKey:@"selected"];
    [defaults setObject:container forKey:@"selectedContainer"];
    // Bootstrap only uses this as a JIT-less presence marker. The secret stays in Keychain.
    [defaults setObject:jit ? @"jit" : @"jitless" forKey:@"RetoolsContainerMode"];
    [defaults setBool:!jit forKey:@"LCIgnoreJITOnLaunch"];
    if (jit) [defaults removeObjectForKey:@"LCCertificatePassword"];
    else [defaults setObject:@"retools-keychain" forKey:@"LCCertificatePassword"];
    [defaults synchronize];
    if (![LCSharedUtils launchToGuestAppWithClassicMode:0]) {
        [defaults removeObjectForKey:@"selected"]; [defaults removeObjectForKey:@"selectedContainer"];
        return fail(error, @"系统没有接受容器重启请求。");
    }
    return YES;
#endif
}
+ (BOOL)testJITLess:(NSString *)p12 password:(NSString *)password profile:(NSString *)profile error:(NSError **)error {
#if TARGET_OS_SIMULATOR
    return fail(error, @"请在真机上运行 JIT-less 检测。");
#else
    if (!self.hostAllowsDebugging)
        return fail(error, @"当前 Retools 的宿主签名缺少 get-task-allow 权限，iOS 会阻止从数据目录加载容器代码。免 JIT 模式也需要支持这项权限的开发签名。请用对应开发证书与描述文件重新签名安装 Retools，并导入同一份证书。");
    NSFileManager *fm = NSFileManager.defaultManager;
    // Test the same writable storage class as guest apps, with a development-
    // signed host. Testing the bundled original would not verify guest loading.
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *checks = [documents stringByAppendingPathComponent:@"Retools/.RuntimeChecks"];
    NSString *directory = [checks stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSString *target = [directory stringByAppendingPathComponent:@"RuntimeProbe"];
    NSString *source = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/RuntimeProbe.framework/RuntimeProbe"];
    BOOL result = NO;
    if ([fm copyItemAtPath:source toPath:target error:error] && [self signBinaries:@[target] p12:p12 password:password profile:profile identifier:NSBundle.mainBundle.bundleIdentifier error:error]) {
        BOOL trusted = [self isSignatureTrusted:target];
        dlerror();
        void *handle = dlopen(target.UTF8String, RTLD_NOW | RTLD_LOCAL);
        NSString *loadError = nil;
        if (!handle) { const char *message = dlerror(); loadError = message ? @(message) : @"系统未返回加载原因"; }
        int (*probe)(void) = handle ? (int (*)(void))dlsym(handle, "RetoolsRuntimeProbe") : NULL;
        result = trusted && probe && probe() == 0x5254;
        if (!result) fail(error, [NSString stringWithFormat:@"JIT-less 检测失败：%@", loadError ?: @"测试动态库未返回正确的检测结果"]);
        if (handle) dlclose(handle);
    }
    [fm removeItemAtPath:directory error:nil]; return result;
#endif
}
@end
