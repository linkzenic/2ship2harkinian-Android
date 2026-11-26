#pragma once

enum class TwoShipTVOSSetupAction { Waiting, Continue, Exit, Unavailable };

void TwoShipTVOS_ShowSetupPrompt(const char* message, const char* actionTitle);
TwoShipTVOSSetupAction TwoShipTVOS_PollSetupAction();
