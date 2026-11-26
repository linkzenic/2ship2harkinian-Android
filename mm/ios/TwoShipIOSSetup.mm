#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "TwoShipIOSSetup.h"
#include <atomic>
#include <memory>
#include <string_view>
#include <utility>
#include <zip.h>

namespace {
using Action = TwoShipIOSSetupAction;
std::atomic<Action> setupAction{Action::Waiting};
std::string selectedPath;

UIViewController* SetupPresenter() {
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState == UISceneActivationStateBackground) {
            continue;
        }
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            UIViewController* presenter = window.rootViewController;
            if (window.isKeyWindow && presenter && !presenter.presentedViewController) {
                return presenter;
            }
        }
    }
    return nil;
}

bool IsGameArchive(const std::string& path) {
    std::unique_ptr<zip_t, decltype(&zip_discard)> archive(
        zip_open(path.c_str(), ZIP_RDONLY | ZIP_CHECKCONS, nullptr), zip_discard);
    if (!archive) {
        return false;
    }
    zip_stat_t entry{};
    if (zip_stat(archive.get(), "version", 0, &entry) != 0 || entry.size != 5 ||
        zip_stat(archive.get(), "portVersion", 0, &entry) != 0 || entry.size != 7) {
        return false;
    }
    for (zip_int64_t i = 0, count = zip_get_num_entries(archive.get(), 0); i < count; ++i) {
        const char* name = zip_get_name(archive.get(), i, 0);
        if (name && std::string_view(name).starts_with("scenes/nonmq/") && !std::string_view(name).ends_with('/')) {
            return true;
        }
    }
    return false;
}
}

@interface TwoShipArchivePickerDelegate : NSObject <UIDocumentPickerDelegate>
@end

@implementation TwoShipArchivePickerDelegate
- (void)documentPicker:(UIDocumentPickerViewController*)picker didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    NSURL* url = urls.firstObject;
    const char* path = url.isFileURL ? url.fileSystemRepresentation : nullptr;
    if (path) {
        selectedPath = path;
        setupAction.store(Action::ArchivePicked);
    } else {
        setupAction.store(Action::Cancelled);
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)picker {
    setupAction.store(Action::Cancelled);
}
@end

void TwoShipIOS_ShowArchiveSetup(const char* error) {
    NSString* message = error ? [NSString stringWithUTF8String:error]
                              : @"Generate mm.o2r with 2 Ship on a computer, then import it from Files.";
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController* presenter = SetupPresenter();
        if (!presenter) {
            setupAction.store(Action::Unavailable);
            return;
        }
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Game Setup"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Exit" style:UIAlertActionStyleCancel
            handler:^(UIAlertAction*) { setupAction.store(Action::Exit); }]];
        UIAlertAction* importAction = [UIAlertAction actionWithTitle:@"Import mm.o2r" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction*) { setupAction.store(Action::OpenPicker); }];
        [alert addAction:importAction];
        alert.preferredAction = importAction;
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

void TwoShipIOS_OpenArchivePicker() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController* presenter = SetupPresenter();
        if (!presenter) {
            setupAction.store(Action::Unavailable);
            return;
        }
        // Keep the original file in Files. UIKit supplies a temporary copy.
        UIDocumentPickerViewController* picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
        static TwoShipArchivePickerDelegate* delegate = [TwoShipArchivePickerDelegate new];
        picker.delegate = delegate;
        picker.modalPresentationStyle = UIModalPresentationFullScreen;
        [presenter presentViewController:picker animated:YES completion:nil];
    });
}

TwoShipIOSSetupAction TwoShipIOS_PollArchiveSetup(std::string& archivePath) {
    const auto action = setupAction.exchange(Action::Waiting);
    if (action == Action::ArchivePicked) {
        archivePath = std::move(selectedPath);
    }
    return action;
}

const char* TwoShipIOS_ImportGameArchive(const std::string& source, const std::string& destination) {
    if (!IsGameArchive(source)) {
        return "That file is not a 2 Ship game archive. Choose the mm.o2r generated on your computer, not 2ship.o2r.";
    }
    NSURL* from = [NSURL fileURLWithFileSystemRepresentation:source.c_str() isDirectory:NO relativeToURL:nil];
    NSURL* to = [NSURL fileURLWithFileSystemRepresentation:destination.c_str() isDirectory:NO relativeToURL:nil];
    if (![NSFileManager.defaultManager moveItemAtURL:from toURL:to error:nullptr]) {
        return "Could not save mm.o2r on this device. Check available storage and try again.";
    }
    return nullptr;
}
