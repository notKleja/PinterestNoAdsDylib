#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <os/lock.h>
#include <stdlib.h>
#include <stdatomic.h>

typedef void (*PIBRemoteLoadIMP)(id, SEL, id, NSArray *, NSInteger, id);
typedef NSURL *(*PIBAppGroupURLIMP)(id, SEL, NSString *);
static _Atomic(PIBRemoteLoadIMP) PIBOriginalRemoteLoad;
static _Atomic(PIBAppGroupURLIMP) PIBOriginalAppGroupURL;
static os_unfair_lock PIBInstallLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock PIBAppGroupInstallLock = OS_UNFAIR_LOCK_INIT;
static BOOL PIBFilterInstalled;
static BOOL PIBAppGroupFallbackInstalled;

__attribute__((visibility("default")))
BOOL PIBSupportsBundleIdentifier(NSString *bundleIdentifier) {
    return [bundleIdentifier isEqual:@"pinterest"] ||
        [bundleIdentifier isEqual:@"com.kleja.pinterestnoads"];
}

static NSURL *PIBAppGroupURLUnderRoot(NSURL *root, NSString *groupIdentifier) {
    if (!root) return nil;
    return [[[root URLByAppendingPathComponent:@"PinterestNoAds" isDirectory:YES]
        URLByAppendingPathComponent:@"AppGroup" isDirectory:YES]
        URLByAppendingPathComponent:groupIdentifier isDirectory:YES];
}

static NSURL *PIBContainerURLForAppGroup(id self, SEL selector,
                                         NSString *groupIdentifier) {
    PIBAppGroupURLIMP original = atomic_load_explicit(
        &PIBOriginalAppGroupURL, memory_order_acquire);
    NSURL *result = original(self, selector, groupIdentifier);
    if (result || ![groupIdentifier isEqualToString:@"group.pinterest"])
        return result;

    NSFileManager *manager = self;
    NSURL *applicationSupport = [manager URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject;
    if (!applicationSupport) {
        NSString *home = NSHomeDirectory();
        if (home.length == 0) return nil;
        applicationSupport = [NSURL fileURLWithPath:
            [home stringByAppendingPathComponent:@"Library/Application Support"]
            isDirectory:YES];
    }
    NSURL *fallback = PIBAppGroupURLUnderRoot(applicationSupport, groupIdentifier);
    NSError *applicationSupportError = nil;
    if (![manager createDirectoryAtURL:fallback withIntermediateDirectories:YES
        attributes:nil error:&applicationSupportError]) {
        NSString *temporaryPath = NSTemporaryDirectory();
        NSURL *temporaryRoot = temporaryPath.length > 0 ?
            [NSURL fileURLWithPath:temporaryPath isDirectory:YES] : nil;
        fallback = PIBAppGroupURLUnderRoot(temporaryRoot, groupIdentifier);
        NSError *temporaryError = nil;
        if (!fallback || ![manager createDirectoryAtURL:fallback
            withIntermediateDirectories:YES attributes:nil error:&temporaryError]) {
            NSLog(@"[PinterestProbe] app-group fallback unavailable: %@; %@",
                applicationSupportError, temporaryError);
            return nil;
        }
    }
    NSLog(@"[PinterestProbe] using app-group fallback for %@", groupIdentifier);
    return fallback;
}

__attribute__((visibility("default")))
BOOL PIBAppGroupFallbackInstall(void) {
    os_unfair_lock_lock(&PIBAppGroupInstallLock);
    SEL selector = @selector(containerURLForSecurityApplicationGroupIdentifier:);
    Method method = class_getInstanceMethod(NSFileManager.class, selector);
    if (!method) {
        os_unfair_lock_unlock(&PIBAppGroupInstallLock);
        return NO;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)PIBContainerURLForAppGroup) {
        PIBAppGroupFallbackInstalled = YES;
        os_unfair_lock_unlock(&PIBAppGroupInstallLock);
        return YES;
    }
    if (PIBAppGroupFallbackInstalled) {
        os_unfair_lock_unlock(&PIBAppGroupInstallLock);
        return NO;
    }
    atomic_store_explicit(&PIBOriginalAppGroupURL,
        (PIBAppGroupURLIMP)current, memory_order_release);
    method_setImplementation(method, (IMP)PIBContainerURLForAppGroup);
    PIBAppGroupFallbackInstalled = YES;
    os_unfair_lock_unlock(&PIBAppGroupInstallLock);
    return YES;
}

static BOOL PIBModelBoolean(id model, SEL selector) {
    if (![model respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(model, selector);
}

static BOOL PIBIsAdModel(id model) {
    return PIBModelBoolean(model, @selector(isPromoted)) ||
        PIBModelBoolean(model, @selector(isSponsored));
}

static BOOL PIBIsSearchImmersiveHeader(id model) {
    SEL selector = NSSelectorFromString(@"storyType");
    Method method = class_getInstanceMethod([model class], selector);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || encoding[0] != '@' || ![model respondsToSelector:selector])
        return NO;
    id value = ((id (*)(id, SEL))objc_msgSend)(model, selector);
    return [value isKindOfClass:NSString.class] &&
        [value isEqual:@"slp_immersive_header"];
}

static void PIBFilteredRemoteLoad(id self, SEL selector, id manager,
                                  NSArray *objects, NSInteger action, id completion) {
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:objects.count];
    NSUInteger adsRemoved = 0;
    NSUInteger searchHeroesRemoved = 0;
    for (id object in objects) {
        if (PIBIsAdModel(object)) {
            adsRemoved++;
        } else if (PIBIsSearchImmersiveHeader(object)) {
            searchHeroesRemoved++;
        } else {
            [filtered addObject:object];
        }
    }
    NSUInteger removed = adsRemoved + searchHeroesRemoved;
    if (removed > 0) {
        SEL paginationSelector =
            NSSelectorFromString(@"setContinuesPaginationAfterObjectsRemoved:");
        if ([self respondsToSelector:paginationSelector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                self, paginationSelector, YES);
        }
        if (adsRemoved > 0) {
            NSLog(@"[PinterestProbe] removed %lu promoted/sponsored model(s)",
                (unsigned long)adsRemoved);
        }
        if (searchHeroesRemoved > 0) {
            NSLog(@"[PinterestProbe] removed %lu Search immersive header(s)",
                (unsigned long)searchHeroesRemoved);
        }
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
        if (!PIBSupportsBundleIdentifier(NSBundle.mainBundle.bundleIdentifier)) return;
        BOOL appGroupFallbackInstalled = PIBAppGroupFallbackInstall();
        BOOL filterInstalled = PIBAdFilterInstall();
        NSLog(@"[PinterestProbe] app-group fallback %@",
            appGroupFallbackInstalled ? @"installed" : @"unavailable");
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
