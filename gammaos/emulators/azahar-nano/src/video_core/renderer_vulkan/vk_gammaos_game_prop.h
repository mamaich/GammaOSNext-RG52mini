// GammaOS per game switches for the renderer.
//
// The frontend publishes a game's override values (or the global ones when the override
// has no line) as sys.gammaos.azahar_nano.<key> at every launch; the persist prop is the
// fallback (tests set it). Read once at startup by the code that latches a switch.
#pragma once

#include <cstdio>
#include <cstring>
#include <sys/system_properties.h>
#include "common/common_types.h"
#include "common/logging/log.h"
#include "core/core.h"
#include "core/loader/loader.h"

namespace GammaGameProp {

inline void Get(const char* key, char* out /* PROP_VALUE_MAX */) {
    char name[128] = {};   // longer than PROP_NAME_MAX: these names are over 32 characters
    std::snprintf(name, sizeof(name), "sys.gammaos.azahar_nano.%s", key);
    out[0] = '\0';
    __system_property_get(name, out);
    if (out[0] == '\0') {
        std::snprintf(name, sizeof(name), "persist.gammaos.azahar_nano.%s", key);
        __system_property_get(name, out);
    }
}

// RG52 Mini: switches some games need, by title ID (from the dArkOS port's patch 013, which
// sets the same ones there). They apply only when neither the game's value nor the persist prop
// is set, so either set to 0 still turns a switch off. Other releases of a game have title IDs
// of their own: the log line below shows the one a game got its defaults for.
struct TitleDefault {
    u64 program_id;
    const char* key;
    const char* value;
};
inline constexpr TitleDefault kTitleDefaults[] = {
    // Castlevania: Lords of Shadow - Mirror of Fate draws the two eyes object by object, a
    // render pass for each draw on the Mali GPU, and flushes the cache before each of its
    // command lists. Its intro on an RG52 Mini (dArkOS): 9.2 fps, 11.1 with stereo_skip, 14.4
    // with the flush lag as well, 20-22 with no copies out of the right eye (AccelerateTextureCopy).
    {0x000400000009E500, "stereo_skip", "1"},
    {0x000400000009E500, "async_gpu_flush_lag", "24"},
};

/// Get, then the game's default from kTitleDefaults when nothing is set.
inline void GetOrTitleDefault(const char* key, char* out /* PROP_VALUE_MAX */) {
    Get(key, out);
    if (out[0] != '\0') {
        return;
    }
    u64 program_id = 0;
    if (Core::System::GetInstance().GetAppLoader().ReadProgramId(program_id) !=
        Loader::ResultStatus::Success) {
        return;
    }
    for (const auto& d : kTitleDefaults) {
        if (d.program_id == program_id && std::strcmp(d.key, key) == 0) {
            std::snprintf(out, PROP_VALUE_MAX, "%s", d.value);
            LOG_INFO(HW_GPU, "title {:016X}: {}={} (the game's default)", program_id, key,
                     d.value);
            return;
        }
    }
}

} // namespace GammaGameProp
