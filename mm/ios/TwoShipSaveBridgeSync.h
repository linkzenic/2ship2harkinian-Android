#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void TwoShipSaveBridgeSync_Pair(const char* code);
void TwoShipSaveBridgeSync_SyncNow(void);
void TwoShipSaveBridgeSync_GetStatus(char* buffer, size_t bufferSize);

#ifdef __cplusplus
}
#endif
