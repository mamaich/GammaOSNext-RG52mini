// GammaOS RG52 Mini: HDMI в режиме nano - копия основного экрана. См. NanoExtMirror.h.

#define LOG_TAG "GammaOSNano"

#include "NanoExtMirror.h"

#include <dirent.h>
#include <inttypes.h>
#include <unistd.h>

#include <climits>
#include <cstring>
#include <fstream>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include <cutils/properties.h>
#include <gui/SurfaceComposerClient.h>
#include <gui/SurfaceControl.h>
#include <ui/DisplayMode.h>
#include <ui/DisplayState.h>
#include <ui/StaticDisplayInfo.h>
#include <utils/Log.h>

namespace android {

namespace {

// Свой стек слоёв для HDMI: не пересекается ни со стеками DisplayManager (0, 1, 2...),
// ни со стеком виртуального дисплея часов PSP.
constexpr uint32_t kExtLayerStack = 0x52473532;  // "RG52"
constexpr int kPowerOff = 0;                     // IComposerClient PowerMode
constexpr int kPowerOn = 2;

std::once_flag sStartOnce;

std::optional<PhysicalDisplayId> externalDisplay() {
    for (const PhysicalDisplayId& id : SurfaceComposerClient::getPhysicalDisplayIds()) {
        ui::StaticDisplayInfo info;
        if (SurfaceComposerClient::getStaticDisplayInfo(static_cast<int64_t>(id.value), &info) ==
                    NO_ERROR &&
            info.connectionType == ui::DisplayConnectionType::External) {
            return id;
        }
    }
    return std::nullopt;
}

std::optional<PhysicalDisplayId> displayIdOf(const sp<IBinder>& token) {
    for (const PhysicalDisplayId& id : SurfaceComposerClient::getPhysicalDisplayIds()) {
        if (SurfaceComposerClient::getPhysicalDisplayToken(id) == token) return id;
    }
    return std::nullopt;
}

// src, вписанный в dst с сохранением пропорций, по центру.
Rect fitRect(ui::Size src, ui::Size dst) {
    if (src.width <= 0 || src.height <= 0) return Rect(dst.width, dst.height);
    int w = dst.width, h = dst.height;
    if (static_cast<int64_t>(dst.width) * src.height > static_cast<int64_t>(dst.height) * src.width) {
        w = static_cast<int>(static_cast<int64_t>(dst.height) * src.width / src.height);
    } else {
        h = static_cast<int>(static_cast<int64_t>(dst.width) * src.height / src.width);
    }
    const int x = (dst.width - w) / 2, y = (dst.height - h) / 2;
    return Rect(x, y, x + w, y + h);
}

bool screenOff() {
    char v[PROPERTY_VALUE_MAX] = {};
    property_get("sys.screen.state", v, "on");
    return strcmp(v, "off") == 0;
}

// Как копия стоит сейчас: стек слоёв, размер источника, куда вписана.
struct Placement {
    ui::LayerStack stack = ui::INVALID_LAYER_STACK;
    ui::Size src;
    Rect dst;
    bool operator==(const Placement& o) const {
        return stack == o.stack && src == o.src && dst == o.dst;
    }
};

void mirrorLoop(sp<SurfaceComposerClient> session, sp<IBinder> primary) {
    sp<SurfaceControl> mirror;
    sp<IBinder> extToken;
    Placement applied;
    bool extPoweredOff = false;

    auto drop = [&](const char* why) {
        if (mirror != nullptr) {
            SurfaceComposerClient::Transaction t;
            t.reparent(mirror, nullptr);
            t.apply();
            mirror.clear();
            ALOGI("ext mirror: removed (%s)", why);
        }
        extToken.clear();
        applied = Placement();
    };

    sp<IBinder> staleOff;  // «призрачный» дисплей, который уже выключили
    for (;;) {
        usleep(500 * 1000);
        std::optional<PhysicalDisplayId> ext = nanoExtMirrorWanted() ? externalDisplay() : std::nullopt;
        sp<IBinder> token = ext ? SurfaceComposerClient::getPhysicalDisplayToken(*ext) : nullptr;
        // Кабель вынули, пока экраном владела DRM-оболочка: SurfaceFlinger отключения не
        // видел и держит внешний дисплей, а включённый выход HDMI гасит встроенный экран
        // (rk628 - один выход). Верим разъёму: нет кабеля - дисплея нет, и его выключаем.
        if (token != nullptr && !nanoHdmiConnected()) {
            drop("HDMI cable is not connected");
            if (staleOff != token) {
                SurfaceComposerClient::setDisplayPowerMode(token, kPowerOff);
                staleOff = token;
                ALOGI("ext mirror: stale external %" PRIu64 " without a cable, powered off", ext->value);
            }
            continue;
        }
        if (token == nullptr) {
            drop("no external display");
            continue;
        }
        staleOff.clear();
        if (extToken != nullptr && extToken != token) drop("external display changed");

        // Экран выключили - гасим и HDMI, иначе копия держала бы его включённым.
        if (screenOff()) {
            if (!extPoweredOff) {
                SurfaceComposerClient::setDisplayPowerMode(token, kPowerOff);
                extPoweredOff = true;
                ALOGI("ext mirror: screen off, external display off");
            }
            continue;
        }

        ui::DisplayState pst, est;
        ui::DisplayMode mode;
        if (SurfaceComposerClient::getDisplayState(primary, &pst) != NO_ERROR ||
            SurfaceComposerClient::getDisplayState(token, &est) != NO_ERROR ||
            SurfaceComposerClient::getActiveDisplayMode(token, &mode) != NO_ERROR) {
            continue;
        }
        // Стек слоёв и проекцию HDMI задаёт DisplayManager (у него это свой, выключенный
        // в nano дисплей) и переписывает их на каждом обходе дисплеев - при запуске
        // игры, выходе в меню. Поэтому с ним не спорим: копия кладётся в его стек и
        // вписывается матрицей самого слоя в его же логический размер. Свой стек и
        // проекция - только если DisplayManager стек не назначил.
        Placement want;
        const bool ownStack = est.layerStack == ui::INVALID_LAYER_STACK;
        want.stack = ownStack ? ui::LayerStack::fromValue(kExtLayerStack) : est.layerStack;
        want.src = pst.layerStackSpaceRect;
        ui::Size target = ownStack ? mode.resolution : est.layerStackSpaceRect;
        if (target.width <= 0 || target.height <= 0) target = mode.resolution;
        want.dst = fitRect(want.src, target);

        const bool fresh = mirror == nullptr;
        if (fresh) {
            std::optional<PhysicalDisplayId> pid = displayIdOf(primary);
            if (!pid) continue;
            mirror = session->mirrorDisplay(*pid);
            if (mirror == nullptr) {
                ALOGW("ext mirror: mirrorDisplay failed");
                continue;
            }
            extToken = token;
        } else if (!extPoweredOff && want == applied) {
            // Всё на месте. Питание подтверждаем каждый раз: для включённого дисплея это
            // пустой вызов, а DisplayManager мог его выключить.
            SurfaceComposerClient::setDisplayPowerMode(token, kPowerOn);
            continue;
        }

        const float sx = want.src.width > 0 ? float(want.dst.getWidth()) / want.src.width : 1.f;
        const float sy = want.src.height > 0 ? float(want.dst.getHeight()) / want.src.height : 1.f;
        SurfaceComposerClient::Transaction t;
        if (ownStack) {
            t.setDisplayLayerStack(token, want.stack);
            t.setDisplayProjection(token, ui::ROTATION_0, Rect(target.width, target.height),
                                   Rect(mode.resolution.width, mode.resolution.height));
        }
        t.setLayerStack(mirror, want.stack);
        t.setMatrix(mirror, sx, 0, 0, sy);
        t.setPosition(mirror, want.dst.left, want.dst.top);
        t.setLayer(mirror, INT_MAX);
        t.show(mirror);
        t.apply();
        SurfaceComposerClient::setDisplayPowerMode(token, kPowerOn);
        extPoweredOff = false;
        ALOGI("ext mirror: %s on external %" PRIu64 " (layer stack %u%s), %dx%d -> %dx%d at %d,%d",
              fresh ? "created" : "moved", ext->value, want.stack.id, ownStack ? ", own" : "",
              want.src.width, want.src.height, want.dst.getWidth(), want.dst.getHeight(),
              want.dst.left, want.dst.top);
        applied = want;
    }
}

} // namespace

bool nanoExtMirrorWanted() {
    return property_get_bool("persist.gammaos.ext.force_mirror", false) ||
           property_get_bool("persist.gammaos.ext.primary", false);
}

bool nanoHdmiConnected() {
    DIR* d = opendir("/sys/class/drm");
    if (d == nullptr) return false;
    bool connected = false;
    while (dirent* e = readdir(d)) {
        if (strstr(e->d_name, "-HDMI-A-") == nullptr) continue;
        std::ifstream f(std::string("/sys/class/drm/") + e->d_name + "/status");
        std::string s;
        if (f >> s && s == "connected") {
            connected = true;
            break;
        }
    }
    closedir(d);
    return connected;
}

void nanoExtMirrorStart(const sp<SurfaceComposerClient>& session, const sp<IBinder>& primaryToken) {
    if (session == nullptr || primaryToken == nullptr) return;
    std::call_once(sStartOnce, [session, primaryToken] {
        ALOGI("ext mirror: watching for an external display");
        std::thread(mirrorLoop, session, primaryToken).detach();
    });
}

} // namespace android
