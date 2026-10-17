#pragma once

// GammaOS RG52 Mini: HDMI в режиме nano - копия основного экрана.
//
// В полной системе копию на HDMI при Force mirror mode строит оконный менеджер
// (ContentRecorder), а включает внешний дисплей SystemUI. В режиме nano SystemUI нет,
// оконный менеджер дисплеи намеренно не зеркалирует (так нужно RG DS с двумя
// панелями), да и меню nano - отдельный слой SurfaceFlinger, а не окно. Поэтому
// здесь копию делает сам nano:
//   - работая поверх SurfaceFlinger (оверлей-оболочка), он держит на внешнем
//     дисплее клон основного (mirrorDisplay: меню nano и запущенные игры), вписанный
//     в разрешение HDMI, и включает этот дисплей;
//   - DRM-оболочка (главное меню до первой игры) владеет экраном сама и HDMI не
//     покажет, поэтому при подключении HDMI она отдаёт экран SurfaceFlinger - так же,
//     как при запуске игры, - и меню продолжает оверлей-оболочка (правило
//     sys.gammaos.nano.hdmi_handoff в gammaos-nano.rc).
// Включается теми же настройками, что и в полной системе: Force mirror mode или
// External as primary.

#include <binder/IBinder.h>
#include <utils/StrongPointer.h>

namespace android {

class SurfaceComposerClient;

// Нужна ли копия на HDMI (persist.gammaos.ext.force_mirror или persist.gammaos.ext.primary).
bool nanoExtMirrorWanted();

// Подключён ли HDMI-разъём (sysfs DRM, card*-HDMI-A-*/status) - для DRM-оболочки,
// которой SurfaceFlinger о дисплеях не сообщает.
bool nanoHdmiConnected();

// Запустить поток, который держит копию основного дисплея (primaryToken) на внешнем.
// Повторный вызов ничего не делает.
void nanoExtMirrorStart(const sp<SurfaceComposerClient>& session, const sp<IBinder>& primaryToken);

} // namespace android
