#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>

static void loaderFailure(NSString *message) { NSLog(@"[Retools Loader] %@", message); abort(); }

__attribute__((constructor)) static void loadRetoolsPlugins(void) {
    @autoreleasepool {
        Dl_info location = {};
        if (!dladdr((const void *)&loadRetoolsPlugins, &location) || !location.dli_fname) loaderFailure(@"无法定位加载器");
        NSString *framework = [[NSString stringWithUTF8String:location.dli_fname] stringByDeletingLastPathComponent];
        NSString *app = framework;
        while (![app.pathExtension isEqualToString:@"app"] && app.length > 1) app = app.stringByDeletingLastPathComponent;
        if (![app.pathExtension isEqualToString:@"app"]) loaderFailure(@"找不到所属应用");
        NSData *data = [NSData dataWithContentsOfFile:[framework stringByAppendingPathComponent:@"RetoolsPlugins.json"]];
        if (!data || data.length > 1048576) loaderFailure(@"插件清单缺失或无效");
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"version"] isEqual:@1] || ![manifest[@"entries"] isKindOfClass:NSArray.class]) loaderFailure(@"插件清单格式无效");
        NSArray *entries = manifest[@"entries"];
        if (entries.count > 128) loaderFailure(@"插件数量过多");
        NSString *root = [app stringByResolvingSymlinksInPath];
        for (id item in entries) {
            if (![item isKindOfClass:NSDictionary.class]) loaderFailure(@"插件条目无效");
            NSString *path = item[@"path"];
            if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"Frameworks/RetoolsPlugins-"] || [path.pathComponents containsObject:@".."] || [path.pathComponents containsObject:@"."]) loaderFailure(@"插件路径无效");
            NSString *absolute = [[root stringByAppendingPathComponent:path] stringByResolvingSymlinksInPath];
            if (![absolute hasPrefix:[root stringByAppendingString:@"/"]]) loaderFailure(@"插件路径越界");
            if (!dlopen(absolute.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
                const char *reason = dlerror();
                NSString *message = [NSString stringWithFormat:@"%@：%s", path.lastPathComponent, reason ?: "未知加载错误"];
                if ([item[@"optional"] boolValue]) NSLog(@"[Retools Loader] 可选插件加载失败：%@", message);
                else loaderFailure(message);
            }
        }
    }
}
