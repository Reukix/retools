#ifndef RT_FAIRPLAY_NATIVE_H
#define RT_FAIRPLAY_NATIVE_H
#include <stdint.h>
#include <stdbool.h>
typedef struct {
    uint64_t slice_offset, slice_size, encrypted_offset, encrypted_size;
    uint64_t signature_offset, signature_size;
    uint32_t cpu_type, cpu_subtype;
} RTFairPlayRegion;
typedef struct {
    uint64_t bytes_written, pages_read, changed_bytes;
    uint64_t code_words_before, code_words_after;
    double entropy_before, entropy_after;
    int system_error, mach_error, signature_error;
} RTFairPlayResult;
typedef bool (*RTFairPlayProgress)(uint64_t completed, uint64_t total, void *context);
int rt_fairplay_decrypt_region(const char *source, const char *output, RTFairPlayRegion region,
                              RTFairPlayResult *result, RTFairPlayProgress progress, void *context);
#endif
