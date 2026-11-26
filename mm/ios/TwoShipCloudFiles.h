#pragma once
#import <Foundation/Foundation.h>

NSURL* TwoShipCloudLocalRoot();
NSURL* TwoShipCloudSafeURL(NSURL* root, NSString* path);
NSString* TwoShipCloudHash(NSData* data);
NSString* TwoShipCloudHashFile(NSURL* url);
NSString* TwoShipCloudCachedHash(NSURL* url);
BOOL TwoShipCloudCopy(NSURL* from, NSURL* to, NSString* expectedHash);
BOOL TwoShipCloudStage(NSString* channel, NSString* account, NSString* path, NSURL* source,
                       NSString* localHash, NSString* remoteHash, BOOL conflict);
BOOL TwoShipCloudIsStaged(NSString* channel, NSString* account, NSString* path,
                         NSString* localHash, NSString* remoteHash, BOOL conflict);
void TwoShipCloudApply(NSString* channel, NSString* account, unsigned selection, NSSet<NSString*>* deleted = nil);
NSSet<NSString*>* TwoShipCloudApplyDeletions(NSSet<NSString*>* paths, unsigned selection);
NSURL* TwoShipCloudStateRoot();
NSString* TwoShipCloudConflictGroup(NSString* path);
NSArray<NSString*>* TwoShipCloudConflictMembers(NSString* group);
NSDictionary* TwoShipCloudConflictChoices(NSString* account, NSString* channel);
NSDictionary* TwoShipCloudActiveConflicts(NSString* account, NSString* channel);
void TwoShipCloudPublishConflicts(NSString* account, NSString* channel, NSDictionary* groups);
NSString* TwoShipCloudConflictRevision(NSDictionary* members);
BOOL TwoShipCloudQueueConflict(NSString* account, NSString* channel, NSString* group, NSString* revision, BOOL useCloud);
void TwoShipCloudClearChoice(NSString* account, NSString* channel, NSString* group, NSDictionary* choice);
NSSet<NSString*>* TwoShipCloudApplyChoices(NSString* account, unsigned selection, NSSet<NSString*>* deleted);
BOOL TwoShipCloudCanChoose(NSDictionary* members, BOOL useCloud);
