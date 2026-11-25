#pragma once
#include "TouchHudBindings.h"

void TwoShipIntegratedButton(unsigned mask, bool pressed);
void TwoShipIntegratedStick(int x, int y);
void TwoShipIntegratedCamera(int x, int y);
void TwoShipIntegratedReset();
int TwoShipIntegratedState();
void TwoShipIntegratedLayout(const float* anchors, bool active);
int TwoShipIOS_IntegratedTouchStyle();
void TwoShipIOS_ConfigureIntegratedTouch(int style, float scale, float opacity, int left, int right,
                                         int transparent, int cameraMode, TouchHud::Bindings bindings);
void TwoShipIOS_ApplyIntegratedTouch(void* window, int enabled, int menuVisible);
void TwoShipIOS_EditIntegratedTouch();
void TwoShipIOS_RefreshOverlay();
void TwoShipIOS_RequestMenuToggle();
