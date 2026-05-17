#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *lastDialedNumber = nil;

static void (*orig_openURL)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL));

static void hook_openURL(id self, SEL _cmd, NSURL *url, NSDictionary *options, void (^completion)(BOOL)) {
    if ([url.scheme isEqualToString:@"tel"]) {
        lastDialedNumber = url.resourceSpecifier;
        NSLog(@"[PhoneContextHook] Outgoing call to: %@", lastDialedNumber);

        dispatch_async(dispatch_get_main_queue(), ^{
            UIScene *scene = UIApplication.sharedApplication.connectedScenes.allObjects.firstObject;
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                UIWindow *keyWindow = windowScene.windows.firstObject;

                UILabel *toast = [[UILabel alloc] init];
                toast.text = [NSString stringWithFormat:@"  Calling %@  ", lastDialedNumber];
                toast.textColor = [UIColor whiteColor];
                toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
                toast.textAlignment = NSTextAlignmentCenter;
                toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
                toast.layer.cornerRadius = 20;
                toast.clipsToBounds = YES;
                toast.alpha = 0;
                toast.translatesAutoresizingMaskIntoConstraints = NO;

                [keyWindow addSubview:toast];
                [NSLayoutConstraint activateConstraints:@[
                    [toast.centerXAnchor constraintEqualToAnchor:keyWindow.centerXAnchor],
                    [toast.bottomAnchor constraintEqualToAnchor:keyWindow.safeAreaLayoutGuide.bottomAnchor constant:-20],
                    [toast.widthAnchor constraintGreaterThanOrEqualToConstant:200],
                    [toast.heightAnchor constraintEqualToConstant:40]
                ]];

                [UIView animateWithDuration:0.3 animations:^{
                    toast.alpha = 1.0;
                } completion:^(BOOL finished) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        [UIView animateWithDuration:0.3 animations:^{
                            toast.alpha = 0;
                        } completion:^(BOOL finished) {
                            [toast removeFromSuperview];
                        }];
                    });
                }];
            }
        });
    }

    if (orig_openURL) {
        orig_openURL(self, _cmd, url, options, completion);
    }
}

__attribute__((constructor))
static void init(void) {
    NSLog(@"[PhoneContextHook] Loaded into %@", [[NSBundle mainBundle] bundleIdentifier]);

    Class cls = objc_getClass("UIApplication");
    SEL sel = @selector(openURL:options:completionHandler:);
    Method method = class_getInstanceMethod(cls, sel);

    if (method) {
        orig_openURL = (void *)method_setImplementation(method, (IMP)hook_openURL);
        NSLog(@"[PhoneContextHook] Successfully hooked openURL:options:completionHandler:");
    }
}
