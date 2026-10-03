#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static unsigned getterCalls;
@interface PIPinProbeFixture : NSObject
@property(nonatomic, readonly) BOOL isPromoted;
@end
@implementation PIPinProbeFixture
- (BOOL)isPromoted { getterCalls++; return YES; }
@end

static void require(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        require(argc == 2, "supply dylib path");
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        require(library != NULL, "runtime probe dylib must load");
        BOOL (*writeInventory)(const char *) = dlsym(library, "PIBProbeWriteInventory");
        require(writeInventory != NULL, "inventory entry point must exist");
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"pib-probe-%@.json", NSUUID.UUID.UUIDString]];
        require(writeInventory(path.fileSystemRepresentation), "write runtime inventory");
        NSData *data = [NSData dataWithContentsOfFile:path];
        NSDictionary *report = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        require([report[@"mode"] isEqual:@"metadata-only"], "report must identify diagnostic mode");
        NSDictionary *fixture = nil;
        for (NSDictionary *item in report[@"classes"]) {
            if ([item[@"name"] isEqual:@"PIPinProbeFixture"]) fixture = item;
        }
        require(fixture != nil, "include a pin model loaded in the application image");
        BOOL foundGetter = NO;
        for (NSDictionary *method in fixture[@"instanceMethods"]) {
            if ([method[@"selector"] isEqual:@"isPromoted"]) {
                foundGetter = YES;
                require([method[@"encoding"] isEqual:@"B16@0:8"],
                    "record the exact Objective-C BOOL getter ABI");
            }
        }
        require(foundGetter, "include promoted discriminator signature");
        require(getterCalls == 0, "metadata collection must never invoke model getters");
        require(!writeInventory(NULL), "reject a null output path");
        require(!writeInventory(""), "reject an empty output path");
        require(!writeInventory("/nonexistent-pib-probe/report.json"), "surface write failure");
        require([NSFileManager.defaultManager removeItemAtPath:path error:NULL], "clean fixture report");
        puts("PASS: runtime metadata, ABI, no getter execution, and write errors");
    }
    return 0;
}
