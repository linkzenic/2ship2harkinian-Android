#import "TwoShipICloudSync.h"
#import "TwoShipCloudFiles.h"
#import <CloudKit/CloudKit.h>
#import <UIKit/UIKit.h>
#include "CloudSyncPolicy.h"
#if !defined(__TVOS__)
#include "TwoShipCloudDrive.h"
#endif
#include <atomic>
#include <cstring>

namespace {
NSString* const kEnabled = @"TwoShipCloudKitEnabled";
NSString* const kChannel = @"CloudKit";
NSString* const kModsChannel = @"CloudKitMods";
constexpr NSUInteger MaxFileSize = 4 * 1024 * 1024;
constexpr NSUInteger MaxSnapshotSize = 12 * 1024 * 1024;
std::atomic_bool running{false};
std::atomic_bool modsRunning{false};
std::atomic_uint accountEpoch{0};
NSString* status = @"Not checked yet.";
NSString* modsStatus = @"";
NSString* conflictAccount = nil;

NSObject* StatusLock() { static NSObject* lock = [NSObject new]; return lock; }
void SetStatus(NSString* message) { @synchronized(StatusLock()) { status = [message copy]; } }
void SetConflictAccount(NSString* account) { @synchronized(StatusLock()) { conflictAccount = [account copy]; } }
NSString* ConflictAccount() { @synchronized(StatusLock()) { return conflictAccount; } }

NSString* CloudErrorStatus(NSString* action, NSError* error) {
    NSError* cause = error;
    if ([error.domain isEqualToString:CKErrorDomain] && error.code == CKErrorPartialFailure) {
        NSDictionary* failures = error.userInfo[CKPartialErrorsByItemIDKey];
        for (NSError* item in failures.allValues) {
            if (![item isKindOfClass:NSError.class]) continue;
            cause = item;
            if (item.code != CKErrorBatchRequestFailed) break;
        }
    }
    NSString* reason = cause.localizedDescription ?: @"No reason supplied by CloudKit.";
    NSString* detail = cause.localizedFailureReason;
    if (detail.length && ![reason containsString:detail]) reason = [reason stringByAppendingFormat:@" %@", detail];
    // Report Apple's error, without printing account, request, or record IDs.
    NSArray* redactions = @[
        @"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
        @"(?i)\\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\\b",
        @"(?i)\\b_?[0-9a-f]{16,}\\b",
        @"(?:file://)?/[^\\s;<>]+",
    ];
    for (NSString* pattern in redactions)
        reason = [reason stringByReplacingOccurrencesOfString:pattern withString:@"[redacted]"
                                                     options:NSRegularExpressionSearch range:NSMakeRange(0, reason.length)];
    if (reason.length > 420) reason = [reason substringToIndex:420];
    NSString* report = [NSString stringWithFormat:@"%@: %@ %ld. %@", action, cause.domain, (long)cause.code, reason];
    NSURL* root = TwoShipCloudStateRoot();
    if ([NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil]) {
        NSURL* diagnostic = [root URLByAppendingPathComponent:@"cloudkit-error.txt"];
        [report writeToURL:diagnostic atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    return report;
}

CKContainer* Container() {
    NSString* identifier = [NSBundle.mainBundle objectForInfoDictionaryKey:@"TwoShipCloudKitContainer"];
    if (!identifier.length) return nil;
    static CKContainer* container = [CKContainer containerWithIdentifier:identifier];
    return container;
}

NSString* Account(CKContainer* container) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSString* hash = nil;
    [container fetchUserRecordIDWithCompletionHandler:^(CKRecordID* idRecord, NSError*) {
        if (idRecord) hash = TwoShipCloudHash([idRecord.recordName dataUsingEncoding:NSUTF8StringEncoding]);
        dispatch_semaphore_signal(done);
    }];
    return dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0 ? hash : nil;
}

NSDictionary<NSString*, NSData*>* LocalFiles(unsigned selection, NSSet<NSString*>* deleted) {
    NSURL* root = TwoShipCloudLocalRoot();
    NSString* prefix = [root.path stringByAppendingString:@"/"];
    NSMutableDictionary* data = [NSMutableDictionary dictionary];
    NSUInteger total = 0;
    NSArray* keys = @[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLIsRegularFileKey, NSURLFileSizeKey];
    __block BOOL complete = YES;
    NSDirectoryEnumerator<NSURL*>* items = [NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:keys
        options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL*, NSError*) { complete = NO; return NO; }];
    if (!items) return nil;
    for (NSURL* url in items) {
        NSDictionary* props = [url resourceValuesForKeys:keys error:nil];
        if (!props || ![url.path hasPrefix:prefix]) return nil;
        if ([props[NSURLIsSymbolicLinkKey] boolValue]) { [items skipDescendants]; continue; }
        NSString* path = [url.path substringFromIndex:prefix.length];
        if ([props[NSURLIsDirectoryKey] boolValue]) {
            using TwoShipCloud::Category;
            if (([path isEqual:@"saves"] && !TwoShipCloud::Includes(selection, Category::Saves)) ||
                (([path isEqual:@"presets"] || [path isEqual:@"randomizer"]) &&
                 !TwoShipCloud::Includes(selection, Category::JSON))) {
                [items skipDescendants];
                continue;
            }
            if (![path isEqual:@"saves"] && ![path isEqual:@"presets"] && ![path isEqual:@"randomizer"] &&
                ![path hasPrefix:@"presets/"] && ![path hasPrefix:@"randomizer/"]) [items skipDescendants];
            continue;
        }
        if (![props[NSURLIsRegularFileKey] boolValue] || !TwoShipCloud::IsSharedPath(path.UTF8String) ||
            !TwoShipCloud::SelectedPath(path.UTF8String, selection) || [deleted containsObject:path]) continue;
        if ([props[NSURLFileSizeKey] unsignedIntegerValue] > MaxFileSize) return nil;
        NSData* bytes = [NSData dataWithContentsOfURL:url];
        if (!bytes.length || bytes.length > MaxFileSize || total + bytes.length > MaxSnapshotSize) return nil;
        data[path] = bytes;
        total += bytes.length;
    }
    return complete ? data : nil;
}

NSDictionary* Decode(CKRecord* record) {
    if (!record) return @{};
    CKAsset* asset = record[@"files"];
    if (![asset isKindOfClass:CKAsset.class] || !asset.fileURL) return nil;
    NSNumber* size = nil;
    [asset.fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (!size || size.unsignedIntegerValue > MaxSnapshotSize + MaxFileSize) return nil;
    NSData* data = [NSData dataWithContentsOfURL:asset.fileURL];
    if (!data) return nil;
    id parsed = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
    if (![parsed isKindOfClass:NSDictionary.class]) return nil;
    NSUInteger total = 0;
    for (id path in parsed) {
        if (![path isKindOfClass:NSString.class] || !TwoShipCloud::IsSharedPath([path UTF8String])) return nil;
        id bytes = parsed[path];
        if (![bytes isKindOfClass:NSData.class] || ![bytes length] || [bytes length] > MaxFileSize) return nil;
        total += [bytes length];
        if (total > MaxSnapshotSize) return nil;
    }
    return parsed;
}

void Finish() { running = false; }

void Reconcile(CKContainer* container, NSString* account, unsigned epoch, unsigned selection, NSSet<NSString*>* deleted) {
    CKDatabase* database = container.privateCloudDatabase;
    CKRecordID* idRecord = [[CKRecordID alloc] initWithRecordName:@"TwoShipPlayerFiles-v1"];
    [database fetchRecordWithID:idRecord completionHandler:^(CKRecord* record, NSError* error) {
        // CKAsset's downloaded file is only guaranteed while inside this callback.
        NSDictionary* snapshot = (!error || ([error.domain isEqualToString:CKErrorDomain] &&
            error.code == CKErrorUnknownItem)) ? Decode(record) : nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (accountEpoch != epoch || !TwoShipICloudSync_Enabled()) { Finish(); return; }
            NSDictionary* local = LocalFiles(selection, deleted);
            if (!snapshot || !local) {
                SetStatus(error && !snapshot ? CloudErrorStatus(@"Download failed", error)
                    : @"Could not read the current files, or the sync size limit was exceeded. Local files are unchanged.");
                Finish();
                return;
            }
            NSString* key = [@"TwoShipCloudBaselines-" stringByAppendingString:account];
            NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
            NSMutableDictionary* baselines = [[defaults dictionaryForKey:key] mutableCopy] ?: [NSMutableDictionary dictionary];
            NSMutableDictionary* merged = [snapshot mutableCopy];
            NSMutableSet* paths = [NSMutableSet setWithArray:local.allKeys];
            [paths addObjectsFromArray:snapshot.allKeys];
            NSURL* staging = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
            unsigned updates = 0, incoming = 0, conflicts = 0, skipped = 0;
            NSDictionary* choices = TwoShipCloudConflictChoices(account, kChannel);
            NSMutableDictionary* completed = [NSMutableDictionary dictionary];
            NSMutableSet* held = [NSMutableSet set];
            NSMutableDictionary* active = [NSMutableDictionary dictionary];
            const auto eligible = [&](NSString* path) {
                return TwoShipCloud::SelectedPath(path.UTF8String, selection) && ![deleted containsObject:path];
            };
            const auto hashes = [&](NSString* path) {
                return @{@"expected":TwoShipCloudHash(local[path]), @"hash":TwoShipCloudHash(snapshot[path])};
            };
            for (NSString* group in choices) {
                NSDictionary* choice = choices[group], *members = choice[@"members"];
                if (![choice[@"applied"] boolValue]) {
                    for (NSString* member in members) [held addObject:member];
                    continue;
                }
                BOOL valid = YES;
                for (NSString* member in members) {
                    NSDictionary* current = hashes(member), *original = members[member];
                    NSString* chosen = original[[choice[@"useCloud"] boolValue] ? @"hash" : @"expected"];
                    if (!eligible(member) || ![current[@"expected"] isEqual:chosen] ||
                        (![current[@"hash"] isEqual:original[@"hash"]] && ![current[@"hash"] isEqual:chosen])) valid = NO;
                }
                if (!valid) {
                    if (eligible(group)) TwoShipCloudClearChoice(account, kChannel, group, choice);
                    continue;
                }
                for (NSString* member in members) {
                    [held addObject:member];
                    NSDictionary* current = hashes(member);
                    if (![current[@"expected"] isEqual:current[@"hash"]]) {
                        if (local[member]) merged[member] = local[member];
                        ++updates;
                    }
                    baselines[member] = current[@"expected"];
                }
                completed[group] = choice;
            }
            NSMutableSet* groups = [NSMutableSet set];
            for (NSString* path in paths) {
                if (!eligible(path) || [held containsObject:path]) continue;
                const auto lh = TwoShipCloudHash(local[path]), rh = TwoShipCloudHash(snapshot[path]);
                NSString* base = [baselines[path] isKindOfClass:NSString.class] ? baselines[path] : @"";
                if (TwoShipCloud::Plan(lh.UTF8String, rh.UTF8String, base.UTF8String) == TwoShipCloud::Action::Conflict)
                    [groups addObject:TwoShipCloudConflictGroup(path)];
            }
            for (NSString* group in groups) {
                NSMutableDictionary* members = [NSMutableDictionary dictionary];
                BOOL complete = YES;
                for (NSString* path in TwoShipCloudConflictMembers(group)) {
                    [held addObject:path];
                    if (!eligible(path)) { complete = NO; continue; }
                    NSDictionary* current = hashes(path);
                    if (snapshot[path] &&
                        (![snapshot[path] writeToURL:staging options:NSDataWritingAtomic error:nil] ||
                         !TwoShipCloudStage(kChannel, account, path, staging, current[@"expected"], current[@"hash"], YES))) {
                        complete = NO;
                    }
                    members[path] = current;
                }
                if (complete) { active[group] = members; ++conflicts; }
                else ++skipped;
            }
            for (NSString* path in paths) {
                if (accountEpoch != epoch) { [NSFileManager.defaultManager removeItemAtURL:staging error:nil]; Finish(); return; }
                if (!eligible(path) || [held containsObject:path]) continue;
                NSData* localData = local[path], *cloudData = snapshot[path];
                NSString* lh = TwoShipCloudHash(localData), *rh = TwoShipCloudHash(cloudData);
                NSString* base = [baselines[path] isKindOfClass:NSString.class] ? baselines[path] : @"";
                using TwoShipCloud::Action;
                const auto action = TwoShipCloud::Plan(lh.UTF8String, rh.UTF8String, base.UTF8String);
                if (action == Action::None) {
                    baselines[path] = lh;
                } else if (action == Action::Upload) {
                    merged[path] = localData;
                    baselines[path] = lh;
                    ++updates;
                } else if ([cloudData writeToURL:staging options:NSDataWritingAtomic error:nil] &&
                           TwoShipCloudStage(kChannel, account, path, staging, lh, rh, action == Action::Conflict)) {
                    if (action == Action::Conflict) ++conflicts; else ++incoming;
                } else {
                    ++skipped;
                }
            }
            NSString* report = [NSString stringWithFormat:@"%u uploaded, %u ready for restart, %u conflicts, %u skipped.",
                                updates, incoming, conflicts, skipped];
            TwoShipCloudPublishConflicts(account, kChannel, active);
            const auto clearCompleted = ^{
                for (NSString* group in completed) TwoShipCloudClearChoice(account, kChannel, group, completed[group]);
            };
            if (!updates) {
                [defaults setObject:baselines forKey:key];
                clearCompleted();
                SetStatus(report);
                [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
                Finish();
                return;
            }
            NSData* payload = [NSPropertyListSerialization dataWithPropertyList:merged format:NSPropertyListBinaryFormat_v1_0
                options:0 error:nil];
            NSUInteger total = 0;
            for (NSData* bytes in merged.allValues) total += bytes.length;
            if (total > MaxSnapshotSize || !payload || ![payload writeToURL:staging options:NSDataWritingAtomic error:nil] ||
                accountEpoch != epoch || !TwoShipICloudSync_Enabled()) {
                [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
                SetStatus(@"iCloud sync paused before upload. Local files are unchanged.");
                Finish();
                return;
            }
            CKRecord* updated = record ?: [[CKRecord alloc] initWithRecordType:@"TwoShipPlayerFiles" recordID:idRecord];
            updated[@"files"] = [[CKAsset alloc] initWithFileURL:staging];
            CKModifyRecordsOperation* operation = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:@[updated]
                                                                                      recordIDsToDelete:nil];
            operation.savePolicy = CKRecordSaveIfServerRecordUnchanged;
            operation.modifyRecordsCompletionBlock = ^(NSArray<CKRecord*>*, NSArray<CKRecordID*>*, NSError* uploadError) {
                [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
                if (accountEpoch == epoch && TwoShipICloudSync_Enabled()) {
                    if (!uploadError) { [defaults setObject:baselines forKey:key]; clearCompleted(); SetStatus(report); }
                    else SetStatus(CloudErrorStatus(@"Upload failed", uploadError));
                }
                Finish();
            };
            [database addOperation:operation];
        });
    }];
}

// Keep large packs out of the in-memory saves snapshot. A small manifest
// points to file-backed assets, each addressed by its path and content hash.
NSDictionary<NSString*, NSString*>* ReadModManifest(CKRecord* record) {
    NSURL* url = [(CKAsset*)record[@"files"] fileURL];
    NSNumber* size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (!size || size.unsignedIntegerValue > MaxFileSize) return nil;
    NSData* data = [NSData dataWithContentsOfURL:url];
    if (!data) return nil;
    id manifest = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
    if (![manifest isKindOfClass:NSDictionary.class]) return nil;
    for (id path in manifest) {
        id hash = manifest[path];
        if (![path isKindOfClass:NSString.class] || TwoShipCloud::FileCategory([path UTF8String]) != TwoShipCloud::Category::Mods ||
            ![hash isKindOfClass:NSString.class] || [hash length] != 64 ||
            [hash rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound)
            return nil;
    }
    return manifest;
}

NSSet<NSString*>* ListMods() {
    NSURL* root = TwoShipCloudLocalRoot();
    NSURL* mods = TwoShipCloudSafeURL(root, @"mods");
    if (!mods) return nil;
    if (![NSFileManager.defaultManager fileExistsAtPath:mods.path]) return [NSSet set];
    NSString* prefix = [root.path stringByAppendingString:@"/"];
    NSArray* keys = @[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLIsRegularFileKey];
    NSMutableSet* paths = [NSMutableSet set];
    __block bool complete = true;
    NSDirectoryEnumerator<NSURL*>* items = [NSFileManager.defaultManager enumeratorAtURL:mods includingPropertiesForKeys:keys
        options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL*, NSError*) { complete = false; return NO; }];
    for (NSURL* url in items) {
        NSDictionary* props = [url resourceValuesForKeys:keys error:nil];
        if (!props || ![url.path hasPrefix:prefix]) return nil;
        NSString* path = [url.path substringFromIndex:prefix.length];
        if ([props[NSURLIsSymbolicLinkKey] boolValue] || TwoShipCloud::FileCategory(path.UTF8String) != TwoShipCloud::Category::Mods) {
            [items skipDescendants];
        } else if ([props[NSURLIsRegularFileKey] boolValue]) {
            [paths addObject:path];
        }
    }
    return complete && items ? paths : nil;
}

bool ModsActive(unsigned epoch) {
    return epoch == accountEpoch && TwoShipCloud::Includes(TwoShipICloudSync_Selection(), TwoShipCloud::Category::Mods);
}

NSError* SaveModRecord(CKDatabase* database, CKRecord* record, CKRecordSavePolicy policy) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError* result = nil;
    CKModifyRecordsOperation* operation = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:@[record] recordIDsToDelete:nil];
    operation.savePolicy = policy;
    operation.qualityOfService = NSQualityOfServiceUtility;
    operation.modifyRecordsCompletionBlock = ^(NSArray<CKRecord*>*, NSArray<CKRecordID*>*, NSError* error) {
        result = error;
        dispatch_semaphore_signal(done);
    };
    [database addOperation:operation];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return result;
}

void SetModsStatus(NSString* message, unsigned epoch) {
    @synchronized(StatusLock()) { if (ModsActive(epoch)) modsStatus = [message copy]; }
}

void ReconcileMods(CKDatabase* database, NSString* account, unsigned epoch, NSSet<NSString*>* deleted) {
    if (!ModsActive(epoch)) return;
    SetModsStatus(@"Checking mods", epoch);
    CKRecordID* manifestID = [[CKRecordID alloc] initWithRecordName:@"TwoShipMods-v1"];
    dispatch_semaphore_t manifestReady = dispatch_semaphore_create(0);
    __block CKRecord* original = nil;
    __block NSDictionary<NSString*, NSString*>* manifest = nil;
    __block NSError* manifestError = nil;
    [database fetchRecordWithID:manifestID completionHandler:^(CKRecord* record, NSError* error) {
        original = record;
        if (!error && record) manifest = ReadModManifest(record);
        else if ([error.domain isEqualToString:CKErrorDomain] && error.code == CKErrorUnknownItem) manifest = @{};
        else manifestError = error;
        dispatch_semaphore_signal(manifestReady);
    }];
    dispatch_semaphore_wait(manifestReady, DISPATCH_TIME_FOREVER);
    NSSet* local = ListMods();
    if (!manifest || !local) {
        SetModsStatus(manifestError ? CloudErrorStatus(@"Could not read the mod list", manifestError)
            : @"Could not read the mod list. Local mods are unchanged.", epoch);
        return;
    }

    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSString* ledger = [@"TwoShipModBaselines-" stringByAppendingString:account];
    NSMutableDictionary* baselines = [[defaults dictionaryForKey:ledger] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary* merged = [manifest mutableCopy];
    NSMutableSet* paths = [local mutableCopy];
    [paths addObjectsFromArray:manifest.allKeys];
    NSURL* root = TwoShipCloudLocalRoot();
    unsigned uploaded = 0, incoming = 0, conflicts = 0, pending = 0;
    NSError* transferError = nil;
    NSDictionary* choices = TwoShipCloudConflictChoices(account, kModsChannel);
    NSMutableDictionary* completed = [NSMutableDictionary dictionary];
    NSMutableDictionary* active = [NSMutableDictionary dictionary];
    for (NSString* path in paths) {
        @autoreleasepool {
            if (!ModsActive(epoch)) return;
            if ([deleted containsObject:path]) continue;
            NSURL* file = TwoShipCloudSafeURL(root, path);
            NSString* lh = [local containsObject:path] ? TwoShipCloudCachedHash(file) : @"";
            NSString* rh = manifest[path] ?: @"";
            if (!file || !lh) { ++pending; continue; }
            NSString* base = [baselines[path] isKindOfClass:NSString.class] ? baselines[path] : @"";
            using TwoShipCloud::Action;
            auto action = TwoShipCloud::Plan(lh.UTF8String, rh.UTF8String, base.UTF8String);
            NSDictionary* choice = choices[path];
            if (choice && ![choice[@"applied"] boolValue]) continue;
            if (choice) {
                NSDictionary* original = choice[@"members"][path];
                NSString* chosen = original[[choice[@"useCloud"] boolValue] ? @"hash" : @"expected"];
                if ([lh isEqual:chosen] && ([rh isEqual:original[@"hash"]] || [rh isEqual:chosen])) {
                    action = [lh isEqual:rh] ? Action::None : Action::Upload;
                } else {
                    TwoShipCloudClearChoice(account, kModsChannel, path, choice);
                    choice = nil;
                }
            }
            if (action == Action::None) {
                baselines[path] = lh;
                if (choice) completed[path] = choice;
                continue;
            }
            const bool upload = action == Action::Upload;
            const bool conflict = action == Action::Conflict;
            NSString* hash = upload ? lh : rh;
            NSString* key = TwoShipCloudHash([[hash stringByAppendingString:path] dataUsingEncoding:NSUTF8StringEncoding]);
            CKRecordID* idRecord = [[CKRecordID alloc] initWithRecordName:[@"TwoShipMod-" stringByAppendingString:key]];
            if (upload) {
                NSURL* staged = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
                if (!TwoShipCloudCopy(file, staged, lh)) { ++pending; continue; }
                if (!ModsActive(epoch)) {
                    [NSFileManager.defaultManager removeItemAtURL:staged error:nil];
                    return;
                }
                CKRecord* record = [[CKRecord alloc] initWithRecordType:@"TwoShipPlayerFiles" recordID:idRecord];
                record[@"files"] = [[CKAsset alloc] initWithFileURL:staged];
                NSError* error = SaveModRecord(database, record, CKRecordSaveChangedKeys);
                [NSFileManager.defaultManager removeItemAtURL:staged error:nil];
                if (error) {
                    transferError = error;
                    ++pending;
                    continue;
                }
                merged[path] = lh;
                baselines[path] = lh;
                if (choice) completed[path] = choice;
                ++uploaded;
            } else {
                __block BOOL staged = TwoShipCloudIsStaged(kModsChannel, account, path, lh, rh, conflict);
                if (!staged) {
                    dispatch_semaphore_t done = dispatch_semaphore_create(0);
                    __block NSError* fetchError = nil;
                    [database fetchRecordWithID:idRecord completionHandler:^(CKRecord* record, NSError* error) {
                        fetchError = error;
                        CKAsset* asset = record[@"files"];
                        if (!error && ModsActive(epoch) && asset.fileURL)
                            staged = TwoShipCloudStage(kModsChannel, account, path, asset.fileURL, lh, rh, conflict);
                        dispatch_semaphore_signal(done);
                    }];
                    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
                    if (fetchError) transferError = fetchError;
                }
                if (!staged) ++pending;
                else if (conflict) { active[path] = @{path:@{@"expected":lh, @"hash":rh}}; ++conflicts; }
                else ++incoming;
            }
        }
    }
    if (!ModsActive(epoch)) return;
    TwoShipCloudPublishConflicts(account, kModsChannel, active);
    if (uploaded) {
        NSData* list = [NSPropertyListSerialization dataWithPropertyList:merged format:NSPropertyListBinaryFormat_v1_0
            options:0 error:nil];
        NSURL* staging = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        if (!list || list.length > MaxFileSize || ![list writeToURL:staging options:NSDataWritingAtomic error:nil]) {
            SetModsStatus(@"Could not prepare the iCloud mod list. Local mods are unchanged.", epoch);
            return;
        }
        CKRecord* updated = original ?: [[CKRecord alloc] initWithRecordType:@"TwoShipPlayerFiles" recordID:manifestID];
        updated[@"files"] = [[CKAsset alloc] initWithFileURL:staging];
        NSError* updateError = ModsActive(epoch) ? SaveModRecord(database, updated, CKRecordSaveIfServerRecordUnchanged) : nil;
        if (ModsActive(epoch) && !updateError) {
            if (ModsActive(epoch)) [defaults setObject:baselines forKey:ledger];
        } else {
            if (updateError) SetModsStatus(CloudErrorStatus(@"Could not save the mod list", updateError), epoch);
            [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
            return;
        }
        [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
    } else {
        [defaults setObject:baselines forKey:ledger];
    }
    if (ModsActive(epoch))
        for (NSString* group in completed) TwoShipCloudClearChoice(account, kModsChannel, group, completed[group]);
    NSString* report = [NSString stringWithFormat:@"Mods: %u uploaded, %u ready for restart, %u conflicts, %u pending.",
        uploaded, incoming, conflicts, pending];
    if (transferError) report = [report stringByAppendingFormat:@"\n%@", CloudErrorStatus(@"Mod transfer failed", transferError)];
    SetModsStatus(report, epoch);
}

NSString* JournalKey(NSString* account) {
    return [@"TwoShipDriveJournal-" stringByAppendingString:account];
}

// Journal values: 1 = deleted in Drive, 2 = stale CloudKit copy pruned,
// 3 = re-added in Drive and staged to apply at the next iPhone launch.
NSDictionary* FetchFileRecord(CKDatabase* database, NSString* name, NSDictionary* (^decode)(CKRecord*), CKRecord** original,
                              NSError** failure = nullptr) {
    CKRecordID* idRecord = [[CKRecordID alloc] initWithRecordName:name];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary* result = nil;
    __block CKRecord* saved = nil;
    __block NSError* problem = nil;
    [database fetchRecordWithID:idRecord completionHandler:^(CKRecord* record, NSError* error) {
        if (!error && record) {
            saved = record;
            result = decode(record);
        } else if ([error.domain isEqualToString:CKErrorDomain] && error.code == CKErrorUnknownItem) {
            result = @{};
        } else {
            problem = error;
        }
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (original) *original = saved;
    if (failure) *failure = problem;
    return result;
}

NSDictionary* ReadJournal(CKRecord* record) {
    CKAsset* asset = record[@"files"];
    NSNumber* size = nil;
    [asset.fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (!size || size.unsignedIntegerValue > MaxFileSize) return nil;
    NSData* bytes = [NSData dataWithContentsOfURL:asset.fileURL];
    if (!bytes) return nil;
    id data = [NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:nil error:nil];
    if (![data isKindOfClass:NSDictionary.class]) return nil;
    for (id path in data) {
        id state = data[path];
        if (![path isKindOfClass:NSString.class] || TwoShipCloud::FileCategory([path UTF8String]) == TwoShipCloud::Category::None ||
            ![state isKindOfClass:NSNumber.class] || (![state isEqual:@1] && ![state isEqual:@2] && ![state isEqual:@3])) return nil;
    }
    return data;
}

#if !defined(__TVOS__)
void DeleteModAsset(CKDatabase* database, CKRecordID* asset) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [database deleteRecordWithID:asset completionHandler:^(CKRecordID*, NSError*) {
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

bool WriteFileRecord(CKDatabase* database, CKRecord* original, NSString* name, NSDictionary* data, unsigned epoch) {
    NSData* payload = [NSPropertyListSerialization dataWithPropertyList:data format:NSPropertyListBinaryFormat_v1_0
        options:0 error:nil];
    NSURL* file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    if (!payload || ![payload writeToURL:file options:NSDataWritingAtomic error:nil]) return false;
    CKRecordID* idRecord = [[CKRecordID alloc] initWithRecordName:name];
    CKRecord* record = original ?: [[CKRecord alloc] initWithRecordType:@"TwoShipPlayerFiles" recordID:idRecord];
    record[@"files"] = [[CKAsset alloc] initWithFileURL:file];
    const bool saved = accountEpoch == epoch && TwoShipICloudSync_Enabled() &&
        !SaveModRecord(database, record, CKRecordSaveIfServerRecordUnchanged);
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    return saved;
}

// Never unblock a re-added Drive file until the old CloudKit copy is gone.
bool PruneDeleted(CKDatabase* database, NSMutableDictionary* journal, unsigned epoch) {
    for (bool mods : {false, true}) {
        NSMutableArray* paths = [NSMutableArray array];
        for (NSString* path in journal) {
            if ([journal[path] isEqual:@1] && (mods == (TwoShipCloud::FileCategory(path.UTF8String) == TwoShipCloud::Category::Mods)))
                [paths addObject:path];
        }
        if (!paths.count) continue;
        NSString* name = mods ? @"TwoShipMods-v1" : @"TwoShipPlayerFiles-v1";
        CKRecord* original = nil;
        NSDictionary* data = FetchFileRecord(database, name, ^NSDictionary*(CKRecord* record) {
            return mods ? ReadModManifest(record) : Decode(record);
        }, &original);
        if (!data) return false;
        NSMutableDictionary* remaining = [data mutableCopy];
        [remaining removeObjectsForKeys:paths];
        if (remaining.count != data.count && !WriteFileRecord(database, original, name, remaining, epoch)) return false;
        for (NSString* path in paths) journal[path] = @2;
        if (mods) {
            for (NSString* path in paths) {
                NSString* hash = data[path];
                if (!hash.length) continue;
                NSString* key = TwoShipCloudHash([[hash stringByAppendingString:path] dataUsingEncoding:NSUTF8StringEncoding]);
                CKRecordID* asset = [[CKRecordID alloc] initWithRecordName:[@"TwoShipMod-" stringByAppendingString:key]];
                if (accountEpoch == epoch) DeleteModAsset(database, asset);
            }
        }
    }
    return true;
}
#endif
}

bool TwoShipICloudSync_Enabled() {
    NSNumber* preference = [NSUserDefaults.standardUserDefaults objectForKey:kEnabled];
    return preference ? preference.boolValue : [NSBundle.mainBundle objectForInfoDictionaryKey:@"TwoShipCloudKitContainer"] != nil;
}
static NSString* CategoryKey(TwoShipCloud::Category category) {
    using TwoShipCloud::Category;
    switch (category) {
        case Category::JSON: return @"TwoShipCloudSyncJSON";
        case Category::Saves: return @"TwoShipCloudSyncSaves";
        case Category::Mods: return @"TwoShipCloudSyncMods";
        default: return nil;
    }
}
bool TwoShipICloudSync_CategoryEnabled(TwoShipCloud::Category category) {
    NSString* key = CategoryKey(category);
    if (!key) return false;
    NSNumber* preference = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return preference ? preference.boolValue : category != TwoShipCloud::Category::Mods;
}
unsigned TwoShipICloudSync_Selection() {
    if (!TwoShipICloudSync_Enabled()) return 0;
    using TwoShipCloud::Category;
    unsigned selection = 0;
    for (auto category : {Category::JSON, Category::Saves, Category::Mods})
        if (TwoShipICloudSync_CategoryEnabled(category)) selection |= static_cast<unsigned>(category);
    return selection;
}
void TwoShipICloudSync_SetCategoryEnabled(TwoShipCloud::Category category, bool enabled) {
    NSString* key = CategoryKey(category);
    if (!key) return;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:key];
    ++accountEpoch;
    TwoShipICloudSync_SyncNow();
}
void TwoShipICloudSync_SetEnabled(bool enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kEnabled];
    ++accountEpoch;
    if (enabled) TwoShipICloudSync_SyncNow();
}
void TwoShipICloudSync_ApplyAtLaunch() {
    const unsigned selection = TwoShipICloudSync_Selection();
    CKContainer* container = selection ? Container() : nil;
    if (!container) return;
    NSString* account = Account(container);
    if (!account) return;
    SetConflictAccount(account);
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSString* key = JournalKey(account);
    NSDictionary* journal = [defaults dictionaryForKey:key] ?: @{};
    NSSet* deleted = [NSSet setWithArray:journal.allKeys];
    NSSet* chosen = TwoShipCloudApplyChoices(account, selection, deleted);
    NSString* appliedKey = [key stringByAppendingString:@"-applied"];
    NSMutableSet* applied = [NSMutableSet setWithArray:[defaults stringArrayForKey:appliedKey] ?: @[]];
    [applied intersectSet:deleted];
    NSMutableSet* pending = [deleted mutableCopy];
    [pending minusSet:applied];
#if !defined(__TVOS__)
    NSMutableSet* driveDeleted = [deleted mutableCopy];
    for (NSString* path in deleted) {
        if ([journal[path] isEqual:@3]) {
            [pending removeObject:path];
            [driveDeleted removeObject:path];
        }
    }
    [driveDeleted unionSet:chosen];
    TwoShipCloudDriveApplyAtLaunch(driveDeleted);
#endif
    [applied unionSet:TwoShipCloudApplyDeletions(pending, selection)];
    [defaults setObject:applied.allObjects forKey:appliedKey];
    NSSet* guarded = [deleted setByAddingObjectsFromSet:chosen];
    TwoShipCloudApply(kChannel, account, selection, guarded);
    TwoShipCloudApply(kModsChannel, account, selection, guarded);
}
void TwoShipICloudSync_SyncNow() {
    const unsigned selection = TwoShipICloudSync_Selection();
    if (!selection) return;
    if (running.exchange(true)) return;
    SetStatus(@"Checking for changes");
    const unsigned epoch = accountEpoch;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CKContainer* container = Container();
        NSString* account = container ? Account(container) : nil;
        if (account && accountEpoch == epoch && TwoShipICloudSync_Selection() == selection) {
            CKDatabase* database = container.privateCloudDatabase;
            NSString* recordName = @"TwoShipDriveDeletions-v1";
            CKRecord* original = nil;
            NSError* journalError = nil;
            NSDictionary* last = FetchFileRecord(database, recordName, ^NSDictionary*(CKRecord* record) {
                return ReadJournal(record);
            }, &original, &journalError);
            if (!last || accountEpoch != epoch) {
                if (accountEpoch == epoch) SetStatus(journalError ? CloudErrorStatus(@"Could not check deletions", journalError)
                    : @"Could not read the deletion list. Sync will retry.");
                Finish();
                return;
            }
            SetConflictAccount(account);
            NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
            NSString* key = JournalKey(account);
            unsigned syncEpoch = epoch;
            if (![[defaults dictionaryForKey:key] ?: @{} isEqual:last]) syncEpoch = ++accountEpoch;
            [defaults setObject:last forKey:key];
            NSMutableDictionary* journal = [last mutableCopy];
            NSMutableSet* blocked = [NSMutableSet set];
#if !defined(__TVOS__)
            NSMutableSet* held = [NSMutableSet set];
            for (NSString* channel in @[kChannel, kModsChannel])
                for (NSDictionary* choice in TwoShipCloudConflictChoices(account, channel).allValues)
                    [held addObjectsFromArray:[choice[@"members"] allKeys]];
            if (!TwoShipCloudDriveReconcile(selection, journal, blocked, held) || accountEpoch != syncEpoch) {
                Finish();
                return;
            }
            if (![journal isEqual:last]) {
                syncEpoch = ++accountEpoch;
                if (!WriteFileRecord(database, original, recordName, journal, syncEpoch)) {
                    SetStatus(@"Could not relay iCloud Drive changes. Sync will retry.");
                    Finish();
                    return;
                }
            }
            NSMutableDictionary* pruned = [journal mutableCopy];
            if (!PruneDeleted(database, pruned, syncEpoch)) {
                [defaults setObject:journal forKey:key];
                SetStatus(@"iCloud deletions are pending. Sync will retry.");
                Finish();
                return;
            }
            if (![pruned isEqual:journal]) {
                CKRecord* current = nil;
                NSDictionary* saved = FetchFileRecord(database, recordName, ^NSDictionary*(CKRecord* record) {
                    return ReadJournal(record);
                }, &current);
                if ([saved isEqual:journal] && WriteFileRecord(database, current, recordName, pruned, syncEpoch))
                    journal = pruned;
            }
#endif
            if (accountEpoch != syncEpoch) { Finish(); return; }
            NSString* appliedKey = [key stringByAppendingString:@"-applied"];
            NSMutableSet* applied = [NSMutableSet setWithArray:[defaults stringArrayForKey:appliedKey] ?: @[]];
            NSSet* deleted = [NSSet setWithArray:journal.allKeys];
            [applied intersectSet:deleted];
            [defaults setObject:applied.allObjects forKey:appliedKey];
            [defaults setObject:journal forKey:key];
            [blocked unionSet:deleted];
            if (ModsActive(syncEpoch) && !modsRunning.exchange(true)) {
                const unsigned modEpoch = syncEpoch;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    ReconcileMods(database, account, modEpoch, blocked);
                    modsRunning = false;
                });
            }
            using TwoShipCloud::Category;
            if (TwoShipCloud::Includes(selection, Category::JSON) || TwoShipCloud::Includes(selection, Category::Saves))
                Reconcile(container, account, syncEpoch, selection, blocked);
            else { SetStatus(@""); Finish(); }
        } else {
            if (accountEpoch == epoch) SetStatus(@"iCloud sync requires a cloud-enabled build and an active iCloud account.");
            Finish();
        }
    });
}
void TwoShipICloudSync_Start() {
    dispatch_async(dispatch_get_main_queue(), ^{
        static id activeObserver, accountObserver;
        static NSTimer* timer;
        if (!activeObserver) activeObserver = [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
            object:nil queue:nil usingBlock:^(NSNotification*) { TwoShipICloudSync_SyncNow(); }];
        if (!accountObserver) accountObserver = [NSNotificationCenter.defaultCenter addObserverForName:CKAccountChangedNotification
            object:nil queue:nil usingBlock:^(NSNotification*) { SetConflictAccount(nil); ++accountEpoch; TwoShipICloudSync_SyncNow(); }];
        if (!timer) timer = [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer*) {
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) TwoShipICloudSync_SyncNow();
        }];
        TwoShipICloudSync_SyncNow();
    });
}
void TwoShipICloudSync_GetStatus(char* buffer, size_t length) {
    if (!buffer || !length) return;
    @synchronized(StatusLock()) {
        NSString* message = status;
        if (!TwoShipICloudSync_Enabled()) message = @"Sync is off.";
        else if (!TwoShipICloudSync_Selection()) message = @"Select which files to sync.";
        else if (TwoShipICloudSync_CategoryEnabled(TwoShipCloud::Category::Mods) && modsStatus.length)
            message = status.length ? [NSString stringWithFormat:@"%@\n%@", status, modsStatus] : modsStatus;
        std::strncpy(buffer, message.UTF8String, length - 1);
        buffer[length - 1] = 0;
    }
}

std::vector<TwoShipCloudConflict> TwoShipICloudSync_GetConflicts() {
    std::vector<TwoShipCloudConflict> rows;
    NSString* account = ConflictAccount();
    const unsigned selection = TwoShipICloudSync_Selection();
    if (!account || !selection) return rows;
    for (NSString* channel in @[kChannel, kModsChannel]) {
        NSDictionary* active = TwoShipCloudActiveConflicts(account, channel);
        NSDictionary* choices = TwoShipCloudConflictChoices(account, channel);
        NSMutableSet* groups = [NSMutableSet setWithArray:active.allKeys];
        [groups addObjectsFromArray:choices.allKeys];
        for (NSString* group in [groups.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
            if (!TwoShipCloud::SelectedPath(group.UTF8String, selection)) continue;
            NSDictionary* members = active[group] ?: choices[group][@"members"];
            rows.push_back({group.UTF8String, TwoShipCloudConflictRevision(members).UTF8String,
                            TwoShipCloudCanChoose(members, NO), TwoShipCloudCanChoose(members, YES),
                            choices[group] != nil});
        }
    }
    return rows;
}

bool TwoShipICloudSync_ChooseConflict(const std::string& path, const std::string& revision, bool useCloud) {
    NSString* account = ConflictAccount();
    if (!account || !TwoShipCloud::SelectedPath(path, TwoShipICloudSync_Selection())) return false;
    NSString* group = @(path.c_str());
    NSString* channel = TwoShipCloud::FileCategory(path) == TwoShipCloud::Category::Mods ? kModsChannel : kChannel;
    return TwoShipCloudQueueConflict(account, channel, group, @(revision.c_str()), useCloud);
}
