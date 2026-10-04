#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>

static void require(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        require(argc == 2, "supply dylib path");

        NSFileManager *manager = NSFileManager.defaultManager;
        NSString *unrelatedGroup = [NSString stringWithFormat:
            @"group.pinterest-noads-unrelated.%@", NSUUID.UUID.UUIDString];
        NSURL *unrelatedBefore =
            [manager containerURLForSecurityApplicationGroupIdentifier:unrelatedGroup];

        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        require(library != NULL, "runtime filter dylib must load");
        BOOL (*installFallback)(void) =
            dlsym(library, "PIBAppGroupFallbackInstall");
        require(installFallback != NULL,
            "app-group fallback install entry point must exist");
        require(installFallback(), "app-group fallback must install");
        dispatch_apply(64,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
            ^(size_t iteration) {
                (void)iteration;
                require(installFallback(),
                    "concurrent app-group fallback installation must succeed");
            });

        NSURL *fallback =
            [manager containerURLForSecurityApplicationGroupIdentifier:
                @"group.pinterest"];
        require(fallback != nil,
            "missing Pinterest app group must receive a fallback URL");
        BOOL insideHome = [fallback.path hasPrefix:NSHomeDirectory()];
        BOOL insideTemporaryDirectory =
            [fallback.path hasPrefix:NSTemporaryDirectory()];
        require(insideHome || insideTemporaryDirectory,
            "fallback must remain inside the app home or process temporary container");
        require([fallback.lastPathComponent isEqual:@"group.pinterest"],
            "fallback must isolate the Pinterest app-group directory");
        BOOL isDirectory = NO;
        require([manager fileExistsAtPath:fallback.path
            isDirectory:&isDirectory] && isDirectory,
            "fallback directory must exist before returning it");

        NSURL *unrelatedAfter =
            [manager containerURLForSecurityApplicationGroupIdentifier:
                unrelatedGroup];
        require((unrelatedBefore == nil && unrelatedAfter == nil) ||
            [unrelatedBefore isEqual:unrelatedAfter],
            "unrelated app-group lookup must preserve Foundation behavior");

        puts("PASS: missing Pinterest app group receives an isolated fallback");
    }
    return 0;
}
