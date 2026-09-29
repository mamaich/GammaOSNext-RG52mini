/*
 * Copyright (C) 2026 GammaOS
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#define LOG_TAG "GammaOSOta"

#include <stdint.h>
#include <inttypes.h>
#include <string.h>
#include <sys/stat.h>

#include <binder/Binder.h>
#include <binder/IPCThreadState.h>
#include <binder/Parcel.h>
#include <binder/ProcessState.h>
#include <binder/IServiceManager.h>
#include <cutils/properties.h>
#include <android-base/properties.h>
#include <sys/resource.h>
#include <utils/Log.h>
#include <utils/SystemClock.h>

#include "OtaMenu.h"
#include "OtaFlasher.h"
#include "OtaDisplay.h"

using namespace android;

// Wait for SurfaceFlinger to be available
static void waitForSurfaceFlinger() {
    sp<IServiceManager> sm = defaultServiceManager();
    const String16 name("SurfaceFlinger");
    int retry = 0;
    while (sm->checkService(name) == nullptr) {
        retry++;
        if ((retry % 100) == 0) {
            ALOGW("Waiting for SurfaceFlinger...");
        }
        usleep(10000);
    }
}

// Экран не должен гаснуть, пока каркас ещё жив.
//
// Пока прошивальщик переселяется в tmpfs и проверяет контрольные суммы, Android
// продолжает отсчитывать время до гашения экрана. Переселение идёт от минуты до
// четырёх (дольше, когда память занята игрой), и 29.09.2026 экран погас по
// таймауту прямо на проверке файла: меню рисовало в погашенный экран, а
// Android вдобавок обнулил яркость. Держим обычную блокировку яркого экрана,
// как у приложения с keepScreenOn.
//
// Отпускать её не нужно: она живёт, пока жив наш процесс и system_server, и
// снимается сама - при переходе в tmpfs (exec) и при остановке zygote. Второй
// процесс берёт её заново. ON_AFTER_RELEASE на этом стыке продлевает время до
// гашения, иначе при давно истёкшем таймауте экран погас бы сразу. Дальше
// экран - наш, и подсветку держит OtaDisplay::keepBacklightOn().
//
// Интерфейс Java-шный (android.os.IPowerManager), готовой обёртки для C++ нет,
// поэтому транзакция собирается руками по IPowerManager.aidl этого дерева:
// acquireWakeLock(IBinder lock, int flags, String tag, String packageName,
// in WorkSource ws, String historyTag, int displayId, IWakeLockCallback) -
// первый метод, то есть FIRST_CALL_TRANSACTION.
static void keepScreenOn() {
    static sp<IBinder> sLock;   // жетон блокировки: пока он жив, жива и она
    if (sLock) return;
    sp<IBinder> power = defaultServiceManager()->checkService(String16("power"));
    if (!power) {
        OtaFlasher::logToFile("WARN", "keepScreenOn: no power service");
        return;
    }
    sp<IBinder> lock = sp<BBinder>::make();
    Parcel data, reply;
    data.writeInterfaceToken(String16("android.os.IPowerManager"));
    data.writeStrongBinder(lock);
    data.writeInt32(0x0000000a      // SCREEN_BRIGHT_WAKE_LOCK
                    | 0x10000000    // ACQUIRE_CAUSES_WAKEUP
                    | 0x20000000);  // ON_AFTER_RELEASE
    data.writeString16(String16("GammaOSOta"));   // tag
    data.writeString16(String16("android"));      // packageName
    data.writeInt32(0);                            // WorkSource: null
    data.writeString16(String16("GammaOSOta"));   // historyTag
    data.writeInt32(-1);                           // displayId: INVALID_DISPLAY, как у newWakeLock()
    data.writeStrongBinder(nullptr);               // callback
    status_t st = power->transact(IBinder::FIRST_CALL_TRANSACTION, data, &reply);
    int32_t ex = (st == OK) ? reply.readExceptionCode() : 0;
    if (st != OK || ex != 0) {
        OtaFlasher::logToFile("WARN", "keepScreenOn: acquireWakeLock failed (status %d, exception %d)",
                              st, ex);
        return;
    }
    sLock = lock;
    OtaFlasher::logToFile("INFO", "keepScreenOn: screen wake lock held");
}

int main(int argc, char** argv) {
    setpriority(PRIO_PROCESS, 0, ANDROID_PRIORITY_DISPLAY);

    ALOGI("GammaOS OTA starting...");

    // --test-flash-display [секунды]: сухой прогон обновления. От --test-display
    // отличается тем, что воспроизводит всю обстановку прошивки: процесс
    // переселяется в tmpfs, каркас останавливается, /system/bin и /system/lib64
    // подменяются пустым tmpfs - и лишь потом забирается панель. Раздел не
    // пишется, система в конце возвращается на место.
    if (argc > 1 && strcmp(argv[1], "--test-flash-display") == 0) {
        OtaFlasher::initLogFile();
        int seconds = (argc > 2) ? atoi(argv[2]) : 40;
        if (seconds < 6) seconds = 6;

        // Экран держим так же, как при настоящей прошивке: иначе сухой прогон
        // проверял бы не ту обстановку.
        keepScreenOn();
        if (!OtaFlasher::isRunningFromTmpfs()) {
            OtaFlasher staging;
            staging.stageToTmpfs(argc, argv);   // в норме сюда не возвращается
            OtaFlasher::logToFile("ERROR", "dry run: staging to tmpfs failed");
            return 1;
        }

        OtaFlasher flasher;
        bool ok = flasher.dryRunDisplay(seconds);
        printf("%s\n", ok ? "OK" : "FAILED");
        return ok ? 0 : 1;
    }

    // --test-display [секунды]: проверка прямого вывода на панель без всякой
    // прошивки. Нужен потому, что проверять вывод прогресса настоящим
    // обновлением - это пять минут записи и незагружаемое устройство при
    // ошибке. Здесь тот же путь: отпустить панель, взять DRM, отрисовать
    // прогресс, вернуть каркас.
    if (argc > 1 && strcmp(argv[1], "--test-display") == 0) {
        OtaFlasher::initLogFile();
        int seconds = (argc > 2) ? atoi(argv[2]) : 12;
        if (seconds < 2) seconds = 2;
        OtaFlasher::logToFile("INFO", "=== DISPLAY TEST (%d s) ===", seconds);

        bool released = OtaFlasher::releaseDisplayServices();
        OtaDisplay display;
        bool ok = display.init();
        printf("backend: %s, %dx%d\n", display.backendName(),
               display.width(), display.height());
        if (ok) {
            int steps = seconds * 5;
            for (int i = 0; i <= steps; i++) {
                char status[64];
                snprintf(status, sizeof(status), "Writing system (%d of %d)", i, steps);
                display.drawProgress(i * 100 / steps, status);
                usleep(200000);
            }
            display.drawMessage("Display test finished",
                                "the panel is driven directly",
                                "restoring the framework");
            sleep(2);
            display.close();
        }
        if (released) OtaFlasher::restoreDisplayServices();
        printf("%s\n", ok ? "OK" : "FAILED");
        OtaFlasher::logToFile("INFO", "=== DISPLAY TEST %s ===", ok ? "OK" : "FAILED");
        return ok ? 0 : 1;
    }

    // Check if we need to stage to tmpfs first
    if (!OtaFlasher::isRunningFromTmpfs()) {
        ALOGI("Not yet staged to tmpfs — staging now...");
        OtaFlasher::initLogFile();
        keepScreenOn();
        OtaFlasher flasher;
        // stageToTmpfs will re-exec. If it returns, staging failed.
        if (!flasher.stageToTmpfs(argc, argv)) {
            ALOGE("Failed to stage to tmpfs! Continuing from system (risky).");
            // Continue anyway — better to try than to fail silently
        }
    }

    ALOGI("Running from tmpfs: %s", OtaFlasher::isRunningFromTmpfs() ? "yes" : "no");

    // Coordinated handoff (no black screen): nano started us early (on sys.gammaos.ota.prestage=1)
    // and stayed up showing "Preparing update... X%" while we staged to tmpfs. Now that we are
    // staged and about to take the SurfaceFlinger panel, tell nano we are ready, then wait for it
    // to release DRM master (exit) before we init our display. This keeps the panel painted by nano
    // right up to the moment we take over, and avoids DRM master contention.
    if (OtaFlasher::isRunningFromTmpfs() &&
        android::base::GetProperty("sys.gammaos.ota.prestage", "") == "1") {
        android::base::SetProperty("sys.gammaos.ota.stageprog", "100");
        android::base::SetProperty("sys.gammaos.ota.staged", "1");
        ALOGI("Staged; waiting for the home to release DRM master...");
        for (int i = 0; i < 200; i++) {   // up to ~20s, then proceed anyway
            if (android::base::GetProperty("init.svc.gammaos-nano", "") != "running") break;
            usleep(100 * 1000);
        }
        ALOGI("Home released DRM (svc=%s); taking the panel.",
              android::base::GetProperty("init.svc.gammaos-nano", "?").c_str());
    }

    // Read package path and autoinstall flag from system properties
    std::string packagePath = android::base::GetProperty("sys.gammaos.ota.package", "");
    std::string autoInstall = android::base::GetProperty("sys.gammaos.ota.autoinstall", "0");

    // Guard: if no package path and no autoinstall, check if we have anything to do.
    // This prevents the service from running after a reboot if it was spuriously started.
    if (packagePath.empty() && autoInstall != "1") {
        // Check if there's an extracted package ready
        struct stat st;
        if (stat("/data/gammaos_ota/package/manifest.json", &st) != 0) {
            ALOGI("No package to install and no autoinstall flag — exiting.");
            return 0;
        }
    }

    sp<ProcessState> proc(ProcessState::self());
    ProcessState::self()->startThreadPool();
    keepScreenOn();

    // OtaMenu runs as a Thread, matching NanoMenu pattern
    sp<OtaMenu> menu(new OtaMenu());
    if (!packagePath.empty()) {
        menu->setPackagePath(packagePath);
    }

    waitForSurfaceFlinger();

    menu->run("GammaOSOta", PRIORITY_DISPLAY);

    ALOGI("GammaOS OTA running. Joining thread pool.");
    IPCThreadState::self()->joinThreadPool();

    return 0;
}
