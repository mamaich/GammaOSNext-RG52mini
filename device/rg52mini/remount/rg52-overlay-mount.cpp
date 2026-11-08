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
 *
 * Цена первого запуска. Без overlay корень и всё под ним в обоих пространствах - одна
 * peer-группа, и то, что init монтирует в начальном пространстве позже (on post-fs), само
 * появляется в default. fs_mgr_overlayfs_mount_all на время монтирования делает родителя
 * частным и потом снова общим, а это уже новая группа: связь между пространствами рвётся.
 * Из того, что init делает в начальном пространстве между fs и post-fs-data, до default
 * после этого не доходят две вещи (сверено по /proc/<pid>/mountinfo vold и init, 08.11.2026):
 *   - /storage: bind от /mnt/user/0 из init.rc. Без него adb shell видит пустые /storage и
 *     /sdcard; приложениям не мешает, zygote монтирует им /storage сам;
 *   - /vendor/etc/usb_audio_policy_configuration.xml из gammaos.rc. Без него служба звука
 *     (она в default) читает настройки USB-звука от vendor, а не наши.
 * Поэтому во втором запуске после overlay повторяем оба, как их делает init. Второй запуск
 * узнаём по пространству: начальное у init - то же, что у потоков ядра (kthreadd, pid 2),
 * default - другое. Ключа в .rc для этого не нужно: init читает .rc до того, как поднят
 * overlay, и новый .rc поверх старого образа через adb remount не заработал бы.
 */
#include <dirent.h>
#include <sys/mount.h>
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

// Смонтировано ли что-нибудь ровно в path (пятое поле /proc/self/mountinfo).
static bool IsMountPoint(const std::string& path) {
    std::string info;
    android::base::ReadFileToString("/proc/self/mountinfo", &info);
    for (const auto& line : android::base::Split(info, "\n")) {
        auto fields = android::base::Split(line, " ");
        if (fields.size() > 4 && fields[4] == path) return true;
    }
    return false;
}

// Повторить в default-пространстве то, что init сделал в начальном и что сюда не дошло
// (см. начало файла). Уже смонтированное не трогаем: без overlay всё это приходит само.
static void ReplayBootstrapMounts() {
    // init.rc: mount none /mnt/user/0 /storage bind rec; mount none none /storage slave rec.
    // Подчинённый /mnt/user/0 - FUSE, который vold поднимет позже, сам появится и здесь.
    if (!IsMountPoint("/storage")) {
        if (mount("/mnt/user/0", "/storage", nullptr, MS_BIND | MS_REC, nullptr) == 0 &&
            mount(nullptr, "/storage", nullptr, MS_SLAVE | MS_REC, nullptr) == 0) {
            LOG(INFO) << "/storage bound from /mnt/user/0, as init.rc does";
        } else {
            PLOG(ERROR) << "cannot bind /storage";
        }
    }
    // gammaos.rc: mount none /system/etc/usb_audio_policy_configuration.xml
    //             /vendor/etc/usb_audio_policy_configuration.xml bind
    static const char kPolicySrc[] = "/system/etc/usb_audio_policy_configuration.xml";
    static const char kPolicyDst[] = "/vendor/etc/usb_audio_policy_configuration.xml";
    if (access(kPolicySrc, F_OK) == 0 && access(kPolicyDst, F_OK) == 0 &&
        !IsMountPoint(kPolicyDst)) {
        if (mount(kPolicySrc, kPolicyDst, nullptr, MS_BIND, nullptr) == 0) {
            LOG(INFO) << kPolicyDst << " bound from " << kPolicySrc << ", as gammaos.rc does";
        } else {
            PLOG(ERROR) << "cannot bind " << kPolicyDst;
        }
    }
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
    // В начальном пространстве init сам сделает всё это позже (on post-fs).
    std::string kernel_ns;
    android::base::Readlink("/proc/2/ns/mnt", &kernel_ns);
    if (count > 0 && !kernel_ns.empty() && ns != kernel_ns) {
        ReplayBootstrapMounts();
    }
    return 0;
}
