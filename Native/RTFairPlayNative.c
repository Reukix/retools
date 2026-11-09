// Independent Retools implementation. Research references: Docs/DEPENDENCIES.md.
#include "RTFairPlayNative.h"
#include <TargetConditionals.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <math.h>

static bool arm64_code_word(uint32_t word) {
    return word == 0xd65f03c0 || word == 0xd65f0fff || word == 0xd503237f;
}
static double byte_entropy(const uint64_t *counts, uint64_t total) {
    double value = 0;
    for (int i=0;i<256;i++) if (counts[i]) {
        double p=(double)counts[i]/(double)total; value-=p*log2(p);
    }
    return value;
}

static int remap_readonly(void *address, size_t size, uint32_t cpu, uint32_t subtype) {
#if TARGET_OS_SIMULATOR
    errno = ENOTSUP; return -1;
#else
    typedef int (*Remap)(void *, size_t, uint32_t, uint32_t, uint32_t);
    Remap fn = (Remap)dlsym(RTLD_DEFAULT, "mremap_encrypted");
    if (fn) return fn(address, size, 2, cpu, subtype);
#if defined(__arm64__)
    register uint64_t a0 __asm__("x0") = (uint64_t)address;
    register uint64_t a1 __asm__("x1") = size;
    register uint64_t a2 __asm__("x2") = 2;
    register uint64_t a3 __asm__("x3") = cpu;
    register uint64_t a4 __asm__("x4") = subtype;
    register uint64_t number __asm__("x16") = 489;
    uint32_t failed;
    __asm__ volatile("svc #0x80\n\tcset %w[failed], cs" : "+r"(a0), [failed] "=r"(failed)
        : "r"(a1), "r"(a2), "r"(a3), "r"(a4), "r"(number) : "memory", "cc");
    if (failed) { errno = (int)a0; return -1; }
    return (int)a0;
#else
    errno = ENOTSUP; return -1;
#endif
#endif
}

int rt_fairplay_decrypt_region(const char *source, const char *output, RTFairPlayRegion r,
                              RTFairPlayResult *result, RTFairPlayProgress progress, void *context) {
    if (!result) return -1;
    memset(result, 0, sizeof(*result));
    int input = -1, destination = -1, status = -1;
    unsigned char *mapping = MAP_FAILED, *clear = NULL, *original = NULL;
    size_t mapped_size = 0;
    uint64_t page = (uint64_t)getpagesize();
    uint64_t before[256]={0}, after[256]={0};
    struct stat si, so;
    if (!source || !output || r.cpu_type != 0x0100000c || !r.encrypted_size ||
        r.slice_offset % page || r.encrypted_offset % page || r.encrypted_size % 4096 ||
        r.encrypted_offset > r.slice_size || r.encrypted_size > r.slice_size-r.encrypted_offset ||
        r.slice_size > (UINT64_C(8)<<30) || r.slice_offset > INT64_MAX-r.slice_size) { errno=EINVAL; goto cleanup; }
    input=open(source,O_RDONLY|O_NOFOLLOW|O_CLOEXEC); destination=open(output,O_WRONLY|O_NOFOLLOW|O_CLOEXEC);
    if (input<0 || destination<0 || fstat(input,&si) || fstat(destination,&so)) goto cleanup;
    if (!S_ISREG(si.st_mode) || !S_ISREG(so.st_mode) || si.st_size!=so.st_size ||
        (si.st_dev==so.st_dev && si.st_ino==so.st_ino) || r.slice_offset+r.slice_size>(uint64_t)si.st_size) { errno=EINVAL; goto cleanup; }
#if defined(F_ADDFILESIGS_RETURN)
    if (r.signature_size && r.signature_offset<=r.slice_size && r.signature_size<=r.slice_size-r.signature_offset) {
        fsignatures_t sig={.fs_file_start=(off_t)r.slice_offset,.fs_blob_start=(void *)(uintptr_t)r.signature_offset,.fs_blob_size=(size_t)r.signature_size};
        if (fcntl(input,F_ADDFILESIGS_RETURN,&sig)!=0) result->signature_error=errno;
    }
#endif
    mapped_size=(size_t)((r.encrypted_offset+r.encrypted_size+page-1)/page*page);
    mapping=mmap(NULL,mapped_size,PROT_READ,MAP_PRIVATE,input,(off_t)r.slice_offset);
    if (mapping==MAP_FAILED) goto cleanup;
    clear=malloc((size_t)page); original=malloc((size_t)page);
    if (!clear || !original) { errno=ENOMEM; goto cleanup; }
    if (remap_readonly(mapping+r.encrypted_offset,(size_t)r.encrypted_size,r.cpu_type,r.cpu_subtype)) goto cleanup;
    for (uint64_t offset=0; offset<r.encrypted_size;) {
        size_t length=(size_t)((r.encrypted_size-offset<page)?r.encrypted_size-offset:page);
        vm_size_t received=0;
        kern_return_t kr=vm_read_overwrite(mach_task_self(),(vm_address_t)(mapping+r.encrypted_offset+offset),(vm_size_t)length,(vm_address_t)clear,&received);
        if (kr!=KERN_SUCCESS || received!=length) { result->mach_error=kr?kr:KERN_FAILURE; errno=EIO; goto cleanup; }
        off_t absolute=(off_t)(r.slice_offset+r.encrypted_offset+offset);
        if (pread(input,original,length,absolute)!=(ssize_t)length) { errno=EIO; goto cleanup; }
        for (size_t i=0;i<length;i++) {
            result->changed_bytes+=original[i]!=clear[i]; before[original[i]]++; after[clear[i]]++;
        }
        for (size_t i=0;i+4<=length;i+=4) {
            uint32_t a,b; memcpy(&a,original+i,4); memcpy(&b,clear+i,4);
            result->code_words_before+=arm64_code_word(a); result->code_words_after+=arm64_code_word(b);
        }
        size_t written=0;
        while (written<length) {
            ssize_t count=pwrite(destination,clear+written,length-written,absolute+(off_t)written);
            if (count<=0) { if (count<0 && errno==EINTR) continue; errno=EIO; goto cleanup; }
            written+=(size_t)count;
        }
        offset+=length; result->bytes_written+=length; result->pages_read++;
        if (progress && !progress(offset,r.encrypted_size,context)) { errno=ECANCELED; goto cleanup; }
    }
    result->entropy_before=byte_entropy(before,r.encrypted_size);
    result->entropy_after=byte_entropy(after,r.encrypted_size);
    // A successful syscall alone is insufficient: preserve cryptid on unverifiable data.
    if (result->changed_bytes<r.encrypted_size/10 || result->entropy_after>=7.75 ||
        result->entropy_before-result->entropy_after<0.1 || result->code_words_after<=result->code_words_before) { errno=EILSEQ; goto cleanup; }
    if (fsync(destination)) goto cleanup;
    status=0;
cleanup:
    if (status!=0) result->system_error=errno?errno:EIO;
    if (mapping!=MAP_FAILED) munmap(mapping,mapped_size);
    if (clear) { memset(clear,0,(size_t)page); free(clear); }
    if (original) { memset(original,0,(size_t)page); free(original); }
    if (input>=0) close(input);
    if (destination>=0) close(destination);
    return status;
}
