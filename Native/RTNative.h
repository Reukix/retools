#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface RTNative : NSObject
+ (nullable NSDictionary *)certificateDetails:(NSData *)data password:(NSString *)password error:(NSError **)error;
+ (nullable NSData *)profilePayload:(NSData *)data error:(NSError **)error;
+ (BOOL)signApp:(NSString *)path p12:(NSString *)p12 password:(NSString *)password profile:(NSString *)profile bundleID:(NSString *)bundleID removeExtensions:(BOOL)removeExtensions hostBundle:(BOOL)hostBundle error:(NSError **)error;
+ (BOOL)signApp:(NSString *)path p12:(NSString *)p12 password:(NSString *)password profile:(NSString *)profile bundleID:(NSString *)bundleID removeExtensions:(BOOL)removeExtensions hostBundle:(BOOL)hostBundle options:(NSDictionary *)options error:(NSError **)error;
+ (BOOL)signBinaries:(NSArray<NSString *> *)paths p12:(NSString *)p12 password:(NSString *)password profile:(NSString *)profile identifier:(NSString *)identifier error:(NSError **)error;
/// 每个 bundle 使用各自的描述文件签名（Apple ID 签名，与 SideStore 一致）。bundles 主应用在前，每项含
/// bundleID、profile（描述文件路径）与 entitlements（原可执行文件声明的授权）。授权以描述文件为准，只保留原应用
/// 声明过的项（另保留应用标识、团队标识与 get-task-allow），钥匙串组沿用原分组并换成新团队前缀。
+ (BOOL)signApp:(NSString *)path p12:(NSString *)p12 password:(NSString *)password bundles:(NSArray<NSDictionary *> *)bundles options:(NSDictionary *)options error:(NSError **)error;
+ (BOOL)signHostApp:(NSString *)path credentials:(NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *)credentials error:(NSError **)error;
+ (BOOL)prepareContainer:(NSString *)path error:(NSError **)error;
+ (BOOL)isSignatureTrusted:(NSString *)path;
+ (nullable NSString *)hostTeamIdentifier;
+ (BOOL)usesPrivateSandbox;
+ (BOOL)launchGuest:(NSString *)folder container:(NSString *)container jit:(BOOL)jit error:(NSError **)error;
+ (BOOL)isJITEnabled;
+ (BOOL)hostAllowsDebugging;
+ (BOOL)enableJITForCurrentProcess:(NSError **)error;
+ (BOOL)extractDeb:(NSString *)source to:(NSString *)destination error:(NSError **)error;
+ (BOOL)injectLibraries:(NSArray<NSString *> *)libraries intoExecutable:(NSString *)executable error:(NSError **)error;
+ (BOOL)injectLibraries:(NSArray<NSString *> *)libraries weak:(NSArray<NSNumber *> *)weak intoExecutable:(NSString *)executable error:(NSError **)error;
+ (BOOL)testJITLess:(NSString *)p12 password:(NSString *)password profile:(NSString *)profile error:(NSError **)error;
/// 可执行文件代码签名中的签名证书（DER）；临时签名或无签名时返回 nil。
+ (nullable NSData *)signingCertificateOfExecutable:(NSString *)path error:(NSError **)error;
/// 可执行文件代码签名中嵌入的授权。
+ (nullable NSDictionary *)entitlementsOfExecutable:(NSString *)path error:(NSError **)error;
/// 实验性本机文件访问；调用方必须在同一操作结束时释放，不能保留给容器客体。
+ (nullable NSNumber *)acquireLocalFileAccess:(NSString *)container group:(NSString *)group error:(NSError **)error;
+ (BOOL)releaseLocalFileAccess:(int64_t)handle;
+ (BOOL)localFileAccessRequiresRestart;
@end
NS_ASSUME_NONNULL_END
