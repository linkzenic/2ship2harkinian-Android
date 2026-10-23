#include "fast/ColorCombinerKey.h"

#include <cassert>
#include <cstring>
#include <map>
#include <new>

static_assert(ColorCombinerKey{}.shader_id == 0);
static_assert(ColorCombinerKey{ 1, 2 } == ColorCombinerKey{ 1, 2, 0 });
static_assert(ColorCombinerKey{ 1, 2, 0 } != ColorCombinerKey{ 1, 2, 1 });

int main() {
    std::map<ColorCombinerKey, int> cache;
    for (int pattern = 0; pattern < 256; ++pattern) {
        alignas(ColorCombinerKey) unsigned char storage[sizeof(ColorCombinerKey)];
        std::memset(storage, pattern, sizeof(storage));
        auto* key = new (storage) ColorCombinerKey;
        key->combine_mode = 123;
        key->options = 456;
        assert(key->shader_id == 0);
        cache.emplace(*key, pattern);
        key->~ColorCombinerKey();
    }
    assert(cache.size() == 1);
    cache.emplace(ColorCombinerKey{ 124, 456 }, 0);
    cache.emplace(ColorCombinerKey{ 123, 457 }, 0);
    cache.emplace(ColorCombinerKey{ 123, 456, 1 }, 0);
    assert(cache.size() == 4);
}
