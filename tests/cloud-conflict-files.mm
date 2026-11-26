#import <Foundation/Foundation.h>
#include <cassert>
#include "TwoShipCloudFiles.h"
#include "CloudSyncPolicy.h"
#include "ship/Context.h"

static std::string dataRoot;

std::string Ship::Context::GetAppDirectoryPath(const std::string&) {
    return dataRoot;
}

static void Write(NSURL* url, NSString* text) {
    assert([NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil]);
}

static void RunCase(NSURL* scratch, bool useCloud) {
    NSString* account = NSUUID.UUID.UUIDString;
    NSString* channel = @"CloudKit";
    NSURL* root = [scratch URLByAppendingPathComponent:account isDirectory:YES];
    dataRoot = root.fileSystemRepresentation;
    NSString* group = @"saves/file1.json";
    NSURL* remoteRoot = [root URLByAppendingPathComponent:@"source" isDirectory:YES];
    NSMutableDictionary* members = [NSMutableDictionary dictionary];
    for (NSString* path in TwoShipCloudConflictMembers(group)) {
        NSURL* local = [root URLByAppendingPathComponent:path];
        NSURL* remote = [remoteRoot URLByAppendingPathComponent:path];
        Write(local, @"{\"copy\":\"device\"}");
        Write(remote, @"{\"copy\":\"cloud\"}");
        NSString* lh = TwoShipCloudHashFile(local), *rh = TwoShipCloudHashFile(remote);
        assert(lh.length && rh.length && ![lh isEqual:rh]);
        members[path] = @{@"expected":lh, @"hash":rh};
        assert(TwoShipCloudStage(channel, account, path, remote, lh, rh, YES));
    }
    TwoShipCloudPublishConflicts(account, channel, @{group:members});
    assert(!TwoShipCloudQueueConflict(account, channel, group, @"stale revision", useCloud));
    assert(TwoShipCloudQueueConflict(account, channel, group, TwoShipCloudConflictRevision(members), useCloud));
    assert(!TwoShipCloudQueueConflict(account, channel, group, TwoShipCloudConflictRevision(members), !useCloud));
    unsigned selection = static_cast<unsigned>(TwoShipCloud::Category::Saves);
    NSSet* applied = TwoShipCloudApplyChoices(account, selection, [NSSet set]);
    assert(applied.count == 2);
    NSArray* backups = [NSFileManager.defaultManager contentsOfDirectoryAtURL:
        [root URLByAppendingPathComponent:@"Conflicts/Resolved"] includingPropertiesForKeys:nil options:0 error:nil];
    assert(backups.count == 1);
    for (NSString* path in members) {
        NSURL* local = [root URLByAppendingPathComponent:path];
        NSDictionary* hashes = members[path];
        assert([TwoShipCloudHashFile(local) isEqual:hashes[useCloud ? @"hash" : @"expected"]]);
        NSURL* recovery = backups.firstObject;
        assert([TwoShipCloudHashFile([[recovery URLByAppendingPathComponent:@"This Device"] URLByAppendingPathComponent:path])
            isEqual:hashes[@"expected"]]);
        assert([TwoShipCloudHashFile([[recovery URLByAppendingPathComponent:@"iCloud"] URLByAppendingPathComponent:path])
            isEqual:hashes[@"hash"]]);
    }
    NSDictionary* choice = TwoShipCloudConflictChoices(account, channel)[group];
    assert([choice[@"applied"] boolValue]);
    TwoShipCloudClearChoice(account, channel, group, choice);
    TwoShipCloudPublishConflicts(account, channel, @{});
    assert(TwoShipCloudConflictChoices(account, channel).count == 0);
}

int main(int argc, char** argv) {
    @autoreleasepool {
        assert(argc == 2);
        NSURL* scratch = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        RunCase(scratch, true);
        RunCase(scratch, false);
    }
}
