#import "RTNative.h"
#include "../Vendor/Libarchive/include/archive.h"
#include "../Vendor/Libarchive/include/archive_entry.h"
#include <memory>
#include <fcntl.h>
#include <unistd.h>

static BOOL archiveFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"RetoolsPlugin" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static BOOL copyEntry(struct archive *reader, NSString *path, uint64_t *total, uint64_t maximum, NSError **error) {
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) return archiveFail(error, @"插件压缩包包含重复或无效的文件路径。");
    char buffer[65536]; la_ssize_t count = 0; BOOL ok = YES;
    while ((count = archive_read_data(reader, buffer, sizeof(buffer))) > 0) {
        if ((uint64_t)count > maximum - *total) { archiveFail(error, @"插件解压体积超过限制。"); ok = NO; break; }
        *total += (uint64_t)count;
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written = write(fd, buffer + offset, (size_t)(count - offset));
            if (written <= 0) { archiveFail(error, @"无法写入插件文件。"); ok = NO; break; }
            offset += written;
        }
        if (!ok) break;
    }
    close(fd);
    if (count < 0) return archiveFail(error, @"插件归档解压失败，文件可能损坏或压缩格式不受支持。");
    return ok;
}
@implementation RTNative (PluginArchive)
+ (BOOL)extractDeb:(NSString *)source to:(NSString *)destination error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    if ([fm contentsOfDirectoryAtPath:destination error:error].count != 0) return archiveFail(error, @"插件解压目录必须为空。");
    NSString *compressed = [destination.stringByDeletingLastPathComponent stringByAppendingPathComponent:[@".deb-data-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    BOOL result = NO;
    @try {
        std::unique_ptr<struct archive, decltype(&archive_read_free)> outer(archive_read_new(), &archive_read_free);
        archive_read_support_format_ar(outer.get());
        if (archive_read_open_filename(outer.get(), source.fileSystemRepresentation, 65536) != ARCHIVE_OK) return archiveFail(error, @"这不是有效的 Debian 插件包。");
        struct archive_entry *entry = NULL;
        int status; BOOL found = NO, debian = NO;
        while ((status = archive_read_next_header(outer.get(), &entry)) == ARCHIVE_OK) {
            const char *raw = archive_entry_pathname(entry);
            NSString *name = raw ? [NSString stringWithUTF8String:raw] : nil;
            if ([name isEqualToString:@"debian-binary"]) {
                char version[8] = {}; la_ssize_t length = archive_read_data(outer.get(), version, sizeof(version));
                debian = length == 4 && memcmp(version, "2.0\n", 4) == 0;
            } else if ([name isEqualToString:@"data.tar"] || [name hasPrefix:@"data.tar."]) {
                if (found) return archiveFail(error, @"Debian 包包含多份数据归档。");
                uint64_t bytes = 0;
                if (!copyEntry(outer.get(), compressed, &bytes, 256 * 1024 * 1024, error)) return NO;
                found = YES;
            } else { archive_read_data_skip(outer.get()); }
        }
        if (status != ARCHIVE_EOF || !found || !debian) return archiveFail(error, @"Debian 包缺少有效的数据归档或版本标记。");
        std::unique_ptr<struct archive, decltype(&archive_read_free)> reader(archive_read_new(), &archive_read_free);
        archive_read_support_filter_all(reader.get()); archive_read_support_format_tar(reader.get());
        if (archive_read_open_filename(reader.get(), compressed.fileSystemRepresentation, 65536) != ARCHIVE_OK) return archiveFail(error, @"无法打开 Debian 包中的压缩数据。");
        uint64_t total = 0; NSUInteger files = 0;
        while ((status = archive_read_next_header(reader.get(), &entry)) == ARCHIVE_OK) {
            if (++files > 20000) return archiveFail(error, @"插件文件数量过多。");
            const char *raw = archive_entry_pathname(entry);
            NSString *name = raw ? [NSString stringWithUTF8String:raw] : nil;
            while ([name hasPrefix:@"./"]) name = [name substringFromIndex:2];
            if ([name isEqualToString:@"."] || name.length == 0) { archive_read_data_skip(reader.get()); continue; }
            if ([name hasPrefix:@"/"] || [name containsString:@"\\"] || [name.pathComponents containsObject:@".."] ||
                [name.pathComponents containsObject:@"."] || name.pathComponents.count > 64 || archive_entry_symlink(entry) || archive_entry_hardlink(entry))
                return archiveFail(error, @"Debian 包包含不安全的路径或链接。");
            NSString *path = [destination stringByAppendingPathComponent:name];
            if (archive_entry_filetype(entry) == AE_IFDIR) {
                if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:error]) return NO;
            } else if (archive_entry_filetype(entry) == AE_IFREG) {
                if (![fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error] ||
                    !copyEntry(reader.get(), path, &total, 512 * 1024 * 1024, error)) return NO;
            } else { return archiveFail(error, @"插件包包含不支持的特殊文件。"); }
        }
        result = status == ARCHIVE_EOF;
        if (!result) archiveFail(error, @"插件归档不完整。");
    } @finally { [fm removeItemAtPath:compressed error:nil]; }
    return result;
}
@end
