#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void TwoShipTVOSFileServer_Start(void);
void TwoShipTVOSFileServer_Stop(void);
int TwoShipTVOSFileServer_IsRunning(void);
void TwoShipTVOSFileServer_GetStatus(char* buffer, size_t bufferSize);
void TwoShipTVOS_GetNativeRightStick(float* rightX, float* rightY);
int TwoShipApple_GetNativeControllerGyro(float* gyroX, float* gyroY, float* gyroZ);
void TwoShipTVOS_GetNativeControllerStatus(char* buffer, size_t bufferSize);
void TwoShipTVOS_PrepareSettingsJSON(const char* workingPath);
void TwoShipTVOS_PersistSettingsJSON(const char* jsonBytes, size_t jsonLength);

#ifdef __cplusplus
}
#endif
