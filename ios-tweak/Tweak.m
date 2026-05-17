#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreText/CoreText.h>

static BOOL menuIsShowing = NO;
static NSDataDetector *phoneDetector = nil;

// Associated object keys
static const char kPhoneRangesKey;
static const char kPhoneNumbersKey;
static const char kProcessedKey;
static const char kOriginalTextKey;

#pragma mark - Helpers

static UIViewController *topViewController(void) {
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            scene = (UIWindowScene *)s;
            break;
        }
    }
    if (!scene) return nil;

    UIWindow *keyWindow = nil;
    for (UIWindow *w in scene.windows) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow) keyWindow = scene.windows.firstObject;

    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

static void showToast(NSString *message, UIColor *bgColor) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = topViewController();
        if (!vc) return;

        UILabel *toast = [[UILabel alloc] init];
        toast.text = [NSString stringWithFormat:@"  %@  ", message];
        toast.textColor = UIColor.whiteColor;
        toast.backgroundColor = bgColor;
        toast.textAlignment = NSTextAlignmentCenter;
        toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        toast.layer.cornerRadius = 20;
        toast.clipsToBounds = YES;
        toast.alpha = 0;
        toast.translatesAutoresizingMaskIntoConstraints = NO;
        // Don't let our toast get re-scanned
        objc_setAssociatedObject(toast, &kProcessedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        [vc.view addSubview:toast];
        [NSLayoutConstraint activateConstraints:@[
            [toast.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
            [toast.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:8],
            [toast.heightAnchor constraintEqualToConstant:40]
        ]];

        [UIView animateWithDuration:0.25 animations:^{ toast.alpha = 1; }
        completion:^(BOOL done) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{ toast.alpha = 0; }
                completion:^(BOOL d) { [toast removeFromSuperview]; }];
            });
        }];
    });
}

static NSDataDetector *getPhoneDetector(void) {
    if (!phoneDetector) {
        phoneDetector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypePhoneNumber error:nil];
    }
    return phoneDetector;
}

// Strip a phone number down to digits only
static NSString *digitsOnly(NSString *phone) {
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [[phone componentsSeparatedByCharactersInSet:nonDigits] componentsJoinedByString:@""];
}

#pragma mark - Forward declaration
static void (*orig_openURL)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL));

#pragma mark - HTTP API Call

static void makeAPICall(NSString *phoneNumber) {
    NSLog(@"[PhoneContextHook] Making HTTP API call for: %@", phoneNumber);

    NSURL *url = [NSURL URLWithString:@"https://mewanthuman-production.up.railway.app/calls"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{
        @"phone_number": phoneNumber,
        @"action": @"connect_human",
        @"source": @"PhoneContextHook"
    };
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                showToast([NSString stringWithFormat:@"API Error: %@", error.localizedDescription],
                          [UIColor systemRedColor]);
                return;
            }
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            showToast([NSString stringWithFormat:@"API OK (%ld) — %@",
                       (long)httpResp.statusCode, phoneNumber],
                      [[UIColor systemGreenColor] colorWithAlphaComponent:0.95]);
        }];
    [task resume];
}

#pragma mark - Popup Menu

static void showPhoneMenu(NSString *phoneNumber) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = topViewController();
        if (!vc) return;

        NSString *digits = digitsOnly(phoneNumber);
        NSString *formatted = phoneNumber;
        if (digits.length == 10) {
            formatted = [NSString stringWithFormat:@"(%@) %@-%@",
                [digits substringToIndex:3],
                [digits substringWithRange:NSMakeRange(3, 3)],
                [digits substringFromIndex:6]];
        } else if (digits.length == 11) {
            formatted = [NSString stringWithFormat:@"+%@ (%@) %@-%@",
                [digits substringToIndex:1],
                [digits substringWithRange:NSMakeRange(1, 3)],
                [digits substringWithRange:NSMakeRange(4, 3)],
                [digits substringFromIndex:7]];
        }

        UIAlertController *sheet = [UIAlertController
            alertControllerWithTitle:formatted
            message:nil
            preferredStyle:UIAlertControllerStyleActionSheet];

        [sheet addAction:[UIAlertAction actionWithTitle:@"📞  Call"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                menuIsShowing = NO;
                NSURL *tel = [NSURL URLWithString:
                    [NSString stringWithFormat:@"tel:%@", digits]];
                if (orig_openURL) {
                    orig_openURL(UIApplication.sharedApplication,
                        @selector(openURL:options:completionHandler:),
                        tel, @{}, nil);
                }
            }]];

        [sheet addAction:[UIAlertAction actionWithTitle:@"📹  FaceTime"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                menuIsShowing = NO;
                NSURL *ft = [NSURL URLWithString:
                    [NSString stringWithFormat:@"facetime:%@", digits]];
                if (orig_openURL) {
                    orig_openURL(UIApplication.sharedApplication,
                        @selector(openURL:options:completionHandler:),
                        ft, @{}, nil);
                }
            }]];

        [sheet addAction:[UIAlertAction actionWithTitle:@"💬  Send Message"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                menuIsShowing = NO;
                NSURL *sms = [NSURL URLWithString:
                    [NSString stringWithFormat:@"sms:%@", digits]];
                if (orig_openURL) {
                    orig_openURL(UIApplication.sharedApplication,
                        @selector(openURL:options:completionHandler:),
                        sms, @{}, nil);
                }
            }]];

        [sheet addAction:[UIAlertAction actionWithTitle:@"📋  Copy Number"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                menuIsShowing = NO;
                UIPasteboard.generalPasteboard.string = formatted;
                showToast(@"Number copied!", [UIColor systemBlueColor]);
            }]];

        [sheet addAction:[UIAlertAction actionWithTitle:@"🌐  Call via API"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                menuIsShowing = NO;
                showToast([NSString stringWithFormat:@"API request for %@...", formatted],
                          [UIColor systemIndigoColor]);
                makeAPICall(digits);
            }]];

        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
            style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
                menuIsShowing = NO;
            }]];

        if (sheet.popoverPresentationController) {
            sheet.popoverPresentationController.sourceView = vc.view;
            sheet.popoverPresentationController.sourceRect = CGRectMake(
                CGRectGetMidX(vc.view.bounds),
                CGRectGetMidY(vc.view.bounds), 0, 0);
        }

        [vc presentViewController:sheet animated:YES completion:nil];
    });
}

#pragma mark - Label tap detection

static NSUInteger characterIndexAtPoint(UILabel *label, CGPoint point) {
    NSAttributedString *attrText = label.attributedText;
    if (!attrText || attrText.length == 0) return NSNotFound;

    NSTextStorage *textStorage = [[NSTextStorage alloc] initWithAttributedString:attrText];
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    NSTextContainer *textContainer = [[NSTextContainer alloc] initWithSize:label.bounds.size];
    textContainer.lineFragmentPadding = 0;
    textContainer.maximumNumberOfLines = label.numberOfLines;
    textContainer.lineBreakMode = label.lineBreakMode;

    [layoutManager addTextContainer:textContainer];
    [textStorage addLayoutManager:layoutManager];

    CGRect textBounds = [layoutManager usedRectForTextContainer:textContainer];
    CGPoint textOffset = CGPointZero;

    // Vertical alignment
    switch (label.contentMode) {
        default:
            textOffset.y = (label.bounds.size.height - textBounds.size.height) / 2.0;
            break;
    }

    // Horizontal alignment
    if (label.textAlignment == NSTextAlignmentCenter) {
        textOffset.x = (label.bounds.size.width - textBounds.size.width) / 2.0;
    } else if (label.textAlignment == NSTextAlignmentRight) {
        textOffset.x = label.bounds.size.width - textBounds.size.width;
    }

    CGPoint adjusted = CGPointMake(point.x - textOffset.x, point.y - textOffset.y);

    if (adjusted.x < 0 || adjusted.y < 0 ||
        adjusted.x > textBounds.size.width || adjusted.y > textBounds.size.height) {
        return NSNotFound;
    }

    CGFloat fraction = 0;
    NSUInteger idx = [layoutManager characterIndexForPoint:adjusted
                                          inTextContainer:textContainer
                 fractionOfDistanceBetweenInsertionPoints:&fraction];
    return idx;
}

static void handleLabelTap(UITapGestureRecognizer *tap) {
    UILabel *label = (UILabel *)tap.view;
    if (![label isKindOfClass:[UILabel class]]) return;

    CGPoint point = [tap locationInView:label];
    NSUInteger charIdx = characterIndexAtPoint(label, point);
    if (charIdx == NSNotFound) return;

    NSArray<NSValue *> *ranges = objc_getAssociatedObject(label, &kPhoneRangesKey);
    NSArray<NSString *> *numbers = objc_getAssociatedObject(label, &kPhoneNumbersKey);
    if (!ranges || !numbers) return;

    for (NSUInteger i = 0; i < ranges.count; i++) {
        NSRange range = ranges[i].rangeValue;
        if (charIdx >= range.location && charIdx < range.location + range.length) {
            if (!menuIsShowing) {
                menuIsShowing = YES;
                showPhoneMenu(numbers[i]);
            }
            return;
        }
    }
}

#pragma mark - Label phone number scanning

static void scanAndProcessLabel(UILabel *label) {
    // Skip our own toast labels
    if (objc_getAssociatedObject(label, &kProcessedKey)) return;

    NSString *text = label.text;
    if (!text || text.length < 7) return;

    NSDataDetector *detector = getPhoneDetector();
    NSArray<NSTextCheckingResult *> *matches = [detector matchesInString:text
        options:0 range:NSMakeRange(0, text.length)];
    if (matches.count == 0) return;

    // Check if we already processed this exact text
    NSString *prevText = objc_getAssociatedObject(label, &kOriginalTextKey);
    if ([prevText isEqualToString:text]) return;

    NSLog(@"[PhoneContextHook] Found %lu phone number(s) in label: \"%@\"",
          (unsigned long)matches.count, text);

    // Build attributed string with phone numbers highlighted
    UIFont *font = label.font ?: [UIFont systemFontOfSize:17];
    UIColor *textColor = label.textColor ?: UIColor.labelColor;

    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc]
        initWithString:text attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: textColor
        }];

    NSMutableArray<NSValue *> *phoneRanges = [NSMutableArray new];
    NSMutableArray<NSString *> *phoneNumbers = [NSMutableArray new];

    for (NSTextCheckingResult *match in matches) {
        [attr addAttributes:@{
            NSForegroundColorAttributeName: [UIColor systemBlueColor],
            NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)
        } range:match.range];

        [phoneRanges addObject:[NSValue valueWithRange:match.range]];
        [phoneNumbers addObject:match.phoneNumber ?: [text substringWithRange:match.range]];
    }

    // Store data on the label
    objc_setAssociatedObject(label, &kPhoneRangesKey, phoneRanges, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(label, &kPhoneNumbersKey, phoneNumbers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(label, &kOriginalTextKey, text, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(label, &kProcessedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Set the styled text
    label.attributedText = attr;
    label.userInteractionEnabled = YES;

    // Add tap gesture if not already there
    BOOL hasTap = NO;
    for (UIGestureRecognizer *g in label.gestureRecognizers) {
        if ([g isKindOfClass:[UITapGestureRecognizer class]]) {
            hasTap = YES;
            break;
        }
    }
    if (!hasTap) {
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:nil action:nil];
        [tap addTarget:[NSClassFromString(@"NSObject") class]
                action:@selector(description)]; // placeholder
        // We use a different mechanism — see below
        [label removeGestureRecognizer:tap];

        tap = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
        // Use block-based approach via associated object
        __weak UILabel *weakLabel = label;
        id handler = ^(UITapGestureRecognizer *t) {
            UILabel *l = weakLabel;
            if (l) handleLabelTap(t);
        };
        objc_setAssociatedObject(tap, "handler", handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Can't use blocks directly with addTarget, so use a trampoline
        // Instead, just use the C function approach with a target
        [label removeGestureRecognizer:tap];
    }

    // Simpler approach: use a concrete target
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:label action:@selector(pch_handleTap:)];
    [label addGestureRecognizer:tap];
}

#pragma mark - UILabel swizzling

static IMP orig_label_setText = NULL;
static IMP orig_label_didMoveToWindow = NULL;

static void swizzled_label_setText(UILabel *self, SEL _cmd, NSString *text) {
    // Reset processed flag so we re-scan
    objc_setAssociatedObject(self, &kProcessedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kOriginalTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ((void(*)(id, SEL, NSString *))orig_label_setText)(self, _cmd, text);

    if (self.window) {
        scanAndProcessLabel(self);
    }
}

static void swizzled_label_didMoveToWindow(UILabel *self, SEL _cmd) {
    ((void(*)(id, SEL))orig_label_didMoveToWindow)(self, _cmd);

    if (self.window) {
        scanAndProcessLabel(self);
    }
}

#pragma mark - Tap handler via category method added at runtime

static void pch_handleTapIMP(UILabel *self, SEL _cmd, UITapGestureRecognizer *tap) {
    handleLabelTap(tap);
}

#pragma mark - UITextView data detection hook

static IMP orig_textView_shouldInteract = NULL;

static BOOL swizzled_shouldInteract(id self, SEL _cmd, UITextView *textView,
    NSURL *url, NSRange range, UITextItemInteraction interaction) {
    if ([url.scheme isEqualToString:@"tel"]) {
        NSString *number = url.resourceSpecifier;
        if (!menuIsShowing) {
            menuIsShowing = YES;
            showPhoneMenu(number);
        }
        return NO;
    }

    if (orig_textView_shouldInteract) {
        return ((BOOL(*)(id, SEL, UITextView *, NSURL *, NSRange, UITextItemInteraction))
            orig_textView_shouldInteract)(self, _cmd, textView, url, range, interaction);
    }
    return YES;
}

#pragma mark - openURL hook

static void hook_openURL(id self, SEL _cmd, NSURL *url, NSDictionary *options, void (^completion)(BOOL)) {
    if ([url.scheme isEqualToString:@"tel"]) {
        NSString *number = url.resourceSpecifier;
        NSLog(@"[PhoneContextHook] Intercepted tel: link → %@", number);

        if (!menuIsShowing) {
            menuIsShowing = YES;
            showPhoneMenu(number);
        }

        if (completion) completion(NO);
        return;
    }

    if (orig_openURL) {
        orig_openURL(self, _cmd, url, options, completion);
    }
}

#pragma mark - Init

__attribute__((constructor))
static void init_hook(void) {
    NSLog(@"[PhoneContextHook] Loading into %@", [[NSBundle mainBundle] bundleIdentifier]);

    // 1. Hook openURL for tel: links
    Class appClass = objc_getClass("UIApplication");
    Method openMethod = class_getInstanceMethod(appClass, @selector(openURL:options:completionHandler:));
    if (openMethod) {
        orig_openURL = (void *)method_setImplementation(openMethod, (IMP)hook_openURL);
        NSLog(@"[PhoneContextHook] Hooked openURL");
    }

    // 2. Add tap handler method to UILabel
    Class labelClass = objc_getClass("UILabel");
    class_addMethod(labelClass, @selector(pch_handleTap:),
                    (IMP)pch_handleTapIMP, "v@:@");

    // 3. Hook UILabel setText: to scan for phone numbers
    Method setTextMethod = class_getInstanceMethod(labelClass, @selector(setText:));
    if (setTextMethod) {
        orig_label_setText = method_setImplementation(setTextMethod, (IMP)swizzled_label_setText);
        NSLog(@"[PhoneContextHook] Hooked UILabel setText:");
    }

    // 4. Hook UILabel didMoveToWindow to catch labels set before our hook
    Method didMoveMethod = class_getInstanceMethod(labelClass, @selector(didMoveToWindow));
    if (didMoveMethod) {
        orig_label_didMoveToWindow = method_setImplementation(didMoveMethod, (IMP)swizzled_label_didMoveToWindow);
        NSLog(@"[PhoneContextHook] Hooked UILabel didMoveToWindow");
    }

    NSLog(@"[PhoneContextHook] All hooks installed — scanning labels for phone numbers");
}
