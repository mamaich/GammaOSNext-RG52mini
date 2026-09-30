/*
 * rg52-ledd - подсветка стиков RG52 Mini по настройкам GammaOS.
 *
 * GammaOS сама подсветкой не управляет: её интерфейс (раздел RGB в GammaOS
 * Toolbox, плитка и выбор цвета, Nano) только пишет свойства, а применяет
 * их служба gammargb из vendor поддерживаемых устройств. У нас vendor от
 * SyachOS, службы нет, да и ни одна из существующих не знает нашего
 * железа. Эта служба её заменяет. Что именно показывать - ledmap.c.
 *
 * Железо. Светодиодами стиков управляет отдельный микроконтроллер; процессор
 * шлёт ему однобайтовые команды по UART1 (/dev/ttyS1, 9600 8N1, только
 * передача, вывод GPIO1_D2), ответа нет. Каждый байт - 6 раз с паузой 3 мс,
 * как у стоковой mcu_led. Питание подсветки - регулятор vcc-led (GPIO0_C7),
 * его включают через debugfs, как и в стоковой прошивке (mcu_led_ctrl.sh);
 * debugfs монтирует vendor SyachOS на отладочной сборке и после загрузки не
 * отмонтирует.
 *
 * Проверено на устройстве (30.09.2026): сам контроллер питается от батареи
 * всегда - и при снятом vcc-led, и при выключенном устройстве - и помнит
 * режим; vcc-led питает только светодиоды. Поэтому гасим режимом 9 и лишь
 * потом снимаем питание (стоковый скрипт - наоборот): иначе при следующем
 * включении питания светодиоды вспыхнули бы прежним режимом. Init после
 * включения питания не нужен, но и не мешает - шлём, как сток. Программно
 * сбросить контроллер нечем, поэтому незнакомых байтов не шлём.
 *
 * После принятой команды контроллер пропускает всё, что идёт по линии, пока
 * она не помолчит: сплошной поток команд (и даже с паузой в 11 мс, если её
 * занять пустыми байтами) даёт только первую. Отсюда тишина gap_ms после
 * каждой команды; повторы одного байта ничему не мешают.
 *
 * Порт открываем лишь на время посылки, как и стоковая mcu_led: вывод приёма
 * UART1 (GPIO1_D1) отдан ШИМ вентилятора, и открытый порт мог бы ловить с
 * него помехи. Bluetooth этот порт не нужен, хотя vendor-овский
 * bt_vendor.conf и называет его своим: наш libbt-vendor (btvendor) работает
 * через HCI-сокет. Ответов контроллера стоковая прошивка не читает, и их нет:
 * на v1.4 без вентилятора, с приёмом UART1 вместо его ШИМ, на GPIO1_D1 не
 * пришло ни байта ни на одну команду.
 *
 * UART1 включается в дереве устройства (tools/mk-sdimg.sh). Без него
 * /dev/ttyS1 нет, и служба только ждёт.
 *
 * Для опытов без пересборки (живут до перезагрузки):
 *   sys.rg52.ledd.repeat     повторов байта, 1..9, по умолчанию 6
 *   sys.rg52.ledd.byte_ms    пауза после каждого повтора, 1..50 мс, по умолчанию 3
 *   sys.rg52.ledd.gap_ms     пауза после команды, 0..500 мс, по умолчанию 20
 *   sys.rg52.ledd.settle_ms  пауза после включения питания, 0..2000 мс, по умолчанию 100
 *   sys.rg52.ledd.bri_table  байты яркости от тусклого к яркому, "51,50,49,48"
 *   sys.rg52.ledd.leds       светодиодов для init: 4, 8, 12 или 16
 * Служба берёт новые значения при следующем включении подсветки, ручные
 * команды (rg52-ledd help) - сразу.
 */
#define LOG_TAG "rg52-ledd"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/system_properties.h>
/* __system_property_area_serial - общий счётчик изменений свойств; объявлен
 * во внутреннем заголовке bionic, как у init и прочего платформенного кода. */
#define _REALLY_INCLUDE_SYS__SYSTEM_PROPERTIES_H_
#include <sys/_system_properties.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include <log/log.h>

#include "ledmap.h"

#define TTY_PATH "/dev/ttyS1"
#define RAIL_PATH "/sys/kernel/debug/regulator/vcc-led/enable"
#define WAKE_LOCK_PATH "/sys/power/wake_lock"
#define WAKE_UNLOCK_PATH "/sys/power/wake_unlock"
#define WAKE_LOCK_NAME "rg52_ledd"
/* Блокировки сна - только с тайм-аутом (в наносекундах): если процесс
 * убьют посреди посылки, блокировка снимется сама, а не будет держать
 * устройство. Эта - для обработчика сигнала. */
#define WAKE_LOCK_TIMED WAKE_LOCK_NAME " 2000000000"

#define DEFAULT_REPEAT 6
#define DEFAULT_BYTE_MS 3
#define DEFAULT_GAP_MS 20
#define DEFAULT_SETTLE_MS 100
#define DEFAULT_BRI_TABLE "51,50,49,48"
#define DEFAULT_LEDS 12

/* Ручные on и stock без аргументов: красный и яркость стоковой прошивки
 * по умолчанию (ee_led.bri=2). */
#define TOOL_MODE MCU_MODE_R
#define TOOL_BRI 49

/* Сколько ждать, пока посылка уйдёт в линию: 6 байт при 9600 - около 6 мс. */
#define DRAIN_LIMIT_MS 50
/* То же в обработчике сигнала: у него всего 200 мс до SIGKILL. */
#define SIGNAL_DRAIN_MS 20
/* Не удалось - повтор не раньше чем через столько. */
#define RETRY_MS 5000
/* Снятие питания - не больше стольких записей, см. rail_off. */
#define RAIL_OFF_TRIES 8

/* Как слать байты - для обработчика сигнала. */
static volatile sig_atomic_t g_repeat = DEFAULT_REPEAT;
static volatile sig_atomic_t g_byte_ms = DEFAULT_BYTE_MS;

/* ---- Устройство -------------------------------------------------------
 * Всё до обработчика сигнала включительно годится и для него: только
 * безопасные в обработчике вызовы, без журнала и без malloc. */

static void nap_ms(int ms) {
    if (ms <= 0) return;
    struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
    while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {
    }
}

/* O_NONBLOCK - как у стоковой mcu_led: ни открытие, ни запись не должны
 * повиснуть. */
static int tty_open(void) {
    const int fd = open(TTY_PATH, O_WRONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return -1;
    struct termios t;
    if (tcgetattr(fd, &t) == 0) {
        cfmakeraw(&t);
        cfsetispeed(&t, B9600);
        cfsetospeed(&t, B9600);
        t.c_cflag &= ~(PARENB | CSTOPB | CRTSCTS | CSIZE);
        t.c_cflag |= CS8 | CLOCAL;
        (void)tcsetattr(fd, TCSANOW, &t);
    }
    return fd;
}

/* Очередь передачи при наших посылках не переполняется, а EAGAIN бывает,
 * когда в порт в тот же миг пишет кто-то ещё (ручная команда), - подождать
 * немного. */
static bool put_byte(int fd, unsigned char b) {
    for (int i = 0; i < 100; i++) {
        const ssize_t n = write(fd, &b, 1);
        if (n == 1) return true;
        if (n == 0) {
            errno = EIO;
            return false;
        }
        if (errno == EAGAIN) {
            nap_ms(1);
        } else if (errno != EINTR) {
            return false;
        }
    }
    return false;
}

/* Дождаться, пока посылка уйдёт в линию (TIOCSER_TEMT - пусты и очередь, и
 * передатчик), но не дольше limit_ms: tcdrain ждал бы без предела, и
 * зависшая передача остановила бы службу. Не ушла - выбрасываем. */
static bool drain(int fd, int limit_ms) {
    for (int waited = 0;; waited += 2) {
        unsigned int lsr = 0;
        if (ioctl(fd, TIOCSERGETLSR, &lsr) != 0) return false;
        if (lsr & TIOCSER_TEMT) return true;
        if (waited >= limit_ms) break;
        nap_ms(2);
    }
    tcflush(fd, TCOFLUSH);
    errno = ETIMEDOUT;
    return false;
}

/* repeat раз один байт с паузой byte_ms - так шлёт стоковая mcu_led: ответа
 * нет, и повтор - единственная страховка от потерянного байта. */
static bool put_command(int fd, int cmd, int repeat, int byte_ms) {
    for (int k = 0; k < repeat; k++) {
        if (!put_byte(fd, (unsigned char)cmd)) return false;
        nap_ms(byte_ms);
    }
    return true;
}

/* Посылка: команды по очереди, после каждой - пауза gap_ms. */
static bool mcu_send(const int *cmd, int n, int repeat, int byte_ms, int gap_ms) {
    const int fd = tty_open();
    if (fd < 0) return false;
    bool ok = true;
    for (int i = 0; ok && i < n; i++) {
        ok = put_command(fd, cmd[i], repeat, byte_ms) && drain(fd, DRAIN_LIMIT_MS);
        if (ok) nap_ms(gap_ms);
    }
    const int err = errno;
    close(fd);
    errno = err;
    return ok;
}

/* Файл enable регулятора в debugfs: чтение - горит ли питание на деле,
 * запись - включение или выключение от имени одного отладочного
 * потребителя, и эти включения считаются. -1 - файла нет. */
static int rail_get(void) {
    const int fd = open(RAIL_PATH, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    char c = 0;
    const ssize_t n = read(fd, &c, 1);
    close(fd);
    if (n != 1) return -1;
    return c == '1' ? 1 : (c == '0' ? 0 : -1);
}

static bool rail_write(char c) {
    const int fd = open(RAIL_PATH, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return false;
    const ssize_t n = write(fd, &c, 1);
    close(fd);
    return n == 1;
}

/* Включить - одной записью и только если выключено: лишнее включение
 * счётчик запомнил бы. Возвращает, что вышло. */
static int rail_on(void) {
    const int cur = rail_get();
    if (cur != 0) return cur;
    rail_write('1');
    return rail_get();
}

/* Выключать, пока не погаснет: одно лишнее включение (рукой при опытах,
 * гонкой с ручной командой) иначе оставило бы питание гореть. Других
 * потребителей у vcc-led нет, так что, пока питание горит, счётчик не ноль.
 * Запись не прошла - значит, выключил кто-то другой (ядро ругается на
 * лишнее выключение): перечитываем и больше не пишем. */
static int rail_off(void) {
    int cur = rail_get();
    for (int i = 0; i < RAIL_OFF_TRIES && cur == 1; i++) {
        if (!rail_write('0')) {
            cur = rail_get();
            break;
        }
        cur = rail_get();
    }
    return cur;
}

static void wake_write(const char *path, const char *s) {
    const int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return;
    if (write(fd, s, strlen(s)) < 0) {
        /* без блокировки работаем всё равно */
    }
    close(fd);
}

/* SIGTERM (stop у init с gentle_kill, выключение устройства), SIGINT,
 * SIGHUP: погасить и выйти прямо отсюда. Главный цикл почти всё время ждёт
 * изменения свойств, bionic после сигнала продолжает ждать весь тайм-аут,
 * а init после SIGTERM даёт лишь 200 мс до SIGKILL. Поэтому здесь повторы и
 * пауза - не больше стоковых, без паузы после команды, а порт не
 * закрываем до снятия питания (close ждёт передачи): его закроет _exit.
 * Процесс однопоточный, и в прерванный код мы не возвращаемся, так что
 * брошенная на полпути посылка или запись в регулятор не мешают. */
static void on_signal(int sig) {
    (void)sig;
    wake_write(WAKE_LOCK_PATH, WAKE_LOCK_TIMED);
    const int fd = tty_open();
    if (fd >= 0) {
        const int repeat = g_repeat < DEFAULT_REPEAT ? g_repeat : DEFAULT_REPEAT;
        const int byte_ms = g_byte_ms < DEFAULT_BYTE_MS ? g_byte_ms : DEFAULT_BYTE_MS;
        if (put_command(fd, MCU_MODE_OFF, repeat, byte_ms)) drain(fd, SIGNAL_DRAIN_MS);
    }
    rail_off();
    wake_write(WAKE_UNLOCK_PATH, WAKE_LOCK_NAME);
    _exit(0);
}

/* ---- Настройки ---------------------------------------------------------- */

static void prop(const char *name, char out[PROP_VALUE_MAX]) {
    out[0] = '\0';
    __system_property_get(name, out);
}

static int prop_int(const char *name, int def, int lo, int hi) {
    char v[PROP_VALUE_MAX];
    prop(name, v);
    if (!v[0]) return def;
    char *end = NULL;
    const long x = strtol(v, &end, 10);
    if (end == v || *end != '\0' || x < lo || x > hi) return def;
    return (int)x;
}

typedef struct {
    int repeat;
    int byte_ms;
    int gap_ms;
    int settle_ms;
    int init;
    uint8_t bri[LEDMAP_MAX_LEVELS];
    int nbri;
} config;

static void read_config(config *c) {
    char v[PROP_VALUE_MAX];
    c->repeat = prop_int("sys.rg52.ledd.repeat", DEFAULT_REPEAT, 1, 9);
    c->byte_ms = prop_int("sys.rg52.ledd.byte_ms", DEFAULT_BYTE_MS, 1, 50);
    c->gap_ms = prop_int("sys.rg52.ledd.gap_ms", DEFAULT_GAP_MS, 0, 500);
    c->settle_ms = prop_int("sys.rg52.ledd.settle_ms", DEFAULT_SETTLE_MS, 0, 2000);
    c->init = ledmap_init_byte(prop_int("sys.rg52.ledd.leds", DEFAULT_LEDS, 4, 16));
    if (c->init < 0) c->init = ledmap_init_byte(DEFAULT_LEDS);
    prop("sys.rg52.ledd.bri_table", v);
    c->nbri = ledmap_parse_bri_table(v, c->bri, LEDMAP_MAX_LEVELS);
    if (c->nbri == 0) {
        if (v[0]) ALOGW("sys.rg52.ledd.bri_table=\"%s\" is invalid, using %s", v, DEFAULT_BRI_TABLE);
        c->nbri = ledmap_parse_bri_table(DEFAULT_BRI_TABLE, c->bri, LEDMAP_MAX_LEVELS);
    }
    g_repeat = c->repeat;
    g_byte_ms = c->byte_ms;
}

/* Сколько может занять посылка из n команд. */
static int burst_ms(const config *c, int n) {
    return n * (c->repeat * c->byte_ms + DRAIN_LIMIT_MS + c->gap_ms);
}

/* ---- Служба ------------------------------------------------------------- */

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Не дать устройству уснуть посреди посылки: экран, например, погас, и
 * подсветка с питанием остались бы гореть весь сон. Тайм-аут - с запасом. */
static void hold_awake(int ms) {
    char s[48];
    snprintf(s, sizeof(s), "%s %lld", WAKE_LOCK_NAME, (long long)(ms + 1000) * 1000000LL);
    wake_write(WAKE_LOCK_PATH, s);
}

static void let_sleep(void) {
    const int err = errno;
    wake_write(WAKE_UNLOCK_PATH, WAKE_LOCK_NAME);
    errno = err;
}

/* Включить: питание, пауза, init, яркость, режим. Питание, уже горевшее
 * (перезапуск службы, сбой), не трогаем, но init шлём всё равно:
 * неизвестно, что контроллер успел получить. */
static bool power_up(const config *c, const ledmap_target *t) {
    hold_awake(c->settle_ms + burst_ms(c, 3));
    if (rail_get() != 1) {
        if (rail_on() != 1) ALOGW("LED power did not come on (%s)", RAIL_PATH);
        nap_ms(c->settle_ms);
    }
    const int cmd[3] = { c->init, c->bri[t->level], t->mode };
    const bool ok = mcu_send(cmd, 3, c->repeat, c->byte_ms, c->gap_ms);
    let_sleep();
    return ok;
}

static bool change(const config *c, const int *cmd, int n) {
    hold_awake(burst_ms(c, n));
    const bool ok = mcu_send(cmd, n, c->repeat, c->byte_ms, c->gap_ms);
    let_sleep();
    return ok;
}

/* Погасить: режим 9, затем снять питание. Удачно, если питание снято, а без
 * файла питания - если дошла девятка. */
static bool power_down(const config *c) {
    hold_awake(burst_ms(c, 1));
    const int off = MCU_MODE_OFF;
    const bool sent = mcu_send(&off, 1, c->repeat, c->byte_ms, c->gap_ms);
    const int rail = rail_off();
    let_sleep();
    return rail == 0 || (rail < 0 && sent);
}

/* Неудачи подряд: в журнал - только первая, дальше повторяем молча. */
static int g_fails;

__attribute__((format(printf, 1, 2))) static void failed(const char *fmt, ...) {
    if (g_fails++ > 0) return;
    char msg[192];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    ALOGW("%s; retrying every %d s", msg, RETRY_MS / 1000);
}

static void succeeded(void) {
    if (g_fails > 0) ALOGI("LEDs respond again (after %d failures in a row)", g_fails);
    g_fails = 0;
}

static int daemon_main(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaddset(&sa.sa_mask, SIGTERM);
    sigaddset(&sa.sa_mask, SIGINT);
    sigaddset(&sa.sa_mask, SIGHUP);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    /* Блокировка сна от прошлого экземпляра, если его убили посреди посылки. */
    wake_write(WAKE_UNLOCK_PATH, WAKE_LOCK_NAME);

    config cfg;
    read_config(&cfg);

    /* Питание могло остаться от прошлого экземпляра: погасим или заново
     * включим, смотря по настройкам. */
    const int rail = rail_get();
    ledmap_sent sent = { .on = false, .rail_leftover = rail == 1, .mode = -1, .level = -1,
                         .last_send_ms = 0 };
    ALOGI("started; LED power is %s",
          rail == 1 ? "on" : (rail == 0 ? "off" : "unavailable (" RAIL_PATH ")"));

    ledmap_state st = LEDMAP_STATE_INIT;
    char prev_control[PROP_VALUE_MAX];
    prop("persist.gammargb.control", prev_control);
    bool tty_warned = false;
    /* После неудачи - пауза перед повтором; у гашения своя: сбой связи с
     * контроллером не должен задерживать снятие питания. */
    long long up_retry_at = 0, down_retry_at = 0;
    uint32_t serial = __system_property_area_serial();

    for (;;) {
        char control[PROP_VALUE_MAX], enable[PROP_VALUE_MAX], screen[PROP_VALUE_MAX];
        char effect[PROP_VALUE_MAX], hex[PROP_VALUE_MAX], custom[PROP_VALUE_MAX];
        char split[PROP_VALUE_MAX], csplit[PROP_VALUE_MAX], left[PROP_VALUE_MAX];
        char right[PROP_VALUE_MAX], scale[PROP_VALUE_MAX], sbri[PROP_VALUE_MAX];
        char lbri[PROP_VALUE_MAX], mbri[PROP_VALUE_MAX];
        prop("persist.gammargb.control", control);
        prop("persist.gammaos.rgb.enable", enable);
        prop("sys.screen.state", screen);
        prop("persist.gammaos.rgb.effect", effect);
        prop("persist.gammaos.primary.rgb_hex", hex);
        prop("persist.gammaos.primary.rgb_hex_custom", custom);
        prop("persist.gammaos.rgb.split", split);
        prop("persist.gammaos.rgb.color_split", csplit);
        prop("persist.gammaos.rgb.left_hex_custom", left);
        prop("persist.gammaos.rgb.right_hex_custom", right);
        prop("persist.gammaos.rgb.scale_with_brightness", scale);
        prop("debug.tracing.screen_brightness", sbri);
        prop("persist.gammaos.rgb.led_brightness", lbri);
        prop("persist.gammaos.rgb.min_led_brightness", mbri);

        if (ledmap_reenable(prev_control, control, enable)) {
            ALOGI("LEDs switched on (persist.gammargb.control=%s), "
                  "restoring persist.gammaos.rgb.enable=1",
                  control);
            if (__system_property_set("persist.gammaos.rgb.enable", "1") == 0) {
                strcpy(enable, "1");
            } else {
                ALOGW("cannot set persist.gammaos.rgb.enable");
            }
        }
        memcpy(prev_control, control, sizeof(prev_control));

        const ledmap_props p = {
            .control = control, .enable = enable, .screen = screen, .effect = effect,
            .hex = hex, .hex_custom = custom, .split = split, .color_split = csplit,
            .left_custom = left, .right_custom = right, .scale = scale,
            .screen_bri = sbri, .led_bri = lbri, .min_bri = mbri,
        };
        ledmap_target t = ledmap_compute(&p, cfg.nbri, &st);
        const long long now = now_ms();
        const ledmap_actions a = ledmap_decide(&t, &sent, now);
        int wait_ms = a.wait_ms;

        if (a.power_down) {
            if (now < down_retry_at) {
                wait_ms = (int)(down_retry_at - now);
            } else {
                const bool ok = power_down(&cfg);
                sent.on = false;
                sent.mode = sent.level = -1;
                sent.rail_leftover = !ok;
                if (ok) {
                    ALOGI("LEDs off");
                    succeeded();
                } else {
                    failed("LED power-down: power stays on (%s)", RAIL_PATH);
                    down_retry_at = now_ms() + RETRY_MS;
                    wait_ms = RETRY_MS;
                }
            }
        } else if (a.power_up || a.send_level || a.send_mode) {
            if (now < up_retry_at) {
                wait_ms = (int)(up_retry_at - now);
            } else if (a.power_up) {
                if (access(TTY_PATH, F_OK) != 0) {
                    if (!tty_warned) {
                        ALOGW("no %s: UART1 is not enabled in the device tree "
                              "(tools/mk-sdimg.sh), LEDs unavailable",
                              TTY_PATH);
                        tty_warned = true;
                    }
                } else {
                    /* Настройки для опытов - при каждом включении; с ними
                     * может смениться и число уровней. */
                    read_config(&cfg);
                    st.level = -1;
                    t = ledmap_compute(&p, cfg.nbri, &st);
                    if (power_up(&cfg, &t)) {
                        sent = (ledmap_sent){ .on = true, .rail_leftover = false, .mode = t.mode,
                                              .level = t.level, .last_send_ms = now };
                        ALOGI("LEDs on: init 0x%02x, brightness %d, mode %d", cfg.init,
                              cfg.bri[t.level], t.mode);
                        succeeded();
                    } else {
                        failed("LED power-up: %s", strerror(errno));
                        sent.rail_leftover = rail_get() == 1;
                        up_retry_at = now_ms() + RETRY_MS;
                        wait_ms = RETRY_MS;
                    }
                }
            } else {
                int cmd[2], n = 0;
                if (a.send_level) cmd[n++] = cfg.bri[t.level];
                if (a.send_mode) cmd[n++] = t.mode;
                if (change(&cfg, cmd, n)) {
                    sent.mode = t.mode;
                    sent.level = t.level;
                    sent.last_send_ms = now;
                    if (!t.follow) ALOGI("mode %d, brightness %d", t.mode, cfg.bri[t.level]);
                    succeeded();
                } else {
                    failed("LED mode change: %s", strerror(errno));
                    /* Что дошло - неизвестно: в следующий раз включим заново. */
                    sent.on = false;
                    sent.mode = sent.level = -1;
                    sent.rail_leftover = rail_get() == 1;
                    up_retry_at = now_ms() + RETRY_MS;
                    wait_ms = RETRY_MS;
                }
            }
        }

        /* Ждём изменения любого свойства или тайм-аута. */
        struct timespec ts = { wait_ms / 1000, (long)(wait_ms % 1000) * 1000000L };
        uint32_t next = serial;
        if (__system_property_wait(NULL, serial, &next, &ts)) {
            /* При ошибке bionic отвечает «изменилось», не тронув next, - не
             * крутиться же вхолостую. */
            if (next == serial) {
                nap_ms(wait_ms);
            } else {
                serial = next;
            }
        }
    }
}

/* ---- Ручные команды ----------------------------------------------------- */

static int usage(void) {
    fputs("RG52 Mini stick LEDs. Without arguments: the service (started by init).\n"
          "Manual commands, for experiments:\n"
          "  rg52-ledd send BYTE [N]       send byte 0..255 N times (1..50, default 6)\n"
          "  rg52-ledd rail on|off|state   LED power; prints whether it is on (1/0)\n"
          "  rg52-ledd on [MODE [BRI]]     switch on in the service's order: power, pause,\n"
          "                                init, brightness, mode\n"
          "  rg52-ledd stock [MODE [BRI]]  switch on in the stock firmware's order: init,\n"
          "                                brightness, power, mode\n"
          "  rg52-ledd off                 switch off: mode 9, then power off\n"
          "MODE is the mode byte (default 3, red), BRI the brightness byte (default 49).\n"
          "Exit code: 0 done, 1 port or power error, 2 bad arguments,\n"
          "3 bytes sent but LED power is not on.\n"
          "The sys.rg52.ledd.* settings apply here too. Stop the service before\n"
          "experimenting: stop rg52_ledd (this switches the LEDs off); start rg52_ledd\n"
          "brings it back.\n",
          stderr);
    return 2;
}

static bool parse_num(const char *s, int lo, int hi, int *out) {
    if (!s || !*s) return false;
    long v = 0;
    for (const char *q = s; *q; q++) {
        if (*q < '0' || *q > '9') return false;
        v = v * 10 + (*q - '0');
        if (v > hi) return false;
    }
    if (v < lo) return false;
    *out = (int)v;
    return true;
}

static int tool_main(int argc, char **argv) {
    const char *cmd = argv[1];
    if (!strcmp(cmd, "help") || !strcmp(cmd, "-h") || !strcmp(cmd, "--help")) {
        usage();
        return 0;
    }
    config cfg;
    read_config(&cfg);
    char svc[PROP_VALUE_MAX];
    prop("init.svc.rg52_ledd", svc);
    if (!strcmp(svc, "running") && !(argc == 3 && !strcmp(argv[2], "state"))) {
        fputs("service rg52_ledd is running and may override this command (stop rg52_ledd)\n",
              stderr);
    }

    if (!strcmp(cmd, "send")) {
        int b, n = cfg.repeat;
        if (argc < 3 || argc > 4 || !parse_num(argv[2], 0, 255, &b) ||
            (argc == 4 && !parse_num(argv[3], 1, 50, &n)))
            return usage();
        if (!mcu_send(&b, 1, n, cfg.byte_ms, cfg.gap_ms)) {
            fprintf(stderr, "%s: %s\n", TTY_PATH, strerror(errno));
            return 1;
        }
        return 0;
    }

    if (!strcmp(cmd, "rail")) {
        if (argc != 3) return usage();
        int r;
        if (!strcmp(argv[2], "on")) {
            r = rail_on();
        } else if (!strcmp(argv[2], "off")) {
            r = rail_off();
        } else if (!strcmp(argv[2], "state")) {
            r = rail_get();
        } else {
            return usage();
        }
        if (r < 0) {
            fprintf(stderr, "%s is not available\n", RAIL_PATH);
            return 1;
        }
        printf("%d\n", r);
        return 0;
    }

    if (!strcmp(cmd, "on") || !strcmp(cmd, "stock")) {
        int mode = TOOL_MODE, bri = TOOL_BRI;
        if (argc > 4 || (argc > 2 && !parse_num(argv[2], 0, 255, &mode)) ||
            (argc > 3 && !parse_num(argv[3], 0, 255, &bri)))
            return usage();
        bool ok;
        if (!strcmp(cmd, "on")) {
            if (rail_get() != 1) {
                if (rail_on() != 1) fprintf(stderr, "LED power did not come on (%s)\n", RAIL_PATH);
                nap_ms(cfg.settle_ms);
            }
            const int seq[3] = { cfg.init, bri, mode };
            ok = mcu_send(seq, 3, cfg.repeat, cfg.byte_ms, cfg.gap_ms);
        } else {
            /* Как mcu_led_ctrl.sh init: init и яркость, затем питание, если
             * оно выключено, затем режим - без паузы. */
            if (rail_get() == 1) {
                fputs("LED power is already on, so this is not the stock order; "
                      "run 'rg52-ledd rail off' first\n",
                      stderr);
            }
            const int seq[2] = { cfg.init, bri };
            ok = mcu_send(seq, 2, cfg.repeat, cfg.byte_ms, cfg.gap_ms);
            if (rail_on() != 1) fprintf(stderr, "LED power did not come on (%s)\n", RAIL_PATH);
            ok = mcu_send(&mode, 1, cfg.repeat, cfg.byte_ms, cfg.gap_ms) && ok;
        }
        if (!ok) {
            fprintf(stderr, "%s: %s\n", TTY_PATH, strerror(errno));
            return 1;
        }
        return rail_get() == 1 ? 0 : 3;
    }

    if (!strcmp(cmd, "off")) {
        if (argc != 2) return usage();
        const int off = MCU_MODE_OFF;
        const bool ok = mcu_send(&off, 1, cfg.repeat, cfg.byte_ms, cfg.gap_ms);
        const int err = errno;
        const int r = rail_off();
        if (!ok) fprintf(stderr, "%s: %s\n", TTY_PATH, strerror(err));
        if (r == 1) fprintf(stderr, "LED power stays on (%s)\n", RAIL_PATH);
        if (r < 0) fprintf(stderr, "%s is not available\n", RAIL_PATH);
        return ok && r == 0 ? 0 : 1;
    }

    return usage();
}

int main(int argc, char **argv) {
    if (argc > 1) return tool_main(argc, argv);
    return daemon_main();
}
