#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <os/lock.h>
#include <stdlib.h>
#include <stdatomic.h>

typedef void (*PIBRemoteLoadIMP)(id, SEL, id, NSArray *, NSInteger, id);
static _Atomic(PIBRemoteLoadIMP) PIBOriginalRemoteLoad;
static os_unfair_lock PIBInstallLock = OS_UNFAIR_LOCK_INIT;
static BOOL PIBFilterInstalled;

static BOOL PIBModelBoolean(id model, SEL selector) {
    if (![model respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(model, selector);
}

static BOOL PIBIsAdModel(id model) {
    return PIBModelBoolean(model, @selector(isPromoted)) ||
        PIBModelBoolean(model, @selector(isSponsored));
}

static void PIBFilteredRemoteLoad(id self, SEL selector, id manager,
                                  NSArray *objects, NSInteger action, id completion) {
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:objects.count];
    for (id object in objects) {
        if (!PIBIsAdModel(object)) [filtered addObject:object];
    }
    NSUInteger removed = objects.count - filtered.count;
    if (removed > 0) {
        SEL paginationSelector =
            NSSelectorFromString(@"setContinuesPaginationAfterObjectsRemoved:");
        if ([self respondsToSelector:paginationSelector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                self, paginationSelector, YES);
        }
        NSLog(@"[PinterestProbe] removed %lu promoted/sponsored model(s)",
            (unsigned long)removed);
    }
    PIBRemoteLoadIMP original = atomic_load_explicit(
        &PIBOriginalRemoteLoad, memory_order_acquire);
    original(self, selector, manager,
        removed ? filtered : objects, action, completion);
}

__attribute__((visibility("default")))
BOOL PIBAdFilterInstall(void) {
    os_unfair_lock_lock(&PIBInstallLock);
    Class collection = objc_getClass("PINRemoteModelCollection");
    SEL selector = NSSelectorFromString(
        @"requestManager:didLoadObjects:withAction:andCompletion:");
    Method method = class_getInstanceMethod(collection, selector);
    if (!method) {
        os_unfair_lock_unlock(&PIBInstallLock);
        return NO;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)PIBFilteredRemoteLoad) {
        PIBFilterInstalled = YES;
        os_unfair_lock_unlock(&PIBInstallLock);
        return YES;
    }
    if (PIBFilterInstalled) {
        os_unfair_lock_unlock(&PIBInstallLock);
        return NO;
    }
    atomic_store_explicit(&PIBOriginalRemoteLoad,
        (PIBRemoteLoadIMP)current, memory_order_release);
    method_setImplementation(method, (IMP)PIBFilteredRemoteLoad);
    PIBFilterInstalled = YES;
    os_unfair_lock_unlock(&PIBInstallLock);
    return YES;
}

#ifdef PIB_FILTER_AUTOSTART_TEST
__attribute__((constructor))
static void PIBFilterTestStart(void) {
    PIBAdFilterInstall();
}
#endif

// Discovery only: do not invoke methods, read object values, or install hooks.
static BOOL PIBCandidateName(NSString *name) {
    if ([name hasPrefix:@"PINModels."] || [name hasPrefix:@"PI"])
        return YES;
    NSString *lower = name.lowercaseString;
    for (NSString *term in @[@"feed", @"promoted", @"sponsor", @"snapshot", @"advertis"])
        if ([lower containsString:term]) return YES;
    return NO;
}

static NSArray *PIBMethods(Class cls, BOOL *truncated) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray *result = [NSMutableArray array];
    unsigned int limit = MIN(count, 200u);
    if (count > limit) *truncated = YES;
    for (unsigned int i = 0; i < limit; i++) {
        const char *encoding = method_getTypeEncoding(methods[i]);
        [result addObject:@{
            @"selector": NSStringFromSelector(method_getName(methods[i])),
            @"encoding": encoding ? @(encoding) : @"",
        }];
    }
    free(methods);
    return result;
}

__attribute__((visibility("default")))
BOOL PIBProbeWriteInventory(const char *outputPath) {
    if (!outputPath || !outputPath[0]) return NO;
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *executable = bundle.executablePath;
        NSString *bundlePrefix = [bundle.bundlePath stringByAppendingString:@"/"];
        BOOL appBundle = [bundle.bundlePath.pathExtension isEqual:@"app"];
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        NSMutableArray *records = [NSMutableArray array];
        NSUInteger matched = 0;
        BOOL truncated = NO;
        for (unsigned int i = 0; i < count; i++) {
            Class cls = classes[i];
            const char *imageName = class_getImageName(cls);
            if (!imageName) continue;
            NSString *image = @(imageName);
            if (![image isEqual:executable] && !(appBundle && [image hasPrefix:bundlePrefix]))
                continue;
            NSString *name = @(class_getName(cls));
            if (!PIBCandidateName(name)) continue;
            matched++;
            if (records.count >= 400) { truncated = YES; continue; }
            unsigned int propertyCount = 0;
            objc_property_t *properties = class_copyPropertyList(cls, &propertyCount);
            NSMutableArray *propertyRecords = [NSMutableArray array];
            for (unsigned int j = 0; j < MIN(propertyCount, 200u); j++) {
                const char *attributes = property_getAttributes(properties[j]);
                [propertyRecords addObject:@{
                    @"name": @(property_getName(properties[j])),
                    @"attributes": attributes ? @(attributes) : @"",
                }];
            }
            if (propertyCount > 200) truncated = YES;
            free(properties);
            Class parent = class_getSuperclass(cls);
            [records addObject:@{
                @"name": name,
                @"image": image,
                @"superclass": parent ? @(class_getName(parent)) : @"",
                @"instanceMethods": PIBMethods(cls, &truncated),
                @"classMethods": PIBMethods(object_getClass(cls), &truncated),
                @"properties": propertyRecords,
            }];
        }
        free(classes);
        NSDictionary *report = @{
            @"schemaVersion": @1,
            @"mode": @"metadata-only",
            @"bundleIdentifier": bundle.bundleIdentifier ?: @"",
            @"version": [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"",
            @"matchedClassCount": @(matched),
            @"truncated": @(truncated),
            @"scope": @"Objective-C-visible app classes; declared methods only; no object values",
            @"classes": records,
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:report
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
        NSString *path = [NSString stringWithUTF8String:outputPath];
        return data && path && [data writeToFile:path options:NSDataWritingAtomic error:NULL];
    }
}

#ifndef PIB_PROBE_NO_AUTOSTART
__attribute__((constructor))
static void PIBProbeStart(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"pinterest"]) return;
        BOOL filterInstalled = PIBAdFilterInstall();
        NSLog(@"[PinterestProbe] ad filter %@",
            filterInstalled ? @"installed" : @"unavailable");
#ifdef PIB_ENABLE_METADATA_AUTOSTART
        // Two bounded snapshots include classes registered after startup.
        for (NSNumber *delay in @[@5, @30]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay.longLongValue * NSEC_PER_SEC),
                dispatch_get_main_queue(), ^{
                    @autoreleasepool {
                        NSString *cache = NSSearchPathForDirectoriesInDomains(
                            NSCachesDirectory, NSUserDomainMask, YES).firstObject;
                        if (!cache) return;
                        NSString *directory = [cache stringByAppendingPathComponent:@"PinterestProbe"];
                        if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES attributes:nil error:NULL]) return;
                        NSString *path = [directory stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"runtime-%@s.json", delay]];
                        BOOL saved = PIBProbeWriteInventory(path.fileSystemRepresentation);
                        NSLog(@"[PinterestProbe] metadata inventory %@", saved ? @"saved" : @"failed");
                    }
                });
        }
#endif
    }
}
#endif
