#!/usr/bin/env python3
# Новые платформы Daijishō для папок РОМов dArkOS/EmuELEC, которых в GammaOS не было
# (решение владельца 17.10.2026). Описания платформ и списки эмуляторов - официальные,
# из TapiocaFox/Daijishou (platforms/*.json, скачаны 17.10.2026 в platforms/ рядом).
# Записи RetroArch переписываются в формат, в котором они уже лежат в базе GammaOS:
# полный путь к ядру и прочие -e, шаблон - запись nes.ra64.nestopia.
#
# Выдаёт SQL; повторный запуск ничего не меняет (платформа с таким unique_id
# пропускается). Номера платформ фиксированные - по ним названы файлы обоев
# platform_wallpapers/<id>.png; соответствие номер -> обои пишется в walls.json.
# С двумя последними аргументами ещё и SQL переноса на уже установленную систему
# (rg52-daijisho.sh): без фиксированных номеров - у пользователя могут быть свои
# платформы, - и список <unique_id> <номер обоев в архиве> для обоев.
#   platforms.py <Daijishou.db (только чтение)> <каталог с *.json> <walls.json> #       [<migrate.sql> <walls.txt>] > platforms.sql
import json
import os
import re
import sqlite3
import sys

DB, DJP, WALLS = sys.argv[1], sys.argv[2], sys.argv[3]
MIGRATE, MWALLS = (sys.argv[4], sys.argv[5]) if len(sys.argv) > 5 else (None, None)

TREE = "content://com.android.externalstorage.documents/tree/"
EXT = ["00000000-0000-0000-0000-00000000000%d" % n for n in range(1, 6)]
WALL = "/data/user/0/com.magneticchen.daijishou/files/platform_wallpapers/%d.png"
# Служебные файлы dArkOS (Scan_for_new_games.*) и скрытые файлы - не игры.
ANY = r"^(?!(?:\._|\.|Scan_for_new_games\.).*).*$"
FIRST_PLATFORM_ID = 23
FIRST_PLAYER_ID = 313
# ScummVM (37) и Wolfenstein 3D (40) были и убраны по решению владельца 17.10.2026;
# номера остальных платформ - как на его консоли, где они уже стояли.
SKIP_IDS = {"gc": 38}
# Скрыты (is_visible = 0) по решению владельца 17.10.2026 - на RK3562 (4x Cortex-A53)
# неиграбельны: PS2 (эмулятора в GammaOS нет, EmuCoreX ставится вручную) и GameCube
# (Dolphin). Включаются в настройках Daijishō.
HIDDEN = {"ps2", "gc"}


def uris(folder):
    # Тот же набор, что у основных папок платформ GammaOS: ROMs/<папка> во
    # внутренней памяти, roms/<папка> и <папка> на внешних картах.
    out = [TREE + "primary%3AROMs%2F" + folder]
    for v in EXT:
        out.append(TREE + v + "%3Aroms%2F" + folder)
        out.append(TREE + v + "%3A" + folder)
    return out


EMUCOREX_GIT = {
    # EmuCoreX (PCSX2 для Android) из Google Play, пакет com.aetherplay_emulator.git. Действие
    # и ключ - с исходными именами com.sbro.emucorex (GameLaunchShortcut.kt), а не с префиксом
    # пакета: с ним приложение открывает свою библиотеку, а не игру (проверено 17.10.2026).
    "name": "ps2 - EmuCoreX (Google Play)",
    "uniqueId": "ps2.com.aetherplay_emulator.git",
    "description": "EmuCoreX from Google Play. Supported extensions: iso, chd, cso, bin.",
    "acceptedFilenameRegex": "^(.*).(?:iso|chd|cso|bin)$",
    "amStartArguments": "-n com.aetherplay_emulator.git/com.sbro.emucorex.MainActivity\n"
                        " -a com.sbro.emucorex.action.LAUNCH_GAME\n"
                        " --es com.sbro.emucorex.extra.GAME_PATH {file.path}\n"
                        " --activity-clear-task\n --activity-clear-top\n ",
    "killPackageProcesses": False,
    "killPackageProcessesWarning": True,
    "extra": "",
}

# (описание, имя в библиотеке, папки ROMs, эмулятор по умолчанию, регулярка платформы, обои BB-1 Dark)
# Эмуляторы по умолчанию проверены запуском на консоли 17.10.2026. Atomiswave - ядро flycast
# RetroArch: BIOS берёт из общей ROMs/bios/dc, у отдельного Flycast своя папка данных.
SPECS = [
    ("ArcadeFinalBurnNeo", "Arcade (FinalBurn Neo)", ["fbneo", "fba", "arcade", "cps"], "fbneo.ra64.fbneo", None, "fbneo"),
    ("ArcadeMAME", "Arcade (MAME)", ["mame", "mame2003"], "mame.ra64.mame2003_plus", None, "mame"),
    ("CPS1", "CP System I", ["cps1"], "cps1.ra64.fbneo", None, "cps1"),
    ("CPS2", "CP System II", ["cps2"], "cps2.ra64.fbneo", None, "cps2"),
    ("CPS3", "CP System III", ["cps3"], "cps3.ra64.fbneo", None, "cps3"),
    ("NeoGeo", "Neo Geo", ["neogeo"], "neogeo.ra64.fbneo", None, "neogeo"),
    ("Atomiswave", "Atomiswave", ["atomiswave"], "atomiswave.ra64.flycast", None, "atomiswave"),
    ("TurboGrafx16", "PC Engine / TurboGrafx-16", ["pcengine", "tg16", "turbografx"],
     "tg16.ra64.mednafen_pce_fast", None, "tg16"),
    # CD-платформы: только образы диска, без дорожек .bin/.wav/.iso, на которые ссылается .cue
    ("TurboGrafxCD", "PC Engine CD / TurboGrafx-CD", ["pcenginecd", "tg-cd", "tgcd", "turbografxcd"],
     "tgcd.ra64.mednafen_pce_fast", r"(?i)^(?!(?:\._|\.).*).*\.(?:cue|chd|ccd|toc|m3u)$", "tg16cd"),
    ("Sega32X", "Sega 32X", ["sega32x", "sega32xjp", "sega32xna"], "sega32x.ra64.picodrive", None, "sega32x"),
    ("SegaCD", "Sega CD", ["segacd", "megacd", "megacdjp"], "segacd.ra64.genesis_plus_gx",
     r"(?i)^(?!(?:\._|\.).*).*\.(?:cue|chd|m3u)$", "segacd"),
    ("Atari2600", "Atari 2600", ["atari2600"], "atari2600.ra64.stella", None, "atari2600"),
    ("AtariLynx", "Atari Lynx", ["atarilynx", "lynx"], "lynx.ra64.handy", None, "atarilynx"),
    ("AmstradCPC", "Amstrad CPC", ["amstradcpc", "cpc"], "cpc.ra64.cap32", None, "amstradcpc"),
    ("NintendoGameCube", "Nintendo GameCube", ["gc", "gamecube"], "gc.ra64.dolphin",
     r"(?i)^(?!(?:\._|\.).*).*\.(?:iso|gcm|gcz|rvz|ciso|tgc|dol|elf|m3u)$", "gc"),
    # BIOS PS2 (*.bin) dArkOS держит в ROMs/ps2/bios - .bin исключён, иначе он попадёт в библиотеку.
    ("SonyPlayStation2", "Sony PlayStation 2", ["ps2"], "ps2.com.aetherplay_emulator.git",
     r"(?i)^(?!(?:\._|\.).*).*\.(?:iso|chd|cso|zso|gz|ciso|mdf|nrg|img|elf)$", "ps2"),
]

db = sqlite3.connect("file:%s?mode=ro" % DB, uri=True)
tmpl = db.execute("select am_start_arguments from PlayerEntity where unique_id = 'nes.ra64.nestopia'").fetchone()[0]
assert "/cores/nestopia_libretro_android.so" in tmpl, tmpl
existing = {r[0] for r in db.execute("select unique_id from PlatformEntity")}
if "ps2" not in existing:
    # номера новых записей фиксированные - заняты быть не должны
    mp = db.execute("select max(id) from PlatformEntity").fetchone()[0]
    mpl = db.execute("select max(id) from PlayerEntity").fetchone()[0]
    assert mp < FIRST_PLATFORM_ID and mpl < FIRST_PLAYER_ID, (mp, mpl)


def gammaos_ra(args):
    # -n <pkg>/... -e ROM {file.path} -e LIBRETRO <core> [-e CONFIGFILE ...] -> шаблон GammaOS
    m = re.match(r"-n (com\.retroarch(?:\.aarch64|\.ra32)?)/com\.retroarch\.browser\.retroactivity\.RetroActivityFuture", args)
    if not m:
        return args
    core = re.search(r"-e LIBRETRO (\S+)", args).group(1)
    return tmpl.replace("com.retroarch.aarch64", m.group(1)).replace("nestopia_libretro", core + "_libretro")


def q(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, int):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def js(v):
    return json.dumps(v, separators=(",", ":"), ensure_ascii=False)


COLS = ("unique_id, name, shortname, description, is_visible, "
        "scrape_preview_media, wallpaper_path, thumbnail_path, color_theme, color_on_theme, "
        "accept_filename_regex, default_player_id, player_id_list, scraper_source_list, "
        "box_art_aspect_ratio_id, use_custom_box_art_aspect_ratio, custom_box_art_aspect_ratio, "
        "screen_aspect_ratio_id, use_custom_screen_aspect_ratio, custom_screen_aspect_ratio, "
        "items_sync_tree_uri_list, retro_achievements_console_id_list, extra")
PCOLS = ("unique_id, player, name, description, am_start_arguments, "
         "kill_package_processes, kill_package_processes_warning, accepted_filename_regex, extra")


def player_vals(pl):
    return "%s, 1, %s, %s, %s, %s, %s, %s, %s" % (
        q(pl["uniqueId"]), q(pl["name"]), q(pl.get("description")),
        q(gammaos_ra(pl["amStartArguments"])), q(bool(pl["killPackageProcesses"])),
        q(bool(pl["killPackageProcessesWarning"])), q(pl["acceptedFilenameRegex"]), q(pl.get("extra") or ""))


def platform_vals(p, name, regex, wallpaper, default_id, id_list, paths):
    return "%s, %s, %s, %s, %d, 1, %s, NULL, NULL, NULL, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s" % (
        q(p["uniqueId"]), q(name), q(p["shortname"]), q(p.get("description")),
        0 if p["shortname"] in HIDDEN else 1, wallpaper, q(regex or ANY), default_id, id_list,
        q(js(p["scraperSourceList"])),
        q(p["boxArtAspectRatioId"]), q(bool(p["useCustomBoxArtAspectRatio"])), q(p["customBoxArtAspectRatio"]),
        q(p["screenAspectRatioId"]), q(bool(p["useCustomScreenAspectRatio"])), q(p["customScreenAspectRatio"]),
        q(js(paths)), q(js(p["retroAchievementsConsoleIdList"])), q(p.get("extra") or ""))


# все платформы с номерами, как в исходной базе
plan, pid = [], FIRST_PLATFORM_ID
for src, name, folders, default, regex, wall in SPECS:
    j = json.load(open(os.path.join(DJP, src + ".json"), encoding="utf-8"))
    p = j["platform"]
    players = list(j["playerList"])
    if p["shortname"] == "ps2":
        players.insert(0, EMUCOREX_GIT)
    if p["shortname"] in SKIP_IDS:
        pid = SKIP_IDS[p["shortname"]]
    # в официальных описаниях бывают две записи с одним uniqueId (flycast: uri и path) - берутся обе
    di = [i for i, pl in enumerate(players) if pl["uniqueId"] == default]
    assert di, (name, default)
    plan.append((pid, p, name, players, di[0], [u for f in folders for u in uris(f)], regex, wall))
    pid += 1

# исходная база (build.sh): номера фиксированные
plid, walls = FIRST_PLAYER_ID, {}
print("BEGIN;")
for pid, p, name, players, di, paths, regex, wall in plan:
    if p["uniqueId"] in existing:
        print("-- skip %s: already present" % p["uniqueId"])
        continue
    ids = list(range(plid, plid + len(players)))
    for i, pl in zip(ids, players):
        print("INSERT INTO PlayerEntity (id, %s) VALUES (%d, %s);" % (PCOLS, i, player_vals(pl)))
    plid += len(players)
    print("INSERT INTO PlatformEntity (id, %s) VALUES (%d, %s);" % (
        COLS, pid, platform_vals(p, name, regex, q(WALL % pid), str(ids[di]), q(js(ids)), paths)))
    walls[pid] = wall
    print("-- %d %s: %d players, default %d, %d paths%s" % (
        pid, name, len(ids), ids[di], len(paths), ", hidden" if p["shortname"] in HIDDEN else ""))
# и для платформ, добавленных прежним запуском (GameCube скрыт позже, чем добавлен)
print("UPDATE PlatformEntity SET is_visible = 0 WHERE shortname IN (%s) AND is_visible = 1;"
      % ", ".join(q(s) for s in sorted(HIDDEN)))
print("COMMIT;")
if walls:
    json.dump(walls, open(WALLS, "w"))

# перенос на установленную систему: номера раздаёт сама база. Новые эмуляторы получают
# номера больше всех прежних, по ним платформа и собирает свой список; платформа и её
# эмуляторы добавляются, только если платформы с таким unique_id ещё нет.
if MIGRATE:
    with open(MIGRATE, "w", encoding="utf-8", newline="\n") as o, \
            open(MWALLS, "w", encoding="utf-8", newline="\n") as w:
        o.write("-- generated by device/rg52mini/tools/daijisho/platforms.py, do not edit\n")
        o.write("CREATE TEMP TABLE IF NOT EXISTS rg52_m (k TEXT PRIMARY KEY, v INTEGER);\n")
        new = "(SELECT id FROM PlayerEntity WHERE id > (SELECT v FROM rg52_m WHERE k = 'base') ORDER BY id)"
        for pid, p, name, players, di, paths, regex, wall in plan:
            uid = q(p["uniqueId"])
            o.write("\n-- %s\nBEGIN;\n" % name)
            o.write("INSERT OR REPLACE INTO rg52_m VALUES ('base', (SELECT COALESCE(MAX(id), 0) FROM PlayerEntity)), "
                    "('add', (SELECT COUNT(*) = 0 FROM PlatformEntity WHERE unique_id = %s));\n" % uid)
            for pl in players:
                o.write("INSERT INTO PlayerEntity (%s) SELECT %s WHERE (SELECT v FROM rg52_m WHERE k = 'add');\n"
                        % (PCOLS, player_vals(pl)))
            o.write("INSERT INTO PlatformEntity (%s) SELECT %s WHERE (SELECT v FROM rg52_m WHERE k = 'add');\n" % (
                COLS, platform_vals(
                    p, name, regex, "NULL",
                    "(%s LIMIT 1 OFFSET %d)" % (new[1:-1], di),
                    "(SELECT json_group_array(id) FROM %s)" % new, paths)))
            o.write("UPDATE PlatformEntity SET wallpaper_path = "
                    "'/data/user/0/com.magneticchen.daijishou/files/platform_wallpapers/' || id || '.png' "
                    "WHERE unique_id = %s AND wallpaper_path IS NULL;\n" % uid)
            o.write("COMMIT;\n")
            w.write("%s %d\n" % (p["uniqueId"], pid))
