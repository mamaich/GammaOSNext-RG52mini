/*
 * Подсветка стиков RG52 Mini: расчёт режима и яркости по настройкам GammaOS.
 * Описание протокола и соглашений - в ledmap.h.
 */
#include "ledmap.h"

#include <stdlib.h>
#include <string.h>
#include <strings.h>

/* Яркость, ниже которой не опускаемся (persist.gammaos.rgb.min_led_brightness),
 * по умолчанию 14 из 255 - как у служб gammargb других устройств. У сэмплера
 * SurfaceFlinger своё значение по умолчанию, 3, и только при
 * scale_with_brightness; при четырёх уровнях оба дают нижний. */
#define DEFAULT_MIN_BRI 14

/* Не больше этого по всем каналам - чёрный. */
#define BLACK_MAX 3
/* С гистерезисом из чёрного выходим только с этого. */
#define BLACK_ON 6

/* На сколько уровня точное значение может отойти от прежнего, пока
 * прежний уровень держится (см. level_hyst). */
#define LEVEL_HYST 0.65f

static int max3(int a, int b, int c) {
    int m = a > b ? a : b;
    return m > c ? m : c;
}

/* NaN и отрицательное - 0. */
static float clamp01(float v) {
    if (!(v >= 0.0f)) return 0.0f;
    return v > 1.0f ? 1.0f : v;
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static bool is_off(const char *s) {
    return s && strcasecmp(s, "off") == 0;
}

static bool is_one(const char *s) {
    return s && strcmp(s, "1") == 0;
}

static bool parse_int(const char *s, int *out) {
    if (!s || !*s) return false;
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (end == s || *end != '\0') return false;
    *out = (int)v;
    return true;
}

bool ledmap_parse_bool(const char *s, bool def) {
    if (!s || !*s) return def;
    if (!strcmp(s, "1") || !strcasecmp(s, "y") || !strcasecmp(s, "yes") ||
        !strcasecmp(s, "on") || !strcasecmp(s, "true"))
        return true;
    if (!strcmp(s, "0") || !strcasecmp(s, "n") || !strcasecmp(s, "no") ||
        !strcasecmp(s, "off") || !strcasecmp(s, "false"))
        return false;
    return def;
}

bool ledmap_parse_hex(const char *s, int *r, int *g, int *b) {
    if (!s) return false;
    if (s[0] == '#') s++;
    if (strlen(s) != 6) return false;
    int v[6];
    for (int i = 0; i < 6; i++) {
        v[i] = hexval(s[i]);
        if (v[i] < 0) return false;
    }
    *r = v[0] * 16 + v[1];
    *g = v[2] * 16 + v[3];
    *b = v[4] * 16 + v[5];
    return true;
}

int ledmap_quantize(int r, int g, int b, int prev_bits, bool hysteresis) {
    const int m = max3(r, g, b);
    if (m <= BLACK_MAX) return 0;
    if (hysteresis && prev_bits == 0 && m < BLACK_ON) return 0;
    const int ch[3] = { r, g, b };
    const int bit[3] = { LEDMAP_CH_R, LEDMAP_CH_G, LEDMAP_CH_B };
    int bits = 0;
    for (int i = 0; i < 3; i++) {
        /* Сравнение в целых: ch >= k * m, где k = 0,45/0,5/0,55 (в сотых). */
        int k = 50;
        if (hysteresis) k = (prev_bits & bit[i]) ? 45 : 55;
        if (ch[i] * 100 >= k * m) bits |= bit[i];
    }
    return bits;
}

int ledmap_bits_to_mode(int bits) {
    switch (bits & (LEDMAP_CH_R | LEDMAP_CH_G | LEDMAP_CH_B)) {
        case LEDMAP_CH_G: return MCU_MODE_G;
        case LEDMAP_CH_B: return MCU_MODE_B;
        case LEDMAP_CH_R: return MCU_MODE_R;
        case LEDMAP_CH_G | LEDMAP_CH_B: return MCU_MODE_GB;
        case LEDMAP_CH_R | LEDMAP_CH_G: return MCU_MODE_RG;
        case LEDMAP_CH_B | LEDMAP_CH_R: return MCU_MODE_BR;
        case LEDMAP_CH_R | LEDMAP_CH_G | LEDMAP_CH_B: return MCU_MODE_RGB;
        default: return MCU_MODE_OFF;
    }
}

int ledmap_init_byte(int leds) {
    switch (leds) {
        case 4: return 0x20;
        case 8: return 0x21;
        case 12: return 0x22;
        case 16: return 0x23;
        default: return -1;
    }
}

int ledmap_level(float f, int n) {
    if (n <= 1) return 0;
    f = clamp01(f);
    int idx = (int)(f * (float)(n - 1) + 0.5f);
    if (idx < 0) idx = 0;
    if (idx > n - 1) idx = n - 1;
    return idx;
}

/* Уровень с гистерезисом: прежний держим, пока точное положение f*(n-1) не
 * отойдёт от него дальше чем на LEVEL_HYST, - иначе цвет экрана на границе
 * двух уровней мигал бы яркостью с каждым кадром сэмплера. */
static int level_hyst(float f, int n, int prev) {
    if (n <= 1) return 0;
    const float x = clamp01(f) * (float)(n - 1);
    if (prev >= 0 && prev < n && x >= (float)prev - LEVEL_HYST && x <= (float)prev + LEVEL_HYST)
        return prev;
    return ledmap_level(f, n);
}

int ledmap_parse_bri_table(const char *s, uint8_t *out, int max) {
    if (!s || !*s || max <= 0) return 0;
    int n = 0;
    const char *p = s;
    while (*p) {
        while (*p == ' ' || *p == ',') p++;
        if (!*p) break;
        char *end = NULL;
        long v = strtol(p, &end, 10);
        if (end == p) return 0;
        /* Байт яркости не должен совпасть с командой другого рода:
         * 1..9 - цвета и выключение, 17..24 - дыхание, 32..35 - init.
         * Стоковая прошивка шлёт 48..51, dArkOS - 41..49. */
        if (v < 36 || v > 52) return 0;
        if (n == max) return 0;
        out[n++] = (uint8_t)v;
        p = end;
    }
    return n;
}

/* Яркость по правилам GammaOS: за экраном (scale_with_brightness,
 * debug.tracing.screen_brightness 0..1) или ползунком led_brightness 0..255,
 * но не ниже min_led_brightness. */
static float policy_brightness(const ledmap_props *p) {
    float f = 1.0f;
    if (ledmap_parse_bool(p->scale, false)) {
        if (p->screen_bri && *p->screen_bri) {
            char *end = NULL;
            float v = strtof(p->screen_bri, &end);
            if (end != p->screen_bri) f = v;
        }
    } else {
        int lb = 255;
        if (parse_int(p->led_bri, &lb)) f = (float)lb / 255.0f;
    }
    f = clamp01(f);
    int mb = DEFAULT_MIN_BRI;
    (void)parse_int(p->min_bri, &mb);
    const float minf = clamp01((float)mb / 255.0f);
    return f < minf ? minf : f;
}

/* Свой цвет. Раздельные цвета (with_split) - только у постоянного своего
 * цвета и только при split=1 и color_split=1: так решает и выбор цвета, и
 * службы других устройств. Стики у нас светятся одинаково, поэтому берём
 * среднее левого и правого, как одноцветная служба Anbernic. Без своего
 * цвета - итог сэмплера, а без того - красный. */
static void custom_colour(const ledmap_props *p, bool with_split, int *r, int *g, int *b) {
    if (with_split && is_one(p->split) && is_one(p->color_split)) {
        int lr, lg, lb, rr, rg, rb;
        if (ledmap_parse_hex(p->left_custom, &lr, &lg, &lb) &&
            ledmap_parse_hex(p->right_custom, &rr, &rg, &rb)) {
            *r = (lr + rr + 1) / 2;
            *g = (lg + rg + 1) / 2;
            *b = (lb + rb + 1) / 2;
            return;
        }
    }
    if (ledmap_parse_hex(p->hex_custom, r, g, b)) return;
    if (ledmap_parse_hex(p->hex, r, g, b)) return;
    *r = 255;
    *g = 0;
    *b = 0;
}

ledmap_target ledmap_compute(const ledmap_props *p, int nlevels, ledmap_state *st) {
    ledmap_target t = { .on = true, .mode = MCU_MODE_OFF, .level = 0, .follow = false };
    /* Выключено - плиткой, выбором цвета, Nano (control) или главным
     * выключателем GammaOS Toolbox и Nano (enable); и при погасшем экране. */
    if (is_off(p->control) || !ledmap_parse_bool(p->enable, true) || is_off(p->screen)) {
        t.on = false;
        st->level = -1;
        return t;
    }
    const char *e = p->effect ? p->effect : "";
    int r = 0, g = 0, b = 0;

    if (strcasecmp(e, "follow") == 0) {
        t.follow = true;
        if (ledmap_parse_hex(p->hex, &r, &g, &b)) {
            /* Цвет за экраном. Сэмплер уже учёл яркость, она заложена в цвете. */
            st->bits = ledmap_quantize(r, g, b, st->bits, true);
            t.level = level_hyst((float)max3(r, g, b) / 255.0f, nlevels, st->level);
            st->level = t.level;
        } else {
            /* Сэмплер ещё ничего не написал (или его поток не запущен) -
             * свой цвет, и яркость для него своя. */
            custom_colour(p, false, &r, &g, &b);
            st->bits = ledmap_quantize(r, g, b, 0, false);
            t.level = ledmap_level(policy_brightness(p) * (float)max3(r, g, b) / 255.0f, nlevels);
            st->level = -1;
        }
        t.mode = ledmap_bits_to_mode(st->bits);
        return t;
    }

    st->level = -1;
    if (strcmp(e, "1") == 0 || strcmp(e, "4") == 0 || strcmp(e, "5") == 0) {
        /* Эффект 1 - «бегущий огонь», заводской режим. Эффектов 4 и 5 у
         * контроллера нет, приложение их и не предлагает (effectN.supported),
         * но если значение всё же пришло - показываем эффект 1. */
        t.mode = MCU_MODE_SCROLL;
        t.level = ledmap_level(policy_brightness(p), nlevels);
    } else if (strcmp(e, "2") == 0) {
        t.mode = MCU_MODE_BREATH;
        t.level = ledmap_level(policy_brightness(p), nlevels);
    } else if (strcmp(e, "3") == 0) {
        /* Дыхание своим (общим) цветом; яркость цвета - общая яркость
         * эффекта, как у служб других устройств (выбор цвета оставляет этот
         * ползунок). */
        custom_colour(p, false, &r, &g, &b);
        st->bits = ledmap_quantize(r, g, b, 0, false);
        t.mode = st->bits ? MCU_BREATH_OFFSET + ledmap_bits_to_mode(st->bits) : MCU_MODE_BREATH;
        t.level = ledmap_level(policy_brightness(p) * (float)max3(r, g, b) / 255.0f, nlevels);
    } else {
        /* none, пусто и всё прочее - постоянный свой цвет, как у служб
         * других устройств: сэмплер работает только при "follow", и за
         * пустым значением остался бы устаревший цвет. Контроллер знает
         * только полные цвета, поэтому тёмный цвет передаём яркостью. */
        custom_colour(p, true, &r, &g, &b);
        st->bits = ledmap_quantize(r, g, b, 0, false);
        t.mode = ledmap_bits_to_mode(st->bits);
        t.level = ledmap_level(policy_brightness(p) * (float)max3(r, g, b) / 255.0f, nlevels);
    }
    return t;
}

ledmap_actions ledmap_decide(const ledmap_target *t, const ledmap_sent *s, long long now_ms) {
    ledmap_actions a = { .power_down = false, .power_up = false, .send_level = false,
                         .send_mode = false, .wait_ms = LEDMAP_IDLE_WAIT_MS };
    if (!t->on) {
        if (s->on || s->rail_leftover) a.power_down = true;
        return a;
    }
    if (!s->on) {
        /* И после перезапуска службы с горящим питанием - заново init:
         * неизвестно, что контроллер успел получить. */
        a.power_up = true;
        return a;
    }
    const bool level = t->level != s->level;
    const bool mode = t->mode != s->mode;
    if (!level && !mode) return a;
    const long long since = now_ms - s->last_send_ms;
    if (t->follow && since >= 0 && since < LEDMAP_FOLLOW_MIN_INTERVAL_MS) {
        a.wait_ms = (int)(LEDMAP_FOLLOW_MIN_INTERVAL_MS - since);
        return a;
    }
    a.send_level = level;
    a.send_mode = mode;
    return a;
}

bool ledmap_reenable(const char *prev_control, const char *control, const char *enable) {
    return is_off(prev_control) && !is_off(control) && !ledmap_parse_bool(enable, true);
}
