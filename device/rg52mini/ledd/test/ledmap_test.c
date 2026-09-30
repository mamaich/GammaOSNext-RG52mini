/*
 * Проверка логики подсветки на компьютере: sh device/rg52mini/ledd/test/run.sh
 */
#include "../ledmap.h"

#include <stdio.h>

static int g_fails;

#define CHECK(cond)                                                      \
    do {                                                                 \
        if (!(cond)) {                                                   \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);       \
            g_fails++;                                                   \
        }                                                                \
    } while (0)

static int mode_of(int r, int g, int b) {
    return ledmap_bits_to_mode(ledmap_quantize(r, g, b, 0, false));
}

static ledmap_props base(void) {
    ledmap_props p = {
        .control = "on",
        .enable = "1",
        .screen = "on",
        .effect = "1",
        .hex = "#000000",
        .hex_custom = "#FF0000",
        .split = "0",
        .color_split = "0",
        .left_custom = "",
        .right_custom = "",
        .scale = "0",
        .screen_bri = "0.44",
        .led_bri = "255",
        .min_bri = "",
    };
    return p;
}

/* Один расчёт с чистой памятью. */
static ledmap_target run(const ledmap_props *p) {
    ledmap_state st = LEDMAP_STATE_INIT;
    return ledmap_compute(p, 4, &st);
}

static void test_parsing(void) {
    int r, g, b;
    CHECK(ledmap_parse_hex("#FF8000", &r, &g, &b) && r == 255 && g == 128 && b == 0);
    CHECK(ledmap_parse_hex("00ff7f", &r, &g, &b) && r == 0 && g == 255 && b == 127);
    CHECK(!ledmap_parse_hex("#FFF", &r, &g, &b));
    CHECK(!ledmap_parse_hex("", &r, &g, &b));
    CHECK(!ledmap_parse_hex(NULL, &r, &g, &b));
    CHECK(!ledmap_parse_hex("#GG0000", &r, &g, &b));
    CHECK(!ledmap_parse_hex("#FF00001", &r, &g, &b));

    CHECK(ledmap_parse_bool("1", false) && ledmap_parse_bool("true", false));
    CHECK(ledmap_parse_bool("TRUE", false) && ledmap_parse_bool("yes", false));
    CHECK(ledmap_parse_bool("on", false) && ledmap_parse_bool("y", false));
    CHECK(!ledmap_parse_bool("0", true) && !ledmap_parse_bool("false", true));
    CHECK(!ledmap_parse_bool("off", true) && !ledmap_parse_bool("no", true));
    CHECK(ledmap_parse_bool("", true) && !ledmap_parse_bool("", false));
    CHECK(ledmap_parse_bool("junk", true) && !ledmap_parse_bool(NULL, false));

    uint8_t t[LEDMAP_MAX_LEVELS];
    CHECK(ledmap_parse_bri_table("51,50,49,48", t, LEDMAP_MAX_LEVELS) == 4 && t[0] == 51 && t[3] == 48);
    CHECK(ledmap_parse_bri_table("49, 47,45 ,43,41", t, LEDMAP_MAX_LEVELS) == 5 && t[4] == 41);
    CHECK(ledmap_parse_bri_table("", t, LEDMAP_MAX_LEVELS) == 0);
    CHECK(ledmap_parse_bri_table("60", t, LEDMAP_MAX_LEVELS) == 0);   /* вне диапазона */
    CHECK(ledmap_parse_bri_table("34", t, LEDMAP_MAX_LEVELS) == 0);   /* это init */
    CHECK(ledmap_parse_bri_table("20", t, LEDMAP_MAX_LEVELS) == 0);   /* это дыхание */
    CHECK(ledmap_parse_bri_table("51,x", t, LEDMAP_MAX_LEVELS) == 0);
    CHECK(ledmap_parse_bri_table("51,50,49", t, 2) == 0);             /* не влезает */
}

static void test_colours(void) {
    CHECK(mode_of(255, 0, 0) == MCU_MODE_R);
    CHECK(mode_of(0, 255, 0) == MCU_MODE_G);
    CHECK(mode_of(0, 0, 255) == MCU_MODE_B);
    CHECK(mode_of(255, 255, 0) == MCU_MODE_RG);
    CHECK(mode_of(0, 255, 255) == MCU_MODE_GB);
    CHECK(mode_of(255, 0, 255) == MCU_MODE_BR);
    CHECK(mode_of(255, 255, 255) == MCU_MODE_RGB);
    CHECK(mode_of(0, 0, 0) == MCU_MODE_OFF);
    CHECK(mode_of(1, 1, 1) == MCU_MODE_OFF);      /* #010101: подсветка экрана ниже порога */
    CHECK(mode_of(3, 0, 3) == MCU_MODE_OFF);
    CHECK(mode_of(40, 40, 40) == MCU_MODE_RGB);   /* тёмно-серый - белый, тусклее */
    CHECK(mode_of(255, 128, 0) == MCU_MODE_RG);   /* оранжевый - на границе, к жёлтому */
    CHECK(mode_of(255, 120, 0) == MCU_MODE_R);    /* а чуть краснее - красный */
    CHECK(mode_of(200, 20, 90) == MCU_MODE_R);

    /* Гистерезис: 120/255 = 0,47 - между 0,45 и 0,55 */
    CHECK(ledmap_quantize(255, 120, 0, LEDMAP_CH_R, true) == LEDMAP_CH_R);
    CHECK(ledmap_quantize(255, 120, 0, LEDMAP_CH_R | LEDMAP_CH_G, true) == (LEDMAP_CH_R | LEDMAP_CH_G));
    CHECK(ledmap_quantize(255, 150, 0, LEDMAP_CH_R, true) == (LEDMAP_CH_R | LEDMAP_CH_G));
    CHECK(ledmap_quantize(255, 100, 0, LEDMAP_CH_R | LEDMAP_CH_G, true) == LEDMAP_CH_R);
    /* ...и у чёрного: из чёрного - с 6, в чёрный - с 3 */
    CHECK(ledmap_quantize(5, 5, 5, 0, true) == 0);
    CHECK(ledmap_quantize(6, 6, 6, 0, true) == (LEDMAP_CH_R | LEDMAP_CH_G | LEDMAP_CH_B));
    CHECK(ledmap_quantize(5, 0, 0, LEDMAP_CH_R, true) == LEDMAP_CH_R);
    CHECK(ledmap_quantize(3, 0, 0, LEDMAP_CH_R, true) == 0);
    CHECK(ledmap_quantize(5, 5, 5, 0, false) == (LEDMAP_CH_R | LEDMAP_CH_G | LEDMAP_CH_B));

    CHECK(ledmap_init_byte(4) == 0x20);
    CHECK(ledmap_init_byte(8) == 0x21);
    CHECK(ledmap_init_byte(12) == 0x22);
    CHECK(ledmap_init_byte(16) == 0x23);
    CHECK(ledmap_init_byte(10) == -1);

    CHECK(ledmap_level(0.0f, 4) == 0);
    CHECK(ledmap_level(1.0f, 4) == 3);
    CHECK(ledmap_level(0.5f, 4) == 2);
    CHECK(ledmap_level(0.44f, 4) == 1);
    CHECK(ledmap_level(-1.0f, 4) == 0);
    CHECK(ledmap_level(7.0f, 4) == 3);
    CHECK(ledmap_level(0.9f, 1) == 0);
    volatile float zero = 0.0f;
    CHECK(ledmap_level(zero / zero, 4) == 0);     /* NaN */
}

static void test_compute(void) {
    ledmap_props p = base();
    ledmap_target x = run(&p);
    CHECK(x.on && x.mode == MCU_MODE_SCROLL && x.level == 3 && !x.follow);

    p = base(); p.effect = "2";
    x = run(&p);
    CHECK(x.on && x.mode == MCU_MODE_BREATH);

    p = base(); p.effect = "3"; p.hex_custom = "#00FF00";
    x = run(&p);
    CHECK(x.on && x.mode == MCU_BREATH_OFFSET + MCU_MODE_G && x.level == 3);
    p.hex_custom = "#004000";   /* тёмный свой цвет - дыхание тусклее */
    x = run(&p);
    CHECK(x.mode == MCU_BREATH_OFFSET + MCU_MODE_G && x.level == 1);

    p = base(); p.effect = "3"; p.hex_custom = "#000000"; p.hex = "";
    x = run(&p);
    CHECK(x.on && x.mode == MCU_MODE_BREATH);   /* чёрный - просто дыхание */

    p = base(); p.effect = "4";
    x = run(&p);
    CHECK(x.mode == MCU_MODE_SCROLL);

    /* Свой цвет: тёмный - тусклее */
    p = base(); p.effect = "none"; p.hex_custom = "#FF0000";
    x = run(&p);
    CHECK(x.on && x.mode == MCU_MODE_R && x.level == 3 && !x.follow);
    p.hex_custom = "#800000";
    x = run(&p);
    CHECK(x.mode == MCU_MODE_R && x.level == 2);
    p.hex_custom = "FF00FF";    /* без решётки - так он задан по умолчанию */
    x = run(&p);
    CHECK(x.mode == MCU_MODE_BR);
    p.hex_custom = "#000000";
    x = run(&p);
    CHECK(x.on && x.mode == MCU_MODE_OFF);   /* чёрный - погасить, питание не снимать */
    p.effect = "NONE"; p.hex_custom = "#0000FF";
    x = run(&p);
    CHECK(x.mode == MCU_MODE_B);

    /* Пустой и незнакомый эффект - тоже свой цвет, не за экраном */
    p = base(); p.effect = ""; p.hex = "#00FF00"; p.hex_custom = "#0000FF";
    x = run(&p);
    CHECK(!x.follow && x.mode == MCU_MODE_B);
    p.effect = "rainbow";
    x = run(&p);
    CHECK(!x.follow && x.mode == MCU_MODE_B);
}

static void test_split(void) {
    /* Раздельные цвета - только у постоянного своего цвета и только при
     * split=1 и color_split=1, как решает выбор цвета; берём среднее. */
    ledmap_props p = base();
    p.effect = "none"; p.split = "1"; p.color_split = "1"; p.hex_custom = "#00FF00";
    p.left_custom = "#FF0000"; p.right_custom = "#0000FF";
    ledmap_target x = run(&p);
    CHECK(x.mode == MCU_MODE_BR && x.level == 2);   /* #800080 */
    p.right_custom = "";
    x = run(&p);
    CHECK(x.mode == MCU_MODE_G);                    /* правого нет - общий цвет */
    p.right_custom = "#0000FF"; p.split = "0";
    x = run(&p);
    CHECK(x.mode == MCU_MODE_G);                    /* устройство без раздельных */
    p.split = "true";
    x = run(&p);
    CHECK(x.mode == MCU_MODE_G);                    /* Toolbox пишет true; выбор цвета ждёт 1 */
    p.split = "1"; p.color_split = "0";
    x = run(&p);
    CHECK(x.mode == MCU_MODE_G);
    p.color_split = "1"; p.effect = "3";
    x = run(&p);
    CHECK(x.mode == MCU_BREATH_OFFSET + MCU_MODE_G);   /* эффекты - общим цветом */
}

static void test_brightness(void) {
    ledmap_props p = base(); p.scale = "1"; p.screen_bri = "1.0";
    ledmap_target x = run(&p);
    CHECK(x.level == 3);
    p.screen_bri = "0.0";
    x = run(&p);
    CHECK(x.level == 0);
    p.screen_bri = "";
    x = run(&p);
    CHECK(x.level == 3);   /* нет данных - полная */
    p.screen_bri = "NaN";
    x = run(&p);
    CHECK(x.level == 0);
    p.screen_bri = "-1.0";
    x = run(&p);
    CHECK(x.level == 0);
    p.screen_bri = "1.0E-4";   /* так пишет Java String.valueOf(float) */
    x = run(&p);
    CHECK(x.level == 0);
    /* Toolbox пишет true/false */
    p.scale = "true"; p.screen_bri = "0.1";
    x = run(&p);
    CHECK(x.level == 0);
    p.scale = "false";
    x = run(&p);
    CHECK(x.level == 3);   /* ползунок, 255 */
    p = base(); p.led_bri = "128";
    x = run(&p);
    CHECK(x.level == 2);
    p.led_bri = "0"; p.min_bri = "200";
    x = run(&p);
    CHECK(x.level == 2);   /* порог 200/255 */
}

static void test_follow(void) {
    ledmap_state st = LEDMAP_STATE_INIT;
    ledmap_props p = base(); p.effect = "follow"; p.hex = "#0000FF";
    ledmap_target x = ledmap_compute(&p, 4, &st);
    CHECK(x.on && x.follow && x.mode == MCU_MODE_B && x.level == 3);
    p.hex = "#000000";
    x = ledmap_compute(&p, 4, &st);
    CHECK(x.on && x.mode == MCU_MODE_OFF);
    p.hex = "#010101";
    x = ledmap_compute(&p, 4, &st);
    CHECK(x.on && x.mode == MCU_MODE_OFF);
    p.effect = "Follow"; p.hex = "#00FF00";
    x = ledmap_compute(&p, 4, &st);
    CHECK(x.follow && x.mode == MCU_MODE_G);

    /* Сэмплер ещё молчит - свой цвет, и яркость по своим правилам */
    p.hex = ""; p.hex_custom = "#FF0000";
    x = ledmap_compute(&p, 4, &st);
    CHECK(x.mode == MCU_MODE_R && x.level == 3);
    p.scale = "1"; p.screen_bri = "0.1";
    x = ledmap_compute(&p, 4, &st);
    CHECK(x.mode == MCU_MODE_R && x.level == 0);

    /* Гистерезис цвета между вызовами */
    p = base(); p.effect = "follow";
    st = (ledmap_state)LEDMAP_STATE_INIT;
    p.hex = "#FF9600";   /* 150/255 = 0,59 - жёлтый */
    x = ledmap_compute(&p, 4, &st);
    CHECK(x.mode == MCU_MODE_RG);
    p.hex = "#FF7800";   /* 120/255 = 0,47 - остаётся жёлтым */
    x = ledmap_compute(&p, 4, &st);
    CHECK(x.mode == MCU_MODE_RG);
    p.hex = "#FF6400";   /* 100/255 = 0,39 - уже красный */
    x = ledmap_compute(&p, 4, &st);
    CHECK(x.mode == MCU_MODE_R);

    /* Гистерезис яркости: на границе уровней не мигать */
    st = (ledmap_state)LEDMAP_STATE_INIT;
    p.hex = "#800000";   /* 128: 1,51 - уровень 2 */
    CHECK(ledmap_compute(&p, 4, &st).level == 2);
    p.hex = "#7F0000";   /* 127: 1,49 - держим 2 */
    CHECK(ledmap_compute(&p, 4, &st).level == 2);
    p.hex = "#800000";
    CHECK(ledmap_compute(&p, 4, &st).level == 2);
    p.hex = "#400000";   /* 64: 0,75 - далеко, уровень 1 */
    CHECK(ledmap_compute(&p, 4, &st).level == 1);
    p.hex = "#2B0000";   /* 43: 0,51 - держим 1 */
    CHECK(ledmap_compute(&p, 4, &st).level == 1);
    p.hex = "#150000";   /* 21: 0,25 - уровень 0 */
    CHECK(ledmap_compute(&p, 4, &st).level == 0);

    /* ...и у чёрного */
    st = (ledmap_state)LEDMAP_STATE_INIT;
    p.hex = "#FF0000";
    CHECK(ledmap_compute(&p, 4, &st).mode == MCU_MODE_R);
    p.hex = "#050505";   /* горели - тёмно-серый ещё виден */
    x = ledmap_compute(&p, 4, &st);
    CHECK(x.mode == MCU_MODE_RGB && x.level == 0);
    p.hex = "#030303";
    CHECK(ledmap_compute(&p, 4, &st).mode == MCU_MODE_OFF);
    p.hex = "#050505";   /* из чёрного - ещё рано */
    CHECK(ledmap_compute(&p, 4, &st).mode == MCU_MODE_OFF);
    p.hex = "#060606";
    CHECK(ledmap_compute(&p, 4, &st).mode == MCU_MODE_RGB);

    /* Уход из режима за экраном сбрасывает память уровня */
    st = (ledmap_state)LEDMAP_STATE_INIT;
    p.hex = "#800000";
    CHECK(ledmap_compute(&p, 4, &st).level == 2);
    p.effect = "none";
    (void)ledmap_compute(&p, 4, &st);
    CHECK(st.level == -1);
    p.effect = "follow"; p.hex = "#7F0000";
    CHECK(ledmap_compute(&p, 4, &st).level == 1);
}

static void test_off(void) {
    ledmap_props p = base(); p.control = "off";
    CHECK(!run(&p).on);
    p = base(); p.control = "OFF";
    CHECK(!run(&p).on);
    p = base(); p.screen = "off";
    CHECK(!run(&p).on);
    p = base(); p.enable = "0";
    CHECK(!run(&p).on);
    p = base(); p.enable = "false";
    CHECK(!run(&p).on);
    p = base(); p.enable = "true";
    CHECK(run(&p).on);
    p = base(); p.control = ""; p.screen = ""; p.enable = "";
    CHECK(run(&p).on);   /* не задано - включено */

    /* Возврат главного выключателя - только на переходе control из off */
    CHECK(ledmap_reenable("off", "on", "0"));
    CHECK(ledmap_reenable("off", "on", "false"));
    CHECK(!ledmap_reenable("on", "on", "0"));     /* та же запись ещё раз */
    CHECK(!ledmap_reenable("off", "off", "0"));
    CHECK(!ledmap_reenable("off", "on", "1"));    /* и так включён */
    CHECK(!ledmap_reenable("off", "on", ""));
    CHECK(!ledmap_reenable("on", "off", "0"));
}

static void test_decide(void) {
    ledmap_target on = { .on = true, .mode = MCU_MODE_R, .level = 2, .follow = false };
    ledmap_target off = { .on = false, .mode = MCU_MODE_OFF, .level = 0, .follow = false };
    ledmap_sent idle = { .on = false, .rail_leftover = false, .mode = -1, .level = -1, .last_send_ms = 0 };
    ledmap_sent lit = { .on = true, .rail_leftover = false, .mode = MCU_MODE_R, .level = 2, .last_send_ms = 1000 };

    ledmap_actions a = ledmap_decide(&off, &idle, 5000);
    CHECK(!a.power_down && !a.power_up && !a.send_mode && !a.send_level);
    a = ledmap_decide(&on, &idle, 5000);
    CHECK(a.power_up && !a.power_down);
    a = ledmap_decide(&off, &lit, 5000);
    CHECK(a.power_down && !a.power_up);
    a = ledmap_decide(&on, &lit, 5000);
    CHECK(!a.power_down && !a.power_up && !a.send_mode && !a.send_level &&
          a.wait_ms == LEDMAP_IDLE_WAIT_MS);

    /* перезапуск службы с горящим питанием */
    ledmap_sent left = idle; left.rail_leftover = true;
    a = ledmap_decide(&off, &left, 5000);
    CHECK(a.power_down);
    a = ledmap_decide(&on, &left, 5000);
    CHECK(a.power_up && !a.power_down);   /* заново init, питание не трогаем повторно */

    /* смена режима и яркости */
    ledmap_target blue = on; blue.mode = MCU_MODE_B;
    a = ledmap_decide(&blue, &lit, 5000);
    CHECK(a.send_mode && !a.send_level);
    ledmap_target dim = on; dim.level = 0;
    a = ledmap_decide(&dim, &lit, 5000);
    CHECK(a.send_level && !a.send_mode);
    ledmap_target black = on; black.mode = MCU_MODE_OFF;
    a = ledmap_decide(&black, &lit, 5000);
    CHECK(a.send_mode && !a.power_down);   /* чёрный - режим 9, питание остаётся */

    /* за экраном - не чаще 300 мс, и для цвета, и для яркости */
    ledmap_target fol = blue; fol.follow = true;
    a = ledmap_decide(&fol, &lit, 1100);
    CHECK(!a.send_mode && a.wait_ms == 200);
    a = ledmap_decide(&fol, &lit, 1300);
    CHECK(a.send_mode);
    ledmap_target fdim = dim; fdim.follow = true;
    a = ledmap_decide(&fdim, &lit, 1100);
    CHECK(!a.send_level && a.wait_ms == 200);
    a = ledmap_decide(&fdim, &lit, 1300);
    CHECK(a.send_level && !a.send_mode);
    a = ledmap_decide(&blue, &lit, 1100);
    CHECK(a.send_mode);   /* свой цвет - сразу */
}

int main(void) {
    test_parsing();
    test_colours();
    test_compute();
    test_split();
    test_brightness();
    test_follow();
    test_off();
    test_decide();
    printf("%s: %d failure(s)\n", g_fails ? "FAIL" : "OK", g_fails);
    return g_fails != 0;
}
