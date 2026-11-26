#include "CloudSyncPolicy.h"
#include <cassert>

int main() {
    using TwoShipCloud::Action;
    using TwoShipCloud::IsSharedPath;
    using TwoShipCloud::IsUserPath;
    using TwoShipCloud::Plan;

    assert(Plan("same", "same", "") == Action::None);
    assert(Plan("local", "", "") == Action::Upload);
    assert(Plan("", "remote", "") == Action::Download);
    assert(Plan("local", "remote", "") == Action::Conflict);
    assert(Plan("base", "remote", "base") == Action::Download);
    assert(Plan("local", "base", "base") == Action::Upload);
    assert(Plan("local", "remote", "base") == Action::Conflict);

    assert(IsUserPath("mods/MM Reloaded.o2r"));
    assert(IsUserPath("mm.o2r"));
    assert(!IsUserPath("../mm.o2r"));
    assert(!IsUserPath("mods/../mm.o2r"));
    assert(!IsUserPath("/mm.o2r"));
    assert(!IsUserPath("mods//pack.o2r"));
    assert(!IsUserPath("mods\\pack.o2r"));
    assert(!IsUserPath(".icloud-sync/CloudKit"));
    assert(!IsUserPath("Conflicts/settings.json"));
    assert(!IsUserPath("logs/2 Ship 2 Harkinian.log"));
    assert(!IsUserPath("signing.mobileprovision"));

    assert(IsSharedPath("2ship2harkinian.json"));
    assert(IsSharedPath("saves/global.json"));
    assert(IsSharedPath("saves/file3.json"));
    assert(IsSharedPath("saves/file2backup.json"));
    assert(IsSharedPath("saves/picto1.png"));
    assert(IsSharedPath("randomizer/settings/preset.json"));
    assert(!IsSharedPath("saves/file4.json"));
    assert(!IsSharedPath("saves/file1/extra.json"));
    assert(!IsSharedPath("mods/MM Reloaded.o2r"));
    assert(!IsSharedPath("mm.o2r"));

    using TwoShipCloud::Category;
    using TwoShipCloud::FileCategory;
    using TwoShipCloud::SelectedPath;
    constexpr unsigned json = static_cast<unsigned>(Category::JSON);
    constexpr unsigned saves = static_cast<unsigned>(Category::Saves);
    constexpr unsigned mods = static_cast<unsigned>(Category::Mods);

    assert(FileCategory("2ship2harkinian.json") == Category::JSON);
    assert(FileCategory("presets/preset.json") == Category::JSON);
    assert(FileCategory("saves/global.json") == Category::Saves);
    assert(FileCategory("saves/picto1.png") == Category::Saves);
    assert(FileCategory("mods/graphics/MM Reloaded.o2r") == Category::Mods);
    assert(!SelectedPath("2ship2harkinian.json", saves | mods));
    assert(!SelectedPath("saves/file1.json", json | mods));
    assert(!SelectedPath("mods/HD.o2r", json | saves));
    assert(SelectedPath("mods/HD.o2r", mods));
    assert(!SelectedPath("mods/HD.o2r", 0));
    assert(!SelectedPath("mods/../HD.o2r", mods));
    assert(!SelectedPath("mods/.HD.o2r.icloud", mods));
    assert(!SelectedPath("mm.o2r", json | saves | mods));
    using TwoShipCloud::CanChooseConflictMember;
    using TwoShipCloud::SaveSlotGroup;
    assert(SaveSlotGroup("saves/file1.json") == SaveSlotGroup("saves/file1backup.json"));
    assert(SaveSlotGroup("saves/file2backup.json") == "saves/file2.json");
    assert(SaveSlotGroup("saves/file3backup.json") == "saves/file3.json");
    assert(SaveSlotGroup("saves/global.json").empty());
    assert(SaveSlotGroup("saves/picto1.png").empty());
    assert(CanChooseConflictMember("chosen", "other"));
    assert(CanChooseConflictMember("", ""));
    assert(!CanChooseConflictMember("", "other"));
    using TwoShipCloud::IsDriveDeletion;
    assert(IsDriveDeletion(true, false, false, true));
    assert(!IsDriveDeletion(false, false, false, true)); // Never uploaded to Drive.
    assert(!IsDriveDeletion(true, false, true, true));   // Cloud-only placeholder.
    assert(!IsDriveDeletion(true, true, false, true));   // Still in the Drive folder.
    assert(!IsDriveDeletion(true, false, false, false)); // No complete inventory.
    assert(!TwoShipCloud::DriveDeletionConfirmed(0, 60));  // Never observed missing.
    assert(!TwoShipCloud::DriveDeletionConfirmed(10, 39));
    assert(TwoShipCloud::DriveDeletionConfirmed(10, 40));
    assert(!TwoShipCloud::DriveDeletionConfirmed(40, 10)); // Clock moved backwards.
}
