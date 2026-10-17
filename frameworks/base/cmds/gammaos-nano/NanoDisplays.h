#pragma once

// GammaOS RG52 Mini: какие физические дисплеи nano считает своими панелями.
//
// Двухэкранный режим nano (RG DS: две встроенные DSI-панели) включается, когда
// физических дисплеев больше одного: на второй дисплей уходят часы нижней панели,
// Control Center, его поверхность nano создаёт сам и включает дисплей. На RG52 Mini
// второй физический дисплей - HDMI (мост rk628, connectionType External), и nano
// принимал его за нижнюю панель: на телевизоре - часы в углу кадра, встроенный экран
// гаснет (rk628 - один выход), а зеркало DisplayManager (persist.gammaos.ext.force_mirror)
// перекрывалось поверхностью nano. Панели - только встроенные дисплеи; внешний
// оставляем DisplayManager, как в полной системе. Если встроенных SurfaceFlinger не
// назвал вовсе, берём все - как было.

#include <gui/SurfaceComposerClient.h>
#include <ui/StaticDisplayInfo.h>

#include <vector>

namespace android {

static inline std::vector<PhysicalDisplayId> nanoPanelDisplayIds() {
    const std::vector<PhysicalDisplayId> all = SurfaceComposerClient::getPhysicalDisplayIds();
    std::vector<PhysicalDisplayId> panels;
    for (const PhysicalDisplayId& id : all) {
        ui::StaticDisplayInfo info;
        if (SurfaceComposerClient::getStaticDisplayInfo(static_cast<int64_t>(id.value), &info) ==
                    NO_ERROR &&
            info.connectionType == ui::DisplayConnectionType::External) {
            continue;
        }
        panels.push_back(id);
    }
    return panels.empty() ? all : panels;
}

} // namespace android
