#import "RTNative.h"
#include "bundle.h"
#include "macho.h"
#include <openssl/pkcs12.h>
#include <openssl/cms.h>
#include <openssl/provider.h>
#include <openssl/err.h>
#include <mutex>
#include <dlfcn.h>

static std::mutex signingMutex;

// zsign 每签一个文件会输出一行 ">>> SignFile:" 或 ">>> SignFolder:" 日志；签名期间把它转成进度回调。
// 调用方持有 signingMutex，同一时间只有一个观察者。
static void RTSigningLogObserver(const char *line, void *context) {
    if (!context || !line) return;
    NSString *text = [NSString stringWithUTF8String:line];
    if (!text) return;
    NSString *name = nil;
    for (NSString *prefix in @[@">>> SignFile: \t", @">>> SignFolder: "]) {
        if ([text hasPrefix:prefix]) { name = [[text substringFromIndex:prefix.length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; break; }
    }
    if (!name.length) return;
    NSRange comma = [name rangeOfString:@", ("];
    if (comma.location != NSNotFound) name = [name substringToIndex:comma.location];
    void (^handler)(NSString *) = (__bridge void (^)(NSString *))context;
    handler(name.lastPathComponent.length ? name.lastPathComponent : name);
}
struct RTSigningObserverScope {
    explicit RTSigningObserverScope(id handler) : retained(handler) {
        if (handler) { ZLog::g_pObserverContext = (__bridge void *)retained; ZLog::g_pObserver = RTSigningLogObserver; }
    }
    ~RTSigningObserverScope() { ZLog::g_pObserver = NULL; ZLog::g_pObserverContext = NULL; }
    id retained;
};
static BOOL fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"Retools" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static NSDate *certificateDate(const ASN1_TIME *time) {
    struct tm value = {};
    if (!ASN1_TIME_to_tm(time, &value)) return nil;
    return [NSDate dateWithTimeIntervalSince1970:timegm(&value)];
}
static BOOL isMachO(NSString *path) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *head = [file readDataOfLength:4]; [file closeFile];
    if (head.length != 4) return NO;
    uint32_t magic = 0; memcpy(&magic, head.bytes, 4);
    return magic == 0xfeedfacf || magic == 0xcffaedfe || magic == 0xcafebabe || magic == 0xbebafeca;
}
static BOOL permittedEntitlement(id requested, id allowed) {
    if ([requested isKindOfClass:NSString.class] && [allowed isKindOfClass:NSString.class]) {
        if ([allowed isEqualToString:requested]) return YES;
        if ([allowed hasSuffix:@"*"]) return [requested hasPrefix:[allowed substringToIndex:[allowed length]-1]];
        return NO;
    }
    if ([requested isKindOfClass:NSNumber.class] && [allowed isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)requested) == CFBooleanGetTypeID() && CFGetTypeID((__bridge CFTypeRef)allowed) == CFBooleanGetTypeID()) return ![requested boolValue] || [allowed boolValue];
        return [requested isEqual:allowed];
    }
    if ([requested isKindOfClass:NSArray.class] && [allowed isKindOfClass:NSArray.class]) {
        for (id item in requested) {
            BOOL found = NO;
            for (id candidate in allowed) if (permittedEntitlement(item, candidate)) { found = YES; break; }
            if (!found) return NO;
        }
        return YES;
    }
    if ([requested isKindOfClass:NSDictionary.class] && [allowed isKindOfClass:NSDictionary.class]) {
        for (id key in requested) if (!allowed[key] || !permittedEntitlement(requested[key], allowed[key])) return NO;
        return YES;
    }
    return allowed && [requested isEqual:allowed];
}
// 仅保留描述文件已明确授权的专用组；扩展和无组授权的公版继续不带 App Group。
static void configureHostAppGroup(NSMutableDictionary *entitlements, NSDictionary *info, NSString *team, BOOL mainBundle) {
    id allowed = entitlements[@"com.apple.security.application-groups"];
    id base = info[@"RetoolsFileToolsAppGroup"];
    NSString *selected = nil;
    if (mainBundle && [base isKindOfClass:NSString.class] && [base hasPrefix:@"group."] &&
        ![base containsString:@"*"] && [allowed isKindOfClass:NSArray.class]) {
        NSString *scoped = [NSString stringWithFormat:@"%@.%@", base, team];
        if ([allowed containsObject:scoped]) selected = scoped;
        else if ([allowed containsObject:base]) selected = base;
    }
    if (selected) entitlements[@"com.apple.security.application-groups"] = @[selected];
    else [entitlements removeObjectForKey:@"com.apple.security.application-groups"];
}
@implementation RTNative
+ (BOOL)injectLibraries:(NSArray<NSString *> *)libraries intoExecutable:(NSString *)executable error:(NSError **)error {
    NSMutableArray *weak = [NSMutableArray new];
    for (__unused NSString *library in libraries) [weak addObject:@NO];
    return [self injectLibraries:libraries weak:weak intoExecutable:executable error:error];
}
+ (BOOL)injectLibraries:(NSArray<NSString *> *)libraries weak:(NSArray<NSNumber *> *)weak intoExecutable:(NSString *)executable error:(NSError **)error {
    std::lock_guard<std::mutex> lock(signingMutex);
    if (libraries.count != weak.count) return fail(error, @"插件加载方式与动态库数量不一致。");
    ZMachO binary;
    if (!binary.Init(executable.UTF8String)) return fail(error, @"无法读取待注入的可执行文件。");
    NSUInteger index = 0;
    for (NSString *library in libraries) {
        if (![library hasPrefix:@"@executable_path/Frameworks/RetoolsPlugins-"] || [library containsString:@"/../"] ||
            !binary.InjectDylib(weak[index++].boolValue, library.UTF8String)) return fail(error, @"无法写入插件加载命令，可能是可执行文件没有足够的命令空间。");
    }
    return YES;
}
+ (NSDictionary *)certificateDetails:(NSData *)data password:(NSString *)password error:(NSError **)error {
    std::lock_guard<std::mutex> lock(signingMutex);
    OSSL_PROVIDER_load(NULL, "default"); OSSL_PROVIDER_load(NULL, "legacy");
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    PKCS12 *p12 = d2i_PKCS12(NULL, &bytes, data.length);
    EVP_PKEY *key = NULL; X509 *cert = NULL; STACK_OF(X509) *chain = NULL;
    BOOL valid = p12 && PKCS12_parse(p12, password.UTF8String, &key, &cert, &chain) == 1;
    if (!valid || !key || !cert || X509_check_private_key(cert, key) != 1) {
        if (p12) PKCS12_free(p12); if (key) EVP_PKEY_free(key); if (cert) X509_free(cert);
        if (chain) sk_X509_pop_free(chain, X509_free);
        fail(error, @"无法读取证书私钥，请检查 P12 文件和密码。"); return nil;
    }
    char cn[1024] = {}, ou[256] = {};
    X509_NAME_get_text_by_NID(X509_get_subject_name(cert), NID_commonName, cn, sizeof(cn));
    X509_NAME_get_text_by_NID(X509_get_subject_name(cert), NID_organizationalUnitName, ou, sizeof(ou));
    unsigned char *der = NULL; int length = i2d_X509(cert, &der);
    NSData *derData = [NSData dataWithBytes:der length:MAX(0,length)];
    NSDate *expiry = certificateDate(X509_get0_notAfter(cert));
    NSDate *start = certificateDate(X509_get0_notBefore(cert));
    NSDictionary *result = @{ @"name": @(cn), @"teamID": @(ou), @"certificateDER": derData,
                              @"expiresAt": expiry ?: NSDate.distantPast, @"startsAt": start ?: NSDate.distantFuture };
    OPENSSL_free(der); PKCS12_free(p12); EVP_PKEY_free(key); X509_free(cert);
    if (chain) sk_X509_pop_free(chain, X509_free);
    return result;
}
+ (NSData *)profilePayload:(NSData *)data error:(NSError **)error {
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    CMS_ContentInfo *cms = d2i_CMS_ContentInfo(NULL, &bytes, data.length);
    BIO *output = BIO_new(BIO_s_mem());
    if (!cms || CMS_verify(cms, NULL, NULL, NULL, output, CMS_NO_SIGNER_CERT_VERIFY | CMS_BINARY) != 1) {
        if (cms) CMS_ContentInfo_free(cms); BIO_free(output);
        fail(error, @"描述文件不是完整的 CMS 签名文件，或内容校验失败。"); return nil;
    }
    char *payload = NULL; long length = BIO_get_mem_data(output, &payload);
    NSData *result = [NSData dataWithBytes:payload length:MAX(0,length)];
    CMS_ContentInfo_free(cms); BIO_free(output); return result;
}
+ (BOOL)signApp:(NSString *)path p12:(NSString *)p12 password:(NSString *)password profile:(NSString *)profile bundleID:(NSString *)bundleID removeExtensions:(BOOL)removeExtensions hostBundle:(BOOL)hostBundle error:(NSError **)error {
    return [self signApp:path p12:p12 password:password profile:profile bundleID:bundleID removeExtensions:removeExtensions hostBundle:hostBundle options:@{} error:error];
}
+ (BOOL)signApp:(NSString *)path p12:(NSString *)p12 password:(NSString *)password profile:(NSString *)profile bundleID:(NSString *)bundleID removeExtensions:(BOOL)removeExtensions hostBundle:(BOOL)hostBundle options:(NSDictionary *)options error:(NSError **)error {
    std::lock_guard<std::mutex> lock(signingMutex);
    ZSignAsset asset;
    if (!asset.Init("", p12.UTF8String, profile.UTF8String, "", password.UTF8String, false, true, false))
        return fail(error, @"签名凭据初始化失败，请重新导入匹配的证书和描述文件。");
    NSData *entitlementData = [NSData dataWithBytes:asset.m_strEntitleData.data() length:asset.m_strEntitleData.size()];
    NSMutableDictionary *entitlements = [[NSPropertyListSerialization propertyListWithData:entitlementData options:NSPropertyListMutableContainers format:nil error:error] mutableCopy];
    if (!entitlements) return NO;
    NSDictionary *profileEntitlements = entitlements.copy;
    NSString *team = [NSString stringWithUTF8String:asset.m_strTeamId.c_str()];
    NSString *identifier = bundleID.length ? bundleID : [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"];
    if (!identifier.length) return fail(error, @"缺少签名目标的 Bundle ID。");
    // An exact profile identity may differ from CFBundleIdentifier. Preserve it;
    // only wildcard profiles require a concrete application identifier.
    NSString *applicationID = entitlements[@"application-identifier"];
    if (![applicationID isKindOfClass:NSString.class] || !applicationID.length)
        return fail(error, @"描述文件缺少应用签名身份。");
    if ([applicationID hasSuffix:@"*"]) {
        NSString *prefix = [applicationID substringToIndex:applicationID.length-1];
        NSString *candidate = [NSString stringWithFormat:@"%@.%@", team, identifier];
        if (![candidate hasPrefix:prefix] || candidate.length <= prefix.length)
            return fail(error, @"目标标识不在描述文件的通配符授权范围内。");
        applicationID = candidate;
    }
    if ([profileEntitlements[@"get-task-allow"] boolValue] &&
        ![applicationID isEqualToString:[NSString stringWithFormat:@"%@.%@", team, identifier]])
        return fail(error, @"当前开发描述文件不匹配目标应用，请使用 Apple ID 为此应用获取描述文件后重试。");
    entitlements[@"application-identifier"] = applicationID;
    entitlements[@"com.apple.developer.team-identifier"] = team;
    NSArray *allowedGroups = entitlements[@"keychain-access-groups"] ?: @[];
    NSMutableArray *groups = [NSMutableArray new];
    for (NSString *group in allowedGroups) {
        if (![group isKindOfClass:NSString.class]) continue;
        // Keep a re-signed app's wildcard keychain group as the profile grants
        // it: apps derive their own groups (e.g. from the App Group they were
        // given), and narrowing "TEAM.*" to the bundle ID denies all of those.
        // Only Retools' own bundle needs one concrete group.
        NSString *resolved = hostBundle ? [group stringByReplacingOccurrencesOfString:@"*" withString:identifier] : group;
        [groups addObject:resolved];
    }
    if (hostBundle) {
        configureHostAppGroup(entitlements, [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]], team, YES);
        NSString *shared = [team stringByAppendingString:@".com.reukix.retools.shared"];
        for (NSString *pattern in allowedGroups) {
            if (![pattern isKindOfClass:NSString.class]) continue;
            if ([pattern isEqualToString:shared] || ([pattern hasSuffix:@"*"] && [shared hasPrefix:[pattern substringToIndex:pattern.length-1]])) {
                if (![groups containsObject:shared]) [groups addObject:shared];
                break;
            }
        }
    }
    if (groups.count) entitlements[@"keychain-access-groups"] = groups;
    NSData *custom = [options[@"customEntitlements"] isKindOfClass:NSData.class] ? options[@"customEntitlements"] : nil;
    if (custom) {
        if (custom.length > 262144) return fail(error, @"自定义 Entitlements 超过 256 KB。");
        NSDictionary *values = [NSPropertyListSerialization propertyListWithData:custom options:0 format:nil error:error];
        if (![values isKindOfClass:NSDictionary.class]) return fail(error, @"Entitlements 必须是 plist 字典。");
        for (NSString *key in values) {
            id value = values[key];
            if (![key isKindOfClass:NSString.class] || !permittedEntitlement(value, profileEntitlements[key])) return fail(error, [@"描述文件未授权此 Entitlement：" stringByAppendingString:[key description]]);
            if (([key isEqualToString:@"application-identifier"] && ![value isEqual:applicationID]) ||
                ([key isEqualToString:@"com.apple.developer.team-identifier"] && ![value isEqual:team])) return fail(error, @"自定义 Entitlements 不能更改应用或团队签名身份。");
            entitlements[key] = value;
        }
    }
    NSData *resolved = [NSPropertyListSerialization dataWithPropertyList:entitlements format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!resolved) return NO;
    asset.m_strEntitleData.assign((const char *)resolved.bytes, resolved.length);
    ZBundle bundle;
    if ([options[@"preserveDecryptionPayload"] boolValue]) {
        NSData *helperData = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
        NSDictionary *helperInfo = helperData ? [NSPropertyListSerialization propertyListWithData:helperData options:0 format:nil error:error] : nil;
        if (![helperInfo[@"RetoolsDecryptHelper"] boolValue] || ![helperInfo[@"CFBundleExecutable"] isEqual:@"RetoolsDecryptHelper"])
            return fail(error, [NSString stringWithFormat:@"解密助手模板身份无效（程序 %@，标记 %@，文件 %@）。", helperInfo[@"CFBundleExecutable"] ?: @"缺失", helperInfo[@"RetoolsDecryptHelper"] ?: @"缺失", helperData ? @"已读取" : @"无法读取"]);
        bundle.m_bPreserveDecryptionPayload = true;
    }
    bundle.m_bRemoveExtensions = removeExtensions;
    bundle.m_bRemoveWatchApp = options[@"removeWatch"] ? [options[@"removeWatch"] boolValue] : removeExtensions;
    id progress = options[@"progress"];
    RTSigningObserverScope observer([progress isKindOfClass:NSClassFromString(@"NSBlock")] ? progress : nil);
    BOOL result = bundle.SignFolder(&asset, path.UTF8String, bundleID.UTF8String, "", "", {}, {}, true, false, false, [options[@"removeEmbedded"] boolValue]);
    return result ?: fail(error, @"签名引擎未能完成签名，请检查可执行文件和描述文件权限。");
}
+ (BOOL)signApp:(NSString *)path p12:(NSString *)p12 password:(NSString *)password bundles:(NSArray<NSDictionary *> *)bundles options:(NSDictionary *)options error:(NSError **)error {
    std::lock_guard<std::mutex> lock(signingMutex);
    if (!bundles.count) return fail(error, @"缺少签名所需的描述文件。");
    std::list<ZSignAsset> assets;
    NSSet *retained = [NSSet setWithArray:@[@"application-identifier", @"com.apple.developer.team-identifier", @"get-task-allow"]];
    for (NSDictionary *bundle in bundles) {
        NSString *identifier = bundle[@"bundleID"], *profile = bundle[@"profile"];
        if (![identifier isKindOfClass:NSString.class] || ![profile isKindOfClass:NSString.class]) return fail(error, @"签名配置无效。");
        assets.emplace_back();
        ZSignAsset &asset = assets.back();
        if (!asset.Init("", p12.UTF8String, profile.UTF8String, "", password.UTF8String, false, true, false))
            return fail(error, [NSString stringWithFormat:@"%@ 的签名凭据初始化失败。", identifier]);
        NSData *data = [NSData dataWithBytes:asset.m_strEntitleData.data() length:asset.m_strEntitleData.size()];
        NSDictionary *profileEntitlements = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:error];
        if (![profileEntitlements isKindOfClass:NSDictionary.class]) return fail(error, [NSString stringWithFormat:@"无法读取 %@ 的描述文件授权。", identifier]);
        NSString *team = @(asset.m_strTeamId.c_str());
        NSDictionary *declared = [bundle[@"entitlements"] isKindOfClass:NSDictionary.class] ? bundle[@"entitlements"] : @{};
        NSMutableDictionary *entitlements = [NSMutableDictionary new];
        for (NSString *key in profileEntitlements) {
            id value = declared[key];
            if (!value) { if ([retained containsObject:key]) entitlements[key] = profileEntitlements[key]; continue; }
            if ([key isEqualToString:@"keychain-access-groups"] && [value isKindOfClass:NSArray.class]) {
                NSMutableArray *groups = [NSMutableArray new];
                for (NSString *group in value) {
                    if (![group isKindOfClass:NSString.class]) continue;
                    NSRange dot = [group rangeOfString:@"."];
                    if (dot.location == NSNotFound) return fail(error, [NSString stringWithFormat:@"钥匙串组 %@ 缺少团队前缀。", group]);
                    [groups addObject:[team stringByAppendingString:[group substringFromIndex:dot.location]]];
                }
                entitlements[key] = groups;
            } else entitlements[key] = profileEntitlements[key];
        }
        NSData *resolved = [NSPropertyListSerialization dataWithPropertyList:entitlements format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
        if (!resolved) return NO;
        asset.m_strEntitleData.assign((const char *)resolved.bytes, resolved.length);
    }
    ZBundle bundle;
    bundle.m_bRemoveExtensions = false;
    bundle.m_bRemoveWatchApp = options[@"removeWatch"] ? [options[@"removeWatch"] boolValue] : YES;
    id progress = options[@"progress"];
    RTSigningObserverScope observer([progress isKindOfClass:NSClassFromString(@"NSBlock")] ? progress : nil);
    NSString *mainID = bundles.firstObject[@"bundleID"];
    return bundle.SignFolder(&assets, path.UTF8String, mainID.UTF8String, "", "", {}, {}, true, false, false) ?: fail(error, @"签名引擎未能完成签名，请检查可执行文件和描述文件。");
}
+ (BOOL)signBinaries:(NSArray<NSString *> *)paths p12:(NSString *)p12 password:(NSString *)password profile:(NSString *)profile identifier:(NSString *)identifier error:(NSError **)error {
    std::lock_guard<std::mutex> lock(signingMutex);
    ZSignAsset asset;
    if (!asset.Init("", p12.UTF8String, profile.UTF8String, "", password.UTF8String, false, true, true))
        return fail(error, @"容器签名凭据初始化失败。");
    // A guest is a loaded library, so it must not request executable entitlements.
    asset.m_strEntitleData.clear();
    for (NSString *path in paths) {
        if (!isMachO(path)) continue;
        // A signed Mach-O may have a cached vnode signature. Sign a fresh inode,
        // close its mmap, then atomically replace the original before validation.
        NSString *fresh = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:[@".retools-sign-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm copyItemAtPath:path toPath:fresh error:error]) return NO;
        BOOL signedFile = NO;
        {
            ZMachO binary;
            signedFile = binary.Init(fresh.UTF8String) && binary.Sign(&asset, true, identifier.UTF8String, "", "", "");
        }
        if (!signedFile) {
            [fm removeItemAtPath:fresh error:nil];
            return fail(error, [@"无法签名容器文件：" stringByAppendingString:path.lastPathComponent]);
        }
        NSString *replacement = [fresh stringByAppendingString:@".ready"];
        BOOL replaced = [fm copyItemAtPath:fresh toPath:replacement error:error] &&
            [fm replaceItemAtURL:[NSURL fileURLWithPath:path] withItemAtURL:[NSURL fileURLWithPath:replacement]
                   backupItemName:nil options:0 resultingItemURL:nil error:error];
        [fm removeItemAtPath:fresh error:nil];
        [fm removeItemAtPath:replacement error:nil];
        if (!replaced) return NO;
        [fm setAttributes:@{NSFilePosixPermissions:@0755} ofItemAtPath:path error:nil];
    }
    return YES;
}
+ (BOOL)signHostApp:(NSString *)path credentials:(NSDictionary<NSString *,NSDictionary<NSString *,NSString *> *> *)credentials error:(NSError **)error {
    std::lock_guard<std::mutex> lock(signingMutex);
    NSDictionary *hostInfo = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *mainID = hostInfo[@"CFBundleIdentifier"];
    if (!credentials[mainID]) return fail(error, @"缺少 Retools 的签名配置。");
    NSMutableArray *identifiers = [NSMutableArray arrayWithObject:mainID];
    for (NSString *identifier in credentials) if (![identifier isEqualToString:mainID]) [identifiers addObject:identifier];
    std::list<ZSignAsset> assets;
    for (NSString *identifier in identifiers) {
        NSDictionary *material = credentials[identifier];
        assets.emplace_back();
        ZSignAsset &asset = assets.back();
        if (!asset.Init("", [material[@"p12"] UTF8String], [material[@"profile"] UTF8String], "", [material[@"password"] UTF8String], false, true, false))
            return fail(error, @"自身续签凭据初始化失败。");
        NSData *data = [NSData dataWithBytes:asset.m_strEntitleData.data() length:asset.m_strEntitleData.size()];
        NSMutableDictionary *entitlements = [[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:nil error:error] mutableCopy];
        if (!entitlements) return NO;
        NSString *team = @(asset.m_strTeamId.c_str());
        NSString *applicationID = entitlements[@"application-identifier"];
        NSString *candidate = [NSString stringWithFormat:@"%@.%@", team, identifier];
        if ([applicationID hasSuffix:@"*"]) {
            if (![candidate hasPrefix:[applicationID substringToIndex:applicationID.length - 1]]) return fail(error, @"自身扩展的签名身份不在授权范围内。");
            applicationID = candidate;
        }
        if (![applicationID isEqualToString:candidate])
            return fail(error, @"自身续签需要为主应用和扩展分别取得匹配的描述文件。");
        entitlements[@"application-identifier"] = applicationID;
        entitlements[@"com.apple.developer.team-identifier"] = team;
        configureHostAppGroup(entitlements, hostInfo, team, [identifier isEqualToString:mainID]);
        NSMutableArray *groups = [NSMutableArray new];
        for (NSString *group in entitlements[@"keychain-access-groups"] ?: @[]) {
            if ([group isKindOfClass:NSString.class]) [groups addObject:[group stringByReplacingOccurrencesOfString:@"*" withString:identifier]];
        }
        if (groups.count) entitlements[@"keychain-access-groups"] = groups;
        NSData *resolved = [NSPropertyListSerialization dataWithPropertyList:entitlements format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
        if (!resolved) return NO;
        asset.m_strApplicationId = applicationID.UTF8String;
        asset.m_strEntitleData.assign((const char *)resolved.bytes, resolved.length);
    }
    ZBundle bundle;
    bundle.m_bRemoveExtensions = false;
    return bundle.SignFolder(&assets, path.UTF8String, mainID.UTF8String, "", "", {}, {}, true, false, false) ?: fail(error, @"Retools 或配对扩展签名未完成。");
}
@end
