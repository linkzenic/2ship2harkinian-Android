#include "ship/port/mobile/CrashFrameWalker.h"
#include <array>
#include <cassert>
#include <cstring>

int main() {
    alignas(16) std::array<uintptr_t, 160> records{};
    const auto low = reinterpret_cast<uintptr_t>(records.data());
    const auto high = low + sizeof(records);
    size_t emitted = 0;
    const auto read = [&](uintptr_t address, void* destination, size_t size) {
        assert(address >= low && address <= high - size);
        std::memcpy(destination, reinterpret_cast<void*>(address), size);
        return true;
    };
    const auto emit = [&](uintptr_t) { ++emitted; };
    for (size_t i = 0; i < 80; ++i) {
        records[i * 2] = low + (i + 1) * 16;
        records[i * 2 + 1] = 0x1000 + i * 4;
    }
    assert(Ship::CrashDiagnostics::WalkFrames(low, low, high, read, emit) == 64);
    assert(emitted == 64);
    assert(Ship::CrashDiagnostics::WalkFrames(low - 16, low, high, read, emit) == 0);
    assert(Ship::CrashDiagnostics::WalkFrames(low + 1, low, high, read, emit) == 0);
    assert(Ship::CrashDiagnostics::WalkFrames(high, low, high, read, emit) == 0);
    assert(Ship::CrashDiagnostics::WalkFrames(low, high, low, read, emit) == 0);
    records[0] = low; // Self-cycle.
    assert(Ship::CrashDiagnostics::WalkFrames(low, low, high, read, emit) == 1);
    records[0] = low - 16; // Backward/corrupted frame.
    assert(Ship::CrashDiagnostics::WalkFrames(low, low, high, read, emit) == 1);
    const auto unreadable = [](uintptr_t, void*, size_t) { return false; };
    assert(Ship::CrashDiagnostics::WalkFrames(low, low, high, unreadable, emit) == 0);
}
