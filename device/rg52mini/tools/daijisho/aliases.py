#!/usr/bin/env python3
# SQL, добавляющий в базу Daijishō папки-синонимы dArkOS/EmuELEC как дополнительные
# пути поиска РОМов. Добавляет только недостающие пути, повторный запуск ничего не
# меняет; годится и для базы в daijisho.tar.zst, и для установленной (sqlite3 на
# устройстве, Daijishō при этом может работать - база в режиме WAL).
#   aliases.py > aliases.sql
ALT = {
    # с 02.10.2026 (93a26266648); синонимы без своей платформы - к ближайшей, чей эмулятор
    # по умолчанию их запускает (sg-1000 - genesis_plus_gx, pico-8 - те же картриджи)
    "genesis": ["megadrive", "megadrivejp", "msumd"],
    "nes": ["famicom", "fds", "nesh"],
    "snes": ["sfc", "snesna", "satellaview", "sufami", "snes-hacks", "snesmsu1"],
    "ngpc": ["ngp"],
    "gb": ["sgb"],
    # 17.10.2026
    "pico8": ["pico-8"],
    "psp": ["pspminis"],
    "n64": ["n64dd"],
    "master": ["sg-1000"],
}

TREE = "content://com.android.externalstorage.documents/tree/"
EXT = ["00000000-0000-0000-0000-00000000000%d" % n for n in range(1, 6)]


def uris(folder):
    # Тот же набор, что у основной папки платформы: ROMs/<папка> во
    # внутренней памяти, roms/<папка> и <папка> на внешних картах.
    out = [TREE + "primary%3AROMs%2F" + folder]
    for v in EXT:
        out.append(TREE + v + "%3Aroms%2F" + folder)
        out.append(TREE + v + "%3A" + folder)
    return out


print("BEGIN;")
for short, alts in ALT.items():
    for a in alts:
        for u in uris(a):
            print("UPDATE PlatformEntity SET items_sync_tree_uri_list = "
                  "json_insert(items_sync_tree_uri_list, '$[#]', '%s') "
                  "WHERE shortname = '%s' AND NOT EXISTS (SELECT 1 FROM "
                  "json_each(PlatformEntity.items_sync_tree_uri_list) WHERE value = '%s');"
                  % (u, short, u))
print("COMMIT;")
