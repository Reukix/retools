#import "RTNative.h"
#import "utils.h"
#import <Security/Security.h>
#import <RetoolsNative/RetoolsNative-Swift.h>

@implementation RTNative (Debugger)
+ (BOOL)enableJITForCurrentProcess:(NSError **)error {
    if (self.isJITEnabled) return YES;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([[defaults stringForKey:@"RetoolsJITProvider"] isEqualToString:@"external"]) {
        for (int i = 0; i < 150 && !self.isJITEnabled; i++) usleep(100000);
        if (self.isJITEnabled) return YES;
        if (error) *error = [NSError errorWithDomain:@"Retools" code:2 userInfo:@{NSLocalizedDescriptionKey:@"新容器进程未在 15 秒内获得 JIT。请让外部调试工具对本次新进程启用 JIT。"}];
        return NO;
    }
    NSDictionary *query = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:@"dev.retools.ios.accounts", (__bridge id)kSecAttrAccount:@"device.pairing",
        (__bridge id)kSecReturnData:@YES, (__bridge id)kSecMatchLimit:(__bridge id)kSecMatchLimitOne};
    CFTypeRef value = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &value);
    NSData *pairing = CFBridgingRelease(value);
    NSString *host = [defaults stringForKey:@"RetoolsJITHostIP"];
    NSInteger port = [defaults integerForKey:@"RetoolsJITRemotePort"];
    if (status != errSecSuccess || !pairing || !host.length || port < 1 || port > 65535) {
        if (error) *error = [NSError errorWithDomain:@"Retools" code:3 userInfo:@{NSLocalizedDescriptionKey:@"JIT 回环配置不可用，请先在 Retools 中完成设备配对和连接检测。"}];
        return NO;
    }
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block NSString *message = nil;
    [RetoolsDeviceDebugger enableWithPairing:pairing host:host port:(uint16_t)port process:(uint32_t)getpid() completion:^(NSString *failure) {
        message = failure;
        dispatch_semaphore_signal(ready);
    }];
    BOOL timedOut = dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC)) != 0;
    if (!timedOut && !message && self.isJITEnabled) return YES;
    if (error) *error = [NSError errorWithDomain:@"Retools" code:4 userInfo:@{NSLocalizedDescriptionKey:timedOut ? @"JIT 回环调试连接超时。" : (message ?: @"调试器已返回，但当前进程的 JIT 状态未启用。") }];
    return NO;
}
@end
