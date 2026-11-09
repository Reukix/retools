#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
BOOL RTAutomationIsAvailable(void);
BOOL RTPerformAutomation(NSString *request, void (^completion)(BOOL success, NSString *message));
NS_ASSUME_NONNULL_END
