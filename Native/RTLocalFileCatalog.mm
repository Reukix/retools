// SPDX-License-Identifier: GPL-3.0-or-later
// Container enumeration adapted from WQ Files by kolbicz (2026), including
// the fsgetpath approach credited upstream to murk-sus / KAMUI.
#import "RTNative.h"
#import <objc/message.h>
#import <TargetConditionals.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <dlfcn.h>
#import <string.h>

// Container discovery follows WQFiles' local API + fsgetpath approach.
// https://github.com/kolbicz/WQFiles (GPL-3.0-or-later). No access tokens are
// acquired or retained by discovery; file reads use RTLocalFileAccess instead.
static id catalogValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *exception) { return nil; }
}
static NSString *catalogPath(NSString *path) {
    return [path hasPrefix:@"/var/"] ? [@"/private" stringByAppendingString:path] : path;
}
static NSArray<NSString *> *catalogParents(void) {
    return @[@"/private/var/mobile/Containers/Data/Application", @"/private/var/mobile/Containers/Data/PluginKitPlugin",
             @"/private/var/mobile/Containers/Data/InternalDaemon", @"/private/var/mobile/Containers/Shared/AppGroup",
             @"/private/var/containers/Shared/SystemGroup"];
}
static void catalogAdd(NSMutableDictionary *records, NSString *path, NSString *identifier, NSString *name) {
    if (![path isKindOfClass:NSString.class]) return;
    path = catalogPath(path);
    if (![catalogParents() containsObject:path.stringByDeletingLastPathComponent]) return;
    NSString *leaf = path.lastPathComponent;
    if (![[NSUUID alloc] initWithUUIDString:leaf] && !([leaf hasPrefix:@"systemgroup."] && leaf.length > 12)) return;
    NSMutableDictionary *item = [records[path] mutableCopy] ?: [@{@"path": path} mutableCopy];
    if ([identifier isKindOfClass:NSString.class] && identifier.length) item[@"identifier"] = identifier;
    if ([name isKindOfClass:NSString.class] && name.length) item[@"name"] = name;
    records[path] = item;
}
static void catalogProxy(NSMutableDictionary *records, id proxy) {
    id url = catalogValue(proxy, @"dataContainerURL");
    if ([url isKindOfClass:NSURL.class]) catalogAdd(records, [url path], catalogValue(proxy, @"bundleIdentifier"), catalogValue(proxy, @"localizedName"));
}
static void catalogQuick(NSMutableDictionary *records) {
    id workspace = catalogValue(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
    id apps = catalogValue(workspace, @"allInstalledApplications");
    if ([apps isKindOfClass:NSArray.class]) for (id app in apps) {
        catalogProxy(records, app);
        id plugins = catalogValue(app, @"plugInKitPlugins");
        if ([plugins isKindOfClass:NSArray.class]) for (id plugin in plugins) catalogProxy(records, plugin);
    }
    // Private container APIs can return a subset. Never advertise it as a full list.
    void *library = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (library) {
        auto create = (void *(*)())dlsym(library, "container_query_create");
        auto setClass = (void (*)(void *, uint64_t))dlsym(library, "container_query_set_class");
        auto iterate = (void (*)(void *, bool (^)(void *)))dlsym(library, "container_query_iterate_results_sync");
        auto pathOf = (const char *(*)(void *))dlsym(library, "container_object_get_path");
        auto freeQuery = (void (*)(void *))dlsym(library, "container_query_free");
        if (create && setClass && iterate && pathOf && freeQuery) for (uint64_t kind = 1; kind <= 14; kind++) {
            void *query = create(); if (!query) continue;
            @try {
                setClass(query, kind);
                iterate(query, ^bool(void *object) {
                    const char *path = object ? pathOf(object) : NULL;
                    if (path) catalogAdd(records, [NSString stringWithUTF8String:path], nil, nil);
                    return records.count < 10000;
                });
            } @catch (__unused NSException *exception) {}
            freeQuery(query);
        }
        dlclose(library);
    }
    for (NSString *parent in catalogParents()) {
        NSArray *children = [NSFileManager.defaultManager contentsOfDirectoryAtPath:parent error:nil];
        for (NSString *child in children) catalogAdd(records, [parent stringByAppendingPathComponent:child], nil, nil);
    }
}

@implementation RTNative (LocalFileCatalog)
+ (NSArray<NSDictionary *> *)localInstalledApplicationsWithError:(NSError **)error {
    id workspace = catalogValue(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
    id apps = catalogValue(workspace, @"allInstalledApplications");
    if (![apps isKindOfClass:NSArray.class]) {
        if (error) *error = [NSError errorWithDomain:@"RetoolsLocalFiles" code:3 userInfo:@{NSLocalizedDescriptionKey: @"系统未提供本机应用列表，可通过设备连接读取。"}];
        return nil;
    }
    NSMutableArray *records = [NSMutableArray new];
    for (id app in apps) {
        id url = catalogValue(app, @"bundleURL"), identifier = catalogValue(app, @"bundleIdentifier");
        if (![url isKindOfClass:NSURL.class] || ![identifier isKindOfClass:NSString.class]) continue;
        NSString *path = catalogPath([url path]);
        if (![path hasPrefix:@"/private/var/containers/Bundle/Application/"] || ![path.pathExtension isEqualToString:@"app"]) continue;
        id name = catalogValue(app, @"localizedName"), version = catalogValue(app, @"shortVersionString");
        [records addObject:@{@"CFBundleIdentifier": identifier, @"Path": path,
                             @"CFBundleDisplayName": [name isKindOfClass:NSString.class] ? name : identifier,
                             @"CFBundleShortVersionString": [version isKindOfClass:NSString.class] ? version : @""}];
    }
    return records;
}
+ (NSDictionary *)localFileCatalogWithScan:(BOOL)scan cursor:(uint64_t)cursor upperBound:(uint64_t)upperBound error:(NSError **)error {
#if TARGET_OS_SIMULATOR
    if (error) *error = [NSError errorWithDomain:@"RetoolsLocalFiles" code:1 userInfo:@{NSLocalizedDescriptionKey: @"模拟器不执行本机容器发现。"}];
    return nil;
#else
    NSMutableDictionary *records = [NSMutableDictionary new];
    if (!scan) {
        catalogQuick(records);
        return @{@"containers": records.allValues, @"cursor": @0, @"upperBound": @0};
    }
    struct statfs volume = {};
    NSString *failure = nil;
    if (upperBound > INT64_MAX - 100000 || (upperBound && cursor > upperBound + 1)) failure = @"目录扫描范围无效，请重新发现目录。";
    if (statfs("/private/var/mobile", &volume) != 0) failure = @"无法确认本机数据卷。";
    if (!failure && upperBound == 0) {
        NSString *probe = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        int descriptor = open(probe.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
        struct stat info = {}; struct statfs probeVolume = {};
        BOOL valid = descriptor >= 0 && fstat(descriptor, &info) == 0 && fstatfs(descriptor, &probeVolume) == 0 &&
            memcmp(&volume.f_fsid, &probeVolume.f_fsid, sizeof(fsid_t)) == 0 && info.st_ino > 0 && (uint64_t)info.st_ino < INT64_MAX - 100000;
        if (descriptor >= 0) { close(descriptor); unlink(probe.fileSystemRepresentation); }
        if (valid) upperBound = (uint64_t)info.st_ino + 100000;
        else failure = @"无法确定目录扫描范围，已停止；可以按完整路径打开。";
    }
    typedef ssize_t (*resolve_fn)(char *, size_t, fsid_t *, uint64_t);
    resolve_fn resolve = (resolve_fn)dlsym(RTLD_DEFAULT, "fsgetpath");
    if (!resolve) failure = @"系统不支持本机目录扫描。";
    if (failure) {
        if (error) *error = [NSError errorWithDomain:@"RetoolsLocalFiles" code:2 userInfo:@{NSLocalizedDescriptionKey: failure}];
        return nil;
    }
    // Return frequently so Swift can publish progress, cancel, or pause on background.
    uint64_t next = MAX(cursor, (uint64_t)2), end = MIN(upperBound, next + 65535);
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    char buffer[PATH_MAX];
    for (; next <= end; next++) {
        if ((next & 255) == 0 && CFAbsoluteTimeGetCurrent() - started > 0.5) break;
        if (resolve(buffer, sizeof(buffer), &volume.f_fsid, next) <= 0) continue;
        NSString *path = [NSString stringWithUTF8String:buffer];
        if (path) catalogAdd(records, path, nil, nil);
    }
    return @{@"containers": records.allValues, @"cursor": @(next), @"upperBound": @(upperBound)};
#endif
}
@end
