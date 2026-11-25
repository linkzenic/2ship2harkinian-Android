#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Downloads newer iCloud saves before the file-select screen reads them, and
// uploads local saves that are newer than their cloud copies.
void TwoShipICloudSync_PrepareSaves(void);

// Queues a reconciliation after a save is committed or deleted.
void TwoShipICloudSync_LocalSaveChanged(const char* path);
void TwoShipICloudSync_LocalSaveDeleted(const char* path);

#ifdef __cplusplus
}
#endif
