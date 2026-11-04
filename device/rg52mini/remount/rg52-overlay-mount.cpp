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
 * Здесь делается тот же вызов из нашей userdebug-сборки, дважды: на триггере fs (начальное
 * пространство монтирования init, ранние службы) и на post-fs-data, когда init уже перешёл
 * в default-пространство (adbd, zygote, приложения) - см. rg52-overlay-mount.rc. Уже
 * поднятые точки fs_mgr_overlayfs_mount_all пропускает сам.
 * Нет в /cache/overlay ни одного каталога раздела (adb remount не делали или OTA их стёр) -
 * выходим сразу, загрузка не меняется.
 */
#include <dirent.h>
#include <unistd.h>

#include <memory>
#include <string>

#include <android-base/file.h>
#include <android-base/logging.h>
#include <android-base/strings.h>
#include <fs_mgr_overlayfs.h>
#include <fstab/fstab.h>

// Есть ли в /cache/overlay хоть один каталог раздела (system, vendor...).
static bool HasOverlayDirs() {
    std::unique_ptr<DIR, decltype(&closedir)> dir(opendir("/cache/overlay"), closedir);
    if (!dir) return false;
    while (auto* entry = readdir(dir.get())) {
        if (entry->d_name[0] != '.' && entry->d_type == DT_DIR) return true;
    }
    return false;
}

int main(int /*argc*/, char** argv) {
    android::base::InitLogging(argv, android::base::KernelLogger);

    if (!HasOverlayDirs()) {
        return 0;
    }

    std::string ns;
    android::base::Readlink("/proc/self/ns/mnt", &ns);

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
            LOG(INFO) << "adb remount overlay mounted on " << fields[1] << " (" << ns << ")";
            ++count;
        }
    }
    if (count == 0) {
        LOG(WARNING) << "/cache/overlay has partition directories but no overlay was mounted ("
                     << ns << ")";
    } else if (!all) {
        LOG(INFO) << "some overlay candidates have no /cache/overlay directory, left as is";
    }
    return 0;
}
