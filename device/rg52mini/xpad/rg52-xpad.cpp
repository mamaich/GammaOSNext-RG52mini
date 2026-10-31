// rg52-xpad: RG52 Mini как проводной геймпад Xbox 360 для компьютера.
//
// Запускает init по sys.rg52.xpad.enable=1 (пункт в выборе режима USB: экран USB в
// Настройках и USB Settings в nano). Служба:
//   * забирает контроллер USB (UDC) у гаджета Android g1 и отдаёт его своему гаджету xpad:
//     VID:PID 045e:028e и интерфейс класса производителя 0xFF/0x5D/0x01, как у проводного
//     Xbox 360 - драйвер к нему Windows подключает сама. Интерфейс обслуживается здесь же,
//     через FunctionFS;
//   * захватывает (EVIOCGRAB) виртуальный геймпад gammapad, чтобы кнопки уходили только на
//     компьютер, и шлёт его состояние отчётами XInput (20 байт);
//   * вибрацию от компьютера возвращает геймпаду как FF_RUMBLE (gammapad передаёт её моторам).
// Останавливается по sys.rg52.xpad.enable=0 (долгое нажатие выключателя: PhoneWindowManager,
// nano), по SIGTERM или по удержанию выключателя 2 с (запасной путь, если до него не дошли):
// возвращает контроллер гаджету g1 и отпускает геймпад.
//
// Гаджет xpad создаётся один раз и остаётся до перезагрузки: удаление гаджета в этом ядре
// уничтожает устройство android0, по которому Android следит за USB (android_device_destroy
// ищет устройство по devt 0:0, а оно у всех гаджетов одно).
//
// Свойства: sys.rg52.xpad.active (1, пока служба работает), sys.rg52.xpad.state (starting,
// waiting, connected, error:<что>, stopped). rg52-xpad --cleanup - уборка после аварийного
// завершения (запускает init, когда служба остановилась).
//
// Вывод - в logcat (тег rg52-xpad), по-английски.

#define LOG_TAG "rg52-xpad"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/usb/ch9.h>
#include <linux/usb/functionfs.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <android-base/file.h>
#include <android-base/properties.h>
#include <android-base/strings.h>
#include <log/log.h>

namespace {

constexpr const char* kGadget = "/config/usb_gadget/xpad";
constexpr const char* kAndroidGadget = "/config/usb_gadget/g1";
constexpr const char* kFfsDir = "/dev/usb-ffs/xpad";
constexpr const char* kPropEnable = "sys.rg52.xpad.enable";
constexpr const char* kPropActive = "sys.rg52.xpad.active";
constexpr const char* kPropState = "sys.rg52.xpad.state";
constexpr int kPowerHoldMs = 2000;

// Дескриптор класса производителя 0x21 проводного Xbox 360 (из дескрипторов настоящего
// геймпада): в нём повторены адреса и размеры конечных точек - 0x81 IN 20 байт, 0x01 OUT
// 8 байт. Без него Windows ставит драйвер, но XInput геймпада не видит (проверено 31.10.2026).
// FunctionFS принимает его с правкой ядра (f_fs.c, класс-дескриптор интерфейса класса
// производителя); на ядре без правки - EINVAL, и интерфейс уходит без него.
const uint8_t kXinputClassDesc[17] = {0x11, 0x21, 0x00, 0x01, 0x01, 0x25, 0x81, 0x14, 0x00,
                                      0x00, 0x00, 0x00, 0x13, 0x01, 0x08, 0x00, 0x00};

// Кнопки отчёта XInput.
enum : uint16_t {
    XB_UP = 0x0001, XB_DOWN = 0x0002, XB_LEFT = 0x0004, XB_RIGHT = 0x0008,
    XB_START = 0x0010, XB_BACK = 0x0020, XB_LS = 0x0040, XB_RS = 0x0080,
    XB_LB = 0x0100, XB_RB = 0x0200, XB_GUIDE = 0x0400,
    XB_A = 0x1000, XB_B = 0x2000, XB_X = 0x4000, XB_Y = 0x8000,
};

std::atomic<bool> gStop{false};

int64_t nowMs() {
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

void setState(const std::string& s) {
    android::base::SetProperty(kPropState, s);
    ALOGI("state: %s", s.c_str());
}

bool writeFile(const std::string& path, const std::string& val) {
    int fd = open(path.c_str(), O_WRONLY | O_CLOEXEC);
    if (fd < 0) return false;
    ssize_t n = write(fd, val.c_str(), val.size());
    int err = errno;
    close(fd);
    errno = err;
    return n == (ssize_t)val.size();
}

std::string readFile(const std::string& path) {
    std::string s;
    android::base::ReadFileToString(path, &s);
    return android::base::Trim(s);
}

bool mkdirOk(const std::string& path, mode_t mode = 0770) {
    return mkdir(path.c_str(), mode) == 0 || errno == EEXIST;
}

// ---------------------------------------------------------------------------------------
// Состояние геймпада
// ---------------------------------------------------------------------------------------

struct PadState {
    uint16_t buttons = 0;   // без крестовины от ABS_HAT0
    int hatX = 0, hatY = 0;
    uint8_t lt = 0, rt = 0;
    int16_t lx = 0, ly = 0, rx = 0, ry = 0;
};

std::mutex gStateMutex;
std::condition_variable gStateCv;
PadState gState;
bool gStateDirty = true;
std::atomic<bool> gEnabled{false};   // компьютер включил конфигурацию (FUNCTIONFS_ENABLE)

void buildReport(const PadState& s, uint8_t r[20]) {
    uint16_t b = s.buttons;
    if (s.hatY < 0) b |= XB_UP;
    if (s.hatY > 0) b |= XB_DOWN;
    if (s.hatX < 0) b |= XB_LEFT;
    if (s.hatX > 0) b |= XB_RIGHT;
    memset(r, 0, 20);
    r[0] = 0x00;
    r[1] = 0x14;
    r[2] = b & 0xff;
    r[3] = b >> 8;
    r[4] = s.lt;
    r[5] = s.rt;
    auto put16 = [&](int off, int16_t v) {
        r[off] = (uint16_t)v & 0xff;
        r[off + 1] = (uint16_t)v >> 8;
    };
    put16(6, s.lx);
    put16(8, s.ly);
    put16(10, s.rx);
    put16(12, s.ry);
}

// ---------------------------------------------------------------------------------------
// Устройства ввода
// ---------------------------------------------------------------------------------------

struct AxisRange {
    int min = -32768, max = 32767;
};

enum class Role { Pad, Keys, Power };

struct InDev {
    int fd = -1;
    Role role = Role::Pad;
    std::string node, name;
    // Раскладка осей: у виртуального геймпада gammapad правый стик - Z/RZ, курки - GAS/BRAKE
    // (как у Xbox по Bluetooth); у геймпада с раскладкой xpad Linux - RX/RY и Z/RZ.
    int axRX = ABS_Z, axRY = ABS_RZ, axLT = ABS_BRAKE, axRT = ABS_GAS;
    // Курки аналоговые: BTN_TL2/BTN_TR2, которые объявляет виртуальный геймпад, тогда не в
    // счёт - отпускание кнопки обнулило бы ещё нажатый курок.
    bool analogTriggers = false;
    AxisRange range[ABS_CNT];
};

std::mutex gDevMutex;   // gPadFd читает поток вибрации
int gPadFd = -1;
std::vector<InDev> gDevs;
bool gHavePad = false;
int64_t gPowerDownAt = 0;

bool testBit(const unsigned long* bits, int bit) {
    return (bits[bit / (8 * sizeof(long))] >> (bit % (8 * sizeof(long)))) & 1;
}

int16_t stickValue(int v, const AxisRange& r, bool invert) {
    const double c = (r.min + r.max) / 2.0, half = (r.max - r.min) / 2.0;
    if (half <= 0) return 0;
    double f = (v - c) / half;
    if (invert) f = -f;
    if (f > 1) f = 1;
    if (f < -1) f = -1;
    int out = (int)(f >= 0 ? f * 32767.0 : f * 32768.0);
    return (int16_t)out;
}

uint8_t triggerValue(int v, const AxisRange& r) {
    if (r.max <= r.min) return v ? 255 : 0;
    int out = (int)((double)(v - r.min) * 255.0 / (r.max - r.min) + 0.5);
    return (uint8_t)(out < 0 ? 0 : out > 255 ? 255 : out);
}

uint16_t keyBit(int code) {
    switch (code) {
        case BTN_A: return XB_A;
        case BTN_B: return XB_B;
        case BTN_X: return XB_X;   // как в Android: 307 - BUTTON_X, левая кнопка
        case BTN_Y: return XB_Y;
        case BTN_TL: return XB_LB;
        case BTN_TR: return XB_RB;
        case BTN_SELECT: return XB_BACK;
        case BTN_START: return XB_START;
        case BTN_MODE: return XB_GUIDE;
        case BTN_THUMBL: return XB_LS;
        case BTN_THUMBR: return XB_RS;
        case BTN_DPAD_UP: return XB_UP;
        case BTN_DPAD_DOWN: return XB_DOWN;
        case BTN_DPAD_LEFT: return XB_LEFT;
        case BTN_DPAD_RIGHT: return XB_RIGHT;
        case KEY_HOMEPAGE: return XB_GUIDE;   // HOME корпуса (rk3562-joystick)
        case KEY_BACK: return XB_BACK;        // BACK корпуса
        default: return 0;
    }
}

// Одно событие ввода в состояние. Возвращает true, если состояние поменялось.
bool applyEvent(const InDev& d, const input_event& ev, PadState& s) {
    if (ev.type == EV_KEY) {
        if (ev.value == 2) return false;
        const bool down = ev.value != 0;
        if (ev.code == BTN_TL2 || ev.code == BTN_TR2) {
            if (d.analogTriggers) return false;
            (ev.code == BTN_TL2 ? s.lt : s.rt) = down ? 255 : 0;
            return true;
        }
        const uint16_t bit = keyBit(ev.code);
        if (!bit) return false;
        const uint16_t old = s.buttons;
        s.buttons = down ? (s.buttons | bit) : (s.buttons & ~bit);
        return s.buttons != old;
    }
    if (ev.type == EV_ABS && ev.code < ABS_CNT) {
        const AxisRange& r = d.range[ev.code];
        if (ev.code == ABS_X) s.lx = stickValue(ev.value, r, false);
        else if (ev.code == ABS_Y) s.ly = stickValue(ev.value, r, true);
        else if (ev.code == d.axRX) s.rx = stickValue(ev.value, r, false);
        else if (ev.code == d.axRY) s.ry = stickValue(ev.value, r, true);
        else if (ev.code == d.axLT) s.lt = triggerValue(ev.value, r);
        else if (ev.code == d.axRT) s.rt = triggerValue(ev.value, r);
        else if (ev.code == ABS_HAT0X) s.hatX = ev.value < 0 ? -1 : ev.value > 0 ? 1 : 0;
        else if (ev.code == ABS_HAT0Y) s.hatY = ev.value < 0 ? -1 : ev.value > 0 ? 1 : 0;
        else return false;
        return true;
    }
    return false;
}

// Текущее положение осей и кнопок устройства - в состояние (после захвата).
void loadCurrent(const InDev& d, PadState& s) {
    unsigned long keys[KEY_CNT / (8 * sizeof(long)) + 1] = {};
    if (ioctl(d.fd, EVIOCGKEY(sizeof(keys)), keys) >= 0) {
        for (int code = 0; code < KEY_CNT; code++) {
            if (!testBit(keys, code)) continue;
            input_event ev = {};
            ev.type = EV_KEY;
            ev.code = code;
            ev.value = 1;
            applyEvent(d, ev, s);
        }
    }
    unsigned long absb[ABS_CNT / (8 * sizeof(long)) + 1] = {};
    if (ioctl(d.fd, EVIOCGBIT(EV_ABS, sizeof(absb)), absb) >= 0) {
        for (int code = 0; code < ABS_CNT; code++) {
            if (!testBit(absb, code)) continue;
            input_absinfo ai = {};
            if (ioctl(d.fd, EVIOCGABS(code), &ai) < 0) continue;
            input_event ev = {};
            ev.type = EV_ABS;
            ev.code = code;
            ev.value = ai.value;
            applyEvent(d, ev, s);
        }
    }
}

bool grabWithRetry(int fd, const std::string& node) {
    // nano может держать устройство захваченным ещё долю секунды после команды на старт
    for (int i = 0; i < 50 && !gStop; i++) {
        if (ioctl(fd, EVIOCGRAB, 1) == 0) return true;
        if (errno != EBUSY) break;
        usleep(100 * 1000);
    }
    ALOGE("cannot grab %s: %s", node.c_str(), strerror(errno));
    return false;
}

void closeDevices() {
    std::lock_guard<std::mutex> lk(gDevMutex);
    for (auto& d : gDevs) {
        if (d.role != Role::Power) ioctl(d.fd, EVIOCGRAB, 0);
        close(d.fd);
    }
    gDevs.clear();
    gPadFd = -1;
    gHavePad = false;
}

// Найти и захватить геймпад. Основной - виртуальный геймпад gammapad (phys
// gammapad-virtual): в нём уже калибровка стиков и настройки GammaOS. Если gammapad
// выключен - сам геймпад корпуса. Клавиатура gammapad (кнопки, назначенные клавишами)
// тоже захватывается. Устройства с KEY_POWER открываются без захвата - только чтобы
// заметить удержание выключателя.
void scanDevices() {
    closeDevices();
    DIR* dir = opendir("/dev/input");
    if (!dir) return;
    std::vector<InDev> found;
    InDev fallbackPad;
    while (dirent* e = readdir(dir)) {
        if (strncmp(e->d_name, "event", 5) != 0) continue;
        const std::string node = std::string("/dev/input/") + e->d_name;
        int fd = open(node.c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) fd = open(node.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        char phys[128] = {}, name[128] = {};
        ioctl(fd, EVIOCGPHYS(sizeof(phys) - 1), phys);
        ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name);
        unsigned long evb[EV_CNT / (8 * sizeof(long)) + 1] = {};
        unsigned long keyb[KEY_CNT / (8 * sizeof(long)) + 1] = {};
        unsigned long absb[ABS_CNT / (8 * sizeof(long)) + 1] = {};
        ioctl(fd, EVIOCGBIT(0, sizeof(evb)), evb);
        ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keyb)), keyb);
        ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absb)), absb);
        InDev d;
        d.fd = fd;
        d.node = node;
        d.name = name;
        if (!strcmp(phys, "gammapad-virtual")) d.role = Role::Pad;
        else if (!strcmp(phys, "gammapad-keyboard")) d.role = Role::Keys;
        else if (testBit(keyb, KEY_POWER) && !testBit(absb, ABS_X)) d.role = Role::Power;
        else if (!strncmp(phys, "gammapad-", 9)) { close(fd); continue; }   // мышь, тачскрин
        else if (testBit(absb, ABS_X) && testBit(keyb, BTN_A) && fallbackPad.fd < 0) {
            fallbackPad = d;   // геймпад корпуса, если gammapad нет
            continue;
        } else { close(fd); continue; }
        found.push_back(d);
    }
    closedir(dir);
    bool havePad = false;
    for (auto& d : found) havePad |= d.role == Role::Pad;
    if (!havePad && fallbackPad.fd >= 0) {
        fallbackPad.role = Role::Pad;
        found.push_back(fallbackPad);
    } else if (fallbackPad.fd >= 0) {
        close(fallbackPad.fd);
    }

    PadState s;
    {
        std::lock_guard<std::mutex> lk(gStateMutex);
        s = gState;
        s.buttons = 0; s.hatX = s.hatY = 0; s.lt = s.rt = 0;
        s.lx = s.ly = s.rx = s.ry = 0;
    }
    std::lock_guard<std::mutex> lk(gDevMutex);
    for (auto& d : found) {
        if (d.role != Role::Power && !grabWithRetry(d.fd, d.node)) { close(d.fd); continue; }
        if (d.role == Role::Pad) {
            unsigned long absb[ABS_CNT / (8 * sizeof(long)) + 1] = {};
            ioctl(d.fd, EVIOCGBIT(EV_ABS, sizeof(absb)), absb);
            if (!testBit(absb, ABS_GAS) && !testBit(absb, ABS_BRAKE) && testBit(absb, ABS_RX)) {
                d.axRX = ABS_RX; d.axRY = ABS_RY; d.axLT = ABS_Z; d.axRT = ABS_RZ;
            }
            d.analogTriggers = testBit(absb, d.axLT) && testBit(absb, d.axRT);
            for (int code = 0; code < ABS_CNT; code++) {
                if (!testBit(absb, code)) continue;
                input_absinfo ai = {};
                if (ioctl(d.fd, EVIOCGABS(code), &ai) == 0) {
                    d.range[code].min = ai.minimum;
                    d.range[code].max = ai.maximum;
                }
            }
            gPadFd = d.fd;
            gHavePad = true;
        }
        if (d.role != Role::Power) loadCurrent(d, s);
        ALOGI("input: %s \"%s\" as %s", d.node.c_str(), d.name.c_str(),
              d.role == Role::Pad ? "gamepad" : d.role == Role::Keys ? "keys" : "power key");
        gDevs.push_back(d);
    }
    {
        std::lock_guard<std::mutex> slk(gStateMutex);
        gState = s;
        gStateDirty = true;
    }
    gStateCv.notify_all();
}

// ---------------------------------------------------------------------------------------
// Вибрация
// ---------------------------------------------------------------------------------------

std::mutex gRumbleMutex;
int gRumbleLeft = 0, gRumbleRight = 0;   // 0..255 от компьютера
int gEffectId = -1;
int gEffectFd = -1;
int64_t gRumblePlayedAt = 0;

// Эффект длится 2 с и подновляется раз в секунду, пока компьютер держит вибрацию: так она
// не залипнет, если служба упадёт. Вызывается из главного цикла.
void rumbleTick(bool force) {
    std::lock_guard<std::mutex> lk(gRumbleMutex);
    std::lock_guard<std::mutex> dlk(gDevMutex);
    if (gPadFd < 0) return;
    if (gEffectFd != gPadFd) { gEffectId = -1; gEffectFd = gPadFd; }
    const bool on = gRumbleLeft || gRumbleRight;
    const int64_t now = nowMs();
    if (!force && (!on || now - gRumblePlayedAt < 1000)) return;
    if (!on) {
        if (gEffectId >= 0) {
            input_event ev = {};
            ev.type = EV_FF;
            ev.code = gEffectId;
            ev.value = 0;
            write(gPadFd, &ev, sizeof(ev));
        }
        return;
    }
    ff_effect e = {};
    e.type = FF_RUMBLE;
    e.id = gEffectId;
    e.u.rumble.strong_magnitude = gRumbleLeft * 257;
    e.u.rumble.weak_magnitude = gRumbleRight * 257;
    e.replay.length = 2000;
    if (ioctl(gPadFd, EVIOCSFF, &e) < 0) {
        ALOGW("rumble upload failed: %s", strerror(errno));
        gEffectId = -1;
        return;
    }
    gEffectId = e.id;
    input_event ev = {};
    ev.type = EV_FF;
    ev.code = gEffectId;
    ev.value = 1;
    write(gPadFd, &ev, sizeof(ev));
    gRumblePlayedAt = now;
}

// ---------------------------------------------------------------------------------------
// USB: гаджет и FunctionFS
// ---------------------------------------------------------------------------------------

int gEp0 = -1, gEpIn = -1, gEpOut = -1;
std::string gController;

void appendLe32(std::vector<uint8_t>& v, uint32_t x) {
    for (int i = 0; i < 4; i++) v.push_back((x >> (8 * i)) & 0xff);
}

void appendDescs(std::vector<uint8_t>& v, bool vendorDesc, bool hs) {
    usb_interface_descriptor intf = {};
    intf.bLength = sizeof(intf);
    intf.bDescriptorType = USB_DT_INTERFACE;
    intf.bInterfaceNumber = 0;
    intf.bNumEndpoints = 2;
    intf.bInterfaceClass = 0xff;
    intf.bInterfaceSubClass = 0x5d;
    intf.bInterfaceProtocol = 0x01;
    const uint8_t* p = (const uint8_t*)&intf;
    v.insert(v.end(), p, p + sizeof(intf));
    if (vendorDesc) v.insert(v.end(), kXinputClassDesc, kXinputClassDesc + sizeof(kXinputClassDesc));
    usb_endpoint_descriptor_no_audio in = {}, out = {};
    in.bLength = out.bLength = USB_DT_ENDPOINT_SIZE;
    in.bDescriptorType = out.bDescriptorType = USB_DT_ENDPOINT;
    in.bEndpointAddress = 0x81;
    out.bEndpointAddress = 0x01;
    in.bmAttributes = out.bmAttributes = USB_ENDPOINT_XFER_INT;
    in.wMaxPacketSize = out.wMaxPacketSize = 32;
    // full speed: в миллисекундах; high speed: 2^(n-1) микрокадров по 125 мкс
    in.bInterval = hs ? 4 : 1;     // 1 мс
    out.bInterval = hs ? 7 : 8;    // 8 мс
    p = (const uint8_t*)&in;
    v.insert(v.end(), p, p + USB_DT_ENDPOINT_SIZE);
    p = (const uint8_t*)&out;
    v.insert(v.end(), p, p + USB_DT_ENDPOINT_SIZE);
}

bool writeFfsDescriptors(bool vendorDesc) {
    std::vector<uint8_t> v;
    appendLe32(v, FUNCTIONFS_DESCRIPTORS_MAGIC_V2);
    appendLe32(v, 0);   // длина - ниже
    // Без FUNCTIONFS_ALL_CTRL_RECIP: в этом ядре android_setup (configfs.c) отдаёт запрос
    // функциям раньше composite_setup, и с этим флагом сюда ушли бы и стандартные запросы к
    // устройству (GET_DESCRIPTOR) - перечисление бы сломалось.
    appendLe32(v, FUNCTIONFS_HAS_FS_DESC | FUNCTIONFS_HAS_HS_DESC);
    const uint32_t count = vendorDesc ? 4 : 3;
    appendLe32(v, count);
    appendLe32(v, count);
    appendDescs(v, vendorDesc, false);
    appendDescs(v, vendorDesc, true);
    const uint32_t len = v.size();
    for (int i = 0; i < 4; i++) v[4 + i] = (len >> (8 * i)) & 0xff;
    if (write(gEp0, v.data(), v.size()) != (ssize_t)v.size()) {
        ALOGW("descriptors%s rejected: %s", vendorDesc ? " with the XInput class descriptor" : "",
              strerror(errno));
        return false;
    }
    usb_functionfs_strings_head strings = {};
    strings.magic = FUNCTIONFS_STRINGS_MAGIC;
    strings.length = sizeof(strings);
    strings.str_count = 0;
    strings.lang_count = 0;
    if (write(gEp0, &strings, sizeof(strings)) != (ssize_t)sizeof(strings)) {
        ALOGE("strings rejected: %s", strerror(errno));
        return false;
    }
    ALOGI("FunctionFS ready (%s)", vendorDesc ? "with the XInput class descriptor"
                                              : "without the XInput class descriptor");
    return true;
}

bool isMounted(const char* dir) {
    // /proc/mounts - символьная ссылка на self/mounts, а ReadFileToString по умолчанию
    // открывает с O_NOFOLLOW: читалась пустая строка, и второй запуск падал на EBUSY.
    std::string m;
    android::base::ReadFileToString("/proc/self/mounts", &m);
    return m.find(std::string(" ") + dir + " ") != std::string::npos;
}

std::string findController() {
    std::string c = android::base::GetProperty("sys.usb.controller", "");
    if (!c.empty()) return c;
    if (DIR* d = opendir("/sys/class/udc")) {
        while (dirent* e = readdir(d)) {
            if (e->d_name[0] != '.') { c = e->d_name; break; }
        }
        closedir(d);
    }
    return c;
}

bool setupGadget() {
    const std::string g = kGadget;
    if (!mkdirOk(g)) { ALOGE("mkdir %s: %s", g.c_str(), strerror(errno)); return false; }
    writeFile(g + "/UDC", "none");   // на случай прошлого незавершённого запуска
    writeFile(g + "/idVendor", "0x045e");
    writeFile(g + "/idProduct", "0x028e");
    writeFile(g + "/bcdDevice", "0x0114");
    writeFile(g + "/bcdUSB", "0x0200");
    writeFile(g + "/bDeviceClass", "0xff");
    writeFile(g + "/bDeviceSubClass", "0xff");
    writeFile(g + "/bDeviceProtocol", "0xff");
    // Настоящий проводной Xbox 360 - full speed; так же и здесь, если ядро позволяет.
    if (!writeFile(g + "/max_speed", "full-speed")) ALOGW("max_speed: %s", strerror(errno));
    mkdirOk(g + "/strings/0x409");
    writeFile(g + "/strings/0x409/manufacturer", "AISLPC");
    writeFile(g + "/strings/0x409/product", "RG52 Mini Controller");
    writeFile(g + "/strings/0x409/serialnumber",
              android::base::GetProperty("ro.serialno", "0123456789"));
    mkdirOk(g + "/configs/c.1");
    mkdirOk(g + "/configs/c.1/strings/0x409");
    writeFile(g + "/configs/c.1/strings/0x409/configuration", "XInput");
    writeFile(g + "/configs/c.1/MaxPower", "500");
    if (!mkdirOk(g + "/functions/ffs.xpad")) {
        ALOGE("mkdir ffs.xpad: %s", strerror(errno));
        return false;
    }
    const std::string link = g + "/configs/c.1/f1";
    struct stat st;
    if (lstat(link.c_str(), &st) != 0 && symlink((g + "/functions/ffs.xpad").c_str(), link.c_str()) != 0) {
        ALOGE("link ffs.xpad: %s", strerror(errno));
        return false;
    }
    mkdirOk("/dev/usb-ffs", 0775);
    mkdirOk(kFfsDir);
    // FunctionFS остаётся смонтированной после прошлого запуска (как у adb и mtp).
    // EBUSY - экземпляр xpad уже смонтирован: тоже годится.
    if (!isMounted(kFfsDir) && mount("xpad", kFfsDir, "functionfs", 0, "") != 0 && errno != EBUSY) {
        ALOGE("mount functionfs: %s", strerror(errno));
        return false;
    }
    return true;
}

bool openFfs() {
    const std::string ep0 = std::string(kFfsDir) + "/ep0";
    for (int pass = 0; pass < 2; pass++) {
        gEp0 = open(ep0.c_str(), O_RDWR | O_CLOEXEC);
        if (gEp0 < 0) { ALOGE("open %s: %s", ep0.c_str(), strerror(errno)); return false; }
        if (writeFfsDescriptors(pass == 0)) break;
        close(gEp0);
        gEp0 = -1;
    }
    if (gEp0 < 0) return false;
    // Конечные точки - в порядке дескрипторов: ep1 - IN (отчёты), ep2 - OUT (вибрация).
    // O_NONBLOCK: пока компьютер не включил конфигурацию, вызов не висит, а сразу EAGAIN.
    gEpIn = open((std::string(kFfsDir) + "/ep1").c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC);
    gEpOut = open((std::string(kFfsDir) + "/ep2").c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (gEpIn < 0 || gEpOut < 0) { ALOGE("open endpoints: %s", strerror(errno)); return false; }
    return true;
}

// Контроллер - гаджету xpad. Гаджет Android отпускает его заранее; если init успеет
// снова привязать g1 (пересборка его функций), повторяем.
bool bindXpad() {
    gController = findController();
    if (gController.empty()) { ALOGE("no USB device controller"); return false; }
    for (int i = 0; i < 20 && !gStop; i++) {
        writeFile(std::string(kAndroidGadget) + "/UDC", "none");
        if (writeFile(std::string(kGadget) + "/UDC", gController)) {
            ALOGI("USB controller %s taken from the Android gadget", gController.c_str());
            return true;
        }
        ALOGW("bind %s: %s", gController.c_str(), strerror(errno));
        usleep(200 * 1000);
    }
    return false;
}

// Вернуть контроллер гаджету Android. Его функции за это время настроил init по
// sys.usb.config (Android, увидев отключение, обычно возвращается к adb или «только
// зарядке»); если связывать нечего, init сделает это сам при следующем выборе режима.
void releaseUsb() {
    const std::string cur = readFile(std::string(kGadget) + "/UDC");
    if (!cur.empty() && cur != "none") writeFile(std::string(kGadget) + "/UDC", "none");
    const std::string ctl = gController.empty() ? findController() : gController;
    const std::string cfg = android::base::GetProperty("sys.usb.config", "none");
    const std::string g1 = readFile(std::string(kAndroidGadget) + "/UDC");
    if (cfg != "none" && !cfg.empty() && (g1.empty() || g1 == "none") && !ctl.empty()) {
        if (writeFile(std::string(kAndroidGadget) + "/UDC", ctl))
            ALOGI("USB controller given back to the Android gadget (%s)", cfg.c_str());
        else
            ALOGW("Android gadget not bound back (%s): %s", cfg.c_str(), strerror(errno));
    }
}

// Запросы к интерфейсу и его конечным точкам. В этом ядре сюда приходят и стандартные
// (android_setup спрашивает функции раньше composite): GET_STATUS и GET_INTERFACE получают
// нули, SET_INTERFACE, CLEAR_FEATURE и прочие без данных - подтверждение. Из запросов
// класса производителя драйвер Windows спрашивает возможности геймпада.
void handleSetup(const usb_ctrlrequest& s) {
    static int logged = 0;
    const uint16_t value = s.wValue, index = s.wIndex, length = s.wLength;
    if (logged < 40) {
        logged++;
        ALOGI("setup: type 0x%02x req 0x%02x value 0x%04x index 0x%04x length %u",
              s.bRequestType, s.bRequest, value, index, length);
    }
    const bool in = s.bRequestType & USB_DIR_IN;
    if (in && (s.bRequestType & USB_TYPE_MASK) == USB_TYPE_STANDARD &&
        (s.bRequest == USB_REQ_GET_STATUS || s.bRequest == USB_REQ_GET_INTERFACE)) {
        const uint8_t zero[2] = {0, 0};
        size_t n = s.bRequest == USB_REQ_GET_STATUS ? 2 : 1;
        if (n > length) n = length;
        if (write(gEp0, zero, n) < 0) ALOGW("setup reply: %s", strerror(errno));
        return;
    }
    if (in && (s.bRequestType & USB_TYPE_MASK) == USB_TYPE_VENDOR && s.bRequest == 0x01) {
        // Возможности геймпада: какие кнопки и оси есть (маска в раскладке отчёта)...
        static const uint8_t caps[20] = {0x00, 0x14, 0xff, 0xf7, 0xff, 0xff, 0xc0, 0xff, 0xc0, 0xff,
                                         0xc0, 0xff, 0xc0, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
        // ...и вибромоторы
        static const uint8_t rumbleCaps[8] = {0x00, 0x08, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00};
        const uint8_t* data = nullptr;
        size_t n = 0;
        if (value == 0x0100) { data = caps; n = sizeof(caps); }
        else if (value == 0x0000 && (s.bRequestType & USB_RECIP_MASK) == USB_RECIP_INTERFACE) {
            data = rumbleCaps; n = sizeof(rumbleCaps);
        }
        if (data) {
            if (n > length) n = length;
            if (write(gEp0, data, n) < 0) ALOGW("setup reply: %s", strerror(errno));
            return;
        }
    }
    if (in) {
        char c;
        read(gEp0, &c, 0);   // чтение на запрос IN - отказ (STALL)
    } else {
        std::vector<uint8_t> buf(length ? length : 1);
        read(gEp0, buf.data(), length);   // OUT: принять данные (или пустую фазу) и подтвердить
    }
}

void ep0Thread() {
    pollfd p = {gEp0, POLLIN, 0};
    while (!gStop) {
        if (poll(&p, 1, 200) <= 0) continue;
        usb_functionfs_event evs[4];
        ssize_t n = read(gEp0, evs, sizeof(evs));
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN) continue;
            ALOGW("ep0: %s", strerror(errno));
            usleep(100 * 1000);
            continue;
        }
        for (ssize_t i = 0; i < n / (ssize_t)sizeof(evs[0]); i++) {
            switch (evs[i].type) {
                case FUNCTIONFS_ENABLE: {
                    gEnabled = true;
                    usb_endpoint_descriptor in = {}, out = {};
                    ioctl(gEpIn, FUNCTIONFS_ENDPOINT_DESC, &in);
                    ioctl(gEpOut, FUNCTIONFS_ENDPOINT_DESC, &out);
                    ALOGI("enabled by the host, endpoints IN 0x%02x OUT 0x%02x",
                          in.bEndpointAddress, out.bEndpointAddress);
                    setState("connected");
                    { std::lock_guard<std::mutex> lk(gStateMutex); gStateDirty = true; }
                    gStateCv.notify_all();
                    break;
                }
                case FUNCTIONFS_DISABLE:
                    gEnabled = false;
                    if (!gStop) setState("waiting");
                    break;
                case FUNCTIONFS_SETUP:
                    handleSetup(evs[i].u.setup);
                    break;
                case FUNCTIONFS_BIND: ALOGI("bound"); break;
                case FUNCTIONFS_UNBIND: ALOGI("unbound"); break;
                case FUNCTIONFS_SUSPEND: ALOGI("host suspended"); break;
                case FUNCTIONFS_RESUME: ALOGI("host resumed"); break;
                default: break;
            }
        }
    }
}

// Отчёты компьютеру: по каждому изменению состояния.
void reportThread() {
    uint8_t rep[20];
    while (!gStop) {
        PadState s;
        {
            std::unique_lock<std::mutex> lk(gStateMutex);
            gStateCv.wait_for(lk, std::chrono::milliseconds(200),
                              [] { return gStop || (gStateDirty && gEnabled); });
            if (gStop) break;
            if (!gStateDirty || !gEnabled) continue;
            gStateDirty = false;
            s = gState;
        }
        buildReport(s, rep);
        ssize_t n = write(gEpIn, rep, sizeof(rep));
        if (n != (ssize_t)sizeof(rep)) {
            // не включено (EAGAIN), компьютер отключился (ESHUTDOWN) или прервано сигналом
            { std::lock_guard<std::mutex> lk(gStateMutex); gStateDirty = true; }
            usleep(20 * 1000);
        }
    }
}

// Сообщения от компьютера: 00 08 00 <левый> <правый> 00 00 00 - вибрация,
// 01 03 <n> - светодиоды (кольца у этого корпуса нет).
void outThread() {
    uint8_t buf[64];
    while (!gStop) {
        ssize_t n = read(gEpOut, buf, sizeof(buf));
        if (n < 0) {
            usleep((errno == EAGAIN ? 100 : 20) * 1000);
            continue;
        }
        if (n >= 5 && buf[0] == 0x00 && buf[1] == 0x08) {
            {
                std::lock_guard<std::mutex> lk(gRumbleMutex);
                if (gRumbleLeft == buf[3] && gRumbleRight == buf[4]) continue;
                gRumbleLeft = buf[3];
                gRumbleRight = buf[4];
            }
            rumbleTick(true);
        }
    }
}

void onSignal(int) { gStop = true; }

int cleanup() {
    // Служба остановилась: если она не успела убрать за собой - вернуть USB Android.
    releaseUsb();
    android::base::SetProperty(kPropActive, "0");
    const std::string st = android::base::GetProperty(kPropState, "");
    if (st.rfind("error", 0) != 0) android::base::SetProperty(kPropState, "stopped");
    android::base::SetProperty(kPropEnable, "0");
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc > 1 && !strcmp(argv[1], "--cleanup")) return cleanup();

    struct sigaction sa = {};
    sa.sa_handler = onSignal;   // без SA_RESTART: висящие read/write прерываются
    sigaction(SIGTERM, &sa, nullptr);
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGUSR1, &sa, nullptr);

    android::base::SetProperty(kPropActive, "1");
    setState("starting");
    // режим мыши gammapad увёл бы стики в мышь
    android::base::SetProperty("sys.gammaos.gamepad.mouse_active", "0");

    std::string error;
    if (!setupGadget()) error = "gadget";
    else if (!openFfs()) error = "functionfs";
    if (error.empty()) {
        scanDevices();
        if (!gHavePad) error = "no gamepad";
    }
    if (error.empty() && !bindXpad()) error = "usb controller busy";

    std::thread t0, tIn, tOut;
    if (error.empty()) {
        setState("waiting");
        t0 = std::thread(ep0Thread);
        tIn = std::thread(reportThread);
        tOut = std::thread(outThread);

        int64_t lastScan = nowMs();
        while (!gStop) {
            std::vector<pollfd> pfds;
            std::vector<InDev> devs;
            {
                std::lock_guard<std::mutex> lk(gDevMutex);
                devs = gDevs;
            }
            for (auto& d : devs) pfds.push_back({d.fd, POLLIN, 0});
            poll(pfds.data(), pfds.size(), 100);
            bool lost = false;
            for (size_t i = 0; i < pfds.size(); i++) {
                if (pfds[i].revents & (POLLERR | POLLHUP | POLLNVAL)) { lost = true; continue; }
                if (!(pfds[i].revents & POLLIN)) continue;
                input_event evs[64];
                ssize_t n = read(devs[i].fd, evs, sizeof(evs));
                if (n < 0) {
                    if (errno == ENODEV) lost = true;
                    continue;
                }
                bool changed = false;
                for (ssize_t k = 0; k < n / (ssize_t)sizeof(evs[0]); k++) {
                    const input_event& ev = evs[k];
                    if (devs[i].role == Role::Power) {
                        if (ev.type == EV_KEY && ev.code == KEY_POWER)
                            gPowerDownAt = ev.value ? nowMs() : 0;
                        continue;
                    }
                    std::lock_guard<std::mutex> lk(gStateMutex);
                    changed |= applyEvent(devs[i], ev, gState);
                }
                if (changed) {
                    { std::lock_guard<std::mutex> lk(gStateMutex); gStateDirty = true; }
                    gStateCv.notify_all();
                }
            }
            const int64_t now = nowMs();
            // gammapad пересоздаёт виртуальный геймпад (смена настроек): найти заново
            if ((lost || !gHavePad) && now - lastScan > 500) {
                ALOGI("gamepad lost, rescanning");
                scanDevices();
                lastScan = now;
            }
            if (gPowerDownAt && now - gPowerDownAt >= kPowerHoldMs) {
                ALOGI("power key held, stopping");
                break;
            }
            if (android::base::GetProperty(kPropEnable, "0") != "1") {
                ALOGI("stop requested");
                break;
            }
            rumbleTick(false);
        }
    }

    // Остановка: сначала отвязать гаджет - это прерывает передачи, висящие в потоках.
    gStop = true;
    {
        std::lock_guard<std::mutex> lk(gRumbleMutex);
        gRumbleLeft = gRumbleRight = 0;
    }
    rumbleTick(true);
    releaseUsb();
    gStateCv.notify_all();
    for (std::thread* t : {&t0, &tIn, &tOut}) {
        if (t->joinable()) pthread_kill(t->native_handle(), SIGUSR1);
    }
    for (std::thread* t : {&t0, &tIn, &tOut}) {
        if (t->joinable()) t->join();
    }
    closeDevices();
    if (gEpIn >= 0) close(gEpIn);
    if (gEpOut >= 0) close(gEpOut);
    if (gEp0 >= 0) close(gEp0);

    if (!error.empty()) {
        ALOGE("not started: %s", error.c_str());
        setState("error:" + error);
    } else {
        setState("stopped");
    }
    android::base::SetProperty(kPropActive, "0");
    android::base::SetProperty(kPropEnable, "0");
    return error.empty() ? 0 : 1;
}
