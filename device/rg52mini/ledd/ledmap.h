/*
 * Подсветка стиков RG52 Mini: что показывать, по настройкам GammaOS.
 *
 * Здесь только расчёт, без обращения к устройству и к свойствам Android, -
 * чтобы логику можно было проверить тестом на компьютере (test/run.sh).
 *
 * Подсветкой управляет отдельный микроконтроллер. Команда ему - один байт
 * (протокол снят с программы mcu_led стоковой прошивки, 20260716):
 *   0x20..0x23        инициализация на 4/8/12/16 светодиодов;
 *   1..7              цвет: G, B, R, G+B, R+G, B+R, R+G+B;
 *   8                 «бегущий огонь» (заводской режим стоковой прошивки);
 *   9                 погасить;
 *   17..23            дыхание цветами 1..7 (цвет + 16);
 *   24                дыхание (LED_BREATH);
 *   51 - уровень      яркость (стоковая прошивка шлёт уровни 0..3).
 * Отдельно левым и правым стиком, как и произвольным цветом, управлять
 * нельзя: цвета GammaOS сводятся к семи.
 */
#ifndef RG52_LEDMAP_H
#define RG52_LEDMAP_H

#include <stdbool.h>
#include <stdint.h>

enum {
    MCU_MODE_G = 1,
    MCU_MODE_B = 2,
    MCU_MODE_R = 3,
    MCU_MODE_GB = 4,
    MCU_MODE_RG = 5,
    MCU_MODE_BR = 6,
    MCU_MODE_RGB = 7,
    MCU_MODE_SCROLL = 8,
    MCU_MODE_OFF = 9,
    MCU_BREATH_OFFSET = 16, /* 17..23: дыхание цветами 1..7 */
    MCU_MODE_BREATH = 24,
};

/* Каналы цвета, как их сводит ledmap_quantize. */
#define LEDMAP_CH_R 1
#define LEDMAP_CH_G 2
#define LEDMAP_CH_B 4

/* Уровней яркости в таблице - не больше этого. */
#define LEDMAP_MAX_LEVELS 16

/* Цвет за экраном меняется часто - шлём не чаще этого. */
#define LEDMAP_FOLLOW_MIN_INTERVAL_MS 300

/* Когда ждать нечего: служба и так просыпается на каждое изменение
 * свойств, тайм-аут - лишь страховка. */
#define LEDMAP_IDLE_WAIT_MS 60000

/* Значения свойств, как их вернул бы __system_property_get ("" - не задано). */
typedef struct {
    const char *control;      /* persist.gammargb.control: "off" гасит */
    const char *enable;       /* persist.gammaos.rgb.enable: ложь гасит */
    const char *screen;       /* sys.screen.state: "off" гасит */
    const char *effect;       /* persist.gammaos.rgb.effect */
    const char *hex;          /* persist.gammaos.primary.rgb_hex (итог сэмплера) */
    const char *hex_custom;   /* persist.gammaos.primary.rgb_hex_custom */
    const char *split;        /* persist.gammaos.rgb.split */
    const char *color_split;  /* persist.gammaos.rgb.color_split */
    const char *left_custom;  /* persist.gammaos.rgb.left_hex_custom */
    const char *right_custom; /* persist.gammaos.rgb.right_hex_custom */
    const char *scale;        /* persist.gammaos.rgb.scale_with_brightness */
    const char *screen_bri;   /* debug.tracing.screen_brightness, 0..1 */
    const char *led_bri;      /* persist.gammaos.rgb.led_brightness, 0..255 */
    const char *min_bri;      /* persist.gammaos.rgb.min_led_brightness, 0..255 */
} ledmap_props;

/* Память ledmap_compute между вызовами, для гистерезиса цвета за экраном. */
typedef struct {
    int bits;  /* каналы прошлого цвета */
    int level; /* прошлый уровень за экраном; -1 - начать заново */
} ledmap_state;

#define LEDMAP_STATE_INIT { 0, -1 }

typedef struct {
    bool on;     /* подсветка нужна; false - погасить и снять питание */
    int mode;    /* байт режима */
    int level;   /* индекс в таблице яркости, 0 - самый тусклый */
    bool follow; /* цвет идёт за экраном: меняется часто, нужна сдержанность */
} ledmap_target;

/* Что уже отправлено контроллеру. */
typedef struct {
    bool on;               /* подсветка включена нами */
    bool rail_leftover;    /* питание горит без нас (перезапуск службы, сбой) */
    int mode;              /* -1 - неизвестно */
    int level;             /* -1 - неизвестно */
    long long last_send_ms;
} ledmap_sent;

/* Что сделать на этом шаге. */
typedef struct {
    bool power_down; /* 9 и снять питание */
    bool power_up;   /* питание, init, яркость, режим */
    bool send_level; /* только байт яркости */
    bool send_mode;  /* только байт режима */
    int wait_ms;     /* сколько ждать изменения свойств до следующего шага */
} ledmap_actions;

/* Логическое значение, как android::base::ParseBool, но без учёта регистра:
 * "1", "y", "yes", "on", "true" - истина; "0", "n", "no", "off", "false" -
 * ложь; иначе def. */
bool ledmap_parse_bool(const char *s, bool def);

/* "#RRGGBB" или "RRGGBB". */
bool ledmap_parse_hex(const char *s, int *r, int *g, int *b);

/* Свести цвет к маске каналов (0 - чёрный). Канал горит, если он не меньше
 * половины самого яркого. Совсем тёмное, до 3 из 255, - чёрный: в том числе
 * #010101, который сэмплер пишет, когда подсветка экрана ниже порога
 * brightness_override_threshold. С гистерезисом (для цвета за экраном)
 * порог для горевшего канала 0,45, для негоревшего 0,55, а из чёрного цвет
 * выходит только с 6 из 255 - чтобы не прыгать на границе. */
int ledmap_quantize(int r, int g, int b, int prev_bits, bool hysteresis);

/* Маска каналов -> байт режима 1..7; 0 -> MCU_MODE_OFF. */
int ledmap_bits_to_mode(int bits);

/* Число светодиодов -> байт инициализации; -1, если такого нет. */
int ledmap_init_byte(int leds);

/* Доля яркости 0..1 -> индекс уровня из n. */
int ledmap_level(float f, int n);

/* "51,50,49,48" (от тусклого к яркому) -> байты; возвращает число уровней,
 * 0 при ошибке. */
int ledmap_parse_bri_table(const char *s, uint8_t *out, int max);

/* Главный расчёт; st - память между вызовами (начальная LEDMAP_STATE_INIT). */
ledmap_target ledmap_compute(const ledmap_props *p, int nlevels, ledmap_state *st);

/* Что сделать, чтобы привести отправленное к цели. */
ledmap_actions ledmap_decide(const ledmap_target *t, const ledmap_sent *s, long long now_ms);

/* Включить ли обратно главный выключатель GammaOS (persist.gammaos.rgb.enable).
 * Nano, выключая подсветку, пишет и control=off, и enable=0, а плитка и выбор
 * цвета, включая, - только control=on; сам Nano в этом случае возвращает
 * enable=1. Делаем так же, но только на переходе control из off, а не на
 * каждой записи того же значения. */
bool ledmap_reenable(const char *prev_control, const char *control, const char *enable);

#endif /* RG52_LEDMAP_H */
