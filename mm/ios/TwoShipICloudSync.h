#pragma once

#include <stddef.h>
#include <string>
#include <vector>
#include "CloudSyncPolicy.h"

bool TwoShipICloudSync_Enabled();
void TwoShipICloudSync_SetEnabled(bool enabled);
unsigned TwoShipICloudSync_Selection();
bool TwoShipICloudSync_CategoryEnabled(TwoShipCloud::Category category);
void TwoShipICloudSync_SetCategoryEnabled(TwoShipCloud::Category category, bool enabled);
void TwoShipICloudSync_ApplyAtLaunch();
void TwoShipICloudSync_Start();
void TwoShipICloudSync_SyncNow();
void TwoShipICloudSync_GetStatus(char* buffer, size_t bufferSize);

struct TwoShipCloudConflict {
    std::string path;
    std::string revision;
    bool canKeepLocal;
    bool canUseCloud;
    bool queued;
};

std::vector<TwoShipCloudConflict> TwoShipICloudSync_GetConflicts();
bool TwoShipICloudSync_ChooseConflict(const std::string& path, const std::string& revision, bool useCloud);
