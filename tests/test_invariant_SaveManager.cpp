#include <gtest/gtest.h>
#include <string>
#include <vector>
#include <cstring>
#include <cstdint>
#include <stdexcept>
#include <algorithm>

// Simulated minimal struct definitions mirroring the vulnerable code's types
// These represent the fixed-size destination structs used in memcpy calls

#pragma pack(push, 1)
struct SaveOptions {
    uint8_t data[64]; // representative fixed-size struct
};

struct Save {
    uint8_t data[256]; // representative fixed-size struct
};

struct SaveContext {
    uint8_t header[16];
    uint32_t fileNum;
    uint8_t rest[512];
};
#pragma pack(pop)

// Safe copy function that enforces the security invariant:
// MUST validate that source buffer is at least as large as destination before copying
bool safeCopyToStruct(const std::vector<uint8_t>& sourceBuffer, void* dest, size_t destSize) {
    if (sourceBuffer.size() < destSize) {
        return false; // Refuse to copy: would read out-of-bounds
    }
    memcpy(dest, sourceBuffer.data(), destSize);
    return true;
}

// Simulates the save loading logic with bounds checking
class SaveLoader {
public:
    bool loadSaveOptions(const std::vector<uint8_t>& saveBuffer, SaveOptions& out) {
        return safeCopyToStruct(saveBuffer, &out, sizeof(SaveOptions));
    }

    bool loadSave(const std::vector<uint8_t>& saveBuffer, Save& out) {
        return safeCopyToStruct(saveBuffer, &out, sizeof(Save));
    }

    bool loadSaveContext(const std::vector<uint8_t>& saveBuffer, SaveContext& out) {
        // offsetof(SaveContext, fileNum) equivalent check
        size_t minRequired = offsetof(SaveContext, fileNum) + sizeof(uint32_t);
        if (saveBuffer.size() < minRequired) {
            return false;
        }
        if (saveBuffer.size() < sizeof(SaveContext)) {
            return false;
        }
        memcpy(&out, saveBuffer.data(), sizeof(SaveContext));
        return true;
    }
};

// Helper to build a payload vector from a string descriptor
std::vector<uint8_t> buildPayload(const std::string& descriptor) {
    if (descriptor == "empty") {
        return {};
    } else if (descriptor == "one_byte") {
        return {0xFF};
    } else if (descriptor == "all_zeros_small") {
        return std::vector<uint8_t>(4, 0x00);
    } else if (descriptor == "all_ff_small") {
        return std::vector<uint8_t>(8, 0xFF);
    } else if (descriptor == "save_options_minus_one") {
        return std::vector<uint8_t>(sizeof(SaveOptions) - 1, 0xAA);
    } else if (descriptor == "save_minus_one") {
        return std::vector<uint8_t>(sizeof(Save) - 1, 0xBB);
    } else if (descriptor == "save_context_minus_one") {
        return std::vector<uint8_t>(sizeof(SaveContext) - 1, 0xCC);
    } else if (descriptor == "exactly_save_options") {
        return std::vector<uint8_t>(sizeof(SaveOptions), 0x42);
    } else if (descriptor == "exactly_save") {
        return std::vector<uint8_t>(sizeof(Save), 0x43);
    } else if (descriptor == "exactly_save_context") {
        return std::vector<uint8_t>(sizeof(SaveContext), 0x44);
    } else if (descriptor == "oversized") {
        return std::vector<uint8_t>(sizeof(SaveContext) * 4, 0x55);
    } else if (descriptor == "half_save_options") {
        return std::vector<uint8_t>(sizeof(SaveOptions) / 2, 0xDE);
    } else if (descriptor == "null_bytes_partial") {
        return std::vector<uint8_t>(3, 0x00);
    } else if (descriptor == "pattern_small") {
        std::vector<uint8_t> v;
        for (int i = 0; i < 10; i++) v.push_back(static_cast<uint8_t>(i));
        return v;
    } else if (descriptor == "filenum_offset_minus_one") {
        size_t target = offsetof(SaveContext, fileNum);
        if (target == 0) return {};
        return std::vector<uint8_t>(target - 1, 0xEE);
    } else if (descriptor == "filenum_offset_exact") {
        size_t target = offsetof(SaveContext, fileNum) + sizeof(uint32_t);
        return std::vector<uint8_t>(target, 0xFF);
    } else if (descriptor == "max_attack_pattern") {
        std::vector<uint8_t> v(sizeof(SaveOptions) - 1);
        for (size_t i = 0; i < v.size(); i++) {
            v[i] = static_cast<uint8_t>(0x41 + (i % 26));
        }
        return v;
    }
    return {};
}

class SecurityTest : public ::testing::TestWithParam<std::string> {};

TEST_P(SecurityTest, SaveManagerBoundsCheckInvariant) {
    // Invariant: memcpy into fixed-size structs MUST NOT proceed when the source
    // buffer is smaller than the destination struct size. The loader must reject
    // undersized buffers and never read out-of-bounds from the source.

    std::string descriptor = GetParam();
    std::vector<uint8_t> payload = buildPayload(descriptor);

    SaveLoader loader;
    SaveOptions saveOptions{};
    Save save{};
    SaveContext saveContext{};

    // Fill destinations with sentinel values to detect partial/corrupt writes
    memset(&saveOptions, 0xCD, sizeof(SaveOptions));
    memset(&save, 0xCD, sizeof(Save));
    memset(&saveContext, 0xCD, sizeof(SaveContext));

    bool optionsResult = loader.loadSaveOptions(payload, saveOptions);
    bool saveResult = loader.loadSave(payload, save);
    bool contextResult = loader.loadSaveContext(payload, saveContext);

    // INVARIANT 1: If buffer is smaller than SaveOptions, load MUST fail
    if (payload.size() < sizeof(SaveOptions)) {
        EXPECT_FALSE(optionsResult)
            << "SECURITY VIOLATION: SaveOptions loaded from undersized buffer ("
            << payload.size() << " < " << sizeof(SaveOptions) << ") for payload: " << descriptor;
    }

    // INVARIANT 2: If buffer is smaller than Save, load MUST fail
    if (payload.size() < sizeof(Save)) {
        EXPECT_FALSE(saveResult)
            << "SECURITY VIOLATION: Save loaded from undersized buffer ("
            << payload.size() << " < " << sizeof(Save) << ") for payload: " << descriptor;
    }

    // INVARIANT 3: If buffer is smaller than SaveContext, load MUST fail
    if (payload.size() < sizeof(SaveContext)) {
        EXPECT_FALSE(contextResult)
            << "SECURITY VIOLATION: SaveContext loaded from undersized buffer ("
            << payload.size() << " < " << sizeof(SaveContext) << ") for payload: " << descriptor;
    }

    // INVARIANT 4: If buffer is smaller than offsetof(SaveContext, fileNum) + sizeof(fileNum),
    // context load MUST fail
    size_t minContextRequired = offsetof(SaveContext, fileNum) + sizeof(uint32_t);
    if (payload.size() < minContextRequired) {
        EXPECT_FALSE(contextResult)
            << "SECURITY VIOLATION: SaveContext loaded without sufficient data for fileNum field ("
            << payload.size() << " < " << minContextRequired << ") for payload: " << descriptor;
    }

    // INVARIANT 5: Successful loads MUST only occur when buffer is large enough
    if (optionsResult) {
        EXPECT_GE(payload.size(), sizeof(SaveOptions))
            << "SECURITY VIOLATION: SaveOptions reported success with insufficient buffer for payload: "
            << descriptor;
    }

    if (saveResult) {
        EXPECT_GE(payload.size(), sizeof(Save))
            << "SECURITY VIOLATION: Save reported success with insufficient buffer for payload: "
            << descriptor;
    }

    if (contextResult) {
        EXPECT_GE(payload.size(), sizeof(SaveContext))
            << "SECURITY VIOLATION: SaveContext reported success with insufficient buffer for payload: "
            << descriptor;
        EXPECT_GE(payload.size(), minContextRequired)
            << "SECURITY VIOLATION: SaveContext success without fileNum coverage for payload: "
            << descriptor;
    }

    // INVARIANT 6: Sentinel bytes in destination must remain intact on failed loads
    // (no partial writes should corrupt the destination)
    if (!optionsResult) {
        uint8_t sentinel[sizeof(SaveOptions)];
        memset(sentinel, 0xCD, sizeof(SaveOptions));
        EXPECT_EQ(0, memcmp(&saveOptions, sentinel, sizeof(SaveOptions)))
            << "SECURITY VIOLATION: SaveOptions destination was partially corrupted on failed load for payload: "
            << descriptor;
    }

    if (!saveResult) {
        uint8_t sentinel[sizeof(Save)];
        memset(sentinel, 0xCD, sizeof(Save));
        EXPECT_EQ(0, memcmp(&save, sentinel, sizeof(Save)))
            << "SECURITY VIOLATION: Save destination was partially corrupted on failed load for payload: "
            << descriptor;
    }

    if (!contextResult) {
        uint8_t sentinel[sizeof(SaveContext)];
        memset(sentinel, 0xCD, sizeof(SaveContext));
        EXPECT_EQ(0, memcmp(&saveContext, sentinel, sizeof(SaveContext)))
            << "SECURITY VIOLATION: SaveContext destination was partially corrupted on failed load for payload: "
            << descriptor;
    }
}

INSTANTIATE_TEST_SUITE_P(
    AdversarialInputs,
    SecurityTest,
    ::testing::Values(
        "empty",
        "one_byte",
        "all_zeros_small",
        "all_ff_small",
        "save_options_minus_one",
        "save_minus_one",
        "save_context_minus_one",
        "exactly_save_options",
        "exactly_save",
        "exactly_save_context",
        "oversized",
        "half_save_options",
        "null_bytes_partial",
        "pattern_small",
        "filenum_offset_minus_one",
        "filenum_offset_exact",
        "max_attack_pattern"
    )
);

int main(int argc, char **argv) {
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}