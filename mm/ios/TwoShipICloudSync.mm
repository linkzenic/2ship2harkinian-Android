#import "TwoShipICloudSync.h"

#import <CloudKit/CloudKit.h>
#import <Foundation/Foundation.h>

#ifndef TWO_SHIP_ICLOUD_CONTAINER_ID
#define TWO_SHIP_ICLOUD_CONTAINER_ID "iCloud.com.shipofharkinian.shared"
#endif

namespace {

NSString* const kRecordType = @"TwoShipSaveFile";
NSString* const kRelativePathField = @"relativePath";
NSString* const kModifiedAtField = @"sourceModifiedAt";
NSString* const kContentsField = @"contents";

dispatch_queue_t SyncQueue() {
    static dispatch_queue_t queue =
        dispatch_queue_create("com.linkzenic.twoship.cloud-save-sync", DISPATCH_QUEUE_SERIAL);
    return queue;
}

bool IsProvisionedForCloudKit() {
    NSNumber* provisioned =
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"TwoShipCloudKitProvisionedBuild"];
    return provisioned == nil || provisioned.boolValue;
}

NSArray<NSString*>* SaveRelativePaths() {
    return @[
        @"saves/global.json",
        @"saves/file1.json", @"saves/file1backup.json",
        @"saves/file2.json", @"saves/file2backup.json",
        @"saves/file3.json", @"saves/file3backup.json",
        @"saves/picto1.png", @"saves/picto2.png", @"saves/picto3.png"
    ];
}

NSString* LocalRootPath() {
#if TARGET_OS_TV
    NSArray<NSString*>* paths =
        NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString* caches = paths.firstObject ?: NSTemporaryDirectory();
    return [caches stringByAppendingPathComponent:@"2Ship 2 Harkinian"];
#else
    NSArray<NSString*>* paths =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
#endif
}

NSString* AbsolutePath(NSString* relativePath) {
    return [LocalRootPath() stringByAppendingPathComponent:relativePath];
}

CKRecordID* RecordID(NSString* relativePath) {
    NSString* name = [@"twoship-" stringByAppendingString:
        [relativePath stringByReplacingOccurrencesOfString:@"/" withString:@"-"]];
    return [[CKRecordID alloc] initWithRecordName:name];
}

CKContainer* Container() {
    static CKContainer* container =
        [CKContainer containerWithIdentifier:@TWO_SHIP_ICLOUD_CONTAINER_ID];
    return container;
}

CKDatabase* Database() {
    return Container().privateCloudDatabase;
}

bool WaitForAccount() {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block CKAccountStatus status = CKAccountStatusCouldNotDetermine;
    [Container() accountStatusWithCompletionHandler:^(CKAccountStatus accountStatus, NSError* error) {
        status = accountStatus;
        dispatch_semaphore_signal(semaphore);
    }];
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
        return false;
    }
    return status == CKAccountStatusAvailable;
}

NSDate* LocalModificationDate(NSString* path) {
    return [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileModificationDate];
}

void UploadPath(NSString* relativePath, CKRecord* existingRecord) {
    NSString* localPath = AbsolutePath(relativePath);
    NSDate* modifiedAt = LocalModificationDate(localPath);
    if (modifiedAt == nil) {
        return;
    }

    NSString* stagingPath =
        [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![[NSFileManager defaultManager] copyItemAtPath:localPath toPath:stagingPath error:nil]) {
        return;
    }

    CKRecord* record = existingRecord ?: [[CKRecord alloc] initWithRecordType:kRecordType
                                                                     recordID:RecordID(relativePath)];
    record[kRelativePathField] = relativePath;
    record[kModifiedAtField] = modifiedAt;
    record[kContentsField] = [[CKAsset alloc] initWithFileURL:[NSURL fileURLWithPath:stagingPath]];

    CKModifyRecordsOperation* operation =
        [[CKModifyRecordsOperation alloc] initWithRecordsToSave:@[ record ] recordIDsToDelete:nil];
    operation.savePolicy = CKRecordSaveAllKeys;
    operation.modifyRecordsCompletionBlock =
        ^(NSArray<CKRecord*>* savedRecords, NSArray<CKRecordID*>* deletedRecordIDs, NSError* error) {
            [[NSFileManager defaultManager] removeItemAtPath:stagingPath error:nil];
        };
    [Database() addOperation:operation];
}

void DeleteCloudPath(NSString* relativePath) {
    CKModifyRecordsOperation* operation =
        [[CKModifyRecordsOperation alloc] initWithRecordsToSave:nil
                                             recordIDsToDelete:@[ RecordID(relativePath) ]];
    [Database() addOperation:operation];
}

void ApplyCloudData(NSString* relativePath, NSData* contents, NSDate* modifiedAt) {
    NSString* destination = AbsolutePath(relativePath);
    NSFileManager* files = NSFileManager.defaultManager;
    [files createDirectoryAtPath:destination.stringByDeletingLastPathComponent
     withIntermediateDirectories:YES attributes:nil error:nil];

    NSData* localContents = [NSData dataWithContentsOfFile:destination];
    if (localContents != nil && ![localContents isEqualToData:contents]) {
        NSString* backup = [destination stringByAppendingFormat:@".icloud-conflict-%.0f",
                                                               NSDate.date.timeIntervalSince1970];
        [files copyItemAtPath:destination toPath:backup error:nil];
    }

    NSString* temporary = [destination stringByAppendingString:@".icloud-download"];
    [files removeItemAtPath:temporary error:nil];
    if (![contents writeToFile:temporary options:NSDataWritingAtomic error:nil]) {
        return;
    }
    if ([files fileExistsAtPath:destination]) {
        [files replaceItemAtURL:[NSURL fileURLWithPath:destination]
                  withItemAtURL:[NSURL fileURLWithPath:temporary]
                 backupItemName:nil options:0 resultingItemURL:nil error:nil];
    } else {
        [files moveItemAtPath:temporary toPath:destination error:nil];
    }
    if (modifiedAt != nil) {
        [files setAttributes:@{ NSFileModificationDate: modifiedAt }
               ofItemAtPath:destination error:nil];
    }
}

void ReconcilePaths(NSArray<NSString*>* relativePaths, bool allowDownloads) {
    if (!WaitForAccount()) {
        return;
    }

    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary<NSString*, CKRecord*>* records = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSData*>* cloudData = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSError*>* errors = [NSMutableDictionary dictionary];

    for (NSString* relativePath in relativePaths) {
        dispatch_group_enter(group);
        [Database() fetchRecordWithID:RecordID(relativePath)
                    completionHandler:^(CKRecord* record, NSError* error) {
                        @synchronized(records) {
                            if (record != nil) {
                                records[relativePath] = record;
                                CKAsset* asset = record[kContentsField];
                                NSData* contents = asset.fileURL == nil ? nil :
                                    [NSData dataWithContentsOfURL:asset.fileURL];
                                if (contents != nil) {
                                    cloudData[relativePath] = contents;
                                }
                            }
                            if (error != nil) {
                                errors[relativePath] = error;
                            }
                        }
                        dispatch_group_leave(group);
                    }];
    }

    if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC)) != 0) {
        return;
    }

    for (NSString* relativePath in relativePaths) {
        CKRecord* record = records[relativePath];
        NSDate* localDate = LocalModificationDate(AbsolutePath(relativePath));
        if (record == nil) {
            NSError* error = errors[relativePath];
            if ((error == nil || error.code == CKErrorUnknownItem) && localDate != nil) {
                UploadPath(relativePath, nil);
            }
            continue;
        }

        NSDate* cloudDate = record[kModifiedAtField] ?: record.modificationDate;
        NSData* contents = cloudData[relativePath];
        if (cloudDate == nil || contents == nil) {
            continue;
        }
        if (localDate == nil || [cloudDate compare:localDate] == NSOrderedDescending) {
            if (allowDownloads) {
                ApplyCloudData(relativePath, contents, cloudDate);
            }
        } else if ([localDate compare:cloudDate] == NSOrderedDescending) {
            UploadPath(relativePath, record);
        }
    }
}

NSString* RelativeSavePath(const char* path) {
    if (path == nullptr) {
        return nil;
    }
    NSString* absolute = [NSString stringWithUTF8String:path];
    NSString* localRoot = LocalRootPath();
    NSString* prefix = [localRoot stringByAppendingString:@"/"];
    if (![absolute hasPrefix:prefix]) {
        return nil;
    }
    NSString* relative = [absolute substringFromIndex:prefix.length];
    return [relative hasPrefix:@"saves/"] ? relative : nil;
}

} // namespace

extern "C" void TwoShipICloudSync_PrepareSaves(void) {
    if (!IsProvisionedForCloudKit()) {
        return;
    }
    dispatch_sync(SyncQueue(), ^{
        ReconcilePaths(SaveRelativePaths(), true);
    });
}

extern "C" void TwoShipICloudSync_LocalSaveChanged(const char* path) {
    if (!IsProvisionedForCloudKit()) {
        return;
    }
    NSString* relative = RelativeSavePath(path);
    if (relative == nil) {
        return;
    }
    dispatch_async(SyncQueue(), ^{
        ReconcilePaths(@[ relative ], false);
    });
}

extern "C" void TwoShipICloudSync_LocalSaveDeleted(const char* path) {
    if (!IsProvisionedForCloudKit()) {
        return;
    }
    NSString* relative = RelativeSavePath(path);
    if (relative == nil) {
        return;
    }
    dispatch_async(SyncQueue(), ^{
        if (WaitForAccount()) {
            DeleteCloudPath(relative);
        }
    });
}
