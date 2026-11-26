#pragma once

#include <string>

enum class TwoShipIOSSetupAction { Waiting, OpenPicker, ArchivePicked, Cancelled, Exit, Unavailable };

void TwoShipIOS_ShowArchiveSetup(const char* error);
void TwoShipIOS_OpenArchivePicker();
TwoShipIOSSetupAction TwoShipIOS_PollArchiveSetup(std::string& archivePath);
const char* TwoShipIOS_ImportGameArchive(const std::string& source, const std::string& destination);
