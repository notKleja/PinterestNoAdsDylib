#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSArray *receivedObjects;
static id receivedManager;
static id receivedCompletion;
static NSInteger receivedAction;
static NSUInteger callbackCalls;
static BOOL continuesPaginationAfterRemoval;

static void captureLoadedObjects(id self, SEL _cmd, id manager, NSArray *objects,
                                 NSInteger action, id completion) {
    (void)self;
    (void)_cmd;
    callbackCalls++;
    receivedObjects = [objects copy];
    receivedManager = manager;
    receivedCompletion = completion;
    receivedAction = action;
}

static void capturePaginationSetting(id self, SEL _cmd, BOOL enabled) {
    (void)self;
    (void)_cmd;
    continuesPaginationAfterRemoval = enabled;
}

static void conflictingLoadHook(id self, SEL _cmd, id manager, NSArray *objects,
                                NSInteger action, id completion) {
    (void)self;
    (void)_cmd;
    (void)manager;
    (void)objects;
    (void)action;
    (void)completion;
}

@interface PIAdFilterFixture : NSObject
@property(nonatomic) BOOL promoted;
@property(nonatomic) BOOL sponsored;
@end

@implementation PIAdFilterFixture
- (BOOL)isPromoted { return self.promoted; }
- (BOOL)isSponsored { return self.sponsored; }
@end

static void require(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static void resetCapture(void) {
    receivedObjects = nil;
    receivedManager = nil;
    receivedCompletion = nil;
    receivedAction = 0;
    callbackCalls = 0;
    continuesPaginationAfterRemoval = NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        require(argc == 2, "supply dylib path");

        Class collectionClass = objc_allocateClassPair(NSObject.class,
            "PINRemoteModelCollection", 0);
        require(collectionClass != Nil, "create collection fixture class");
        SEL callback = NSSelectorFromString(
            @"requestManager:didLoadObjects:withAction:andCompletion:");
        require(class_addMethod(collectionClass, callback,
            (IMP)captureLoadedObjects, "v48@0:8@16@24q32@?40"),
            "add callback fixture method");
        require(class_addMethod(collectionClass,
            NSSelectorFromString(@"setContinuesPaginationAfterObjectsRemoved:"),
            (IMP)capturePaginationSetting, "v@:B"), "add pagination fixture method");
        objc_registerClassPair(collectionClass);

        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        require(library != NULL, "runtime filter dylib must load");
        BOOL (*installFilter)(void) = dlsym(library, "PIBAdFilterInstall");
        require(installFilter != NULL, "filter install entry point must exist");
        require(installFilter(), "repeated explicit installation must be idempotent");
        dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
            ^(size_t iteration) {
                (void)iteration;
                require(installFilter(), "concurrent installation must succeed");
            });

        PIAdFilterFixture *organic = [PIAdFilterFixture new];
        PIAdFilterFixture *promoted = [PIAdFilterFixture new];
        promoted.promoted = YES;
        PIAdFilterFixture *sponsored = [PIAdFilterFixture new];
        sponsored.sponsored = YES;
        NSObject *plain = [NSObject new];

        id collection = [collectionClass new];
        NSObject *manager = [NSObject new];
        id completion = [^{ } copy];
        NSArray *input = @[organic, promoted, sponsored, plain];
        ((void (*)(id, SEL, id, NSArray *, NSInteger, id))objc_msgSend)(
            collection, callback, manager, input, -7, completion);

        require(callbackCalls == 1, "original callback must run exactly once");
        require(receivedObjects.count == 2, "remove every classified ad object");
        require(receivedObjects[0] == organic, "preserve organic object order");
        require(receivedObjects[1] == plain, "preserve unclassified object order");
        require(receivedManager == manager, "preserve the request manager argument");
        require(receivedAction == -7, "preserve the signed action argument");
        require(receivedCompletion == completion, "preserve the completion argument");
        require(continuesPaginationAfterRemoval,
            "keep pagination active after removing ad objects");

        resetCapture();
        NSArray *organicOnly = @[organic, plain];
        ((void (*)(id, SEL, id, NSArray *, NSInteger, id))objc_msgSend)(
            collection, callback, manager, organicOnly, 9, completion);
        require(receivedObjects.count == 2 && receivedObjects[0] == organic &&
            receivedObjects[1] == plain, "preserve a page containing no ads");
        require(!continuesPaginationAfterRemoval,
            "do not alter pagination when no objects were removed");

        resetCapture();
        ((void (*)(id, SEL, id, NSArray *, NSInteger, id))objc_msgSend)(
            collection, callback, manager, @[promoted, sponsored], 11, completion);
        require(receivedObjects.count == 0, "forward an empty page when every model is an ad");
        require(continuesPaginationAfterRemoval,
            "continue pagination when an entire page is removed");

        resetCapture();
        NSArray *empty = @[];
        ((void (*)(id, SEL, id, NSArray *, NSInteger, id))objc_msgSend)(
            collection, callback, manager, empty, 13, completion);
        require(receivedObjects.count == 0 && !continuesPaginationAfterRemoval,
            "preserve an empty non-ad page without changing pagination");

        resetCapture();
        ((void (*)(id, SEL, id, NSArray *, NSInteger, id))objc_msgSend)(
            collection, callback, manager, nil, 15, completion);
        require(receivedObjects == nil && !continuesPaginationAfterRemoval,
            "preserve a nil page without changing pagination");

        Method callbackMethod = class_getInstanceMethod(collectionClass, callback);
        method_setImplementation(callbackMethod, (IMP)conflictingLoadHook);
        require(!installFilter(),
            "reject reinstall after an intervening swizzle to avoid a hook cycle");
        puts("PASS: autostart filters promoted and sponsored models before insertion");
    }
    return 0;
}
