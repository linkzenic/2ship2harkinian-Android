#pragma once

#include <string_view>

namespace TwoShipCloud {
enum class Action { None, Upload, Download, Conflict };
enum class Category : unsigned { None = 0, JSON = 1, Saves = 2, Mods = 4 };

inline bool Includes(unsigned selection, Category category) {
    return (selection & static_cast<unsigned>(category)) != 0;
}

// A baseline is content both sides have seen, not a device clock.
inline Action Plan(std::string_view local, std::string_view remote, std::string_view baseline) {
    if (local == remote) return Action::None;
    if (local.empty()) return Action::Download;
    if (remote.empty()) return Action::Upload;
    if (baseline.empty()) return Action::Conflict;
    if (local == baseline) return Action::Download;
    if (remote == baseline) return Action::Upload;
    return Action::Conflict;
}

inline bool IsUserPath(std::string_view path) {
    if (path.empty() || path.back() == '/' || path.find('\\') != path.npos || path.find('\0') != path.npos) return false;
    for (auto rest = path; !rest.empty();) {
        const auto slash = rest.find('/');
        const auto part = rest.substr(0, slash);
        if (part.empty() || part.front() == '.' || part == "logs" || part == "tmp" ||
            part == "cache" || part == "Caches" || part == "Conflicts") return false;
        if (slash == rest.npos) break;
        rest.remove_prefix(slash + 1);
    }
    return !path.ends_with(".log") && !path.ends_with(".lock") && !path.ends_with(".tmp") &&
           !path.ends_with(".icloud") && !path.ends_with(".bak") &&
           !path.ends_with(".mobileprovision") && !path.ends_with(".p12") && !path.ends_with(".pem");
}

inline bool IsSharedPath(std::string_view path) {
    if (!IsUserPath(path)) return false;
    if (path == "2ship2harkinian.json" || path == "2S2HTimeSplitData.json" || path == "saves/global.json") return true;
    if ((path.starts_with("presets/") || path.starts_with("randomizer/")) && path.ends_with(".json")) return true;
    if (!path.starts_with("saves/")) return false;
    const auto name = path.substr(6);
    return (name.starts_with("file") && name.size() >= 6 && name[4] >= '1' && name[4] <= '3' &&
            (name.substr(5) == ".json" || name.substr(5) == "backup.json")) ||
           (name.starts_with("picto") && name.size() == 10 && name[5] >= '1' && name[5] <= '3' && name.substr(6) == ".png");
}

inline Category FileCategory(std::string_view path) {
    if (IsSharedPath(path)) return path.starts_with("saves/") ? Category::Saves : Category::JSON;
    if (IsUserPath(path) && path.starts_with("mods/")) return Category::Mods;
    return Category::None;
}

inline bool SelectedPath(std::string_view path, unsigned selection) {
    return Includes(selection, FileCategory(path));
}

// The slot and its backup must never be resolved independently.
inline std::string_view SaveSlotGroup(std::string_view path) {
    if (path == "saves/file1.json" || path == "saves/file1backup.json") return "saves/file1.json";
    if (path == "saves/file2.json" || path == "saves/file2backup.json") return "saves/file2.json";
    if (path == "saves/file3.json" || path == "saves/file3backup.json") return "saves/file3.json";
    return {};
}

inline bool CanChooseConflictMember(std::string_view chosen, std::string_view other) {
    // Don't splice in the other device's backup when this copy is incomplete.
    return !chosen.empty() || other.empty();
}

// A missing cloud file is a deletion only after this account has seen it
// uploaded to Drive, and a complete Drive inventory confirms its absence.
inline bool IsDriveDeletion(bool knownInDrive, bool inDirectory, bool inMetadata, bool inventoryReady) {
    return knownInDrive && !inDirectory && !inMetadata && inventoryReady;
}

inline bool DriveDeletionConfirmed(double firstMissing, double now) {
    return firstMissing > 0 && now - firstMissing >= 30;
}
}
