#import "SignerCrypto.h"
#import <objc/message.h>
#import <TargetConditionals.h>

NSDictionary *SGSystemInstallationState(NSString *identifier) {
#if TARGET_OS_IPHONE
    @try {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        SEL shared = NSSelectorFromString(@"defaultWorkspace");
        if (!workspaceClass || ![workspaceClass respondsToSelector:shared]) return nil;
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, shared);
        NSMutableDictionary *state = [NSMutableDictionary dictionary];
        SEL progressSelector = NSSelectorFromString(@"installProgressForBundleID:makeSynchronous:");
        if ([workspace respondsToSelector:progressSelector]) {
            id progress = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(workspace, progressSelector, identifier, NO);
            if ([progress isKindOfClass:NSProgress.class]) {
                state[@"fraction"] = @([progress fractionCompleted]);
                state[@"finished"] = @([progress isFinished]);
                state[@"cancelled"] = @([progress isCancelled]);
            }
        }
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        SEL lookup = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (proxyClass && [proxyClass respondsToSelector:lookup]) {
            id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, lookup, identifier);
            SEL installed = NSSelectorFromString(@"isInstalled");
            SEL placeholder = NSSelectorFromString(@"isPlaceholder");
            BOOL valid = proxy && [proxy respondsToSelector:installed] && ((BOOL (*)(id, SEL))objc_msgSend)(proxy, installed);
            if ([proxy respondsToSelector:placeholder] && ((BOOL (*)(id, SEL))objc_msgSend)(proxy, placeholder)) valid = NO;
            state[@"installed"] = @(valid);
            for (NSString *key in @[@"bundleVersion", @"localizedName"]) {
                SEL selector = NSSelectorFromString(key);
                if ([proxy respondsToSelector:selector]) {
                    id value = ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
                    if ([value isKindOfClass:NSString.class]) state[key] = value;
                }
            }
        }
        return state;
    } @catch (NSException *exception) { return nil; }
#else
    return nil;
#endif
}
