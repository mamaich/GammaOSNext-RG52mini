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

#include "OtaDisplay.h"
#include "OtaFlasher.h"
#include "OtaFont.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

#include <linux/fb.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

#include <android-base/properties.h>
#include <utils/Log.h>

namespace android {

// Почему здесь голые ioctl, а не libdrm. Прогресс рисуется в тот момент, когда
// /system/bin и /system/lib64 подменены пустым tmpfs, а сам раздел
// перезаписывается. Всё, что в этот момент попробует подгрузить библиотеку или
// прочитать файл с /system, обречено - именно так падал bootanimation, когда
// искал реализацию GLES. Поэтому дисплей держится на libc и ядре.
//
// Почему fbdev остался, но вторым. На этом устройстве (RK3562, rockchipdrm) он
// бесполезен: буфер fbdev существует (framebuffer[129], allocated by [fbcon]),
// но на плоскость VOP не попадает ни при живом композиторе, ни после его
// остановки - драйвер не восстанавливает режим fbdev на lastclose, и панель
// просто гаснет. Проверено измерением: адрес буфера в
// /sys/kernel/debug/dri/0/summary при записи в fb0 не менялся. На других платах
// fbdev работает, поэтому он оставлен запасным путём, но первым идёт DRM.

OtaDisplay::OtaDisplay() {}

OtaDisplay::~OtaDisplay() {
    close();
}

const char* OtaDisplay::backendName() const {
    switch (mBackend) {
        case DRM:   return "DRM/KMS";
        case FBDEV: return "fbdev";
        default:    return "none";
    }
}

bool OtaDisplay::init() {
    if (initDrm()) {
        mBackend = DRM;
        pickRotation();
        OtaFlasher::logToFile("INFO",
                              "OtaDisplay: DRM/KMS panel %dx%d, drawing %dx%d rotated %d, "
                              "stride=%d connector=%u crtc=%u",
                              mPanelW, mPanelH, mWidth, mHeight, mRotation,
                              mStride, mDrmConnectorId, mDrmCrtcId);
        return true;
    }
    if (initFbdev()) {
        mBackend = FBDEV;
        pickRotation();
        OtaFlasher::logToFile("INFO",
                              "OtaDisplay: fbdev panel %dx%d, drawing %dx%d rotated %d, "
                              "stride=%d bpp=%d",
                              mPanelW, mPanelH, mWidth, mHeight, mRotation, mStride, mBpp);
        return true;
    }
    OtaFlasher::logToFile("ERROR", "OtaDisplay: no display backend could be taken over");
    return false;
}

// Откуда взят угол поворота.
//
// ro.surface_flinger.primary_display_orientation говорит, на сколько повёрнута
// панель, и содержимое поворачивается на тот же угол: ORIENTATION_90 -> 90.
//
// Здесь была ошибка, которую стоит помнить. Сперва угол выводился рассуждением
// по logo.bmp загрузчика: он размером ровно 720x1280, пишется в буфер
// процессором и выводится тем же VOP, то есть проходит наш путь, а не путь GL, -
// и по расположению надписей в нём получалось, что содержимое надо поворачивать
// на 270. Проверка на устройстве показала обратное: при 270 картинка выходит
// вверх ногами, верное значение - 90, то есть прямое, без инверсии. Где именно
// рассуждение сломалось, доподлинно не установлено; вероятнее всего в
// предположении о порядке строк, с которого u-boot начинает вывод BMP.
//
// Урок простой: направление поворота дешевле один раз увидеть, чем вывести.
//
// Почему не скопирована поправка nano. Оболочка nano на этой же панели
// выставляет persist.gammaos.nano.drm_flip_v=1, и её итоговое преобразование -
// не поворот, а отражение по диагонали. Причина в её собственном пути: она
// рисует через GL в буфер, импортированный по PRIME, и тот добавляет
// вертикальное отражение, которое и компенсируется свойством. У буфера, который
// пишет процессор, такого звена нет, поэтому зеркало здесь только как страховка
// и по умолчанию выключено.
//
// Всё три величины перекрываются свойствами, без пересборки:
//   persist.gammaos.ota.display_rotation  0 | 90 | 180 | 270
//   persist.gammaos.ota.display_flip_h    1 - зеркало слева направо
//   persist.gammaos.ota.display_flip_v    1 - зеркало сверху вниз
void OtaDisplay::pickRotation() {
    mPanelW = mWidth;
    mPanelH = mHeight;

    int rot = 0;
    std::string sfOrient =
        android::base::GetProperty("ro.surface_flinger.primary_display_orientation", "");
    if (sfOrient == "ORIENTATION_90") rot = 90;
    else if (sfOrient == "ORIENTATION_180") rot = 180;
    else if (sfOrient == "ORIENTATION_270") rot = 270;

    std::string rotOverride =
        android::base::GetProperty("persist.gammaos.ota.display_rotation", "");
    if (!rotOverride.empty()) {
        int v = atoi(rotOverride.c_str());
        if (v == 0 || v == 90 || v == 180 || v == 270) {
            rot = v;
            OtaFlasher::logToFile("INFO", "OtaDisplay: rotation %d forced by property", rot);
        }
    }
    mFlipH = android::base::GetProperty("persist.gammaos.ota.display_flip_h", "") == "1";
    mFlipV = android::base::GetProperty("persist.gammaos.ota.display_flip_v", "") == "1";
    if (mFlipH || mFlipV) {
        OtaFlasher::logToFile("INFO", "OtaDisplay: mirror flip_h=%d flip_v=%d",
                              mFlipH ? 1 : 0, mFlipV ? 1 : 0);
    }

    mRotation = rot;
    if (rot == 90 || rot == 270) {
        mWidth = mPanelH;
        mHeight = mPanelW;
    }
    mScale = mWidth / 360;
    if (mScale < 1) mScale = 1;
}

// Логические координаты -> панельные. Для 90 и 270 строка логической картинки
// становится столбцом на панели, поэтому сплошная заливка идёт по пикселям, а не
// по строкам; на полноэкранную очистку это несколько миллисекунд, и на сотню
// кадров за прошивку это незаметно.
inline void OtaDisplay::plotPixel(int x, int y, uint32_t color) {
    int px, py;
    switch (mRotation) {
        case 90:  px = mPanelW - 1 - y; py = x;                break;
        case 180: px = mPanelW - 1 - x; py = mPanelH - 1 - y;  break;
        case 270: px = y;               py = mPanelH - 1 - x;  break;
        default:  px = x;               py = y;                break;
    }
    if (mFlipH) px = mPanelW - 1 - px;
    if (mFlipV) py = mPanelH - 1 - py;
    if (px < 0 || py < 0 || px >= mPanelW || py >= mPanelH) return;
    *(uint32_t*)(mBuffer + (size_t)py * mStride + (size_t)px * 4) = color;
}

// ---------------------------------------------------------------------------
// DRM/KMS
// ---------------------------------------------------------------------------

bool OtaDisplay::initDrm() {
    const char* paths[] = {"/dev/dri/card0", "/dev/dri/card1", nullptr};
    for (const char** p = paths; *p; p++) {
        mDrmFd = open(*p, O_RDWR | O_CLOEXEC);
        if (mDrmFd < 0) continue;

        // Мастером может быть только один клиент. Если панель ещё за
        // композитором, тут и выяснится - и это не повод искать другую карту,
        // а повод сперва остановить службы.
        if (ioctl(mDrmFd, DRM_IOCTL_SET_MASTER, 0) < 0) {
            OtaFlasher::logToFile("WARN", "OtaDisplay: %s is busy (SET_MASTER: %s)",
                                  *p, strerror(errno));
            ::close(mDrmFd);
            mDrmFd = -1;
            continue;
        }
        mDrmMaster = true;

        if (drmTakeOutput() && drmMakeBuffer()) {
            drmDpmsOn();
            return true;
        }

        OtaFlasher::logToFile("WARN", "OtaDisplay: %s has no usable output", *p);
        closeDrm();
    }
    return false;
}

bool OtaDisplay::drmTakeOutput() {
    struct drm_mode_card_res res;
    memset(&res, 0, sizeof(res));
    if (ioctl(mDrmFd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        OtaFlasher::logToFile("WARN", "OtaDisplay: GETRESOURCES: %s", strerror(errno));
        return false;
    }
    if (res.count_connectors == 0 || res.count_crtcs == 0) {
        OtaFlasher::logToFile("WARN", "OtaDisplay: card has %u connectors, %u crtcs",
                              res.count_connectors, res.count_crtcs);
        return false;
    }

    std::vector<uint32_t> crtcs(res.count_crtcs);
    std::vector<uint32_t> connectors(res.count_connectors);
    std::vector<uint32_t> encoders(res.count_encoders ? res.count_encoders : 1);
    res.crtc_id_ptr = (uint64_t)(uintptr_t)crtcs.data();
    res.connector_id_ptr = (uint64_t)(uintptr_t)connectors.data();
    res.encoder_id_ptr = (uint64_t)(uintptr_t)encoders.data();
    res.fb_id_ptr = 0;
    res.count_fbs = 0;
    if (ioctl(mDrmFd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        OtaFlasher::logToFile("WARN", "OtaDisplay: GETRESOURCES(2): %s", strerror(errno));
        return false;
    }

    for (uint32_t i = 0; i < res.count_connectors; i++) {
        struct drm_mode_get_connector conn;
        memset(&conn, 0, sizeof(conn));
        conn.connector_id = connectors[i];
        if (ioctl(mDrmFd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0) continue;
        if (conn.count_modes == 0) continue;

        std::vector<struct drm_mode_modeinfo> modes(conn.count_modes);
        std::vector<uint32_t> connEncoders(conn.count_encoders ? conn.count_encoders : 1);
        std::vector<uint32_t> propIds(conn.count_props ? conn.count_props : 1);
        std::vector<uint64_t> propVals(conn.count_props ? conn.count_props : 1);
        conn.modes_ptr = (uint64_t)(uintptr_t)modes.data();
        conn.encoders_ptr = (uint64_t)(uintptr_t)connEncoders.data();
        conn.props_ptr = (uint64_t)(uintptr_t)propIds.data();
        conn.prop_values_ptr = (uint64_t)(uintptr_t)propVals.data();
        if (ioctl(mDrmFd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0) continue;
        if (conn.connection != 1 /* DRM_MODE_CONNECTED */ || conn.count_modes == 0) continue;

        // Режим: тот, что драйвер пометил предпочтительным, иначе первый.
        size_t pick = 0;
        for (size_t m = 0; m < conn.count_modes; m++) {
            if (modes[m].type & DRM_MODE_TYPE_PREFERRED) { pick = m; break; }
        }

        // CRTC: сперва через текущий энкодер, иначе перебором по possible_crtcs.
        uint32_t crtcId = 0;
        if (conn.encoder_id) {
            struct drm_mode_get_encoder enc;
            memset(&enc, 0, sizeof(enc));
            enc.encoder_id = conn.encoder_id;
            if (ioctl(mDrmFd, DRM_IOCTL_MODE_GETENCODER, &enc) == 0) crtcId = enc.crtc_id;
        }
        if (crtcId == 0) {
            for (uint32_t e = 0; e < conn.count_encoders && crtcId == 0; e++) {
                struct drm_mode_get_encoder enc;
                memset(&enc, 0, sizeof(enc));
                enc.encoder_id = connEncoders[e];
                if (ioctl(mDrmFd, DRM_IOCTL_MODE_GETENCODER, &enc) < 0) continue;
                for (uint32_t c = 0; c < res.count_crtcs; c++) {
                    if (enc.possible_crtcs & (1u << c)) { crtcId = crtcs[c]; break; }
                }
            }
        }
        if (crtcId == 0) continue;

        mDrmConnectorId = conn.connector_id;
        mDrmCrtcId = crtcId;
        mWidth = modes[pick].hdisplay;
        mHeight = modes[pick].vdisplay;
        mBpp = 32;

        mDrmMode = malloc(sizeof(struct drm_mode_modeinfo));
        if (!mDrmMode) return false;
        memcpy(mDrmMode, &modes[pick], sizeof(struct drm_mode_modeinfo));

        OtaFlasher::logToFile("INFO", "OtaDisplay: connector %u (type %u) mode %dx%d@%u, crtc %u",
                              conn.connector_id, conn.connector_type, mWidth, mHeight,
                              modes[pick].vrefresh, crtcId);
        return true;
    }

    OtaFlasher::logToFile("WARN", "OtaDisplay: no connected connector with a mode");
    return false;
}

bool OtaDisplay::drmMakeBuffer() {
    struct drm_mode_create_dumb creq;
    memset(&creq, 0, sizeof(creq));
    creq.width = (uint32_t)mWidth;
    creq.height = (uint32_t)mHeight;
    creq.bpp = 32;
    if (ioctl(mDrmFd, DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0) {
        OtaFlasher::logToFile("WARN", "OtaDisplay: CREATE_DUMB: %s", strerror(errno));
        return false;
    }
    mDrmHandle = creq.handle;
    mDrmSize = (size_t)creq.size;
    mStride = (int)creq.pitch;

    // bpp=32 c depth=24 - это XRGB8888, то есть в памяти B,G,R,X. Ровно так и
    // лежит uint32_t вида 0xAARRGGBB на прямом порядке байтов, поэтому цвета в
    // коде отрисовки записываются как есть.
    struct drm_mode_fb_cmd fbcmd;
    memset(&fbcmd, 0, sizeof(fbcmd));
    fbcmd.width = creq.width;
    fbcmd.height = creq.height;
    fbcmd.pitch = creq.pitch;
    fbcmd.bpp = 32;
    fbcmd.depth = 24;
    fbcmd.handle = creq.handle;
    if (ioctl(mDrmFd, DRM_IOCTL_MODE_ADDFB, &fbcmd) < 0) {
        OtaFlasher::logToFile("WARN", "OtaDisplay: ADDFB: %s", strerror(errno));
        return false;
    }
    mDrmFbId = fbcmd.fb_id;

    struct drm_mode_map_dumb mreq;
    memset(&mreq, 0, sizeof(mreq));
    mreq.handle = creq.handle;
    if (ioctl(mDrmFd, DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0) {
        OtaFlasher::logToFile("WARN", "OtaDisplay: MAP_DUMB: %s", strerror(errno));
        return false;
    }
    void* map = mmap(nullptr, mDrmSize, PROT_READ | PROT_WRITE, MAP_SHARED,
                     mDrmFd, (off_t)mreq.offset);
    if (map == MAP_FAILED) {
        OtaFlasher::logToFile("WARN", "OtaDisplay: mmap of dumb buffer: %s", strerror(errno));
        return false;
    }
    mDrmMap = (uint8_t*)map;
    mBuffer = mDrmMap;
    memset(mBuffer, 0, mDrmSize);

    // Прежнее состояние CRTC запоминаем, чтобы вернуть его, если прошивка
    // сорвётся и мы отдадим панель обратно композитору.
    mDrmSavedCrtc = malloc(sizeof(struct drm_mode_crtc));
    if (mDrmSavedCrtc) {
        memset(mDrmSavedCrtc, 0, sizeof(struct drm_mode_crtc));
        ((struct drm_mode_crtc*)mDrmSavedCrtc)->crtc_id = mDrmCrtcId;
        if (ioctl(mDrmFd, DRM_IOCTL_MODE_GETCRTC, mDrmSavedCrtc) < 0) {
            free(mDrmSavedCrtc);
            mDrmSavedCrtc = nullptr;
        }
    }

    struct drm_mode_crtc set;
    memset(&set, 0, sizeof(set));
    set.crtc_id = mDrmCrtcId;
    set.fb_id = mDrmFbId;
    set.x = 0;
    set.y = 0;
    uint32_t conn = mDrmConnectorId;
    set.set_connectors_ptr = (uint64_t)(uintptr_t)&conn;
    set.count_connectors = 1;
    memcpy(&set.mode, mDrmMode, sizeof(struct drm_mode_modeinfo));
    set.mode_valid = 1;
    if (ioctl(mDrmFd, DRM_IOCTL_MODE_SETCRTC, &set) < 0) {
        OtaFlasher::logToFile("WARN", "OtaDisplay: SETCRTC: %s", strerror(errno));
        return false;
    }
    return true;
}

void OtaDisplay::drmDpmsOn() {
    // Панель может быть погашена через DPMS, и тогда SETCRTC сам её не зажжёт.
    // Свойство ищем по имени: его идентификатор у каждого драйвера свой.
    struct drm_mode_get_connector conn;
    memset(&conn, 0, sizeof(conn));
    conn.connector_id = mDrmConnectorId;
    if (ioctl(mDrmFd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0 || conn.count_props == 0) return;

    std::vector<uint32_t> propIds(conn.count_props);
    std::vector<uint64_t> propVals(conn.count_props);
    conn.props_ptr = (uint64_t)(uintptr_t)propIds.data();
    conn.prop_values_ptr = (uint64_t)(uintptr_t)propVals.data();
    conn.modes_ptr = 0;
    conn.count_modes = 0;
    conn.encoders_ptr = 0;
    conn.count_encoders = 0;
    if (ioctl(mDrmFd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0) return;

    for (uint32_t i = 0; i < conn.count_props; i++) {
        struct drm_mode_get_property prop;
        memset(&prop, 0, sizeof(prop));
        prop.prop_id = propIds[i];
        if (ioctl(mDrmFd, DRM_IOCTL_MODE_GETPROPERTY, &prop) < 0) continue;
        if (strcmp(prop.name, "DPMS") != 0) continue;

        struct drm_mode_connector_set_property sp;
        memset(&sp, 0, sizeof(sp));
        sp.value = 0;  // DRM_MODE_DPMS_ON
        sp.prop_id = propIds[i];
        sp.connector_id = mDrmConnectorId;
        if (ioctl(mDrmFd, DRM_IOCTL_MODE_SETPROPERTY, &sp) < 0) {
            OtaFlasher::logToFile("WARN", "OtaDisplay: DPMS on: %s", strerror(errno));
        }
        return;
    }
}

void OtaDisplay::closeDrm() {
    if (mDrmFd >= 0 && mDrmSavedCrtc) {
        ioctl(mDrmFd, DRM_IOCTL_MODE_SETCRTC, mDrmSavedCrtc);
    }
    if (mDrmMap) {
        munmap(mDrmMap, mDrmSize);
        mDrmMap = nullptr;
    }
    if (mDrmFd >= 0 && mDrmFbId) {
        uint32_t fbId = mDrmFbId;
        ioctl(mDrmFd, DRM_IOCTL_MODE_RMFB, &fbId);
        mDrmFbId = 0;
    }
    if (mDrmFd >= 0 && mDrmHandle) {
        struct drm_mode_destroy_dumb dreq;
        memset(&dreq, 0, sizeof(dreq));
        dreq.handle = mDrmHandle;
        ioctl(mDrmFd, DRM_IOCTL_MODE_DESTROY_DUMB, &dreq);
        mDrmHandle = 0;
    }
    if (mDrmFd >= 0 && mDrmMaster) {
        ioctl(mDrmFd, DRM_IOCTL_DROP_MASTER, 0);
        mDrmMaster = false;
    }
    if (mDrmFd >= 0) {
        ::close(mDrmFd);
        mDrmFd = -1;
    }
    free(mDrmMode);
    mDrmMode = nullptr;
    free(mDrmSavedCrtc);
    mDrmSavedCrtc = nullptr;
    mBuffer = nullptr;
}

// ---------------------------------------------------------------------------
// fbdev (запасной путь для плат, где он ещё что-то значит)
// ---------------------------------------------------------------------------

bool OtaDisplay::initFbdev() {
    const char* paths[] = {"/dev/graphics/fb0", "/dev/fb0", nullptr};
    for (const char** p = paths; *p; p++) {
        mFbFd = open(*p, O_RDWR | O_CLOEXEC);
        if (mFbFd >= 0) break;
    }
    if (mFbFd < 0) return false;

    struct fb_var_screeninfo vi;
    struct fb_fix_screeninfo fi;
    if (ioctl(mFbFd, FBIOGET_VSCREENINFO, &vi) < 0 ||
        ioctl(mFbFd, FBIOGET_FSCREENINFO, &fi) < 0) {
        ::close(mFbFd);
        mFbFd = -1;
        return false;
    }

    mWidth = (int)vi.xres;
    mHeight = (int)vi.yres;
    mBpp = (int)vi.bits_per_pixel;
    mStride = (int)fi.line_length;
    if (mBpp != 32) {
        OtaFlasher::logToFile("WARN", "OtaDisplay: fbdev is %d bpp, only 32 is supported", mBpp);
        ::close(mFbFd);
        mFbFd = -1;
        return false;
    }

    mFbMmapSize = (size_t)fi.line_length * (vi.yres_virtual ? vi.yres_virtual : vi.yres);
    void* map = mmap(nullptr, mFbMmapSize, PROT_READ | PROT_WRITE, MAP_SHARED, mFbFd, 0);
    if (map == MAP_FAILED) {
        ::close(mFbFd);
        mFbFd = -1;
        return false;
    }
    mFbMmap = (uint8_t*)map;
    mBuffer = mFbMmap;
    ioctl(mFbFd, FBIOBLANK, FB_BLANK_UNBLANK);
    return true;
}

void OtaDisplay::closeFbdev() {
    if (mFbMmap) {
        munmap(mFbMmap, mFbMmapSize);
        mFbMmap = nullptr;
    }
    if (mFbFd >= 0) {
        ::close(mFbFd);
        mFbFd = -1;
    }
    mBuffer = nullptr;
}

void OtaDisplay::close() {
    if (mBackend == DRM) closeDrm();
    else if (mBackend == FBDEV) closeFbdev();
    mBackend = NONE;
}

// ---------------------------------------------------------------------------
// Отрисовка
// ---------------------------------------------------------------------------

void OtaDisplay::fillRect(int x, int y, int w, int h, uint32_t color) {
    if (!mBuffer) return;
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x >= mWidth || y >= mHeight || w <= 0 || h <= 0) return;
    if (x + w > mWidth) w = mWidth - x;
    if (y + h > mHeight) h = mHeight - y;

    if (mRotation == 0 && !mFlipH && !mFlipV) {
        for (int row = y; row < y + h; row++) {
            uint32_t* line = (uint32_t*)(mBuffer + (size_t)row * mStride);
            for (int col = x; col < x + w; col++) line[col] = color;
        }
        return;
    }
    for (int row = y; row < y + h; row++) {
        for (int col = x; col < x + w; col++) plotPixel(col, row, color);
    }
}

void OtaDisplay::drawChar(int x, int y, char c, uint32_t color, int scale) {
    if (!mBuffer) return;
    unsigned char uc = (unsigned char)c;
    if (uc < 32 || uc > 126) uc = '?';
    const uint8_t* glyph = OTA_FONT_8x16[uc - 32];

    for (int row = 0; row < OTA_FONT_H; row++) {
        uint8_t bits = glyph[row];
        if (!bits) continue;
        for (int col = 0; col < OTA_FONT_W; col++) {
            if (!(bits & (0x80 >> col))) continue;
            fillRect(x + col * scale, y + row * scale, scale, scale, color);
        }
    }
}

void OtaDisplay::drawString(int x, int y, const char* str, uint32_t color, int scale) {
    int cx = x;
    for (; *str; str++) {
        drawChar(cx, y, *str, color, scale);
        cx += OTA_FONT_W * scale;
    }
}

int OtaDisplay::textWidth(const char* str, int scale) const {
    return (int)strlen(str) * OTA_FONT_W * scale;
}

void OtaDisplay::drawCentered(int y, const char* str, uint32_t color, int scale) {
    drawString((mWidth - textWidth(str, scale)) / 2, y, str, color, scale);
}

void OtaDisplay::flip() {
    // DRM: рисуем прямо в буфер, который сканирует VOP, так что ничего
    // переключать не нужно. fbdev: буфер один, панорамировать тоже нечего.
}

void OtaDisplay::drawProgress(int percent, const std::string& status) {
    if (!mBuffer) return;
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;

    const uint32_t BG        = 0xFF141420;
    const uint32_t BAR_BG    = 0xFF2A2A3A;
    const uint32_t BAR_FILL  = 0xFF4488CC;
    const uint32_t TEXT      = 0xFFE0E0E0;
    const uint32_t TITLE     = 0xFFFFFFFF;
    const uint32_t WARN      = 0xFFCCAA44;

    int s = mScale;
    int lineH = OTA_FONT_H * s;
    int margin = mWidth / 12;
    int barW = mWidth - 2 * margin;
    int barH = lineH / 2;
    if (barH < 10) barH = 10;
    int barY = mHeight / 2 - barH / 2;

    fillRect(0, 0, mWidth, mHeight, BG);
    drawCentered(barY - lineH * 4, "GammaOS System Update", TITLE, s);

    // Длинную строку состояния обрезаем по ширине панели, а не за её край.
    std::string line = status;
    size_t fits = (size_t)(mWidth - 2 * margin) / (size_t)(OTA_FONT_W * s);
    if (line.size() > fits) line = line.substr(0, fits);
    drawCentered(barY - lineH * 2, line.c_str(), TEXT, s);

    fillRect(margin, barY, barW, barH, BAR_BG);
    int fillW = (int)(((int64_t)barW * percent) / 100);
    if (fillW > 0) fillRect(margin, barY, fillW, barH, BAR_FILL);

    char pct[16];
    snprintf(pct, sizeof(pct), "%d%%", percent);
    drawCentered(barY + barH + lineH, pct, TEXT, s);

    drawCentered(mHeight - lineH * 3, "Do not power off the device", WARN, s);
    flip();
}

void OtaDisplay::drawMessage(const std::string& title, const std::string& line1,
                             const std::string& line2) {
    if (!mBuffer) return;

    const uint32_t BG    = 0xFF141420;
    const uint32_t TITLE = 0xFFFFFFFF;
    const uint32_t TEXT  = 0xFFE0E0E0;

    int s = mScale;
    int lineH = OTA_FONT_H * s;
    int margin = mWidth / 12;
    size_t fits = (size_t)(mWidth - 2 * margin) / (size_t)(OTA_FONT_W * s);

    fillRect(0, 0, mWidth, mHeight, BG);
    int y = mHeight / 2 - lineH * 2;
    drawCentered(y, title.substr(0, fits).c_str(), TITLE, s);
    if (!line1.empty()) drawCentered(y + lineH * 2, line1.substr(0, fits).c_str(), TEXT, s);
    if (!line2.empty()) drawCentered(y + lineH * 3, line2.substr(0, fits).c_str(), TEXT, s);
    flip();
}

} // namespace android
