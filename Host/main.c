#include <TargetConditionals.h>
#include <dlfcn.h>
#include <stdio.h>

// Keep the UI out of the guest process until the container bootstrap selects it.
int main(int argc, char *argv[]) {
#if TARGET_OS_SIMULATOR
    const char *path = "@executable_path/Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI";
    const char *entry = "main";
#else
    const char *path = "@executable_path/Frameworks/LiveContainerShared.framework/LiveContainerShared";
    const char *entry = "LiveContainerMain";
#endif
    void *handle = dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
    if (!handle) { fprintf(stderr, "Retools: %s\n", dlerror()); return 1; }
    void *symbol = dlsym(handle, entry);
    if (!symbol) { fprintf(stderr, "Retools: missing %s\n", entry); return 1; }
#if TARGET_OS_SIMULATOR
    return ((int (*)(void))symbol)();
#else
    return ((int (*)(int, char **))symbol)(argc, argv);
#endif
}
