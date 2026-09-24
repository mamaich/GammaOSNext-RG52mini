#!/usr/bin/env python3
"""Меняет частоту памяти в загрузчике образа SD-карты или на самой карте.

    set-ddr-freq.py --show  <цель>
    set-ddr-freq.py <цель> <частота> [--set имя=значение ...] [--yes]

Цель — образ карты, сама карта (/dev/sdX) или голый idbloader.bin.

Зачем инструмент, а не заплатка по месту. Частоту задаёт ddrbin внутри
idbloader, и `ddrbin_tool.py` из rkbin умеет её переписать — но он меняет байты
и на этом останавливается. А заголовок idblock у RK3562 версии 2: он несёт
SHA-256 каждого образа внутри себя и свой собственный хеш. Заплатка их ломает,
и BootROM отвергает загрузчик молча - устройство не даёт даже вывода в UART.
Плюс idblock лежит в двух копиях, в секторах 64 и 1088.

Поэтому здесь: переписать частоту, пересчитать хеши, сверить их, продублировать
копию - и только потом записать.

Что важно помнить про саму затею. Обучение DDR не откатывается на меньшую
частоту: память - то, откуда работает сам загрузчик, отступать ему некуда.
Исходов три. Обучение сходится и всё хорошо. Не сходится - зависание в
загрузчике, adb не будет. Сходится с нулевым запасом - система работает, а
ошибки вылезают редко и случайно, то есть тихо портятся данные. Третий исход
хуже второго, поэтому после смены частоты память надо проверять, а не
довольствоваться фактом загрузки: mtest в u-boot, memtest=N в строке загрузки,
stressapptest на прогретом устройстве.
"""

import argparse
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import tempfile

IDB_SECTOR = 64            # где начинается idbloader на карте
IDB_SECTORS = 16320        # до начала раздела uboot (сектор 16384)
SEC = 512
RKBIN = os.environ.get("RKBIN", "/home/mamaich/rg52/rkbin")
CHIP = "rk3562"


def die(msg):
    print("!! " + msg, file=sys.stderr)
    sys.exit(1)


# --------------------------------------------------------------- idblock

def copies(buf):
    """Смещения копий idblock в байтах от начала области."""
    out = []
    for off in range(0, len(buf) - 4, SEC):
        if buf[off:off + 4] == b"RKNS":
            out.append(off)
    return out


def images(buf, base):
    """[(смещение записи, начало образа, размер)] для одной копии."""
    size_nimage = struct.unpack_from("<I", buf, base + 8)[0]
    out = []
    for i in range(size_nimage >> 16):
        entry = base + 120 + i * 88
        so = struct.unpack_from("<I", buf, entry)[0]
        out.append((entry, (so & 0xFFFF) * SEC, (so >> 16) * SEC))
    return out


def header_hash_offset(buf, base):
    return (struct.unpack_from("<I", buf, base + 8)[0] & 0xFFFF) * 4


def rehash(buf, base):
    """Пересчитывает хеши образов и заголовка одной копии. Меняет buf на месте."""
    for entry, off, size in images(buf, base):
        h = hashlib.sha256(buf[base + off:base + off + size]).digest()
        buf[entry + 24:entry + 24 + 32] = h
    hoff = header_hash_offset(buf, base)
    h = hashlib.sha256(buf[base:base + hoff]).digest()
    buf[base + hoff:base + hoff + 32] = h


def check(buf, base):
    """Сверяет хеши одной копии. Возвращает список несошедшихся."""
    bad = []
    for n, (entry, off, size) in enumerate(images(buf, base)):
        want = bytes(buf[entry + 24:entry + 24 + 32])
        got = hashlib.sha256(buf[base + off:base + off + size]).digest()
        if want != got:
            bad.append("образ %d" % n)
    hoff = header_hash_offset(buf, base)
    if bytes(buf[base + hoff:base + hoff + 32]) != hashlib.sha256(buf[base:base + hoff]).digest():
        bad.append("заголовок")
    return bad


def used_sectors(buf, base):
    """Сколько секторов занимает копия целиком, включая заголовок."""
    end = max((off + size) for _, off, size in images(buf, base))
    return end // SEC


# --------------------------------------------------------------- ddrbin

def ddrbin_tool(*args):
    tool = os.path.join(RKBIN, "tools", "ddrbin_tool.py")
    if not os.path.isfile(tool):
        die("нет %s (задайте RKBIN=)" % tool)
    r = subprocess.run([sys.executable, tool, CHIP, *args],
                       capture_output=True, text=True)
    if r.returncode != 0:
        die("ddrbin_tool: %s" % (r.stderr or r.stdout).strip().splitlines()[-1:])
    return r.stdout


def read_params(path):
    with tempfile.NamedTemporaryFile("r+", suffix=".txt", delete=False) as f:
        txt = f.name
    ddrbin_tool("-g", txt, path)
    with open(txt, encoding="utf-8") as f:
        body = f.read()
    os.unlink(txt)
    return body


def param_value(body, name):
    for line in body.splitlines():
        if line.startswith(name + "="):
            return line.split("=", 1)[1]
    return None


# --------------------------------------------------------------- цель

def locate(path):
    """Возвращает (смещение области в байтах, это блочное устройство)."""
    with open(path, "rb") as f:
        f.seek(IDB_SECTOR * SEC)
        if f.read(4) == b"RKNS":
            return IDB_SECTOR * SEC, os.stat(path).st_mode & 0o170000 == 0o060000
        f.seek(0)
        if f.read(4) == b"RKNS":
            return 0, False
    die("в %s не нашёл RKNS ни в секторе 64, ни в начале файла" % path)


def read_region(path, off):
    with open(path, "rb") as f:
        f.seek(off)
        return bytearray(f.read(IDB_SECTORS * SEC))


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("target", help="образ карты, /dev/sdX или idbloader.bin")
    ap.add_argument("freq", nargs="?", type=int, help="частота LPDDR3, МГц")
    ap.add_argument("--show", action="store_true", help="только показать текущее")
    ap.add_argument("--set", action="append", default=[], metavar="имя=значение",
                    help="изменить ещё один параметр ddrbin, можно несколько раз")
    ap.add_argument("--yes", action="store_true",
                    help="обязателен, если цель - блочное устройство")
    ap.add_argument("--no-backup", action="store_true")
    a = ap.parse_args()

    off, is_dev = locate(a.target)
    region = read_region(a.target, off)
    cps = copies(region)
    print("цель: %s" % a.target)
    print("область загрузчика: смещение %d, копий idblock %d (сектора карты %s)"
          % (off, len(cps), ", ".join(str(IDB_SECTOR + c // SEC) for c in cps)))

    for c in cps:
        bad = check(region, c)
        print("   копия в секторе %d: %s"
              % (IDB_SECTOR + c // SEC, "хеши сходятся" if not bad
                 else "НЕ СХОДЯТСЯ: " + ", ".join(bad)))

    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        work = f.name
        f.write(region)
    try:
        body = read_params(work)
        cur = param_value(body, "lp3_freq")
        steps = [param_value(body, "lp3_f%d_freq_mhz" % i) for i in (1, 2, 3)]
        print("сейчас: lp3_freq=%s, ступени %s" % (cur, "/".join(s or "-" for s in steps)))

        if a.show or a.freq is None:
            return

        if is_dev and not a.yes:
            die("цель - блочное устройство, нужен --yes")

        changes = {"lp3_freq": str(a.freq)}
        for s in a.set:
            k, _, v = s.partition("=")
            if not v:
                die("--set ждёт имя=значение, получил %r" % s)
            changes[k] = v

        lines = []
        for line in body.splitlines():
            name = line.split("=", 1)[0]
            if name in changes:
                lines.append("%s=%s" % (name, changes.pop(name)))
            else:
                lines.append(line)
        if changes:
            die("в ddrbin нет параметров: %s" % ", ".join(changes))

        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False,
                                         encoding="utf-8") as f:
            params = f.name
            f.write("\n".join(lines) + "\n")

        # Метка в строке версии блоба: её печатает загрузчик в UART, и сразу
        # видно, наш ли ddrbin работает. Максимум 17 знаков.
        ddrbin_tool(params, work, "--ver_edit=LP3-%d" % a.freq)
        os.unlink(params)

        patched = bytearray(open(work, "rb").read())
    finally:
        os.unlink(work)

    if len(patched) != len(region):
        die("ddrbin_tool изменил размер области, это не то, чего мы ждали")

    # Заплатка ложится только в первую копию - её и пересчитываем, потом
    # накрываем ею вторую целиком.
    first = cps[0]
    rehash(patched, first)
    span = used_sectors(patched, first) * SEC
    for c in cps[1:]:
        patched[c:c + span] = patched[first:first + span]

    print("после правки:")
    ok = True
    for c in cps:
        bad = check(patched, c)
        ok &= not bad
        print("   копия в секторе %d: %s"
              % (IDB_SECTOR + c // SEC, "хеши сходятся" if not bad
                 else "НЕ СХОДЯТСЯ: " + ", ".join(bad)))
    if not ok:
        die("хеши не сошлись, ничего не записываю")

    if not a.no_backup:
        bak = a.target.rstrip("/").replace("/", "_") + ".idbloader.bak" \
              if is_dev else a.target + ".idbloader.bak"
        bak = os.path.join(os.path.dirname(os.path.abspath(a.target)) if not is_dev else ".",
                           os.path.basename(bak))
        with open(bak, "wb") as f:
            f.write(region)
        print("прежняя область сохранена: %s" % bak)
        print("вернуть как было: dd if=%s of=%s bs=512 seek=%d conv=notrunc"
              % (bak, a.target, off // SEC))

    with open(a.target, "r+b") as f:
        f.seek(off)
        f.write(patched)
        f.flush()
        os.fsync(f.fileno())
    print("записано: lp3_freq=%s -> %d, метка версии LP3-%d" % (cur, a.freq, a.freq))
    print()
    print("Проверять память, а не факт загрузки:")
    print("  u-boot:  mtest                       (окно 256..768 МиБ)")
    print("  ядро:    memtest=4 в extlinux.conf   (весь свободный объём)")
    print("  Android: swapoff /dev/block/zram0 && stressapptest -s 1200 -M 1200 -m 4 -W")
    print("           на прогретом устройстве, иначе первый проход пройдёт вчистую")


if __name__ == "__main__":
    main()
