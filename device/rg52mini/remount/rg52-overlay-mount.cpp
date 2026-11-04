/*
 * rg52-overlay-mount: поднять overlay от `adb remount` на каждой загрузке.
 *
 * Раздел system собран с общими блоками (shared_blocks), на запись он открывается только
 * через overlayfs, а подложка overlay лежит в /cache/overlay/<раздел>/{upper,work}. Обычно
 * её поднимает init первого этапа (fs_mgr_overlayfs_mount_all в first_stage_mount.cpp), но
 * init первого этапа в нашем initrd - из пользовательской сборки вендора на Android 13, там
 * overlay выключен при сборке (kAllowOverlayfs), и после перезагрузки изменения пропадали
 * из вида до повторного `adb remount`.
 *
 * Здесь делается тот же вызов из нашей userdebug-сборки, на триггере fs: vendor уже
 * прошёл mount_all, /cache смонтирован, а bind-mount'ов поверх /system и /vendor (post-fs)
 * и почти всех служб ещё нет. Нет /cache/overlay (adb remount не делали или OTA его стёр) -
 * выходим сразу, загрузка не меняется.
 */
#include <unistd.h>

#include <string>

#include <android-base/file.h>
#include <android-base/logging.h>
#include <android-base/strings.h>
#include <fs_mgr_overlayfs.h>
#include <fstab/fstab.h>

int main(int /*argc*/, char** argv) {
    android::base::InitLogging(argv, android::base::KernelLogger);

    if (access("/cache/overlay", F_OK) != 0) {
        return 0;
    }

    android::fs_mgr::Fstab fstab;
    if (!android::fs_mgr::ReadDefaultFstab(&fstab)) {
        LOG(ERROR) << "cannot read the default fstab, adb remount overlays stay unmounted";
        return 1;
    }

    // false означает «не всё»: кандидат без своего каталога в /cache/overlay (раздел,
    // который не перемонтировали) тоже считается неудачей. Что поднялось - видно ниже.
    bool all = fs_mgr_overlayfs_mount_all(&fstab);

    std::string mounts;
    android::base::ReadFileToString("/proc/self/mounts", &mounts);
    int count = 0;
    for (const auto& line : android::base::Split(mounts, "\n")) {
        if (android::base::StartsWith(line, "overlay ")) {
            auto fields = android::base::Split(line, " ");
            LOG(INFO) << "adb remount overlay mounted on " << fields[1];
            ++count;
        }
    }
    if (count == 0) {
        LOG(WARNING) << "/cache/overlay exists but no overlay was mounted";
    } else if (!all) {
        LOG(INFO) << "some overlay candidates have no /cache/overlay directory, left as is";
    }
    return 0;
}
