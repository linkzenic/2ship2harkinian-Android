#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void TwoShipIOS_SetTouchControlsEnabled(int enabled);
void TwoShipIOS_SetTouchControlsMenuVisible(int visible);
int TwoShipIOS_ConsumeMenuToggleRequest(void);
void TwoShipIOS_PrepareTouchController(void);
void TwoShipIOS_GetTouchPadState(uint16_t* buttons, int8_t* leftX, int8_t* leftY,
                                 int8_t* rightX, int8_t* rightY);
void TwoShipIOS_GetCurrentRightStick(int8_t* rightX, int8_t* rightY);
int TwoShipApple_GetNativeControllerGyro(float* gyroX, float* gyroY, float* gyroZ);

#ifdef __cplusplus
}
#endif
