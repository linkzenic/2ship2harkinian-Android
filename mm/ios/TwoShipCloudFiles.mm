#import "TwoShipCloudFiles.h"
#include "CloudSyncPolicy.h"
#include "ship/Context.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/clonefile.h>

NSURL* TwoShipCloudLocalRoot() {
    return [NSURL fileURLWithPath:@(Ship::Context::GetAppDirectoryPath().c_str()) isDirectory:YES];
}

NSURL* TwoShipCloudStateRoot() {
    return [TwoShipCloudLocalRoot() URLByAppendingPathComponent:@".icloud-sync" isDirectory:YES];
}

NSURL* TwoShipCloudSafeURL(NSURL* root, NSString* path) {
    if (!path.UTF8String || !TwoShipCloud::IsUserPath(path.UTF8String)) return nil;
    NSURL* url = root;
    for (NSString* component in path.pathComponents) {
        url = [url URLByAppendingPathComponent:component];
        NSNumber* link = nil;
        [url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
        if (link.boolValue) return nil;
    }
    return url;
}

static NSString* DigestString(const unsigned char* digest) {
    NSMutableString* result = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) [result appendFormat:@"%02x", digest[i]];
    return result;
}

NSString* TwoShipCloudHash(NSData* data) {
    if (!data) return @"";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return DigestString(digest);
}

NSString* TwoShipCloudHashFile(NSURL* url) {
    NSInputStream* stream = [NSInputStream inputStreamWithURL:url];
    if (!stream) return nil;
    [stream open];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[65536];
    NSInteger count;
    while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0)
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    [stream close];
    if (count < 0) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    return DigestString(digest);
}

NSString* TwoShipCloudCachedHash(NSURL* url) {
    static NSMutableDictionary* cache = [NSMutableDictionary dictionary];
    NSDictionary* attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    if (!attrs[NSFileSize] || !attrs[NSFileModificationDate]) return nil;
    NSArray* signature = @[attrs[NSFileSize], attrs[NSFileModificationDate], attrs[NSFileSystemFileNumber] ?: @0];
    @synchronized(cache) {
        NSDictionary* entry = cache[url.path];
        if ([entry[@"signature"] isEqual:signature]) return entry[@"hash"];
    }
    NSString* hash = TwoShipCloudHashFile(url);
    if (hash) {
        @synchronized(cache) { cache[url.path] = @{@"signature":signature, @"hash":hash}; }
    }
    return hash;
}

BOOL TwoShipCloudCopy(NSURL* from, NSURL* to, NSString* expectedHash) {
    NSFileManager* files = NSFileManager.defaultManager;
    NSURL* parent = to.URLByDeletingLastPathComponent;
    if (![files createDirectoryAtURL:parent withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    NSURL* temporary = [parent URLByAppendingPathComponent:[@"." stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (clonefile(from.fileSystemRepresentation, temporary.fileSystemRepresentation, CLONE_NOFOLLOW) != 0 &&
        ![files copyItemAtURL:from toURL:temporary error:nil]) return NO;
    BOOL ok = NO;
    if (!expectedHash || [TwoShipCloudHashFile(temporary) isEqualToString:expectedHash]) {
        ok = [files fileExistsAtPath:to.path]
            ? [files replaceItemAtURL:to withItemAtURL:temporary backupItemName:nil options:0 resultingItemURL:nil error:nil]
            : [files moveItemAtURL:temporary toURL:to error:nil];
    }
    if (!ok) [files removeItemAtURL:temporary error:nil];
    return ok;
}

static NSURL* StageDirectory(NSString* channel, NSString* account, NSString* path, NSData* json, BOOL conflict) {
    NSURL* root = conflict ? [TwoShipCloudLocalRoot() URLByAppendingPathComponent:@"Conflicts" isDirectory:YES]
                           : [TwoShipCloudStateRoot() URLByAppendingPathComponent:channel isDirectory:YES];
    NSData* key = conflict ? json : [NSJSONSerialization dataWithJSONObject:@[account,path] options:0 error:nil];
    return key ? [root URLByAppendingPathComponent:TwoShipCloudHash(key) isDirectory:YES] : nil;
}

static NSData* StageMetadata(NSString* account, NSString* path, NSString* localHash, NSString* remoteHash) {
    if (!account.length || !remoteHash.length || !localHash || !TwoShipCloudSafeURL(TwoShipCloudLocalRoot(), path)) return nil;
    return [NSJSONSerialization dataWithJSONObject:@{@"account":account, @"path":path, @"expected":localHash, @"hash":remoteHash}
        options:NSJSONWritingSortedKeys error:nil];
}

BOOL TwoShipCloudIsStaged(NSString* channel, NSString* account, NSString* path,
                         NSString* localHash, NSString* remoteHash, BOOL conflict) {
    NSData* json = StageMetadata(account, path, localHash, remoteHash);
    NSURL* candidate = json ? StageDirectory(channel, account, path, json, conflict) : nil;
    if (!candidate) return NO;
    NSString* name = conflict ? [@"iCloud-" stringByAppendingString:path.lastPathComponent] : @"contents";
    return [[NSData dataWithContentsOfURL:[candidate URLByAppendingPathComponent:@"metadata.json"]] isEqual:json] &&
           [NSFileManager.defaultManager fileExistsAtPath:[candidate URLByAppendingPathComponent:name].path];
}

BOOL TwoShipCloudStage(NSString* channel, NSString* account, NSString* path, NSURL* source,
                       NSString* localHash, NSString* remoteHash, BOOL conflict) {
    if (TwoShipCloudIsStaged(channel, account, path, localHash, remoteHash, conflict)) return YES;
    NSData* json = StageMetadata(account, path, localHash, remoteHash);
    NSURL* candidate = json ? StageDirectory(channel, account, path, json, conflict) : nil;
    if (!candidate) return NO;
    NSURL* marker = [candidate URLByAppendingPathComponent:@"metadata.json"];
    NSString* name = conflict ? [@"iCloud-" stringByAppendingString:path.lastPathComponent] : @"contents";
    if (!TwoShipCloudCopy(source, [candidate URLByAppendingPathComponent:name], remoteHash)) return NO;
    return [json writeToURL:marker options:NSDataWritingAtomic error:nil];
}

NSString* TwoShipCloudConflictGroup(NSString* path) {
    const auto group = TwoShipCloud::SaveSlotGroup(path.UTF8String);
    return group.empty() ? path : @(group.data());
}

NSArray<NSString*>* TwoShipCloudConflictMembers(NSString* group) {
    if (TwoShipCloud::SaveSlotGroup(group.UTF8String).empty()) return @[group];
    return @[group, [group.stringByDeletingPathExtension stringByAppendingString:@"backup.json"]];
}

static NSString* ConflictKey(NSString* kind, NSString* account, NSString* channel) {
    return [NSString stringWithFormat:@"TwoShipConflicts-%@-%@-%@", kind, account, channel];
}

NSDictionary* TwoShipCloudActiveConflicts(NSString* account, NSString* channel) {
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:ConflictKey(@"active", account, channel)] ?: @{};
}

NSDictionary* TwoShipCloudConflictChoices(NSString* account, NSString* channel) {
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:ConflictKey(@"choice", account, channel)] ?: @{};
}

void TwoShipCloudPublishConflicts(NSString* account, NSString* channel, NSDictionary* groups) {
    [NSUserDefaults.standardUserDefaults setObject:groups forKey:ConflictKey(@"active", account, channel)];
}

BOOL TwoShipCloudCanChoose(NSDictionary* members, BOOL useCloud) {
    for (NSDictionary* hashes in members.allValues) {
        NSString* chosen = hashes[useCloud ? @"hash" : @"expected"];
        NSString* other = hashes[useCloud ? @"expected" : @"hash"];
        if (!chosen || !other || !TwoShipCloud::CanChooseConflictMember(chosen.UTF8String, other.UTF8String)) return NO;
    }
    return members.count != 0;
}

NSString* TwoShipCloudConflictRevision(NSDictionary* members) {
    if (!members.count) return @"";
    return TwoShipCloudHash([NSJSONSerialization dataWithJSONObject:members options:NSJSONWritingSortedKeys error:nil]);
}

BOOL TwoShipCloudQueueConflict(NSString* account, NSString* channel, NSString* group, NSString* revision, BOOL useCloud) {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    @synchronized(defaults) {
        NSDictionary* members = TwoShipCloudActiveConflicts(account, channel)[group];
        if (!TwoShipCloudCanChoose(members, useCloud) || ![TwoShipCloudConflictRevision(members) isEqual:revision]) return NO;
        NSMutableDictionary* choices = [TwoShipCloudConflictChoices(account, channel) mutableCopy];
        if (choices[group]) return NO;
        choices[group] = @{@"members":members, @"useCloud":@(useCloud), @"applied":@NO};
        [defaults setObject:choices forKey:ConflictKey(@"choice", account, channel)];
    }
    return YES;
}

void TwoShipCloudClearChoice(NSString* account, NSString* channel, NSString* group, NSDictionary* choice) {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    @synchronized(defaults) {
        NSMutableDictionary* choices = [TwoShipCloudConflictChoices(account, channel) mutableCopy];
        if (![choices[group] isEqual:choice]) return;
        [choices removeObjectForKey:group];
        [defaults setObject:choices forKey:ConflictKey(@"choice", account, channel)];
    }
}

static BOOL ValidIncoming(NSString* path, NSURL* incoming) {
    if (![path.pathExtension.lowercaseString isEqualToString:@"json"]) return YES;
    NSData* json = [NSData dataWithContentsOfURL:incoming];
    // The time-split tracker writes JSON null when it has no splits.
    const bool timeSplits = [path isEqual:@"2S2HTimeSplitData.json"];
    id value = json ? [NSJSONSerialization JSONObjectWithData:json
        options:timeSplits ? NSJSONReadingFragmentsAllowed : 0 error:nil] : nil;
    return [value isKindOfClass:NSArray.class] || [value isKindOfClass:NSDictionary.class] || (timeSplits && value == NSNull.null);
}

static BOOL ApplyChoice(NSString* account, NSString* channel, NSDictionary* members, BOOL useCloud) {
    NSFileManager* files = NSFileManager.defaultManager;
    NSURL* root = TwoShipCloudLocalRoot();
    NSURL* recovery = [root URLByAppendingPathComponent:@"Conflicts/Resolved" isDirectory:YES];
    recovery = [recovery URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSURL* localBackup = [recovery URLByAppendingPathComponent:@"This Device" isDirectory:YES];
    NSURL* cloudBackup = [recovery URLByAppendingPathComponent:@"iCloud" isDirectory:YES];
    for (NSString* path in members) {
        NSString* expected = members[path][@"expected"], *remote = members[path][@"hash"];
        NSURL* local = TwoShipCloudSafeURL(root, path);
        if (!local) return NO;
        NSString* current = [files fileExistsAtPath:local.path] ? TwoShipCloudHashFile(local) : @"";
        if (![current isEqual:expected]) return NO;
        if (expected.length && !TwoShipCloudCopy(local, [localBackup URLByAppendingPathComponent:path], expected)) return NO;
        if (remote.length) {
            NSData* meta = StageMetadata(account, path, expected, remote);
            NSURL* dir = meta ? StageDirectory(channel, account, path, meta, YES) : nil;
            NSURL* incoming = [dir URLByAppendingPathComponent:[@"iCloud-" stringByAppendingString:path.lastPathComponent]];
            if (!incoming || (useCloud && !ValidIncoming(path, incoming)) ||
                !TwoShipCloudCopy(incoming, [cloudBackup URLByAppendingPathComponent:path], remote)) return NO;
        }
    }
    if (!useCloud) return YES;
    NSMutableArray<NSString*>* changed = [NSMutableArray array];
    for (NSString* path in members) {
        NSString* remote = members[path][@"hash"];
        if ([remote isEqual:members[path][@"expected"]]) continue;
        NSURL* local = TwoShipCloudSafeURL(root, path);
        if (!local || !TwoShipCloudCopy([cloudBackup URLByAppendingPathComponent:path], local, remote)) {
            for (NSString* rollback in changed) {
                NSURL* target = TwoShipCloudSafeURL(root, rollback);
                NSString* previous = members[rollback][@"expected"];
                if (target && previous.length) TwoShipCloudCopy([localBackup URLByAppendingPathComponent:rollback], target, previous);
                else if (target) [files removeItemAtURL:target error:nil];
            }
            return NO;
        }
        [changed addObject:path];
    }
    return YES;
}

NSSet<NSString*>* TwoShipCloudApplyChoices(NSString* account, unsigned selection, NSSet<NSString*>* deleted) {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSMutableSet* guarded = [NSMutableSet set];
    for (NSString* channel in @[@"CloudKit", @"CloudKitMods"]) {
        NSMutableDictionary* choices = [TwoShipCloudConflictChoices(account, channel) mutableCopy];
        for (NSString* group in choices.allKeys) {
            NSDictionary* choice = choices[group], *members = choice[@"members"];
            if (!TwoShipCloud::SelectedPath(group.UTF8String, selection)) continue;
            BOOL unavailable = NO;
            for (NSString* path in members) {
                if ([deleted containsObject:path]) { unavailable = YES; break; }
            }
            if (unavailable) { [choices removeObjectForKey:group]; continue; }
            if (![choice[@"applied"] boolValue]) {
                if (!ApplyChoice(account, channel, members, [choice[@"useCloud"] boolValue])) {
                    [choices removeObjectForKey:group];
                    continue;
                }
                choices[group] = @{@"members":members, @"useCloud":choice[@"useCloud"], @"applied":@YES};
            }
            [guarded addObjectsFromArray:members.allKeys];
        }
        [defaults setObject:choices forKey:ConflictKey(@"choice", account, channel)];
    }
    return guarded;
}

NSSet<NSString*>* TwoShipCloudApplyDeletions(NSSet<NSString*>* paths, unsigned selection) {
    NSFileManager* files = NSFileManager.defaultManager;
    NSMutableSet* applied = [NSMutableSet set];
    for (NSString* path in paths) {
        if (!TwoShipCloud::SelectedPath(path.UTF8String, selection)) continue;
        NSURL* target = TwoShipCloudSafeURL(TwoShipCloudLocalRoot(), path);
        if (!target) continue;
        if (![files fileExistsAtPath:target.path]) { [applied addObject:path]; continue; }
        NSNumber* regular = nil;
        [target getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        if (!regular.boolValue) continue;
        if (TwoShipCloud::FileCategory(path.UTF8String) == TwoShipCloud::Category::Mods) {
            if ([files removeItemAtURL:target error:nil]) [applied addObject:path];
        } else {
            // Small saves and settings remain recoverable outside the synced directories.
            NSURL* trash = [TwoShipCloudLocalRoot() URLByAppendingPathComponent:@"Conflicts/Deleted from iCloud Drive" isDirectory:YES];
            NSURL* backup = [[trash URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES] URLByAppendingPathComponent:path];
            if ([files createDirectoryAtURL:backup.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil] &&
                [files moveItemAtURL:target toURL:backup error:nil]) [applied addObject:path];
        }
    }
    return applied;
}

void TwoShipCloudApply(NSString* channel, NSString* account, unsigned selection, NSSet<NSString*>* deleted) {
    if (!account.length) return;
    NSFileManager* files = NSFileManager.defaultManager;
    NSURL* pending = [TwoShipCloudStateRoot() URLByAppendingPathComponent:channel isDirectory:YES];
    for (NSURL* candidate in [files contentsOfDirectoryAtURL:pending includingPropertiesForKeys:nil options:0 error:nil]) {
        NSData* data = [NSData dataWithContentsOfURL:[candidate URLByAppendingPathComponent:@"metadata.json"]];
        if (!data) continue;
        id meta = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![meta isKindOfClass:NSDictionary.class] || ![meta[@"account"] isEqual:account] ||
            ![meta[@"path"] isKindOfClass:NSString.class] || ![meta[@"hash"] isKindOfClass:NSString.class]) continue;
        if (!TwoShipCloud::SelectedPath([meta[@"path"] UTF8String], selection)) continue;
        if ([deleted containsObject:meta[@"path"]]) {
            [files removeItemAtURL:candidate error:nil];
            continue;
        }
        NSURL* target = TwoShipCloudSafeURL(TwoShipCloudLocalRoot(), meta[@"path"]);
        NSURL* incoming = [candidate URLByAppendingPathComponent:@"contents"];
        if (!target || ![TwoShipCloudHashFile(incoming) isEqual:meta[@"hash"]]) continue;
        if (!ValidIncoming(meta[@"path"], incoming)) continue;
        NSString* current = [files fileExistsAtPath:target.path] ? TwoShipCloudHashFile(target) : @"";
        if (!current) continue;
        if (![current isEqual:meta[@"expected"]] && ![current isEqual:meta[@"hash"]]) {
            TwoShipCloudStage(channel, account, meta[@"path"], incoming, current, meta[@"hash"], YES);
            continue;
        }
        NSURL* history = [[TwoShipCloudStateRoot() URLByAppendingPathComponent:@"History" isDirectory:YES]
            URLByAppendingPathComponent:channel isDirectory:YES];
        NSURL* previous = [history URLByAppendingPathComponent:candidate.lastPathComponent];
        BOOL applied = [current isEqual:meta[@"hash"]];
        if (!current.length) {
            // The staging directory and destination share the app's data volume.
            NSURL* parent = target.URLByDeletingLastPathComponent;
            applied = [files createDirectoryAtURL:parent withIntermediateDirectories:YES attributes:nil error:nil] &&
                      [files moveItemAtURL:incoming toURL:target error:nil];
        } else if (!applied && TwoShipCloudCopy(target, previous, current)) {
            applied = TwoShipCloudCopy(incoming, target, meta[@"hash"]);
        }
        if (applied) {
            [files removeItemAtURL:candidate error:nil];
        }
    }
}
