#import "AutomationBridge.h"
#import <objc/message.h>
BOOL RTAutomationIsAvailable(void) {
    return [NSClassFromString(@"RetoolsAutomationBridge") respondsToSelector:NSSelectorFromString(@"runWithRequest:completion:")];
}
BOOL RTPerformAutomation(NSString *request, void (^completion)(BOOL, NSString *)) {
    Class bridge = NSClassFromString(@"RetoolsAutomationBridge");
    SEL action = NSSelectorFromString(@"runWithRequest:completion:");
    if (![bridge respondsToSelector:action]) return NO;
    ((void (*)(id, SEL, NSString *, void (^)(BOOL, NSString *)))objc_msgSend)(bridge, action, request, completion);
    return YES;
}
