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

#ifndef GAMMAOS_OTA_DISPLAY_H
#define GAMMAOS_OTA_DISPLAY_H

#include <stdint.h>
#include <stddef.h>
#include <string>

namespace android {

// Minimal direct display renderer for OTA progress.
//
// Drives the panel with plain DRM/KMS ioctls and falls back to fbdev. It links
// against nothing beyond libc on purpose: the progress screen is painted while
// /system is being overwritten and /system/bin plus /system/lib64 are masked
// with an empty tmpfs, so anything that would dlopen a library or read a file
// from /system at that moment (EGL, gralloc, a FreeType font file) is a trap.
// The font is a bitmap compiled into the binary for the same reason.
//
// The display must be free before init(): whoever holds DRM master owns the
// panel, and on this hardware that is the vendor composer HAL, with
// SurfaceFlinger behind it. Call OtaFlasher::releaseDisplayServices() first.
class OtaDisplay {
public:
    OtaDisplay();
    ~OtaDisplay();

    // Take over the panel. Returns true on success.
    bool init();

    // Progress screen: a bar, a percentage and one line of status text.
    void drawProgress(int percent, const std::string& status);

    // Plain message screen, used for the result once flashing is over.
    void drawMessage(const std::string& title, const std::string& line1,
                     const std::string& line2);

    // Release the display.
    void close();

    bool ready() const { return mBackend != NONE; }
    const char* backendName() const;
    int width() const { return mWidth; }
    int height() const { return mHeight; }

private:
    // Backends
    bool initDrm();
    void closeDrm();
    bool initFbdev();
    void closeFbdev();

    // DRM helpers
    bool drmTakeOutput();     // resources -> connector -> crtc -> mode
    bool drmMakeBuffer();     // dumb buffer -> fb -> mmap -> setcrtc
    void drmDpmsOn();

    // Поворот: панель у этого устройства портретная, а картинка на ней
    // горизонтальная. Рисуем в логических координатах, plotPixel переводит их
    // в панельные.
    void pickRotation();
    inline void plotPixel(int x, int y, uint32_t color);

    // Drawing (all of it works on mBuffer)
    void fillRect(int x, int y, int w, int h, uint32_t color);
    void drawChar(int x, int y, char c, uint32_t color, int scale);
    void drawString(int x, int y, const char* str, uint32_t color, int scale);
    int textWidth(const char* str, int scale) const;
    void drawCentered(int y, const char* str, uint32_t color, int scale);
    void flip();

    enum Backend { NONE, DRM, FBDEV };
    Backend mBackend = NONE;

    int mWidth = 0;        // логический размер, в котором рисуем
    int mHeight = 0;
    int mPanelW = 0;       // физический размер панели
    int mPanelH = 0;
    int mRotation = 0;     // поворот содержимого, 0/90/180/270 по часовой
    bool mFlipH = false;   // зеркало в панельных координатах, страховка
    bool mFlipV = false;
    int mStride = 0;       // bytes per row
    int mBpp = 0;          // bits per pixel
    int mScale = 1;        // font magnification, chosen from the panel width
    int mAnim = 0;         // счётчик кадров, по нему бежит огонёк
    uint8_t* mBuffer = nullptr;

    // DRM state
    int mDrmFd = -1;
    uint32_t mDrmConnectorId = 0;
    uint32_t mDrmCrtcId = 0;
    uint32_t mDrmFbId = 0;
    uint32_t mDrmHandle = 0;
    size_t mDrmSize = 0;
    uint8_t* mDrmMap = nullptr;
    bool mDrmMaster = false;
    // struct drm_mode_modeinfo and struct drm_mode_crtc, kept as opaque blobs
    // so the DRM headers stay out of this one.
    void* mDrmMode = nullptr;
    void* mDrmSavedCrtc = nullptr;

    // Fbdev state
    int mFbFd = -1;
    uint8_t* mFbMmap = nullptr;
    size_t mFbMmapSize = 0;
};

} // namespace android

#endif // GAMMAOS_OTA_DISPLAY_H
