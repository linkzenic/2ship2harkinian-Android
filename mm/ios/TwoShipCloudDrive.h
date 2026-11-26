#pragma once
#include <stddef.h>

#ifdef __OBJC__
@class NSMutableDictionary, NSMutableSet, NSSet;
void TwoShipCloudDriveApplyAtLaunch(NSSet* deleted);
bool TwoShipCloudDriveReconcile(unsigned selection, NSMutableDictionary* journal, NSMutableSet* pendingDownloads, NSSet* held);
#endif
void TwoShipCloudDriveStatus(char* buffer, size_t size);
