#define LOG_TAG "azahar-nano"

#include "TouchCursor.h"

#include <dlfcn.h>
#include <stddef.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>

#include <cutils/properties.h>
#include <log/log.h>

namespace azahar_nano {

namespace {

// Layout::FramebufferLayout (core/frontend/framebuffer_layout.h) up to bottom_screen. The core
// writes the whole struct through the result pointer, so the tail leaves room for the rest of
// it; start() checks the leading fields with a known layout before the cursor is used.
struct RawLayout {
    uint32_t width, height;
    bool topOn, botOn;
    uint32_t top[4];   // Common::Rectangle<u32>: left, top, right, bottom
    uint32_t bot[4];
    uint8_t tail[512];
};
static_assert(offsetof(RawLayout, top) == 12 && offsetof(RawLayout, bot) == 28,
              "FramebufferLayout field offsets");

// Layout::XxxFrameLayout(u32 width, u32 height, bool swapped, bool upright[, float scale,
// Settings::SmallScreenPosition]) - Itanium-mangled names in the core's dynamic symbols.
using Fn4 = RawLayout (*)(uint32_t, uint32_t, bool, bool);
using FnLarge = RawLayout (*)(uint32_t, uint32_t, bool, bool, float, uint32_t);
constexpr const char* kLarge = "_ZN6Layout16LargeFrameLayoutEjjbbfN8Settings19SmallScreenPositionE";
constexpr const char* kSingle = "_ZN6Layout17SingleFrameLayoutEjjbb";
constexpr const char* kDefault = "_ZN6Layout18DefaultFrameLayoutEjjbb";
constexpr const char* kHybrid = "_ZN6Layout18HybridScreenLayoutEjjbb";
constexpr const char* kCustom = "_ZN6Layout17CustomFrameLayoutEjjbb";
constexpr uint32_t kMiddleRight = 1;   // Settings::SmallScreenPosition::MiddleRight

constexpr int kTickMs = 16;                       // as gammapad's mouse mode
constexpr int64_t kHideNs = 3000LL * 1000000LL;   // the cursor hides after 3 s at rest
constexpr float kAxisMax = 32767.0f;              // gammapad's axis range

int64_t nowNs() {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

bool rectInside(const uint32_t r[4], uint32_t w, uint32_t h) {
    return r[0] < r[2] && r[1] < r[3] && r[2] <= w && r[3] <= h;
}

} // namespace

bool TouchCursor::start(void* coreHandle, const Hooks& h) {
    if (mRun) return true;
    if (!coreHandle) return false;
    mH = h;
    mLarge = dlsym(coreHandle, kLarge);
    mSingle = dlsym(coreHandle, kSingle);
    mDefault = dlsym(coreHandle, kDefault);
    mHybrid = dlsym(coreHandle, kHybrid);
    mCustom = dlsym(coreHandle, kCustom);
    if (!mLarge || !mSingle || !mDefault) {
        ALOGW("touch cursor: the core does not export its layout functions, cursor off");
        return false;
    }
    // Known answer: the default layout of a 1000x1200 window stacks both screens inside it.
    const RawLayout probe = ((Fn4)mDefault)(1000, 1200, false, false);
    if (probe.width != 1000 || probe.height != 1200 || !probe.topOn || !probe.botOn ||
        !rectInside(probe.top, 1000, 1200) || !rectInside(probe.bot, 1000, 1200) ||
        probe.bot[1] < probe.top[3]) {
        ALOGW("touch cursor: unexpected FramebufferLayout from the core (%u x %u), cursor off",
              probe.width, probe.height);
        return false;
    }
    mCurveMax = (float)property_get_int32("persist.gammaos.gamepad.mouse_speed_max", 750);
    mCurvePow = (float)property_get_int32("persist.gammaos.gamepad.mouse_speed_pow", 250) / 100.0f;
    mCurveDead = (float)property_get_int32("persist.gammaos.gamepad.mouse_dead", 250);
    mSpeedMult = (float)std::clamp(
            property_get_int32("persist.gammaos.gamepad.mouse_speed_mult", 100), 25, 200) / 100.0f;
    ALOGI("touch cursor: on (speed max %.0f px/s pow %.2f dead %.0f mult %.2f)", mCurveMax,
          mCurvePow, mCurveDead, mSpeedMult);
    mRelayout = true;
    mRun = true;
    mThread = std::thread([this] { loop(); });
    return true;
}

void TouchCursor::stop() {
    if (!mRun.exchange(false)) return;
    if (mThread.joinable()) mThread.join();
    release();
    std::lock_guard<std::mutex> g(mLock);
    mVisible = false;
    mSeq++;
}

void TouchCursor::setStick(float x, float y) {
    mStickX = x;
    mStickY = y;
}

void TouchCursor::setPressed(bool pressed) {
    std::lock_guard<std::mutex> g(mLock);
    if (!mRun || !mRect.ok || pressed == mPressed) return;
    mPressed = pressed;
    touchCore(pressed);
    mActiveNs = nowNs();
    mVisible = true;
    mSeq++;
}

void TouchCursor::release() {
    std::lock_guard<std::mutex> g(mLock);
    if (!mPressed) return;
    mPressed = false;
    touchCore(false);
    mSeq++;
}

// The point as seen -> the core's window pixels. An upright layout turns the picture by 90
// degrees: the core reads touch_x = 1 - (y - bottom.top) / height and touch_y = (x -
// bottom.left) / width (EmuWindow::TouchPressed, !is_rotated), the inverse of the turn
// bottomRect makes, so the seen x runs down the window's rows from its bottom edge.
void TouchCursor::touchCore(bool pressed) {
    if (!mH.touch) return;
    if (mRect.turned) mH.touch(mY, mRect.fbH - 1.0f - mX, pressed);
    else mH.touch(mX, mY, pressed);
}

void TouchCursor::moveCore() {
    if (!mH.touchMoved) return;
    if (mRect.turned) mH.touchMoved(mY, mRect.fbH - 1.0f - mX);
    else mH.touchMoved(mX, mY);
}

TouchCursor::State TouchCursor::state() const {
    std::lock_guard<std::mutex> g(mLock);
    State s;
    s.visible = mVisible && mRect.ok;
    s.pressed = mPressed;
    s.x = mX;
    s.y = mY;
    // About the 3DS stylus tip: 7 of the bottom screen's 240 rows, at least 6 pixels.
    s.radius = std::max(6.0f, (mRect.b - mRect.t) * 7.0f / 240.0f);
    s.winW = mViewW;
    s.winH = mViewH;
    s.seq = mSeq;
    return s;
}

// gammapad's MouseMode::curveSpeed: panel pixels per tick for one axis, v in -1..1.
float TouchCursor::curve(float v) const {
    const float a = std::fabs(v) * kAxisMax;
    if (a <= mCurveDead) return 0.0f;
    const float span = kAxisMax - mCurveDead;
    const float n = span > 0.0f ? std::min((a - mCurveDead) / span, 1.0f) : 1.0f;
    const float sp = mCurveMax * (kTickMs / 1000.0f) * std::pow(n, mCurvePow);
    return v < 0 ? -sp : sp;
}

// The bottom screen as seen, from the same layout call the core makes for its window
// (EmuWindow::UpdateCurrentFramebufferLayout, one window). An upright layout is turned back:
// the window's rows become the seen columns, its bottom edge the seen left.
TouchCursor::Rect TouchCursor::bottomRect(uint32_t w, uint32_t h) {
    Rect out;
    if (w == 0 || h == 0 || !mH.config) return out;
    auto cfg = [this](const char* key) { return mH.config("Layout", key); };
    const bool upright = mH.upright ? mH.upright() : cfg("upright_screen") == "true";
    const bool swap = cfg("swap_screen") == "true";
    // The Android config reader's defaults: Large Screen, proportion 2.25, top right.
    std::string v = cfg("layout_option");
    int option = v.empty() ? 2 : atoi(v.c_str());
    if (option < 0 || option > 5) option = 2;
    v = cfg("large_screen_proportion");
    const float proportion = v.empty() ? 2.25f : strtof(v.c_str(), nullptr);
    v = cfg("small_screen_position");
    const uint32_t position = v.empty() ? 0u : (uint32_t)atoi(v.c_str());
    RawLayout L;
    switch (option) {
    case 1: L = ((Fn4)mSingle)(w, h, swap, upright); break;
    case 2: L = ((FnLarge)mLarge)(w, h, swap, upright, proportion, position); break;
    case 3: L = ((FnLarge)mLarge)(w, h, swap, upright, 1.0f, kMiddleRight); break;
    // Android numbering (no SeparateWindows): 4 Hybrid, 5 Custom.
    case 4:
        if (!mHybrid) return out;
        L = ((Fn4)mHybrid)(w, h, swap, upright);
        break;
    case 5:
        // The custom layout has no upright form (its last argument is the portrait mode).
        if (!mCustom || upright) return out;
        L = ((Fn4)mCustom)(w, h, swap, false);
        break;
    default: L = ((Fn4)mDefault)(w, h, swap, upright); break;
    }
    if (!L.botOn || !rectInside(L.bot, w, h)) return out;
    if (upright) {
        out.l = (float)(h - L.bot[3]);
        out.r = (float)(h - L.bot[1]);
        out.t = (float)L.bot[0];
        out.b = (float)L.bot[2];
        out.turned = true;
        out.fbH = (float)h;
    } else {
        out.l = (float)L.bot[0];
        out.t = (float)L.bot[1];
        out.r = (float)L.bot[2];
        out.b = (float)L.bot[3];
    }
    out.ok = true;
    return out;
}

void TouchCursor::loop() {
    int sinceLayout = 0;
    while (mRun) {
        usleep(kTickMs * 1000);
        uint32_t winW = 0, winH = 0, panelW = 0, panelH = 0;
        if (mH.sizes) mH.sizes(&winW, &winH, &panelW, &panelH);
        // The layout follows the menu (layout, swap, proportion) and the window size (an LCD
        // shader changes the render scale): look again twice a second, at once when asked.
        Rect rect;
        const bool relayout = mRelayout.exchange(false) || ++sinceLayout >= 30 ||
                              winW != mWinW || winH != mWinH;
        if (relayout) {
            sinceLayout = 0;
            rect = bottomRect(winW, winH);
        }
        const float sx = mStickX.load(), sy = mStickY.load();
        std::lock_guard<std::mutex> g(mLock);
        const int64_t now = nowNs();
        if (relayout) {
            mWinW = winW;
            mWinH = winH;
            mViewW = rect.turned ? winH : winW;
            mViewH = rect.turned ? winW : winH;
            if (!rect.ok) {
                if (mRect.ok) ALOGI("touch cursor: no bottom screen in this layout");
                if (mPressed) touchCore(false);
                mPressed = false;
                if (mRect.ok || mVisible) mSeq++;
                mRect = rect;
                mVisible = false;
                continue;
            }
            if (!mPlaced || !mRect.ok) {
                mX = (rect.l + rect.r) * 0.5f;
                mY = (rect.t + rect.b) * 0.5f;
                mPlaced = true;
            } else if (rect.l != mRect.l || rect.t != mRect.t || rect.r != mRect.r ||
                       rect.b != mRect.b) {
                // Same spot on the 3DS screen in the new rectangle.
                const float fx = (mX - mRect.l) / std::max(1.0f, mRect.r - mRect.l);
                const float fy = (mY - mRect.t) / std::max(1.0f, mRect.b - mRect.t);
                mX = rect.l + fx * (rect.r - rect.l);
                mY = rect.t + fy * (rect.b - rect.t);
                mSeq++;
            }
            if (!mRect.ok) ALOGI("touch cursor: bottom screen %.0f,%.0f-%.0f,%.0f in %ux%u%s",
                                 rect.l, rect.t, rect.r, rect.b, mViewW, mViewH,
                                 rect.turned ? " (upright window, turned back)" : "");
            mRect = rect;
        }
        if (!mRect.ok) continue;
        // Mouse mode moves across the panel's seen width in the time this moves across the
        // bottom screen.
        const uint32_t seenW = mRect.turned ? panelH : panelW;
        const float k = seenW ? mSpeedMult * (mRect.r - mRect.l) / (float)seenW : 0.0f;
        const float dx = curve(sx) * k, dy = curve(sy) * k;
        if (dx != 0.0f || dy != 0.0f) {
            const float nx = std::clamp(mX + dx, mRect.l, mRect.r - 1.0f);
            const float ny = std::clamp(mY + dy, mRect.t, mRect.b - 1.0f);
            mActiveNs = now;
            if (nx != mX || ny != mY) {
                mX = nx;
                mY = ny;
                if (mPressed) moveCore();
                mSeq++;
            }
        }
        const bool visible = mPressed || (mActiveNs && now - mActiveNs < kHideNs);
        if (visible != mVisible) {
            mVisible = visible;
            mSeq++;
        }
    }
}

} // namespace azahar_nano
