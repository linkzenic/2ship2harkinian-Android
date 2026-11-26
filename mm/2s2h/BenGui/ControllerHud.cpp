#include "HudEditor.h"
#include "BenGui.hpp"
#include "2s2h/BenPort.h"
#include "2s2h/ShipInit.hpp"
#include <fast/resource/type/Texture.h>
#include <fast/resource/ResourceType.h>
#include <libultraship/controller/controldevice/controller/Controller.h>
#include <ship/controller/controldeck/ControlDeck.h>
#include <ship/resource/File.h>
#include <ship/resource/ResourceManager.h>
#include <ship/resource/archive/ArchiveManager.h>
#include <ship/window/gui/IconsFontAwesome4.h>
#include <ship/window/gui/resource/Font.h>

extern "C" int16_t OTRGetRectDimensionFromLeftEdge(float v);
extern "C" int16_t OTRGetRectDimensionFromRightEdge(float v);

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <string_view>
#include <stb_image.h>
#define STBTT_STATIC
#define STB_TRUETYPE_IMPLEMENTATION
#include <imstb_truetype.h>

#if defined(__ANDROID__) || (defined(__IOS__) && !defined(__TVOS__))
extern "C" int TwoShipTouchHudActive(void);
extern "C" int TwoShipClassicTouchVisible(void);
#endif

namespace {
struct Slot {
    const char* name;
    const char* labelCvar;
    unsigned button;
    float scale;
    s16 x, y, windX, windY;
};

// One center and radius for all four face positions, independent of plate size.
constexpr int kWindDiamondX = 267;
constexpr int kWindDiamondY = 58;
constexpr int kWindDiamondRadius = 14;
constexpr int kWindFaceHalf = CONTROLLER_HUD_WIND_FACE_SIZE / 2;
constexpr int kRestDiamondX = 270;
constexpr int kRestDiamondY = 44;
constexpr int kRestRadius = 12;
constexpr int kRestHalf = CONTROLLER_HUD_RESTORATION_PLATE_SIZE / 2;

// In HUD editor element order.
constexpr std::array<Slot, 7> slots{{
    {"B action", "gHudEditor.Controller.Label.B", BTN_B, .66f, kRestDiamondX - kRestHalf, kRestDiamondY + kRestRadius - kRestHalf,
     kWindDiamondX - kWindFaceHalf, kWindDiamondY + kWindDiamondRadius - kWindFaceHalf},
    {"C-Left item", "gHudEditor.Controller.Label.CLeft", BTN_CLEFT, .72f, kRestDiamondX - kRestRadius - kRestHalf, kRestDiamondY - kRestHalf,
     kWindDiamondX - kWindDiamondRadius - kWindFaceHalf, kWindDiamondY - kWindFaceHalf},
    {"C-Down item", "gHudEditor.Controller.Label.CDown", BTN_CDOWN, .72f, kRestDiamondX - kRestHalf, kRestDiamondY - kRestRadius - kRestHalf,
     kWindDiamondX - kWindFaceHalf, kWindDiamondY - kWindDiamondRadius - kWindFaceHalf},
    {"C-Right item", "gHudEditor.Controller.Label.CRight", BTN_CRIGHT, .72f, kRestDiamondX + 19,
     kRestDiamondY - kRestRadius - 5, 279, 28},
    {"A action", "gHudEditor.Controller.Label.A", BTN_A, .72f, kRestDiamondX + kRestRadius - kRestHalf, kRestDiamondY - kRestHalf,
     kWindDiamondX + kWindDiamondRadius - CONTROLLER_HUD_WIND_A_SIZE / 2,
     kWindDiamondY - CONTROLLER_HUD_WIND_A_SIZE / 2},
    {"Tatl", "gHudEditor.Controller.Label.Tatl", BTN_CUP, .75f, 244, 16, 248, 15},
    {"D-Pad", nullptr, 0, .66f, 38, 63, 30, 59},
}};

constexpr const char* labels[] = {
    "Default", "Hidden", "A", "B", "X", "Y", "L", "R", "Z", "ZL", "ZR", "LB", "RB", "LT", "RT",
    "L1", "R1", "L2", "R2", "L3", "R3", "I", "II", "1", "2", "3", "4", "C<", "Cv", "C>", "C^", "LS", "RS"
};
constexpr const char* styles[] = {"Original", "Project Restoration", "Wind Waker HD"};
constexpr const char* windLabelModes[] = {"ABXY / R", "Custom", "Off"};
enum RestorationLabelMode { REST_LABEL_ABXY, REST_LABEL_BAYX, REST_LABEL_NONE, REST_LABEL_CUSTOM, REST_LABEL_AUTO };
constexpr const char* restorationLabelModes[] = {"ABXY", "BAYX", "No letters", "Custom", "Automatic"};
constexpr std::array<const char*, 7> windLabels{"B", "Y", "X", "R", "A", "", ""};
constexpr std::array<const char*, 7> restorationABXY{"B", "Y", "X", "ZR", "A", "", ""};
constexpr std::array<const char*, 7> restorationBAYX{"A", "X", "Y", "ZR", "B", "", ""};
constexpr std::array<const char*, 7> windNames{"B action", "Y item", "X item", "R item", "A action", "Tatl", "D-Pad"};
constexpr const char* kLabelMode = "gHudEditor.Controller.LabelMode";
constexpr const char* kRestorationLabelMode = "gHudEditor.Controller.RestorationLabelMode";
constexpr const char* kPresetBindings = "gHudEditor.Controller.UsePresetBindings";
constexpr const char* kRestorationOcarina = "gHudEditor.Controller.RestorationOcarina";

int GetRestorationLabelMode() {
    // Preserve existing Custom and Off selections; Wind Waker keeps its own setting.
    const int legacy = CVarGetInteger(kLabelMode, 0);
    const int fallback = legacy == 1 ? REST_LABEL_CUSTOM : legacy == 2 ? REST_LABEL_NONE : REST_LABEL_ABXY;
    return std::clamp(CVarGetInteger(kRestorationLabelMode, fallback), int(REST_LABEL_ABXY), int(REST_LABEL_AUTO));
}

bool UsePresetBindings() {
    return ControllerHud_GetStyle() != CONTROLLER_HUD_ORIGINAL && CVarGetInteger(kPresetBindings, 1);
}

std::optional<CONTROLLERBUTTONS_T> ReadPresetGamepadButtons() {
    if (!UsePresetBindings()) return std::nullopt;
    const auto deck = Ship::Context::GetRawInstance()->GetControlDeck();
    const auto gamepads = deck->GetConnectedPhysicalDeviceManager()->GetConnectedSDLGamepadsForPort(0);
    const bool wind = ControllerHud_GetStyle() == CONTROLLER_HUD_WIND_WAKER;
    const bool blocked = deck->GamepadGameInputBlocked();

    const std::pair<SDL_GameControllerButton, CONTROLLERBUTTONS_T> buttons[] = {
        { SDL_CONTROLLER_BUTTON_A, BTN_A },
        { SDL_CONTROLLER_BUTTON_B, BTN_B },
        { SDL_CONTROLLER_BUTTON_X, BTN_CDOWN },
        { SDL_CONTROLLER_BUTTON_Y, BTN_CLEFT },
        { SDL_CONTROLLER_BUTTON_RIGHTSHOULDER, wind ? BTN_CRIGHT : BTN_R },
        { SDL_CONTROLLER_BUTTON_LEFTSHOULDER, BTN_L },
        { SDL_CONTROLLER_BUTTON_START, BTN_START },
        { SDL_CONTROLLER_BUTTON_DPAD_UP, BTN_DUP },
        { SDL_CONTROLLER_BUTTON_DPAD_DOWN, BTN_DDOWN },
        { SDL_CONTROLLER_BUTTON_DPAD_LEFT, BTN_DLEFT },
        { SDL_CONTROLLER_BUTTON_DPAD_RIGHT, BTN_DRIGHT },
    };

    std::optional<CONTROLLERBUTTONS_T> result;
    for (const auto& [instance, gamepad] : gamepads) {
        const auto tatl = SDL_GameControllerHasButton(gamepad, SDL_CONTROLLER_BUTTON_RIGHTSTICK)
                              ? SDL_CONTROLLER_BUTTON_RIGHTSTICK : SDL_CONTROLLER_BUTTON_BACK;
        // Leave remotes and other partial controllers on their existing bindings.
        if (SDL_GameControllerGetType(gamepad) == SDL_CONTROLLER_TYPE_VIRTUAL ||
            !SDL_GameControllerHasButton(gamepad, tatl) ||
            !SDL_GameControllerHasAxis(gamepad, SDL_CONTROLLER_AXIS_TRIGGERLEFT) ||
            !SDL_GameControllerHasAxis(gamepad, SDL_CONTROLLER_AXIS_TRIGGERRIGHT) ||
            !std::all_of(std::begin(buttons), std::end(buttons), [gamepad](const auto& binding) {
                return SDL_GameControllerHasButton(gamepad, binding.first);
            })) continue;

        if (!result) result = 0;
        if (blocked) continue;
        for (const auto& [physical, logical] : buttons) {
            if (SDL_GameControllerGetButton(gamepad, physical)) *result |= logical;
        }
        if (SDL_GameControllerGetButton(gamepad, tatl)) *result |= BTN_CUP;
        if (SDL_GameControllerGetAxis(gamepad, SDL_CONTROLLER_AXIS_TRIGGERLEFT) > 16000) *result |= BTN_Z;
        if (SDL_GameControllerGetAxis(gamepad, SDL_CONTROLLER_AXIS_TRIGGERRIGHT) > 16000) {
            *result |= wind ? BTN_R : BTN_CRIGHT;
        }
    }
    return result;
}

void SetOption(const char* key, int value) {
    CVarSetInteger(key, value);
    Ship::Context::GetRawInstance()->GetWindow()->GetGui()->SaveConsoleVariablesNextFrame();
}

std::string CompactLabel(std::string name) {
    const char* direction = name.ends_with(ICON_FA_ARROW_LEFT) ? "<" :
                            name.ends_with(ICON_FA_ARROW_RIGHT) ? ">" :
                            name.ends_with(ICON_FA_ARROW_UP) ? "^" :
                            name.ends_with(ICON_FA_ARROW_DOWN) ? "v" : nullptr;
    if (direction) {
        const char* prefix = name.starts_with("D-Pad ") ? "D" :
                             name.starts_with("Right Stick ") ? "RS" :
                             name.starts_with("Left Stick ") ? "LS" : "";
        return std::string(prefix) + direction;
    }
    if (name == ICON_FA_BARS) return "+";
    if (name == "View") return "-";
    if (name.size() > 3 || std::any_of(name.begin(), name.end(), [](unsigned char c) { return c < 32 || c > 126; })) return {};
    return name;
}

struct Art {
    int size = 0;
    std::vector<u8> pixels;
};

enum class AtlasPart { None, Plate, Dpad, CallingDpad, Tatl, TatlLabel };

using ImagePixels = std::unique_ptr<u8, decltype(&stbi_image_free)>;

ImagePixels ReadBundledHudPng(const char* filename, int& w, int& h, int expectedWidth = 0, int expectedHeight = 0) {
    auto archive = Ship::Context::GetRawInstance()->GetResourceManager()->GetArchiveManager();
    const auto file = archive->LoadFile(std::string("controller-hud/") + filename);
    if (!file || !file->Buffer || file->Buffer->empty() || file->Buffer->size() > 4 * 1024 * 1024)
        return {nullptr, stbi_image_free};

    const auto* bytes = reinterpret_cast<const stbi_uc*>(file->Buffer->data());
    const int size = static_cast<int>(file->Buffer->size());
    int channels;
    if (!stbi_info_from_memory(bytes, size, &w, &h, &channels) ||
        (expectedWidth ? (w != expectedWidth || h != expectedHeight) : (w != h || w < 32 || w > 512)))
        return {nullptr, stbi_image_free};
    return {stbi_load_from_memory(bytes, size, &w, &h, &channels, STBI_rgb_alpha), stbi_image_free};
}

ImagePixels ReadRestorationAtlas(int& w, int& h) {
    return ReadBundledHudPng("project-restoration.png", w, h, 2048, 1024);
}

Art ReadArt(const char* filename, AtlasPart part = AtlasPart::None) {
    const bool atlas = part != AtlasPart::None;
    int w, h;
    const auto rgba = atlas ? ReadRestorationAtlas(w, h) : ReadBundledHudPng(filename, w, h);
    if (!rgba) return {};

    const bool calling = part == AtlasPart::CallingDpad;
    const bool dpad = calling || part == AtlasPart::Dpad;
    const bool fairy = part == AtlasPart::Tatl;
    const bool tatlLabel = part == AtlasPart::TatlLabel;
    const int size = dpad ? 86 : fairy ? 104 : tatlLabel ? 102 : atlas ? 156 : w;
    const int left = dpad ? 167 : fairy ? 349 : tatlLabel ? 1033 : atlas ? 190 : 0;
    const int top = dpad ? 167 : tatlLabel ? 7 : 0;
    Art art{size, std::vector<u8>(size * size * 4)};
    for (int y = 0; y < size; ++y) {
        const int row = top + (tatlLabel ? y * 50 / size : y);
        std::copy_n(rgba.get() + 4 * (row * w + left), size * 4, art.pixels.data() + y * size * 4);
        if (!atlas || fairy || tatlLabel) continue;
        // The atlas border touches the neighboring sprite. Keep only this plate.
        for (int x = 0; x < size; ++x) {
            auto* pixel = art.pixels.data() + 4 * (y * size + x);
            if (dpad) {
                const bool outline = pixel[0] >= 180 && pixel[1] >= 180 && pixel[2] >= 145;
                const bool red = pixel[0] >= 180 && pixel[1] < 115 && pixel[2] < 115;
                if (calling && red) {
                    // The atlas stores the red indicator in transparent pixels.
                    pixel[3] = 255;
                } else if (!outline) {
                    pixel[3] = 0;
                }
                continue;
            }
            const float dx = x + .5f - size / 2.f, dy = y + .5f - size / 2.f;
            const float coverage = std::clamp(size / 2.f + .5f - std::hypot(dx, dy), 0.f, 1.f);
            pixel[3] *= coverage;
        }
    }
    return art;
}

Art BlankWindPlate(const char* filename) {
    auto art = ReadArt(filename);
    if (!art.size) return art;
    const int left = art.size * 22 / 100;
    const int right = art.size * 78 / 100;
    for (int y = art.size * 19 / 100; y < art.size * 78 / 100; ++y) {
        auto* row = art.pixels.data() + 4 * y * art.size;
        for (int x = left + 1; x < right; ++x) {
            for (int c = 0; c < 3; ++c) {
                row[4 * x + c] = (row[4 * left + c] * (right - x) + row[4 * right + c] * (x - left)) /
                                  (right - left);
            }
        }
    }
    return art;
}

std::string RegisterArt(const char* name, Art art) {
    if (!art.size) return {};
    const std::string path = std::string("controller-hud/runtime/") + name;
    auto init = std::make_shared<Ship::ResourceInitData>();
    init->Path = path;
    init->Type = static_cast<uint32_t>(Fast::ResourceType::Texture);
    auto texture = std::make_shared<Fast::Texture>(init);
    texture->Type = Fast::TextureType::RGBA32bpp;
    texture->Flags = TEX_FLAG_LOAD_AS_IMG;
    texture->Width = texture->Height = art.size;
    texture->ImageDataSize = art.pixels.size();
    texture->ImageData = new u8[texture->ImageDataSize];
    std::copy(art.pixels.begin(), art.pixels.end(), texture->ImageData);
    Ship::Context::GetRawInstance()->GetResourceManager()->CacheExternalResource(path, texture);
    return "__OTR__" + path;
}

Art MakeSymbol(bool wind, char direction = 0, bool calling = false) {
    constexpr int size = 96;
    Art art{size, std::vector<u8>(size * size * 4)};
    for (int y = 0; y < size; ++y) {
        for (int x = 0; x < size; ++x) {
            const float dx = (x + .5f) / size - .5f;
            const float dy = (y + .5f) / size - .5f;
            float edge;
            int shade;
            if (direction) {
                const bool horizontal = direction == '<' || direction == '>';
                const float along = (horizontal ? dx : dy) * ((direction == '>' || direction == 'v') ? 1 : -1);
                const float across = std::abs(horizontal ? dy : dx);
                edge = std::min(along + .24f, .26f - along - across);
                shade = wind ? 52 : 248;
            } else {
                const float bar = .16f, length = .46f;
                const float cross = std::max(std::min(bar - std::abs(dx), length - std::abs(dy)),
                                             std::min(bar - std::abs(dy), length - std::abs(dx)));
                edge = cross;
                if (!wind) edge = std::min(cross, .06f - cross);
                shade = !wind ? 255 : std::hypot(dx, dy) < .12f ? 155 :
                        cross < .025f ? 237 : 202 - y / 5;
            }
            auto* pixel = art.pixels.data() + 4 * (y * size + x);
            if (calling && std::abs(dx - .32f) <= .073f && std::abs(dy) <= .073f) {
                pixel[0] = 255;
                pixel[1] = 36;
                pixel[2] = 24;
                pixel[3] = 255;
            } else {
                pixel[0] = pixel[1] = pixel[2] = shade;
                pixel[3] = std::clamp(edge * size + .5f, 0.f, 1.f) * 255;
            }
        }
    }
    return art;
}

// The Wind Waker reference uses a softly beveled ivory cross with small inset ticks.
Art MakeWindDpad() {
    constexpr int size = 96;
    Art art{size, std::vector<u8>(size * size * 4)};
    const auto arm = [](float across, float along) {
        constexpr float radius = .038f;
        const float x = std::abs(across) - .155f + radius;
        const float y = std::abs(along) - .455f + radius;
        return radius - std::hypot(std::max(x, 0.f), std::max(y, 0.f)) - std::min(std::max(x, y), 0.f);
    };
    const auto cross = [&](float x, float y) { return std::max(arm(x, y), arm(y, x)); };
    for (int y = 0; y < size; ++y) {
        for (int x = 0; x < size; ++x) {
            const float dx = (x + .5f) / size - .5f;
            const float dy = (y + .5f) / size - .5f;
            const float edge = cross(dx, dy);
            const float coverage = std::clamp(edge * size + .5f, 0.f, 1.f);
            const float shadow = .38f * std::clamp(cross(dx - .014f, dy - .024f) * .65f * size + .5f, 0.f, 1.f);
            const bool vertical = std::abs(dy) > std::abs(dx);
            const float along = std::abs(vertical ? dy : dx);
            const float across = std::abs(vertical ? dx : dy);
            const bool inset = across < .020f && std::abs(along - .322f) < .044f;
            const int lip = cross(dx - .016f, dy - .02f) < edge ? 253 : 176;
            const int ivory = inset ? 199 : edge < .016f ? 153 :
                              edge < .057f ? lip : 244 - int(12 * (dy + .5f));
            const float behind = shadow * (1.f - coverage);
            const float alpha = coverage + behind;
            if (!alpha) continue;
            const int color = (ivory * coverage + 74 * behind) / alpha;
            auto* pixel = art.pixels.data() + 4 * (y * size + x);
            pixel[0] = color;
            pixel[1] = color;
            pixel[2] = color - 3;
            pixel[3] = alpha * 255;
        }
    }
    return art;
}

const Slot* GetSlot(HudEditorElementID id) {
    return id >= HUD_EDITOR_ELEMENT_B && id <= HUD_EDITOR_ELEMENT_D_PAD ? &slots[id] : nullptr;
}
}

void BenGui::InstallControllerHudBindings() {
    auto controller = std::static_pointer_cast<LUS::Controller>(
        Ship::Context::GetRawInstance()->GetControlDeck()->GetControllerByPort(0));
    controller->SetGamepadButtonOverride(ReadPresetGamepadButtons);
}

extern "C" int ControllerHud_DpadEquipsEnabled() {
    const int style = CVarGetInteger("gHudEditor.Controller.Style", 0);
    return style == CONTROLLER_HUD_RESTORATION || style == CONTROLLER_HUD_WIND_WAKER ||
           CVarGetInteger("gEnhancements.Dpad.DpadEquips", 0);
}

extern "C" int ControllerHud_GetStyle() {
    const int style = CVarGetInteger("gHudEditor.Controller.Style", 0);
    if (style <= CONTROLLER_HUD_ORIGINAL || style > CONTROLLER_HUD_WIND_WAKER) return 0;
#if defined(__ANDROID__) || (defined(__IOS__) && !defined(__TVOS__))
    if (TwoShipTouchHudActive() || TwoShipClassicTouchVisible()) return 0;
#endif
    return style;
}

extern "C" bool ControllerHud_GetAnchor(HudEditorElementID id, s16* x, s16* y) {
    const auto* slot = GetSlot(id);
    const int style = slot ? ControllerHud_GetStyle() : 0;
    if (!style) return false;
    const bool wind = style == CONTROLLER_HUD_WIND_WAKER;
    const s16 posX = wind ? slot->windX : slot->x;
    *x = id == HUD_EDITOR_ELEMENT_D_PAD ? OTRGetRectDimensionFromLeftEdge(posX)
                                       : OTRGetRectDimensionFromRightEdge(posX);
    *y = wind ? slot->windY : slot->y;
    if (id == HUD_EDITOR_ELEMENT_D_PAD) {
        const auto& player = gSaveContext.save.saveInfo.playerData;
        const bool magic = player.isMagicAcquired &&
            CVarGetInteger(hudEditorElements[HUD_EDITOR_ELEMENT_MAGIC_METER].modeCvar, HUD_EDITOR_ELEMENT_MODE_VANILLA) !=
                HUD_EDITOR_ELEMENT_MODE_HIDDEN;
        if (magic) *y += wind ? 10 : 19;
        else if (!wind && player.healthCapacity > 0xA0) *y += 5;
    }
    return true;
}

extern "C" float ControllerHud_GetScale(HudEditorElementID id) {
    const auto* slot = GetSlot(id);
    return slot ? slot->scale : 1.f;
}

extern "C" void ControllerHud_GetLabel(HudEditorElementID id, char* label, size_t capacity) {
    if (!capacity) return;
    label[0] = '\0';
    const auto* slot = GetSlot(id);
    if (!slot || !slot->labelCvar) return;

    const bool wind = ControllerHud_GetStyle() == CONTROLLER_HUD_WIND_WAKER;
    const int mode = wind ? CVarGetInteger(kLabelMode, 0) : GetRestorationLabelMode();
    if (mode == (wind ? 2 : REST_LABEL_NONE)) return;
    if (mode == (wind ? 1 : REST_LABEL_CUSTOM)) {
        const int choice = CVarGetInteger(slot->labelCvar, 0);
        if (choice == 1) return;
        if (choice > 1 && choice < int(std::size(labels))) {
            snprintf(label, capacity, "%s", labels[choice]);
            return;
        }
    }

    if (wind) {
        snprintf(label, capacity, "%s", windLabels[id]);
        return;
    }
    if (mode == REST_LABEL_BAYX) {
        snprintf(label, capacity, "%s", restorationBAYX[id]);
        return;
    }
    if (mode == REST_LABEL_ABXY || UsePresetBindings()) {
        snprintf(label, capacity, "%s", restorationABXY[id]);
        return;
    }

    const auto context = Ship::Context::GetRawInstance();
    const auto ctl = context && context->GetControlDeck() ? context->GetControlDeck()->GetControllerByPort(0) : nullptr;
    const auto logical = ctl ? ctl->GetButton(slot->button) : nullptr;
    if (!logical) return;
    std::string selected, selectedId;
    bool gamepad = false;
    for (const auto& [key, mapping] : logical->GetAllButtonMappings()) {
        const bool mappedGamepad = mapping->GetMappingType() == MAPPING_TYPE_GAMEPAD;
        if (!selected.empty() && ((!mappedGamepad && gamepad) || (mappedGamepad == gamepad && key >= selectedId))) continue;
        std::string name = CompactLabel(mapping->GetPhysicalInputName());
        if (name.empty()) continue;
        selected = std::move(name);
        selectedId = key;
        gamepad = mappedGamepad;
    }
    if (!selected.empty()) snprintf(label, capacity, "%s", selected.c_str());
}

extern "C" const char* ControllerHud_GetArt(int style, const char* label) {
    const bool wind = style == CONTROLLER_HUD_WIND_WAKER;
    const std::string_view glyph = label ? label : "";
    const auto result = [](const std::string& path) { return path.empty() ? nullptr : path.c_str(); };
    if (glyph == "Dpad") {
        static const auto windDpad = RegisterArt("wind-dpad", MakeWindDpad());
        if (wind) return result(windDpad);
        static const auto restoration = [] {
            auto art = ReadArt("project-restoration.png", AtlasPart::Dpad);
            return RegisterArt("restoration-dpad", art.size ? std::move(art) : MakeSymbol(false));
        }();
        return result(restoration);
    }
    if (glyph.size() == 1 && glyph.find_first_of("<>^v") != glyph.npos) {
        static const std::array<std::array<std::string, 4>, 2> arrows = [] {
            std::array<std::array<std::string, 4>, 2> arts;
            for (int theme = 0; theme < 2; ++theme) {
                for (int i = 0; i < 4; ++i) {
                    const auto path = "arrow-" + std::to_string(theme) + "-" + std::to_string(i);
                    arts[theme][i] = RegisterArt(path.c_str(), MakeSymbol(theme == 1, "<>^v"[i]));
                }
            }
            return arts;
        }();
        return result(arrows[wind][std::string_view("<>^v").find(glyph)]);
    }
    if (!wind) {
        if (glyph == "Tatl-Dpad") {
            static const auto calling = [] {
                auto art = ReadArt("project-restoration.png", AtlasPart::CallingDpad);
                return RegisterArt("restoration-tatl-dpad", art.size ? std::move(art) : MakeSymbol(false, 0, true));
            }();
            return result(calling);
        }
        if (glyph == "Tatl-Fairy") {
            static const auto fairy = RegisterArt("restoration-tatl-fairy",
                                                   ReadArt("project-restoration.png", AtlasPart::Tatl));
            return result(fairy);
        }
        if (glyph == "Tatl-Label") {
            static const auto label = RegisterArt("restoration-tatl-label",
                                                   ReadArt("project-restoration.png", AtlasPart::TatlLabel));
            return result(label);
        }
        if (glyph == "extra-plate") {
            static const auto bumper = RegisterArt("restoration-bumper", ReadArt("restoration-zr.png"));
            return result(bumper);
        }
        static const auto restoration = RegisterArt("restoration-plate", ReadArt("project-restoration.png", AtlasPart::Plate));
        return result(restoration);
    }
    if (glyph.empty()) {
        static const auto blank = RegisterArt("wind-plate", BlankWindPlate("wind-b.png"));
        return result(blank);
    }
    if (glyph == "action-plate") {
        static const auto blank = RegisterArt("wind-action-plate", BlankWindPlate("wind-a.png"));
        return result(blank);
    }
    if (glyph == "extra-plate") {
        static const auto blank = RegisterArt("wind-extra-plate", BlankWindPlate("wind-r.png"));
        return result(blank);
    }

    struct Glyph { const char* label; const char* filename; std::string path; bool tried = false; };
    static Glyph glyphs[] = {
        {"A", "wind-a.png"}, {"B", "wind-b.png"}, {"X", "wind-x.png"}, {"Y", "wind-y.png"},
        {"ZL", "wind-zl.png"}, {"ZR", "wind-zr.png"}, {"R", "wind-r.png"},
    };
    for (auto& entry : glyphs) {
        if (glyph != entry.label) continue;
        if (!entry.tried) {
            entry.tried = true;
            entry.path = RegisterArt(entry.filename, ReadArt(entry.filename));
        }
        return result(entry.path);
    }
    return nullptr;
}

extern "C" int ControllerHud_GetDpadItem(int slot) {
    if (slot == EQUIP_SLOT_D_RIGHT && ControllerHud_GetStyle() == CONTROLLER_HUD_RESTORATION &&
        CVarGetInteger(kRestorationOcarina, 1) && INV_CONTENT(ITEM_OCARINA_OF_TIME) == ITEM_OCARINA_OF_TIME) {
        return ITEM_OCARINA_OF_TIME;
    }
    return DPAD_GET_CUR_FORM_BTN_ITEM(slot);
}

extern "C" const char* ControllerHud_GetRestorationInstrumentArt(int form) {
    if (form != PLAYER_FORM_DEKU && form != PLAYER_FORM_GORON && form != PLAYER_FORM_ZORA) return nullptr;
    static const auto instruments = [] {
        std::array<std::string, 3> paths;
        // Optional user-supplied artwork extracted from Majora's Mask 3D.
        const auto file = std::filesystem::path(Ship::Context::GetAppDirectoryPath()) /
                          "controller-hud" / "restoration-instruments.png";
        int w, h, channels;
        if (!stbi_info(file.string().c_str(), &w, &h, &channels) || w != 512 || h != 512) return paths;
        const ImagePixels atlas(stbi_load(file.string().c_str(), &w, &h, &channels, STBI_rgb_alpha), stbi_image_free);
        if (!atlas || w != 512 || h != 512) return paths;
        constexpr int tile = 42;
        constexpr const char* names[] = { "restoration-deku-pipes", "restoration-goron-drums", "restoration-zora-guitar" };
        for (int i = 0; i < 3; ++i) {
            Art art{tile, std::vector<u8>(tile * tile * 4)};
            for (int y = 0; y < tile; ++y) {
                const int offset = (3 * tile + y) * w + (9 + i) * tile;
                std::copy_n(atlas.get() + 4 * offset, 4 * tile, art.pixels.data() + 4 * y * tile);
            }
            paths[i] = RegisterArt(names[i], std::move(art));
        }
        return paths;
    }();
    const auto& art = instruments[form == PLAYER_FORM_DEKU ? 0 : form == PLAYER_FORM_GORON ? 1 : 2];
    return art.empty() ? nullptr : art.c_str();
}

extern "C" const char* ControllerHud_GetRestorationActionArt(int action, s16* width) {
    struct Prompt {
        int action, x, y, w, h;
    };
    // English action sprites in the official Project Restoration HD HUD atlas.
    constexpr std::array prompts{
        Prompt{ DO_ACTION_ATTACK, 31, 382, 197, 54 },
        Prompt{ DO_ACTION_CHECK, 34, 454, 191, 53 },
        Prompt{ DO_ACTION_OPEN, 46, 670, 146, 68 },
        Prompt{ DO_ACTION_SPEAK, 285, 814, 200, 60 },
        Prompt{ DO_ACTION_PUTAWAY, 518, 453, 245, 64 },
        Prompt{ DO_ACTION_CURL, 834, 382, 125, 54 },
        Prompt{ DO_ACTION_SWIM, 813, 525, 159, 56 },
        Prompt{ DO_ACTION_PUNCH, 804, 598, 188, 53 },
        Prompt{ DO_ACTION_POUND, 799, 669, 194, 54 },
    };
    static const auto textures = [&] {
        std::array<std::string, prompts.size()> paths;
        int w, h;
        const auto rgba = ReadRestorationAtlas(w, h);
        if (!rgba) return paths;
        constexpr int size = 128;
        for (size_t i = 0; i < prompts.size(); ++i) {
            const auto& prompt = prompts[i];
            Art art{size, std::vector<u8>(size * size * 4)};
            for (int y = 0; y < size; ++y) {
                for (int x = 0; x < size; ++x) {
                    const u8* source = rgba.get() + 4 * ((prompt.y + y * prompt.h / size) * w +
                                                        prompt.x + x * prompt.w / size);
                    std::copy_n(source, 4, art.pixels.data() + 4 * (y * size + x));
                }
            }
            const auto name = "restoration-action-" + std::to_string(prompt.action);
            paths[i] = RegisterArt(name.c_str(), std::move(art));
        }
        return paths;
    }();
    for (size_t i = 0; i < prompts.size(); ++i) {
        if (prompts[i].action == action && !textures[i].empty()) {
            *width = std::clamp(6 * prompts[i].w / prompts[i].h, 10, 27);
            return textures[i].c_str();
        }
    }
    return nullptr;
}

extern "C" const char* ControllerHud_GetRestorationLabelArt(const char* label, s16* width) {
    struct LabelArt {
        std::string path;
        s16 width = 0;
    };
    static std::unordered_map<std::string, LabelArt> cache;
    const auto [entry, isNew] = cache.try_emplace(label);
    auto& result = entry->second;
    if (isNew) {
        constexpr int size = 64;
        std::array<u8, size * size> mask{};
        const size_t length = strlen(label);
        // X, Y and A are the actual yellow glyphs from the Restoration texture.
        const std::string_view glyph(label);
        if (glyph == "A" || glyph == "X" || glyph == "Y") {
            int w, h;
            if (const auto rgba = ReadRestorationAtlas(w, h)) {
                const int x0 = glyph == "A" ? 87 : glyph == "X" ? 1932 : 1997;
                const int y0 = glyph == "A" ? 0 : 397;
                for (int y = 4; y < size - 4; ++y) {
                    for (int x = 4; x < size - 4; ++x) {
                        const auto* pixel = rgba.get() + 4 * ((y0 + (y - 4) * 42 / 56) * w +
                                                              x0 + (x - 4) * 43 / 56);
                        mask[y * size + x] = std::min(pixel[3], u8(std::max(0, int(pixel[1]) - pixel[2])));
                    }
                }
                result.width = 5;
            }
        }
        // The atlas does not contain every controller letter. Use our existing
        // HUD font for the extra slot and custom labels, not the debug font.
        if (!result.width && length > 0 && length <= 3) {
            const std::string fontPath = "fonts/Montserrat-Regular.ttf";
            auto init = std::make_shared<Ship::ResourceInitData>();
            init->Format = RESOURCE_FORMAT_BINARY;
            init->Type = static_cast<uint32_t>(RESOURCE_TYPE_FONT);
            init->Path = fontPath;
            const auto font = std::static_pointer_cast<Ship::Font>(
                Ship::Context::GetRawInstance()->GetResourceManager()->LoadResource(fontPath, false, init));
            stbtt_fontinfo info{};
            if (font && font->Data && stbtt_InitFont(&info, reinterpret_cast<const unsigned char*>(font->Data), 0)) {
                const float scale = stbtt_ScaleForPixelHeight(&info, length == 3 ? 30.f : 41.f);
                std::array<u8, size * size> text{};
                int pen = 2, left = size, right = 0, top = size, bottom = 0;
                for (const unsigned char ch : glyph) {
                    int x0, y0, x1, y1, advance, bearing;
                    stbtt_GetCodepointBitmapBox(&info, ch, scale, scale, &x0, &y0, &x1, &y1);
                    stbtt_GetCodepointHMetrics(&info, ch, &advance, &bearing);
                    const int x = pen + x0, y = 44 + y0;
                    const int w = x1 - x0, h = y1 - y0;
                    if (w && h && x >= 0 && x + w <= size && y >= 0 && y + h <= size) {
                        stbtt_MakeCodepointBitmap(&info, text.data() + y * size + x, w, h, size, scale, scale, ch);
                        left = std::min(left, x);
                        right = std::max(right, x + w);
                        top = std::min(top, y);
                        bottom = std::max(bottom, y + h);
                    }
                    pen += int(advance * scale + .5f);
                }
                if (right > left && bottom > top) {
                    for (int y = 4; y < size - 4; ++y) {
                        for (int x = 4; x < size - 4; ++x) {
                            mask[y * size + x] = text[(top + (y - 4) * (bottom - top) / 56) * size +
                                                     left + (x - 4) * (right - left) / 56];
                        }
                    }
                    result.width = std::clamp(5 * (right - left) / (bottom - top), 4, 14);
                }
            }
        }
        if (result.width) {
            Art art{size, std::vector<u8>(size * size * 4)};
            for (int y = 1; y < size - 1; ++y) {
                for (int x = 1; x < size - 1; ++x) {
                    const int i = y * size + x;
                    const int ink = mask[i];
                    int opacity = ink;
                    for (int dy = -2; dy <= 2; ++dy) {
                        for (int dx = -2; dx <= 2; ++dx) {
                            opacity = std::max<int>(opacity, mask[std::clamp(y + dy, 0, size - 1) * size +
                                                                  std::clamp(x + dx, 0, size - 1)]);
                        }
                    }
                    if (!opacity) continue;
                    art.pixels[4 * i] = 255 * ink / opacity;
                    art.pixels[4 * i + 1] = 242 * ink / opacity;
                    art.pixels[4 * i + 2] = 100 * ink / opacity;
                    art.pixels[4 * i + 3] = opacity;
                }
            }
            const auto name = "restoration-label-" + std::string(label);
            result.path = RegisterArt(name.c_str(), std::move(art));
        }
    }
    *width = result.width;
    return result.path.empty() ? nullptr : result.path.c_str();
}

void BenGui::DrawControllerHudOptions() {
    int style = std::clamp(CVarGetInteger("gHudEditor.Controller.Style", 0), 0, 2);
    ImGui::SetNextItemWidth(ImGui::GetFontSize() * 13.f);
    if (ImGui::Combo("Controller HUD", &style, styles, IM_ARRAYSIZE(styles))) {
        const bool oldDpad = ControllerHud_DpadEquipsEnabled();
        SetOption("gHudEditor.Controller.Style", style);
        ShipInit::Init("gHudEditor.Controller.Style");
        if (!oldDpad && ControllerHud_DpadEquipsEnabled() && gPlayState && gPlayState->interfaceCtx.iconItemSegment) {
            for (u8 slot = EQUIP_SLOT_D_RIGHT; slot <= EQUIP_SLOT_D_UP; ++slot) {
                if (DPAD_BUTTON_ITEM_EQUIP(0, slot) < ITEM_F0) Interface_Dpad_LoadItemIconImpl(gPlayState, slot);
            }
        }
    }
    if (!style) return;
    const bool wind = style == CONTROLLER_HUD_WIND_WAKER;
    UIWidgets::CheckboxOptions checkbox;
    checkbox.Color(BenGui::GetMenuThemeColor()).DefaultValue(true);
    UIWidgets::CVarCheckbox("Use preset controller bindings", kPresetBindings, checkbox);
    if (!wind) {
        checkbox.Tooltip("Uses the Ocarina once owned. Your saved D-pad item is kept.");
        UIWidgets::CVarCheckbox("Ocarina on D-pad Right", kRestorationOcarina, checkbox);
    }
    if (CVarGetInteger(kPresetBindings, 1)) {
        ImGui::TextWrapped(wind ? "X, Y, and R use items. ZR shields. ZL targets."
                                : "X, Y, and ZR use items. R shields. ZL targets.");
        ImGui::TextWrapped("Right stick click calls Tatl (Back if unavailable). Your saved bindings are kept.");
    } else if (wind) {
        ImGui::TextWrapped("The default Wind Waker labels may not match your controller bindings.");
    }
    int mode = wind ? std::clamp(CVarGetInteger(kLabelMode, 0), 0, 2) : GetRestorationLabelMode();
    ImGui::SetNextItemWidth(ImGui::GetFontSize() * 9.f);
    if (ImGui::Combo("Button Labels", &mode, wind ? windLabelModes : restorationLabelModes,
                     wind ? IM_ARRAYSIZE(windLabelModes) : IM_ARRAYSIZE(restorationLabelModes))) {
        SetOption(wind ? kLabelMode : kRestorationLabelMode, mode);
    }
    if (mode == (wind ? 1 : REST_LABEL_CUSTOM)) {
        for (const auto& slot : slots) {
            if (!slot.labelCvar) continue;
            int label = std::clamp(CVarGetInteger(slot.labelCvar, 0), 0, int(std::size(labels)) - 1);
            ImGui::SetNextItemWidth(ImGui::GetFontSize() * 5.f);
            const char* name = wind ? windNames[&slot - slots.data()] : slot.name;
            if (ImGui::Combo(name, &label, labels, IM_ARRAYSIZE(labels))) SetOption(slot.labelCvar, label);
        }
    }
    if (!wind || mode == 1) ImGui::TextUnformatted("Button labels only change the display.");
    ImGui::TextUnformatted("D-Pad item shortcuts are enabled by this preset.");
    ImGui::TextWrapped("For physical controllers. Turn off or hide touch controls to see this HUD.");
}
