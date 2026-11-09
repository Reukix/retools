#import "RTNative.h"
#include <openssl/cms.h>
#include <openssl/x509.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <libkern/OSByteOrder.h>

// 从 Mach-O 的代码签名中取出签名证书，用于判断「只安装新描述文件」是否安全：
// 新描述文件必须包含当前可执行文件实际使用的签名证书，否则系统不会认可它。

static BOOL codeSignFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"RetoolsCodeSignature" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

/// 返回指定 Mach-O 切片（arm64 优先）内 LC_CODE_SIGNATURE 指向的签名超级块。
static NSData *codeSignatureBlob(NSData *file, NSError **error) {
    const uint8_t *bytes = (const uint8_t *)file.bytes;
    NSUInteger length = file.length;
    if (length < sizeof(uint32_t)) { codeSignFail(error, @"可执行文件过短。"); return nil; }
    uint64_t sliceOffset = 0, sliceSize = length;
    uint32_t magic = *(const uint32_t *)bytes;
    if (magic == FAT_CIGAM || magic == FAT_MAGIC) {
        const struct fat_header *fat = (const struct fat_header *)bytes;
        uint32_t count = OSSwapBigToHostInt32(fat->nfat_arch);
        if (sizeof(struct fat_header) + (uint64_t)count * sizeof(struct fat_arch) > length) { codeSignFail(error, @"通用二进制头部无效。"); return nil; }
        const struct fat_arch *arch = (const struct fat_arch *)(bytes + sizeof(struct fat_header));
        BOOL found = NO;
        for (uint32_t i = 0; i < count; i++) {
            if ((cpu_type_t)OSSwapBigToHostInt32(arch[i].cputype) == CPU_TYPE_ARM64 || (!found && i == count - 1)) {
                sliceOffset = OSSwapBigToHostInt32(arch[i].offset); sliceSize = OSSwapBigToHostInt32(arch[i].size); found = YES;
                if ((cpu_type_t)OSSwapBigToHostInt32(arch[i].cputype) == CPU_TYPE_ARM64) break;
            }
        }
        if (!found || sliceOffset + sliceSize > length) { codeSignFail(error, @"找不到可用的架构切片。"); return nil; }
    }
    const uint8_t *slice = bytes + sliceOffset;
    if (sliceSize < sizeof(struct mach_header_64) || *(const uint32_t *)slice != MH_MAGIC_64) { codeSignFail(error, @"不是 64 位 Mach-O 文件。"); return nil; }
    const struct mach_header_64 *header = (const struct mach_header_64 *)slice;
    uint64_t cursor = sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > sliceSize) break;
        const struct load_command *command = (const struct load_command *)(slice + cursor);
        if (command->cmdsize < sizeof(struct load_command) || cursor + command->cmdsize > sliceSize) break;
        if (command->cmd == LC_CODE_SIGNATURE && command->cmdsize >= sizeof(struct linkedit_data_command)) {
            const struct linkedit_data_command *signature = (const struct linkedit_data_command *)command;
            if ((uint64_t)signature->dataoff + signature->datasize > sliceSize) { codeSignFail(error, @"代码签名超出文件范围。"); return nil; }
            return [NSData dataWithBytes:slice + signature->dataoff length:signature->datasize];
        }
        cursor += command->cmdsize;
    }
    codeSignFail(error, @"可执行文件没有代码签名。");
    return nil;
}

/// 在签名超级块中按类型取出子块内容（去掉 8 字节的魔数与长度头）。
static NSData *signatureSlot(NSData *superBlob, uint32_t wantedType, uint32_t wantedMagic) {
    const uint8_t *bytes = (const uint8_t *)superBlob.bytes;
    NSUInteger length = superBlob.length;
    if (length < 12 || OSSwapBigToHostInt32(*(const uint32_t *)bytes) != 0xfade0cc0) return nil;
    uint32_t count = OSSwapBigToHostInt32(*(const uint32_t *)(bytes + 8));
    if (12 + (uint64_t)count * 8 > length) return nil;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t type = OSSwapBigToHostInt32(*(const uint32_t *)(bytes + 12 + i * 8));
        uint32_t offset = OSSwapBigToHostInt32(*(const uint32_t *)(bytes + 16 + i * 8));
        if (type != wantedType || (uint64_t)offset + 8 > length) continue;
        uint32_t magic = OSSwapBigToHostInt32(*(const uint32_t *)(bytes + offset));
        uint32_t blobLength = OSSwapBigToHostInt32(*(const uint32_t *)(bytes + offset + 4));
        if (magic != wantedMagic || blobLength < 8 || (uint64_t)offset + blobLength > length) return nil;
        return [NSData dataWithBytes:bytes + offset + 8 length:blobLength - 8];
    }
    return nil;
}

@implementation RTNative (CodeSignature)
+ (NSData *)signingCertificateOfExecutable:(NSString *)path error:(NSError **)error {
    NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
    if (!file) return nil;
    NSData *superBlob = codeSignatureBlob(file, error);
    if (!superBlob) return nil;
    NSData *cmsData = signatureSlot(superBlob, 0x10000, 0xfade0b01);
    if (!cmsData.length) { codeSignFail(error, @"代码签名中没有证书签名（可能是临时签名）。"); return nil; }
    const unsigned char *cursor = (const unsigned char *)cmsData.bytes;
    CMS_ContentInfo *cms = d2i_CMS_ContentInfo(NULL, &cursor, (long)cmsData.length);
    if (!cms) { codeSignFail(error, @"无法解析代码签名中的 CMS。"); return nil; }
    NSData *result = nil;
    STACK_OF(X509) *certificates = CMS_get1_certs(cms);
    if (certificates && CMS_set1_signers_certs(cms, certificates, 0) >= 0) {
        STACK_OF(X509) *signers = CMS_get0_signers(cms);
        X509 *leaf = signers && sk_X509_num(signers) > 0 ? sk_X509_value(signers, 0) : NULL;
        unsigned char *der = NULL;
        int derLength = leaf ? i2d_X509(leaf, &der) : -1;
        if (derLength > 0) { result = [NSData dataWithBytes:der length:(NSUInteger)derLength]; OPENSSL_free(der); }
        sk_X509_free(signers);
    }
    if (certificates) sk_X509_pop_free(certificates, X509_free);
    CMS_ContentInfo_free(cms);
    if (!result) codeSignFail(error, @"代码签名中找不到签名证书。");
    return result;
}

+ (NSDictionary *)entitlementsOfExecutable:(NSString *)path error:(NSError **)error {
    NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
    if (!file) return nil;
    NSData *superBlob = codeSignatureBlob(file, error);
    if (!superBlob) return nil;
    NSData *xml = signatureSlot(superBlob, 5, 0xfade7171);
    if (!xml.length) return @{};
    id value = [NSPropertyListSerialization propertyListWithData:xml options:0 format:nil error:error];
    if (![value isKindOfClass:NSDictionary.class]) { codeSignFail(error, @"无法读取签名授权。"); return nil; }
    return value;
}
@end
