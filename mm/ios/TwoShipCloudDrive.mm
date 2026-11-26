#import "TwoShipCloudDrive.h"
#import "TwoShipCloudFiles.h"
#include "TwoShipICloudSync.h"
#import <UIKit/UIKit.h>
#include "CloudSyncPolicy.h"
#include <cstring>

namespace {
NSString* const kChannel = @"Drive";
NSString* status = @"Not checked yet.";
NSObject* StatusLock() { static NSObject* lock = [NSObject new]; return lock; }

void SetStatus(NSString* text) {
    @synchronized(StatusLock()) { status = [text copy]; }
}

NSString* Account() {
    id token = NSFileManager.defaultManager.ubiquityIdentityToken;
    NSData* data = token ? [NSKeyedArchiver archivedDataWithRootObject:token requiringSecureCoding:NO error:nil] : nil;
    return data ? TwoShipCloudHash(data) : nil;
}

// A directory listing alone cannot tell whether an item was deleted in
// iCloud Drive or just hasn't appeared in the local file-provider cache.
NSSet<NSString*>* DriveInventory(NSURL* root) {
    NSString* prefix = [root.URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"];
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block NSSet<NSString*>* result = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMetadataQuery* query = [NSMetadataQuery new];
        query.searchScopes = @[NSMetadataQueryUbiquitousDocumentsScope];
        query.predicate = [NSPredicate predicateWithFormat:@"%K LIKE '*'", NSMetadataItemFSNameKey];
        __block id observer = nil;
        void (^finish)(void) = ^{
            if (!observer) return;
            [NSNotificationCenter.defaultCenter removeObserver:observer];
            observer = nil;
            [query stopQuery];
            dispatch_semaphore_signal(ready);
        };
        observer = [NSNotificationCenter.defaultCenter addObserverForName:NSMetadataQueryDidFinishGatheringNotification
            object:query queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*) {
                NSMutableSet* paths = [NSMutableSet set];
                for (NSMetadataItem* item in query.results) {
                    NSURL* url = [item valueForAttribute:NSMetadataItemURLKey];
                    NSString* path = url.URLByResolvingSymlinksInPath.path;
                    if ([path hasPrefix:prefix]) [paths addObject:[path substringFromIndex:prefix.length]];
                }
                result = paths;
                finish();
            }];
        if (![query startQuery]) finish();
        else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), finish);
    });
    dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
    return result;
}

NSSet<NSString*>* List(NSURL* root, BOOL cloud, unsigned selection, BOOL* complete) {
    NSMutableSet<NSString*>* paths = [NSMutableSet set];
    __block BOOL ok = YES;
    NSArray* keys = @[NSURLIsDirectoryKey, NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey];
    NSString* prefix = [root.URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"];
    NSDirectoryEnumerator<NSURL*>* items = [NSFileManager.defaultManager enumeratorAtURL:root
        includingPropertiesForKeys:keys options:0 errorHandler:^BOOL(NSURL*, NSError*) { ok = NO; return NO; }];
    for (NSURL* item in items) {
        NSDictionary* info = [item resourceValuesForKeys:keys error:nil];
        if (!info) { ok = NO; break; }
        if ([info[NSURLIsSymbolicLinkKey] boolValue]) { [items skipDescendants]; continue; }
        NSString* full = item.URLByResolvingSymlinksInPath.path;
        if (![full hasPrefix:prefix]) { ok = NO; [items skipDescendants]; continue; }
        NSString* path = [full substringFromIndex:prefix.length];
        NSString* name = path.lastPathComponent;
        if (cloud && [name hasPrefix:@"."] && [name hasSuffix:@".icloud"] && name.length > 8) {
            // An undownloaded cloud item is not a missing file.
            NSString* original = [name substringWithRange:NSMakeRange(1, name.length - 8)];
            path = [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:original];
            if (TwoShipCloud::SelectedPath(path.UTF8String, selection)) [paths addObject:path];
            continue;
        }
        if (!TwoShipCloud::IsUserPath(path.UTF8String)) {
            if ([info[NSURLIsDirectoryKey] boolValue]) [items skipDescendants];
            continue;
        }
        if ([info[NSURLIsRegularFileKey] boolValue] && TwoShipCloud::SelectedPath(path.UTF8String, selection))
            [paths addObject:path];
    }
    *complete = ok && items != nil;
    return paths;
}

bool Sync(NSURL* cloud, NSString* account, unsigned selection, NSMutableDictionary* journal,
          NSMutableSet* pendingDownloads, NSSet* held) {
    NSURL* local = TwoShipCloudLocalRoot();
    BOOL localOK = NO, cloudOK = NO;
    NSSet* localFiles = List(local, NO, selection, &localOK);
    NSSet* cloudFiles = List(cloud, YES, selection, &cloudOK);
    NSSet* inventory = DriveInventory(cloud);
    if (!localOK || !cloudOK || !inventory || ![Account() isEqual:account]) {
        SetStatus(@"Waiting for iCloud Drive's file list. Local files were not changed.");
        return false;
    }
    NSFileManager* files = NSFileManager.defaultManager;
    NSURL* ledger = [TwoShipCloudStateRoot() URLByAppendingPathComponent:[@"drive-" stringByAppendingString:account]];
    NSData* saved = [NSData dataWithContentsOfURL:ledger];
    id decoded = saved ? [NSJSONSerialization JSONObjectWithData:saved options:NSJSONReadingMutableContainers error:nil] : nil;
    NSMutableDictionary* baselines = [decoded isKindOfClass:NSMutableDictionary.class] ? decoded : [NSMutableDictionary dictionary];
    NSString* knownKey = [@"TwoShipDriveKnown-" stringByAppendingString:account];
    NSString* missingKey = [@"TwoShipDriveMissing-" stringByAppendingString:account];
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSMutableSet* known = [NSMutableSet setWithArray:[defaults stringArrayForKey:knownKey] ?: @[]];
    NSMutableDictionary* missing = [[defaults dictionaryForKey:missingKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    const NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSMutableSet* confirmedMissing = [NSMutableSet set];
    for (NSString* path in known) {
        if (TwoShipCloud::SelectedPath(path.UTF8String, selection) &&
            TwoShipCloud::IsDriveDeletion(true, [cloudFiles containsObject:path], [inventory containsObject:path], true)) {
            NSURL* url = TwoShipCloudSafeURL(cloud, path);
            if (url && ![files fileExistsAtPath:url.path]) {
                [confirmedMissing addObject:path];
                NSNumber* first = missing[path];
                if (!first || first.doubleValue > now) missing[path] = @(now);
                else if (TwoShipCloud::DriveDeletionConfirmed(first.doubleValue, now) &&
                    (!journal[path] || [journal[path] isEqual:@3])) journal[path] = @1;
            }
        } else if ([cloudFiles containsObject:path] || [inventory containsObject:path]) {
            [missing removeObjectForKey:path];
        }
    }
    NSMutableSet* paths = [localFiles mutableCopy];
    [paths unionSet:cloudFiles];
    [paths unionSet:inventory];
    __block unsigned uploaded = 0, incoming = 0, conflicts = 0, pending = 0;
    for (NSString* path in paths) {
        if (TwoShipICloudSync_Selection() != selection || ![Account() isEqual:account]) return false;
        if (!TwoShipCloud::SelectedPath(path.UTF8String, selection) || [confirmedMissing containsObject:path] ||
            [held containsObject:path]) continue;
        const bool inCloud = [cloudFiles containsObject:path] || [inventory containsObject:path];
        if (journal[path] && ([journal[path] isEqual:@1] || !inCloud)) continue;
        NSURL* source = TwoShipCloudSafeURL(local, path), *remote = TwoShipCloudSafeURL(cloud, path);
        if (!source || !remote) { ++pending; continue; }
        if (inCloud) {
            NSString* downloadStatus = nil;
            [remote getResourceValue:&downloadStatus forKey:NSURLUbiquitousItemDownloadingStatusKey error:nil];
            if ((downloadStatus && ![downloadStatus isEqual:NSURLUbiquitousItemDownloadingStatusCurrent]) ||
                ![files fileExistsAtPath:remote.path]) {
                [pendingDownloads addObject:path];
                [files startDownloadingUbiquitousItemAtURL:remote error:nil];
                ++pending;
                continue;
            }
        }
        NSError* error = nil;
        NSFileCoordinator* coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateWritingItemAtURL:remote options:0 error:&error byAccessor:^(NSURL* url) {
            if (TwoShipICloudSync_Selection() != selection) return;
            NSString* lh = [files fileExistsAtPath:source.path] ? TwoShipCloudCachedHash(source) : @"";
            NSString* rh = [files fileExistsAtPath:url.path] ? TwoShipCloudCachedHash(url) : @"";
            if (!lh || !rh || (inCloud && !rh.length)) { ++pending; return; }
            if (inCloud && [inventory containsObject:path]) {
                NSNumber* isUploaded = nil;
                [url getResourceValue:&isUploaded forKey:NSURLUbiquitousItemIsUploadedKey error:nil];
                if (isUploaded.boolValue) [known addObject:path];
            }
            if (journal[path]) {
                if ([lh isEqual:rh]) {
                    [journal removeObjectForKey:path];
                    baselines[path] = rh;
                } else if (TwoShipCloudStage(kChannel, account, path, url, lh, rh, NO)) {
                    journal[path] = @3;
                    ++incoming;
                } else ++pending;
                return;
            }
            NSString* base = [baselines[path] isKindOfClass:NSString.class] ? baselines[path] : @"";
            using TwoShipCloud::Action;
            const auto action = TwoShipCloud::Plan(lh.UTF8String, rh.UTF8String, base.UTF8String);
            switch (action) {
                case Action::None: baselines[path] = lh; break;
                case Action::Upload:
                    if (TwoShipCloudCopy(source, url, lh)) { baselines[path] = lh; ++uploaded; }
                    else ++pending;
                    break;
                case Action::Download:
                case Action::Conflict:
                    [pendingDownloads addObject:path];
                    if (TwoShipCloudStage(kChannel, account, path, url, lh, rh, NO)) {
                        ++incoming;
                        // ApplyAtLaunch keeps the old local contents before replacing them.
                        if (action == Action::Conflict) ++conflicts;
                    } else ++pending;
                    break;
            }
        }];
        if (error) ++pending;
    }
    [files createDirectoryAtURL:TwoShipCloudStateRoot() withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:baselines options:0 error:nil] writeToURL:ledger options:NSDataWritingAtomic error:nil];
    [defaults setObject:known.allObjects forKey:knownKey];
    [defaults setObject:missing forKey:missingKey];
    SetStatus([NSString stringWithFormat:@"%u uploaded, %u ready for restart, %u conflicts, %u pending.",
               uploaded, incoming, conflicts, pending]);
    return TwoShipICloudSync_Selection() == selection && [Account() isEqual:account];
}
}

void TwoShipCloudDriveApplyAtLaunch(NSSet* deleted) {
    const unsigned selection = TwoShipICloudSync_Selection();
    if (selection) TwoShipCloudApply(kChannel, Account(), selection, deleted);
}
bool TwoShipCloudDriveReconcile(unsigned selection, NSMutableDictionary* journal, NSMutableSet* pendingDownloads, NSSet* held) {
    SetStatus(@"Checking for changes");
    NSString* identifier = [[NSBundle.mainBundle objectForInfoDictionaryKey:@"NSUbiquitousContainers"] allKeys].firstObject;
    NSString* account = Account();
    NSURL* container = identifier && account ? [NSFileManager.defaultManager URLForUbiquityContainerIdentifier:identifier] : nil;
    NSURL* documents = [container URLByAppendingPathComponent:@"Documents" isDirectory:YES];
    if (documents && [NSFileManager.defaultManager createDirectoryAtURL:documents withIntermediateDirectories:YES attributes:nil error:nil])
        return Sync(documents, account, selection, journal, pendingDownloads, held);
    SetStatus(@"iCloud Drive requires iCloud sign-in and an iCloud-enabled build. Local files are available.");
    return false;
}
void TwoShipCloudDriveStatus(char* buffer, size_t size) {
    if (!buffer || !size) return;
    @synchronized(StatusLock()) { std::strncpy(buffer, status.UTF8String, size - 1); buffer[size - 1] = 0; }
}
