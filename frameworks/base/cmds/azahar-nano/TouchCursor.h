// TouchCursor: the 3DS touchscreen on a device without one (GammaOS RG52 Mini).
//
// RG52 Mini: у консоли нет сенсорного экрана, а нижний экран 3DS - сенсорный. Правый стик
// водит курсор по нижнему экрану, R3 касается (удержание R3 - ведение по экрану). Курсор живёт
// в пикселях окна ядра, каким его видит игрок, и не выходит за прямоугольник нижнего экрана;
// прямоугольник дают функции раскладки самого ядра (Layout::*, экспортированы из
// libazahar-nano-core.so), те же, которыми ядро раскладывает своё окно, - поэтому курсор следует
// любой раскладке, в том числе сменённой на ходу в меню.
//
// Панель RG52 сканируется портретом (720x1280), и ядро рисует раскладку повёрнутой (upright).
// Тогда курсор считается в повёрнутых обратно координатах («как видно»), стик двигает его так,
// как видит игрок, а в ядро касание уходит в пикселях портретного окна - по той же формуле,
// которой ядро переводит касание повёрнутой раскладки (EmuWindow::TouchPressed, !is_rotated).
//
// Скорость - кривая и настройки режима мыши gammapad (persist.gammaos.gamepad.mouse_speed_max,
// _speed_pow, _dead, _speed_mult; frameworks/native/services/gammapad/MouseMode.cpp) с поправкой
// на масштаб: нижний экран курсор пересекает за то же время, за какое указатель мыши
// пересекает всю панель.
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

namespace azahar_nano {

class TouchCursor {
public:
    struct Hooks {
        // The core's touch input in window pixels (azn_touch / azn_touch_moved).
        std::function<void(float x, float y, bool pressed)> touch;
        std::function<void(float x, float y)> touchMoved;
        // The core's window size and the panel's own size, in pixels.
        std::function<void(uint32_t* winW, uint32_t* winH, uint32_t* panelW, uint32_t* panelH)> sizes;
        // A config.ini value as the running game sees it (per-game override first).
        std::function<std::string(const char* section, const char* key)> config;
        // Whether the core lays the window out upright (azn_set_upright overrides config.ini).
        std::function<bool()> upright;
    };
    // coreHandle: the core's dlopen handle. Fails (and the cursor stays off) when the layout
    // functions are missing or do not answer as expected.
    bool start(void* coreHandle, const Hooks& h);
    void stop();
    bool running() const { return mRun.load(); }

    void setStick(float x, float y);   // the right stick, -1..1 (input thread)
    void setPressed(bool pressed);     // R3 (input thread)
    void release();                    // lift a touch in progress (menu, pause, sleep)
    void relayout() { mRelayout = true; }   // the layout settings may have changed

    struct State {
        bool visible = false, pressed = false;
        float x = 0, y = 0;            // window pixels as seen (an upright window turned back)
        float radius = 0;              // window pixels, follows the bottom screen's size
        uint32_t winW = 0, winH = 0;   // the window as seen
        uint64_t seq = 0;              // changes whenever the drawing changes
    };
    State state() const;

private:
    // The bottom screen as seen. turned: the window is laid out upright, fbH its height.
    struct Rect { float l = 0, t = 0, r = 0, b = 0; bool ok = false, turned = false; float fbH = 0; };
    void loop();
    Rect bottomRect(uint32_t winW, uint32_t winH);
    float curve(float v) const;
    void touchCore(bool pressed);   // the cursor's point to the core (mLock held)
    void moveCore();

    Hooks mH;
    void* mLarge = nullptr;    // Layout::LargeFrameLayout
    void* mSingle = nullptr;   // Layout::SingleFrameLayout
    void* mDefault = nullptr;  // Layout::DefaultFrameLayout
    void* mHybrid = nullptr;   // Layout::HybridScreenLayout
    void* mCustom = nullptr;   // Layout::CustomFrameLayout
    // gammapad mouse mode settings
    float mCurveMax = 750.0f, mCurvePow = 2.5f, mCurveDead = 250.0f, mSpeedMult = 1.0f;

    std::atomic<bool> mRun{false};
    std::atomic<bool> mRelayout{true};
    std::atomic<float> mStickX{0.0f}, mStickY{0.0f};
    std::thread mThread;
    mutable std::mutex mLock;   // everything below
    Rect mRect;
    float mX = 0, mY = 0;
    bool mPlaced = false;
    bool mPressed = false;
    bool mVisible = false;
    int64_t mActiveNs = 0;      // last movement or touch
    uint32_t mWinW = 0, mWinH = 0;     // the core's window
    uint32_t mViewW = 0, mViewH = 0;   // the same window as seen
    uint64_t mSeq = 0;
};

} // namespace azahar_nano
