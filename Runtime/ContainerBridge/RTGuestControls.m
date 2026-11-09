#import "RTGuestControls.h"
#import "LCSharedUtils.h"
#import "FoundationPrivate.h"
#import "utils.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>

@protocol RetoolsControlsInstalling
+ (void)installWithHostRoot:(NSString *)root defaults:(NSUserDefaults *)defaults currentFolder:(NSString *)folder currentContainer:(NSString *)container restart:(void (^)(void))restart quit:(void (^)(void))quit;
@end

void RetoolsInstallGuestControls(NSString *folder, NSString *container) {
    NSBundle *host = NSUserDefaults.lcMainBundle;
    if (![host.infoDictionary[@"RetoolsPrivateSandbox"] boolValue] || !folder.length) return;
    NSUserDefaults *defaults = NSUserDefaults.lcUserDefaults;
    if ([defaults objectForKey:@"RetoolsFloatingControlsEnabled"] && ![defaults boolForKey:@"RetoolsFloatingControlsEnabled"]) return;
    const char *home = getenv("LC_HOME_PATH");
    if (!home) return;
    NSString *root = @(home);
    NSString *library = [host.bundlePath stringByAppendingPathComponent:@"Frameworks/ContainerControls.framework/ContainerControls"];
    void *handle = dlopen(library.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    Class<RetoolsControlsInstalling> bridge = NSClassFromString(@"RetoolsContainerControls");
    if (!handle || !bridge) { NSLog(@"[Retools] Floating container controls could not be loaded"); return; }
    [bridge installWithHostRoot:root defaults:defaults currentFolder:folder currentContainer:container ?: @"" restart:^{
        [defaults setObject:@"ui" forKey:@"selected"];
        [defaults removeObjectForKey:@"selectedContainer"];
        [defaults synchronize];
        [LCSharedUtils launchToGuestAppWithClassicMode:0];
    } quit:^{
        [defaults removeObjectForKey:@"selected"];
        [defaults removeObjectForKey:@"selectedContainer"];
        [defaults synchronize];
        exit(0);
    }];
}

NSString *RetoolsLoadGuestPlugins(NSString *appPath, NSDictionary *metadata) {
    id values = metadata[@"RetoolsPluginEntries"] ?: metadata[@"RetoolsPluginPaths"];
    if (!values) return nil;
    if (![values isKindOfClass:NSArray.class] || [values count] > 128) return @"容器插件配置无效。";
    for (id entry in values) {
        id value = [entry isKindOfClass:NSDictionary.class] ? entry[@"path"] : entry;
        BOOL weak = [entry isKindOfClass:NSDictionary.class] && [entry[@"weak"] isKindOfClass:NSNumber.class] && [entry[@"weak"] boolValue];
        if (![value isKindOfClass:NSString.class] || ![value hasPrefix:@"Frameworks/RetoolsPlugins-"] || [value hasPrefix:@"/"] ||
            [[value pathComponents] containsObject:@".."] || [[value pathComponents] containsObject:@"."] || [value containsString:@"\\"]) return @"容器插件路径无效。";
        NSString *path = [appPath stringByAppendingPathComponent:value];
        dlerror();
        if (!dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL)) {
            const char *error = dlerror();
            if (weak) { NSLog(@"[Retools] Optional plugin %@ was skipped: %s", [value lastPathComponent], error ?: "unknown loader error"); continue; }
            return [NSString stringWithFormat:@"插件 %@ 加载失败：%@", [value lastPathComponent], error ? @(error) : @"系统未返回原因"];
        }
    }
    return nil;
}
