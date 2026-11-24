#include "BenModals.h"
#include <imgui.h>
#include <vector>
#include <string>
#include "UIWidgets.hpp"
#include "BenGui.hpp"

struct BenModal {
    std::string title_;
    std::string message_;
    std::string button1_;
    std::string button2_;
    std::function<void()> button1callback_;
    std::function<void()> button2callback_;
};
std::vector<BenModal> modals;

bool closePopup = false;

#ifdef __ANDROID__
#include <atomic>
#include <jni.h>
#include <ship/Context.h>
#include <ship/window/Window.h>
#include <ship/window/gui/Gui.h>

enum TouchGuiMode { Gameplay, MenuOpen, PopupOpen };
static std::atomic<int> touchGuiMode{Gameplay};
extern "C" JNIEXPORT jint JNICALL Java_com_twoshipfork_mm_MainActivity_guiTouchMode(JNIEnv*, jobject) {
    return touchGuiMode.load();
}
#endif

void BenModalWindow::Draw() {
#ifdef __ANDROID__
    // This window is drawn in both the extractor's GUI-only loop and normal gameplay.
    bool popup = !modals.empty() || ImGui::IsPopupOpen(nullptr, ImGuiPopupFlags_AnyPopupId | ImGuiPopupFlags_AnyPopupLevel);
    touchGuiMode = popup ? PopupOpen : Ship::Context::GetRawInstance()->GetWindow()->GetGui()->GetMenuOrMenubarVisible() ? MenuOpen : Gameplay;
#endif
    if (!IsVisible()) {
        return;
    }
    DrawElement();
    // Sync up the IsVisible flag if it was changed by ImGui
    SyncVisibilityConsoleVariable();
}

void BenModalWindow::DrawElement() {
    if (modals.size() > 0) {
        BenModal curModal = modals.at(0);
        if (!ImGui::IsPopupOpen(curModal.title_.c_str())) {
            ImGui::OpenPopup(curModal.title_.c_str());
        }
        if (closePopup) {
            ImGui::CloseCurrentPopup();
            modals.erase(modals.begin());
            closePopup = false;
        }
        const ImGuiViewport* viewport = ImGui::GetMainViewport();
        const ImVec2 workCenter =
            ImVec2(viewport->WorkPos.x + viewport->WorkSize.x * 0.5f,
                   viewport->WorkPos.y + viewport->WorkSize.y * 0.5f);
        ImGui::SetNextWindowPos(workCenter, ImGuiCond_Always, ImVec2(0.5f, 0.5f));
        ImGui::SetNextWindowSizeConstraints(
            ImVec2(0.0f, 0.0f), ImVec2(viewport->WorkSize.x * 0.9f, viewport->WorkSize.y * 0.9f));
        if (ImGui::BeginPopupModal(curModal.title_.c_str(), NULL,
                                   ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoResize |
                                       ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings)) {
            ImGui::PushTextWrapPos(ImGui::GetCursorPosX() + viewport->WorkSize.x * 0.8f);
            ImGui::TextWrapped("%s", curModal.message_.c_str());
            ImGui::PopTextWrapPos();
            UIWidgets::PushStyleButton(THEME_COLOR);
            if (ImGui::Button(curModal.button1_.c_str())) {
                if (curModal.button1callback_ != nullptr) {
                    curModal.button1callback_();
                }
                ImGui::CloseCurrentPopup();
                modals.erase(modals.begin());
            }
            UIWidgets::PopStyleButton();
            if (curModal.button2_ != "") {
                ImGui::SameLine();
                UIWidgets::PushStyleButton(THEME_COLOR);
                if (ImGui::Button(curModal.button2_.c_str())) {
                    if (curModal.button2callback_ != nullptr) {
                        curModal.button2callback_();
                    }
                    ImGui::CloseCurrentPopup();
                    modals.erase(modals.begin());
                }
                UIWidgets::PopStyleButton();
            }
            ImGui::EndPopup();
        }
    }
}

void BenModalWindow::RegisterPopup(std::string title, std::string message, std::string button1, std::string button2,
                                   std::function<void()> button1callback, std::function<void()> button2callback) {
    modals.push_back({ title, message, button1, button2, button1callback, button2callback });
}

size_t BenModalWindow::PopupsQueued() {
    return modals.size();
}

bool BenModalWindow::IsPopupOpen(std::string title) {
    return !modals.empty() && modals.at(0).title_ == title;
}

void BenModalWindow::DismissPopup() {
    closePopup = true;
}
