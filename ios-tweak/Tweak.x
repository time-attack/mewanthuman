/*
 * PhoneContextHook
 *
 * Hooks the long-press context menu on recent call entries in Phone.app
 * and adds a "Send to API" action that POSTs the phone number as JSON.
 *
 * Injection: embed this dylib into MobilePhone.app via insert_dylib,
 * TrollStore, or any sideload injection pipeline.
 *
 * Configuration: set your API endpoint in the constant below, or read it
 * from a companion plist (see loadConfig()).
 */

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

static NSString *gAPIEndpoint = @"https://mewanthuman-production.up.railway.app/calls";

// ---------------------------------------------------------------------------
// Networking
// ---------------------------------------------------------------------------

static void sendPhoneNumberToAPI(NSString *phoneNumber) {
    if (phoneNumber.length == 0) {
        NSLog(@"[PhoneContextHook] sendPhoneNumberToAPI: empty number, skipping");
        return;
    }

    NSURL *url = [NSURL URLWithString:gAPIEndpoint];
    if (!url) {
        NSLog(@"[PhoneContextHook] Invalid API endpoint: %@", gAPIEndpoint);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:15.0];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *payload = @{
        @"phone_number": phoneNumber,
        @"source": @"PhoneContextHook",
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };

    NSError *jsonError = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload
                                                   options:0
                                                     error:&jsonError];
    if (jsonError) {
        NSLog(@"[PhoneContextHook] JSON serialization error: %@", jsonError);
        return;
    }

    request.HTTPBody = body;

    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                           completionHandler:^(NSData *data,
                                                               NSURLResponse *response,
                                                               NSError *error) {
        if (error) {
            NSLog(@"[PhoneContextHook] API request failed: %@", error.localizedDescription);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSLog(@"[PhoneContextHook] API response %ld for number %@",
              (long)http.statusCode, phoneNumber);
    }];
    [task resume];
}

// ---------------------------------------------------------------------------
// Phone number extraction helpers
// ---------------------------------------------------------------------------

// Walk up the responder chain from a UIAction sender to find the host table view.
static UITableView *tableViewFromSender(id sender) {
    UIResponder *r = (UIResponder *)sender;
    while (r) {
        if ([r isKindOfClass:[UITableView class]]) return (UITableView *)r;
        r = r.nextResponder;
    }
    return nil;
}

// Try to pull a phone number string out of a UITableViewCell's visible labels.
static NSString *phoneNumberFromCell(UITableViewCell *cell) {
    // Phone.app cells: the main label is usually a contact name; the detail
    // label is usually the number or call type. We scan both labels and any
    // subview UILabels for something that looks like a phone number.
    NSArray<UIView *> *views = @[cell];
    NSMutableArray<UIView *> *queue = [views mutableCopy];
    NSString *fallback = nil;

    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        [queue addObjectsFromArray:v.subviews];

        if (![v isKindOfClass:[UILabel class]]) continue;
        NSString *text = ((UILabel *)v).text;
        if (text.length == 0) continue;

        // Keep the first non-empty string as a fallback (contact name).
        if (!fallback) fallback = text;

        // Prefer strings that look like phone numbers: start with +, (, or digit,
        // and contain at least 7 numeric characters.
        NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
        NSString *digitsOnly = [[text componentsSeparatedByCharactersInSet:
                                    [digits invertedSet]] componentsJoinedByString:@""];
        if (digitsOnly.length >= 7) {
            unichar first = [text characterAtIndex:0];
            if (first == '+' || first == '(' || [digits characterIsMember:first]) {
                return text;
            }
        }
    }
    return fallback; // may be a contact name; caller can decide what to do
}

// ---------------------------------------------------------------------------
// iOS 13+ Context Menu hooks (UITableViewDelegate)
// ---------------------------------------------------------------------------

/*
 * Phone.app recent calls delegate is TURecentCallsViewController (private).
 * We cannot hook it by name without headers. Instead we hook the UITableView
 * UIContextMenuInteractionDelegate path, which is the canonical route iOS
 * uses for all table-view context menus.
 *
 * Strategy:
 *   1. Hook -[UITableView contextMenuInteraction:configurationForMenuAtLocation:]
 *      – this is the bridge method UITableView calls internally to ask its
 *        delegate for a UIContextMenuConfiguration.
 *   2. Grab whatever configuration the original returns (may be nil on rows
 *      without a menu – Phone.app provides one on every recent-call row).
 *   3. Build a new configuration that injects our "Send to API" action into
 *      the menu returned by the original provider.
 */

%hook UITableView

// iOS 13+ – UITableView implements UIContextMenuInteractionDelegate internally
// and calls tableView:contextMenuConfigurationForRowAtIndexPath:point: on its
// delegate. We intercept at the UIContextMenuInteraction level so we catch
// every long-press regardless of the concrete delegate class.
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                         configurationForMenuAtLocation:(CGPoint)location {

    UIContextMenuConfiguration *original = %orig;
    if (!original) return nil; // row has no menu – don't add one

    // Identify which index path we're on.
    CGPoint locationInTable = [interaction.view convertPoint:location
                                                      toView:self];
    NSIndexPath *indexPath = [self indexPathForRowAtPoint:locationInTable];
    if (!indexPath) return original;

    UITableViewCell *cell = [self cellForRowAtIndexPath:indexPath];
    if (!cell) return original;

    NSString *phoneNumber = phoneNumberFromCell(cell);

    // Rebuild the configuration, keeping the original action provider but
    // wrapping it to inject our extra action.
    UIContextMenuConfiguration *augmented = [UIContextMenuConfiguration
        configurationWithIdentifier:original.identifier
                    previewProvider:original.previewProvider
                     actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {

        // Ask the original provider for its menu.
        UIMenu *originalMenu = nil;
        if (original.actionProvider) {
            originalMenu = original.actionProvider(suggestedActions);
        }

        // Build our custom action.
        NSString *title = phoneNumber.length > 0
            ? [NSString stringWithFormat:@"Send \"%@\" to API", phoneNumber]
            : @"Send Number to API";

        UIImage *icon = [UIImage systemImageNamed:@"arrow.up.circle"];

        UIAction *sendAction = [UIAction
            actionWithTitle:title
                      image:icon
                 identifier:UIActionIdentifierNone
                    handler:^(__kindof UIAction *action) {
            if (phoneNumber.length > 0) {
                sendPhoneNumberToAPI(phoneNumber);
            } else {
                NSLog(@"[PhoneContextHook] Could not extract phone number from cell");
            }
        }];

        // Append our action to the existing children.
        NSArray<UIMenuElement *> *existingChildren =
            originalMenu ? originalMenu.children : @[];
        NSArray<UIMenuElement *> *newChildren =
            [existingChildren arrayByAddingObject:sendAction];

        if (originalMenu) {
            return [originalMenu menuByReplacingChildren:newChildren];
        }

        return [UIMenu menuWithTitle:@""
                               image:nil
                          identifier:nil
                             options:UIMenuOptionsDisplayInline
                            children:newChildren];
    }];

    return augmented;
}

%end

// ---------------------------------------------------------------------------
// Fallback: UIMenuController hook for iOS 12 and older apps
// ---------------------------------------------------------------------------

/*
 * Some older calling apps still use UIMenuController (the classic copy/paste
 * bubble). We add our item there too.
 */

static UITableViewCell *gLastLongPressedCell = nil;

%hook UITableViewCell

// Capture which cell the long press occurred in.
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    if (highlighted) {
        gLastLongPressedCell = self;
    }
}

// Make our item appear in UIMenuController when it is shown on a cell.
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (action == @selector(phoneContextHook_sendToAPI:)) return YES;
    return %orig;
}

// The actual handler for the UIMenuController item.
%new
- (void)phoneContextHook_sendToAPI:(id)sender {
    NSString *phoneNumber = phoneNumberFromCell(self);
    if (phoneNumber.length > 0) {
        sendPhoneNumberToAPI(phoneNumber);
    } else {
        NSLog(@"[PhoneContextHook] UIMenuController path: no number found");
    }
}

%end

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------

%ctor {
    @autoreleasepool {
        NSLog(@"[PhoneContextHook] Loaded. API endpoint: %@", gAPIEndpoint);
        %init;
    }
}
