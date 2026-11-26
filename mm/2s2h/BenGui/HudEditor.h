#pragma once

#include <libultraship/libultraship.h>

#ifdef __cplusplus

#include "UIWidgets.hpp"
#include <unordered_map>
#include "CosmeticEditor.h"

class HudEditorWindow : public Ship::GuiWindow {
  public:
    using GuiWindow::GuiWindow;

    void InitElement() override{};
    void DrawElement() override;
    void UpdateElement() override{};
};

namespace BenGui {
void DrawControllerHudOptions();
void InstallControllerHudBindings();
}

extern "C" {
#endif

#include "z64.h"

typedef enum {
    HUD_EDITOR_ELEMENT_NONE = -1,
    HUD_EDITOR_ELEMENT_B,
    HUD_EDITOR_ELEMENT_C_LEFT,
    HUD_EDITOR_ELEMENT_C_DOWN,
    HUD_EDITOR_ELEMENT_C_RIGHT,
    HUD_EDITOR_ELEMENT_A,
    HUD_EDITOR_ELEMENT_C_UP,
    HUD_EDITOR_ELEMENT_D_PAD,
    HUD_EDITOR_ELEMENT_MINIMAP,
    HUD_EDITOR_ELEMENT_START,
    HUD_EDITOR_ELEMENT_CARROT,
    HUD_EDITOR_ELEMENT_CLOCK,
    HUD_EDITOR_ELEMENT_HEARTS,
    HUD_EDITOR_ELEMENT_MAGIC_METER,
    HUD_EDITOR_ELEMENT_TIMERS,
    HUD_EDITOR_ELEMENT_TIMERS_MOON_CRASH,
    HUD_EDITOR_ELEMENT_MINIGAME_COUNTER,
    HUD_EDITOR_ELEMENT_RUPEE_COUNTER,
    HUD_EDITOR_ELEMENT_KEY_COUNTER,
    HUD_EDITOR_ELEMENT_SKULLTULA_COUNTER,
    HUD_EDITOR_ELEMENT_MAX,
} HudEditorElementID;

typedef enum {
    HUD_EDITOR_ELEMENT_MODE_NONE = -1,
    HUD_EDITOR_ELEMENT_MODE_VANILLA,
    HUD_EDITOR_ELEMENT_MODE_HIDDEN,
    HUD_EDITOR_ELEMENT_MODE_MOVABLE_43,
    HUD_EDITOR_ELEMENT_MODE_MOVABLE_LEFT,
    HUD_EDITOR_ELEMENT_MODE_MOVABLE_RIGHT,
} HudEditorElementMode;

enum { CONTROLLER_HUD_ORIGINAL, CONTROLLER_HUD_RESTORATION, CONTROLLER_HUD_WIND_WAKER };
enum {
    CONTROLLER_HUD_RESTORATION_PLATE_SIZE = 16,
    CONTROLLER_HUD_RESTORATION_DPAD_SIZE = 8,
    CONTROLLER_HUD_RESTORATION_ZR_WIDTH = 17,
    CONTROLLER_HUD_RESTORATION_ZR_HEIGHT = 7,
    CONTROLLER_HUD_WIND_FACE_SIZE = 14,
    CONTROLLER_HUD_WIND_A_SIZE = 18,
    CONTROLLER_HUD_WIND_R_WIDTH = 21,
    CONTROLLER_HUD_WIND_R_HEIGHT = 21,
};
int ControllerHud_GetStyle(void);
bool ControllerHud_GetAnchor(HudEditorElementID id, s16* x, s16* y);
float ControllerHud_GetScale(HudEditorElementID id);
void ControllerHud_GetLabel(HudEditorElementID id, char* label, size_t capacity);
const char* ControllerHud_GetArt(int style, const char* label);
const char* ControllerHud_GetRestorationActionArt(int action, s16* width);
const char* ControllerHud_GetRestorationLabelArt(const char* label, s16* width);
int ControllerHud_GetDpadItem(int slot);
const char* ControllerHud_GetRestorationInstrumentArt(int form);

void HudEditor_OverrideNextElementMode(HudEditorElementMode mode);
void HudEditor_SetActiveElement(HudEditorElementID id);
bool HudEditor_ShouldOverrideDraw();
bool HudEditor_IsActiveElementHidden();
f32 HudEditor_GetActiveElementScale();
void HudEditor_ModifyRectPosValuesFromBase(s16 baseX, s16 baseY, s16* rectLeft, s16* rectTop);
void HudEditor_ModifyRectPosValues(s16* rectLeft, s16* rectTop);
void HudEditor_ModifyRectSizeValues(s16* rectWidth, s16* rectHeight);
void HudEditor_ModifyTextureStepValues(s16* dsdx, s16* dtdy);
void HudEditor_ModifyMatrixValues(f32* transX, f32* transY);
void HudEditor_ModifyKaleidoEquipAnimValues(s16* ulx, s16* uly, s16* shrinkRate);
void HudEditor_ModifyDrawValuesFromBase(s16 baseX, s16 baseY, s16* rectLeft, s16* rectTop, s16* rectWidth,
                                        s16* rectHeight, s16* dsdx, s16* dtdy);
void HudEditor_ModifyDrawValues(s16* rectLeft, s16* rectTop, s16* rectWidth, s16* rectHeight, s16* dsdx, s16* dtdy);

#define HUD_EDITOR_NO_COSMETIC nullptr

typedef struct {
    HudEditorElementID id;
    const char* name;
    int32_t defaultX;
    int32_t defaultY;
    int32_t defaultR;
    int32_t defaultG;
    int32_t defaultB;
    int32_t defaultA;
    const char* xCvar;
    const char* yCvar;
    const char* scaleCvar;
    const char* modeCvar;
    const char* cosmeticOptionId;
} HudEditorElement;

#define HUD_EDITOR_ELEMENT(id, name, cvar, defaultX, defaultY, defaultR, defaultG, defaultB, defaultA, cosmeticId) \
    {                                                                                                              \
        id, name, defaultX, defaultY, defaultR, defaultG, defaultB, defaultA, "gHudEditor." cvar ".Position.X",    \
            "gHudEditor." cvar ".Position.Y", "gHudEditor." cvar ".Scale", "gHudEditor." cvar ".Mode", cosmeticId  \
    }

extern HudEditorElementID hudEditorActiveElement;

extern HudEditorElement hudEditorElements[HUD_EDITOR_ELEMENT_MAX];

#ifdef __cplusplus
}
#endif
