#pragma once

#include "VirtualMouse.h"
#include "VirtualTouchscreen.h"

#include <linux/input.h>
#include <chrono>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace gammapad {

class MouseMode {
public:
    // Callback to send a toast message over the bridge socket
    using ToastCallback = std::function<void(const std::string&)>;

    MouseMode();
    ~MouseMode();

    void loadConfig();

    bool isActive() const { return mActive; }

    // Initialize: create timerfd. Returns timerfd for caller to add to epoll,
    // or -1 on failure. VirtualMouse is created on-demand when mode activates.
    int init();

    // Process a transformed input event. Returns true if the event was consumed
    // (either by combo detection or by mouse mode mapping).
    // When true, the event should NOT be forwarded to the virtual gamepad.
    bool processEvent(const struct input_event& ev);

    // Called when the timerfd fires. Generates mouse movement based on
    // current stick/DPAD state.
    void tick();

    // Скорость по одной оси: знак от направления, величина по степенной кривой.
    float curveSpeed(int v) const;

    // Periodic check for combo timeout (called from main loop when no
    // input events arrive). Returns true if mode was toggled.
    // Довести отложенные действия кнопок аккорда. Зовётся из опроса
    // GamepadManager, потому что окно аккорда истекает и без новых событий.
    bool checkChordTimers();

    // Одна кнопка аккорда: вся логика нажатия и отпускания. Возвращает true,
    // если событие поглощено и в приложение уходить не должно.
    bool handleChordButton(int idx, bool pressed);

    // Положить событие клавиши в очередь на виртуальный геймпад.
    void pushFlushKey(int code, int value);

    // Действие кнопки мыши, назначенной на эту половину аккорда.
    void chordAction(int idx, bool down);

    // Действие, назначенное коду кнопки. true - если код занят под мышь.
    bool performButtonAction(int code, bool pressed);

    // Check for external mouse mode toggle (e.g. QS tile setting
    // sys.gammaos.gamepad.mouse_active). Returns true if mode was toggled.
    bool checkExternalToggle();

    // Set the toast callback (called when mouse mode toggles)
    void setToastCallback(ToastCallback cb) { mToastCallback = std::move(cb); }

    // Get events that need to be flushed to the virtual gamepad
    // (e.g., combo button releases when entering mouse mode)
    const std::vector<struct input_event>& getFlushEvents() const { return mFlushEvents; }
    void clearFlushEvents() { mFlushEvents.clear(); }

    // Get the timerfd (for epoll)
    int timerFd() const { return mTimerFd; }

private:
    void setActive(bool active);
    void showToast(const std::string& message);
    void startTimer();
    void stopTimer();
    void detectScreenSize();
    void detectTouchOrientation();

    // Transform display-space coordinates to raw touchscreen coordinates,
    // counteracting InputFlinger's primary_touch_orientation rotation.
    void displayToRaw(int displayX, int displayY, int& rawX, int& rawY) const;

    // Read actual cursor position from framework shared file.
    // Updates mCursorX/mCursorY. Returns true on success.
    bool readCursorPosition();

    bool mActive;

    // Combo detection
    // Аккорд двух стиков, механика заимствована из rgp2pad: срабатывает по
    // почти одновременному нажатию, а не по удержанию. Индекс 0 - первая
    // кнопка аккорда, 1 - вторая.
    bool mChordDown[2];                                  // кнопка сейчас нажата
    std::chrono::steady_clock::time_point mChordTime[2]; // когда нажали
    bool mChordFwd[2];      // нажатие переслано в приложение, отпускание тоже надо переслать
    bool mChordActed[2];    // действие мыши выполнено, при отпускании его надо снять
    bool mChordPending[2];  // ждём, не придёт ли вторая кнопка в окно аккорда
    bool mChordUsed;        // этот аккорд уже переключил режим
    bool mTimerArmed;       // такт заведён (нужен и вне режима мыши, см. handleChordButton)
    int mComboBtn1Code;
    int mComboBtn2Code;
    int mChordMs;           // окно аккорда, мс

    // Current input state for mouse movement (left stick)
    int mStickX;     // left analog X: -32768..32767
    int mStickY;     // left analog Y: -32768..32767
    int mDpadX;      // -1, 0, 1
    int mDpadY;      // -1, 0, 1
    // Что-то прошло насквозь и ждёт SYN: в режиме мыши SYN тоже съедается, и
    // без этого признака виртуальный геймпад не получил бы завершение кадра, а
    // значит и само событие - ни кнопки, ни крестовины.
    bool mPassSynPending;

    // Right stick state for scroll wheel
    int mRStickX;    // right analog X: -32768..32767
    int mRStickY;    // right analog Y: -32768..32767

    // Sub-pixel accumulators for smooth movement
    float mAccumX;
    float mAccumY;

    // Sub-pixel accumulators for scroll wheel
    float mScrollAccumX;
    float mScrollAccumY;

    // Cursor position (read from framework via shared file)
    float mCursorX;
    float mCursorY;
    int mScreenW;
    int mScreenH;
    int mOrientation;  // 0, 90, 180, 270 from ro.input_flinger.primary_touch_orientation
    int mCursorPosFd;  // cached fd for reading cursor position file

    // Drag position tracking (independent of mouse cursor during drags)
    float mDragX;
    float mDragY;

    // Configuration
    float mStickSpeed;       // pixels per tick at max stick deflection
    float mDpadSpeed;        // pixels per tick for DPAD
    float mBoostMultiplier;  // не используется
    float mScrollSpeed;      // scroll ticks per tick at max deflection

    // Кривая скорости курсора, заимствована из rgp2pad. По каждой оси
    // отдельно: нормируем отклонение после вычета мёртвой зоны и возводим в
    // степень. Малое отклонение даёт очень медленный курсор для точного
    // наведения, полное - быстрый бросок через экран.
    float mCurveMax;         // пикселей в секунду на полном отклонении
    float mCurvePow;         // показатель степени
    float mCurveDead;        // мёртвая зона в единицах оси

    // Configurable button mappings for mouse actions
    int mClickBtnCode;       // gamepad button for touch tap (default: BTN_A)
    int mBackBtnCode;        // gamepad button for KEY_BACK (default: BTN_B)
    int mRightClickBtnCode;  // gamepad button for right click (default: BTN_Y)

    std::unique_ptr<VirtualMouse> mMouse;
    std::unique_ptr<VirtualTouchscreen> mTouchscreen;
    int mTimerFd;

    ToastCallback mToastCallback;
    std::vector<struct input_event> mFlushEvents;
};

} // namespace gammapad
