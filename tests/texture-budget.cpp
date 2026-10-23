#include "fast/TextureBudget.h"
#include <cassert>

int main() {
    constexpr uint64_t MiB = 1024 * 1024;
    constexpr uint64_t GiB = 1024 * MiB;
    assert(Fast::TextureBudgetBytes(0) == 128 * MiB);
    assert(Fast::TextureBudgetBytes(16 * GiB, -1) == UINT64_MAX);
    assert(Fast::TextureBudgetBytes(4 * GiB) == 128 * MiB);
    assert(Fast::TextureBudgetBytes(8 * GiB) == 256 * MiB);
    assert(Fast::TextureBudgetBytes(16 * GiB) == 512 * MiB);
    assert(Fast::TextureBudgetBytes(32 * GiB) == 512 * MiB);
    assert(Fast::TextureBudgetBytes(16 * GiB, 128) == 128 * MiB);
    assert(Fast::TextureBudgetBytes(16 * GiB, 1) == 64 * MiB);
    assert(Fast::TextureBudgetBytes(16 * GiB, 4096) == 512 * MiB);
    assert(Fast::TextureStorageBytes(1024, 1024) == 4 * MiB);
    assert(Fast::TextureStorageBytes(8192, 8192) == 256 * MiB);
    assert(!Fast::TextureCanBeEvicted(10, 10, false));
    assert(!Fast::TextureCanBeEvicted(9, 10, true));
    assert(!Fast::TextureCanBeEvicted(9, 10, false));
    assert(!Fast::TextureCanBeEvicted(9, 68, false));
    assert(Fast::TextureCanBeEvicted(9, 69, false));
    assert(!Fast::TextureCanBeEvicted(9, 69, true));
}
