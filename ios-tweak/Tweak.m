#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// ─── state ───────────────────────────────────────────────────────────────────
static BOOL menuVisible = NO;
static void (*orig_openURL3)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL));
static void (*orig_openURL1)(id, SEL, NSURL *);
static void (*orig_presentVC)(id, SEL, UIViewController *, BOOL, void (^)(void));
static void (*orig_wkDecidePolicy)(id, SEL, WKWebView *, WKNavigationAction *, void (^)(WKNavigationActionPolicy));
static void (*orig_wkDecidePolicy2)(id, SEL, WKWebView *, WKNavigationAction *, void (^)(WKNavigationActionPolicy, WKWebpagePreferences *));
static void (*orig_setNavDelegate)(id, SEL, id);
static void (*orig_wkDidFinish)(id, SEL, WKWebView *, WKNavigation *);

// Track which delegate classes we've already swizzled
static NSMutableSet *swizzledDelegateClasses = nil;

// JS that finds unlinked phone numbers and wraps them in tel: links
static NSString *phoneLinkerJS = @""
"(function() {"
"  if (window.__pchLinked) return;"
"  window.__pchLinked = true;"
"  var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);"
"  var phoneRe = /(?:\\+?1[\\s.-]?)?\\(?[2-9]\\d{2}\\)?[\\s.-]?[2-9]\\d{2}[\\s.-]?\\d{4}/g;"
"  var nodes = [];"
"  while (walker.nextNode()) {"
"    var n = walker.currentNode;"
"    if (n.parentElement && n.parentElement.closest('a, button, input, textarea, script, style')) continue;"
"    if (phoneRe.test(n.textContent)) nodes.push(n);"
"    phoneRe.lastIndex = 0;"
"  }"
"  nodes.forEach(function(n) {"
"    var html = n.textContent.replace(phoneRe, function(m) {"
"      var digits = m.replace(/\\D/g, '');"
"      if (digits.length === 11 && digits[0] === '1') digits = digits;"
"      else if (digits.length === 10) digits = '1' + digits;"
"      else return m;"
"      return '<a href=\"tel:' + digits + '\" style=\"color:inherit;text-decoration:underline dotted\">' + m + '</a>';"
"    });"
"    var span = document.createElement('span');"
"    span.innerHTML = html;"
"    n.parentNode.replaceChild(span, n);"
"  });"
"  new MutationObserver(function(muts) {"
"    window.__pchLinked = false;"
"    setTimeout(function() {"
"      if (!window.__pchLinked) {"
"        var s = document.createElement('script');"
"        s.textContent = '(' + arguments.callee + ')();';"
"      }"
"    }, 500);"
"  }).observe(document.body, {childList: true, subtree: true});"
"})();";

// Simpler re-run JS (avoids double-processing)
static NSString *phoneLinkerRerunJS = @""
"(function() {"
"  window.__pchLinked = false;"
"  var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);"
"  var phoneRe = /(?:\\+?1[\\s.-]?)?\\(?[2-9]\\d{2}\\)?[\\s.-]?[2-9]\\d{2}[\\s.-]?\\d{4}/g;"
"  var nodes = [];"
"  while (walker.nextNode()) {"
"    var n = walker.currentNode;"
"    if (n.parentElement && n.parentElement.closest('a, button, input, textarea, script, style')) continue;"
"    if (phoneRe.test(n.textContent)) nodes.push(n);"
"    phoneRe.lastIndex = 0;"
"  }"
"  nodes.forEach(function(n) {"
"    var html = n.textContent.replace(phoneRe, function(m) {"
"      var digits = m.replace(/\\D/g, '');"
"      if (digits.length === 11 && digits[0] === '1') digits = digits;"
"      else if (digits.length === 10) digits = '1' + digits;"
"      else return m;"
"      return '<a href=\"tel:' + digits + '\" style=\"color:inherit;text-decoration:underline dotted\">' + m + '</a>';"
"    });"
"    var span = document.createElement('span');"
"    span.innerHTML = html;"
"    n.parentNode.replaceChild(span, n);"
"  });"
"  window.__pchLinked = true;"
"})();";

// ─── helpers ─────────────────────────────────────────────────────────────────
static UIViewController *topVC(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if (w.isKeyWindow) {
                    UIViewController *vc = w.rootViewController;
                    while (vc.presentedViewController) vc = vc.presentedViewController;
                    return vc;
                }
            }
        }
    }
    return nil;
}

static NSString *formatPhone(NSString *digits) {
    if (digits.length == 10)
        return [NSString stringWithFormat:@"(%@) %@-%@",
            [digits substringToIndex:3],
            [digits substringWithRange:NSMakeRange(3, 3)],
            [digits substringFromIndex:6]];
    if (digits.length == 11)
        return [NSString stringWithFormat:@"+%@ (%@) %@-%@",
            [digits substringToIndex:1],
            [digits substringWithRange:NSMakeRange(1, 3)],
            [digits substringWithRange:NSMakeRange(4, 3)],
            [digits substringFromIndex:7]];
    return digits;
}

static NSString *stripToDigits(NSString *phone) {
    NSMutableString *d = [NSMutableString new];
    for (NSUInteger i = 0; i < phone.length; i++) {
        unichar c = [phone characterAtIndex:i];
        if (c >= '0' && c <= '9') [d appendFormat:@"%C", c];
    }
    return d;
}

static BOOL looksLikePhone(NSString *text) {
    if (!text) return NO;
    NSString *digits = stripToDigits(text);
    return digits.length >= 7 && digits.length <= 15;
}

static void openScheme(NSString *scheme, NSString *digits) {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@:%@", scheme, digits]];
    if (orig_openURL3)
        orig_openURL3(UIApplication.sharedApplication,
            @selector(openURL:options:completionHandler:), url, @{}, nil);
}

static void callAPI(NSString *digits) {
    NSURL *url = [NSURL URLWithString:@"https://mewanthuman-production.up.railway.app/calls"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"phone_number": digits,
        @"action": @"connect_human",
        @"source": @"PhoneContextHook"
    } options:0 error:nil];
    [[NSURLSession.sharedSession dataTaskWithRequest:req] resume];
}

static void showMenu(NSString *number) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
            menuVisible = NO;
            return;
        }
        UIViewController *vc = topVC();
        if (!vc) { menuVisible = NO; return; }

        NSString *digits = stripToDigits(number);
        NSString *display = formatPhone(digits);

        UIAlertController *sheet = [UIAlertController
            alertControllerWithTitle:display message:nil
            preferredStyle:UIAlertControllerStyleActionSheet];

        [sheet addAction:[UIAlertAction actionWithTitle:@"Call" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) { menuVisible = NO; openScheme(@"tel", digits); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"FaceTime" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) { menuVisible = NO; openScheme(@"facetime", digits); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Message" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) { menuVisible = NO; openScheme(@"sms", digits); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) { menuVisible = NO; UIPasteboard.generalPasteboard.string = display; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Connect to Human" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) { menuVisible = NO; callAPI(digits); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
            handler:^(UIAlertAction *a) { menuVisible = NO; }]];

        if (sheet.popoverPresentationController) {
            sheet.popoverPresentationController.sourceView = vc.view;
            sheet.popoverPresentationController.sourceRect = CGRectMake(
                CGRectGetMidX(vc.view.bounds), CGRectGetMidY(vc.view.bounds), 0, 0);
        }

        if (orig_presentVC) {
            orig_presentVC(vc, @selector(presentViewController:animated:completion:),
                           sheet, YES, nil);
        } else {
            [vc presentViewController:sheet animated:YES completion:nil];
        }
    });
}

// Check if a URL is a phone-related scheme
static BOOL isPhoneURL(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:@"tel"] ||
           [scheme isEqualToString:@"telprompt"];
}

// Inject phone-linkifying JS into a WKWebView
static void injectPhoneLinker(WKWebView *webView) {
    [webView evaluateJavaScript:phoneLinkerJS completionHandler:^(id result, NSError *error) {
        if (error) {
            NSLog(@"[PCH] JS inject error: %@", error.localizedDescription);
        } else {
            NSLog(@"[PCH] Phone linker JS injected into %@", webView.URL.host);
        }
    }];
}

// ─── Hook 1: openURL:options:completionHandler: ─────────────────────────────
static void hook_openURL3(id self, SEL _cmd, NSURL *url, NSDictionary *opts, void (^completion)(BOOL)) {
    NSLog(@"[PCH] openURL3: %@", url);
    if (isPhoneURL(url)) {
        UIApplicationState state = UIApplication.sharedApplication.applicationState;
        if (state != UIApplicationStateActive || menuVisible) {
            if (orig_openURL3) orig_openURL3(self, _cmd, url, opts, completion);
            return;
        }
        menuVisible = YES;
        showMenu(url.resourceSpecifier);
        if (completion) completion(NO);
        return;
    }
    if (orig_openURL3) orig_openURL3(self, _cmd, url, opts, completion);
}

// ─── Hook 2: openURL: (legacy, some code paths still use this) ──────────────
static void hook_openURL1(id self, SEL _cmd, NSURL *url) {
    NSLog(@"[PCH] openURL1: %@", url);
    if (isPhoneURL(url)) {
        UIApplicationState state = UIApplication.sharedApplication.applicationState;
        if (state != UIApplicationStateActive || menuVisible) {
            if (orig_openURL1) orig_openURL1(self, _cmd, url);
            return;
        }
        menuVisible = YES;
        showMenu(url.resourceSpecifier);
        return;
    }
    if (orig_openURL1) orig_openURL1(self, _cmd, url);
}

// ─── Hook 3: presentViewController (catches native phone action sheets) ─────
static void hook_presentVC(id self, SEL _cmd, UIViewController *vc, BOOL animated, void (^completion)(void)) {
    if ([vc isKindOfClass:[UIAlertController class]]) {
        UIAlertController *alert = (UIAlertController *)vc;
        if (alert.preferredStyle == UIAlertControllerStyleActionSheet) {
            BOOL hasCallAction = NO;
            for (UIAlertAction *action in alert.actions) {
                NSString *t = action.title.lowercaseString;
                if ([t containsString:@"call"] || [t containsString:@"facetime"] ||
                    [t containsString:@"send message"] || [t containsString:@"add to contacts"]) {
                    hasCallAction = YES;
                    break;
                }
            }
            if (hasCallAction && looksLikePhone(alert.title)) {
                NSString *digits = stripToDigits(alert.title);
                NSLog(@"[PCH] Intercepted native phone sheet: %@", digits);
                if (!menuVisible) {
                    menuVisible = YES;
                    showMenu(digits);
                }
                if (completion) completion();
                return;
            }
        }
    }

    NSLog(@"[PCH] presentVC: %@ from %@",
          NSStringFromClass([vc class]), NSStringFromClass([self class]));
    if (orig_presentVC) orig_presentVC(self, _cmd, vc, animated, completion);
}

// ─── Hook 4: WKWebView navigation delegate — intercept tel: in webviews ─────
static void hook_wkDecidePolicy(id self, SEL _cmd, WKWebView *webView,
                                 WKNavigationAction *action,
                                 void (^decisionHandler)(WKNavigationActionPolicy)) {
    NSURL *url = action.request.URL;
    NSLog(@"[PCH] WK decidePolicyFor: %@", url);
    if (url && isPhoneURL(url)) {
        NSLog(@"[PCH] WK intercepted tel: %@", url);
        decisionHandler(WKNavigationActionPolicyCancel);
        if (!menuVisible) {
            menuVisible = YES;
            showMenu(url.resourceSpecifier);
        }
        return;
    }
    if (orig_wkDecidePolicy)
        orig_wkDecidePolicy(self, _cmd, webView, action, decisionHandler);
    else
        decisionHandler(WKNavigationActionPolicyAllow);
}

static void hook_wkDecidePolicy2(id self, SEL _cmd, WKWebView *webView,
                                  WKNavigationAction *action,
                                  void (^decisionHandler)(WKNavigationActionPolicy, WKWebpagePreferences *)) {
    NSURL *url = action.request.URL;
    NSLog(@"[PCH] WK decidePolicyFor2: %@", url);
    if (url && isPhoneURL(url)) {
        NSLog(@"[PCH] WK intercepted tel (v2): %@", url);
        decisionHandler(WKNavigationActionPolicyCancel, action.targetFrame.request ? nil : nil);
        if (!menuVisible) {
            menuVisible = YES;
            showMenu(url.resourceSpecifier);
        }
        return;
    }
    if (orig_wkDecidePolicy2)
        orig_wkDecidePolicy2(self, _cmd, webView, action, decisionHandler);
    else
        decisionHandler(WKNavigationActionPolicyAllow, nil);
}

// ─── Hook 6: WKWebView didFinishNavigation — inject phone linker JS ─────────
static void hook_wkDidFinish(id self, SEL _cmd, WKWebView *webView, WKNavigation *navigation) {
    NSLog(@"[PCH] WK didFinishNavigation: %@", webView.URL.host);
    injectPhoneLinker(webView);
    if (orig_wkDidFinish)
        orig_wkDidFinish(self, _cmd, webView, navigation);
}

// Swizzle a navigation delegate class to intercept tel: URLs and inject phone linker
static void swizzleDelegateClass(Class cls) {
    if (!cls) return;
    NSString *clsName = NSStringFromClass(cls);
    @synchronized(swizzledDelegateClasses) {
        if ([swizzledDelegateClasses containsObject:clsName]) return;
        [swizzledDelegateClasses addObject:clsName];
    }

    // decidePolicyForNavigationAction (v2 — iOS 13+)
    SEL sel2 = @selector(webView:decidePolicyForNavigationAction:preferences:decisionHandler:);
    SEL sel1 = @selector(webView:decidePolicyForNavigationAction:decisionHandler:);
    SEL selFinish = @selector(webView:didFinishNavigation:);

    Method m2 = class_getInstanceMethod(cls, sel2);
    Method m1 = class_getInstanceMethod(cls, sel1);
    Method mFinish = class_getInstanceMethod(cls, selFinish);

    if (m2) {
        orig_wkDecidePolicy2 = (void *)method_setImplementation(m2, (IMP)hook_wkDecidePolicy2);
        NSLog(@"[PCH] Swizzled %@ decidePolicyV2", clsName);
    }

    if (m1) {
        orig_wkDecidePolicy = (void *)method_setImplementation(m1, (IMP)hook_wkDecidePolicy);
        NSLog(@"[PCH] Swizzled %@ decidePolicyV1", clsName);
    }

    if (!m1 && !m2) {
        class_addMethod(cls, sel1,
            (IMP)hook_wkDecidePolicy,
            "v@:@@?");
        orig_wkDecidePolicy = NULL;
        NSLog(@"[PCH] Added decidePolicyV1 to %@", clsName);
    }

    // didFinishNavigation — inject phone linker JS after page loads
    if (mFinish) {
        orig_wkDidFinish = (void *)method_setImplementation(mFinish, (IMP)hook_wkDidFinish);
        NSLog(@"[PCH] Swizzled %@ didFinishNavigation", clsName);
    } else {
        class_addMethod(cls, selFinish,
            (IMP)hook_wkDidFinish,
            "v@:@@");
        orig_wkDidFinish = NULL;
        NSLog(@"[PCH] Added didFinishNavigation to %@", clsName);
    }
}

// ─── Hook 5: WKWebView setNavigationDelegate: — auto-swizzle any delegate ───
static void hook_setNavDelegate(id self, SEL _cmd, id delegate) {
    if (delegate) {
        NSLog(@"[PCH] WKWebView setNavigationDelegate: %@", NSStringFromClass([delegate class]));
        swizzleDelegateClass([delegate class]);
    }
    if (orig_setNavDelegate) orig_setNavDelegate(self, _cmd, delegate);
}


// ─── FLEX loader ─────────────────────────────────────────────────────────────
static void loadFLEX(void) {
    NSString *frameworksPath = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Frameworks"];
    NSString *flexPath = [frameworksPath stringByAppendingPathComponent:@"FLEX.dylib"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:flexPath]) {
        NSLog(@"[PCH] FLEX.dylib not found at %@", flexPath);
        return;
    }

    void *handle = dlopen(flexPath.UTF8String, RTLD_NOW);
    if (!handle) {
        NSLog(@"[PCH] Failed to load FLEX: %s", dlerror());
        return;
    }

    NSLog(@"[PCH] FLEX loaded successfully");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        Class FLEXManager = objc_getClass("FLEXManager");
        if (!FLEXManager) {
            NSLog(@"[PCH] FLEXManager class not found after dlopen");
            return;
        }
        id manager = [FLEXManager performSelector:@selector(sharedManager)];
        if (manager) {
            [manager performSelector:@selector(showExplorer)];
            NSLog(@"[PCH] FLEX explorer shown");
        }
    });
}

// ─── init ────────────────────────────────────────────────────────────────────
__attribute__((constructor))
static void init_hook(void) {
    NSLog(@"[PCH] ========================================");
    NSLog(@"[PCH] PhoneContextHook v4 loaded into %@", [[NSBundle mainBundle] bundleIdentifier]);
    NSLog(@"[PCH] ========================================");

    swizzledDelegateClasses = [NSMutableSet new];

    // Hook 1: UIApplication openURL:options:completionHandler:
    Method m1 = class_getInstanceMethod(
        objc_getClass("UIApplication"),
        @selector(openURL:options:completionHandler:));
    if (m1) {
        orig_openURL3 = (void *)method_setImplementation(m1, (IMP)hook_openURL3);
        NSLog(@"[PCH] Hooked openURL:options:completionHandler:");
    }

    // Hook 2: UIApplication openURL: (legacy)
    Method m2 = class_getInstanceMethod(
        objc_getClass("UIApplication"),
        @selector(openURL:));
    if (m2) {
        orig_openURL1 = (void *)method_setImplementation(m2, (IMP)hook_openURL1);
        NSLog(@"[PCH] Hooked openURL:");
    }

    // Hook 3: UIViewController presentViewController:animated:completion:
    Method m3 = class_getInstanceMethod(
        objc_getClass("UIViewController"),
        @selector(presentViewController:animated:completion:));
    if (m3) {
        orig_presentVC = (void *)method_setImplementation(m3, (IMP)hook_presentVC);
        NSLog(@"[PCH] Hooked presentViewController:animated:completion:");
    }

    // Hook 4: WKWebView setNavigationDelegate:
    Method m4 = class_getInstanceMethod(
        objc_getClass("WKWebView"),
        @selector(setNavigationDelegate:));
    if (m4) {
        orig_setNavDelegate = (void *)method_setImplementation(m4, (IMP)hook_setNavDelegate);
        NSLog(@"[PCH] Hooked WKWebView setNavigationDelegate:");
    }

    // Load FLEX if present
    loadFLEX();
}
