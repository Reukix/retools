#import <XCTest/XCTest.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <sys/stat.h>
#import "../Vendor/LiveContainer/LiveContainer/LCMachOUtils.h"

typedef NSString *(*MachOParser)(const char *, bool, LCParseMachOCallback);

@interface MachOFileReadTests : XCTestCase
@property(nonatomic) NSURL *root;
@end

@implementation MachOFileReadTests
- (void)setUp {
    [super setUp];
    self.root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.root withIntermediateDirectories:YES attributes:nil error:nil]);
}
- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:self.root error:nil];
    [super tearDown];
}
- (MachOParser)parser {
    MachOParser parser = (MachOParser)dlsym(RTLD_DEFAULT, "LCParseMachO");
    XCTAssertTrue(parser != NULL);
    return parser;
}
- (NSData *)binary {
    struct mach_header_64 header = {0};
    header.magic = MH_MAGIC_64; header.cputype = CPU_TYPE_ARM64; header.filetype = MH_DYLIB;
    header.ncmds = 1; header.sizeofcmds = sizeof(struct build_version_command);
    struct build_version_command version = {0};
    version.cmd = LC_BUILD_VERSION; version.cmdsize = sizeof(version); version.platform = PLATFORM_IOS;
    version.minos = 0x00110000; version.sdk = 0x00120501;
    NSMutableData *data = [NSMutableData dataWithBytes:&header length:sizeof(header)];
    [data appendBytes:&version length:sizeof(version)];
    return data;
}
- (void)testReadOnlyInspectionRetainsOriginalDescriptorAndLeavesFileUnchanged {
    MachOParser parser = self.parser;
    if (!parser) return;
    NSURL *file = [self.root URLByAppendingPathComponent:@"PatchedGuest"];
    NSData *original = self.binary;
    XCTAssertTrue([original writeToURL:file atomically:NO]);
    // Modify the same inode, as LC does between signature registration and re-signing.
    int writer = open(file.fileSystemRepresentation, O_RDWR);
    XCTAssertGreaterThanOrEqual(writer, 0);
    uint32_t sdk = 0x00130501;
    XCTAssertEqual(pwrite(writer, &sdk, sizeof(sdk), sizeof(struct mach_header_64) + offsetof(struct build_version_command, sdk)), sizeof(sdk));
    close(writer);
    NSData *patched = [NSData dataWithContentsOfURL:file];
    struct stat expected = {0};
    XCTAssertEqual(stat(file.fileSystemRepresentation, &expected), 0);
    __block NSUInteger callbacks = 0;
    NSString *issue = parser(file.fileSystemRepresentation, true, ^(const char *path, struct mach_header_64 *header, int fd, void *base) {
        callbacks++;
        struct stat actual = {0};
        XCTAssertEqual(fstat(fd, &actual), 0);
        XCTAssertEqual(actual.st_ino, expected.st_ino); XCTAssertEqual(actual.st_dev, expected.st_dev);
        XCTAssertEqual(header, base); XCTAssertEqual(header->cputype, CPU_TYPE_ARM64);
        struct build_version_command *version = (void *)(header + 1);
        XCTAssertEqual(version->sdk, sdk);
        uint32_t diskMagic = 0;
        XCTAssertEqual(pread(fd, &diskMagic, sizeof(diskMagic), 0), sizeof(diskMagic));
        XCTAssertEqual(diskMagic, header->magic);
    });
    XCTAssertNil(issue); XCTAssertEqual(callbacks, 1);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], patched);
}
- (void)testReadOnlyInspectionRejectsMissingAndMalformedFiles {
    MachOParser parser = self.parser;
    if (!parser) return;
    __block BOOL invoked = NO;
    LCParseMachOCallback callback = ^(const char *path, struct mach_header_64 *header, int fd, void *base) { invoked = YES; };
    NSURL *file = [self.root URLByAppendingPathComponent:@"InvalidGuest"];
    XCTAssertNotNil(parser(file.fileSystemRepresentation, true, callback));
    uint32_t truncatedFat[] = {0xbebafeca, 0x02000000};
    uint32_t truncatedMachO[] = {MH_MAGIC_64};
    for (NSData *data in @[[NSData data], [NSData dataWithBytes:truncatedFat length:sizeof(truncatedFat)], [NSData dataWithBytes:truncatedMachO length:sizeof(truncatedMachO)], [@"not Mach-O" dataUsingEncoding:NSUTF8StringEncoding]]) {
        XCTAssertTrue([data writeToURL:file atomically:NO]);
        XCTAssertNotNil(parser(file.fileSystemRepresentation, true, callback));
    }
    XCTAssertFalse(invoked);
}
@end
