#import <UIKit/UIKit.h>

#include "TwoShipTVOSSetup.h"
#include <atomic>

namespace {
std::atomic<TwoShipTVOSSetupAction> setupAction{TwoShipTVOSSetupAction::Waiting};

UIViewController* ActivePresenter() {
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState == UISceneActivationStateBackground) {
            continue;
        }
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            if (!window.isKeyWindow || window.rootViewController == nil) {
                continue;
            }
            UIViewController* presenter = window.rootViewController;
            // Wait for the previous transfer alert to dismiss before showing the next one.
            if (presenter.presentedViewController != nil) {
                return nil;
            }
            return presenter;
        }
    }
    return nil;
}
}

void TwoShipTVOS_ShowSetupPrompt(const char* message, const char* actionTitle) {
    NSString* body = [NSString stringWithUTF8String:message];
    NSString* button = [NSString stringWithUTF8String:actionTitle];
    setupAction.store(TwoShipTVOSSetupAction::Waiting);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController* presenter = ActivePresenter();
        if (presenter == nil) {
            setupAction.store(TwoShipTVOSSetupAction::Unavailable);
            return;
        }
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Transfer Game Data"
                                                                       message:body
                                                                preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* primary = [UIAlertAction actionWithTitle:button style:UIAlertActionStyleDefault
            handler:^(UIAlertAction*) { setupAction.store(TwoShipTVOSSetupAction::Continue); }];
        [alert addAction:primary];
        [alert addAction:[UIAlertAction actionWithTitle:@"Exit" style:UIAlertActionStyleCancel
            handler:^(UIAlertAction*) { setupAction.store(TwoShipTVOSSetupAction::Exit); }]];
        alert.preferredAction = primary;
        [presenter presentViewController:alert animated:NO completion:nil];
    });
}

TwoShipTVOSSetupAction TwoShipTVOS_PollSetupAction() {
    return setupAction.exchange(TwoShipTVOSSetupAction::Waiting);
}
