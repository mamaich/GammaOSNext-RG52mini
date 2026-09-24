#!/usr/bin/env python3
"""Сводка окон обучения DDR из журнала загрузки, снятого с UART.

    ddr-margins.py <журнал> [<журнал-для-сравнения>]

Зачем. Менять частоту памяти можно, а понять, осталось ли после этого запас,
по факту загрузки нельзя: обучение либо сошлось, либо нет, и «сошлось с нулевым
запасом» выглядит точно так же, как «сошлось хорошо». Разница видна только в
окнах, которые ddrbin печатает по каждой линии на финальной частоте - строки
`range:` в блоках `rdtrn`/`wrtrn`.

Отдельный диагностический блоб eyescan из rkbin для этого не нужен: обычный
загрузчик печатает всё сам, достаточно снять журнал.

Как читать. Окна измеряются в шагах линии задержки. При росте частоты период
укорачивается пропорционально, поэтому и окна должны сузиться примерно во
столько же раз - это нормально. Тревожно, когда они проседают заметно сильнее:
значит запас съеден не периодом, а качеством сигнала.
"""

import io
import re
import sys


def parse(path):
    t = io.open(path, encoding="utf-8", errors="replace").read().replace("\r\n", "\n")

    freq = None
    m = re.search(r"change to:\s*(\d+)MHz\(final freq\)", t)
    if m:
        freq = int(m.group(1))

    ver = None
    m = re.search(r"DDR [0-9a-f]+ \S+ (.{1,20}?),fwver", t)
    if m:
        ver = m.group(1).strip()

    # Блоки range: идут по одному на каждый rdtrn/wrtrn каждого cs. Значения
    # могут занимать несколько строк, поэтому забираем всё до следующего
    # ключевого слова.
    blocks = re.findall(r"range:(.*?)(?=\n\s*(?:cs |rdtrn|wrtrn|out\b|min|mid|max))",
                        t, re.S)
    names = ["cs0 чтение", "cs0 запись", "cs1 чтение", "cs1 запись"]
    out = []
    for name, b in zip(names, blocks):
        vals = [int(v, 16) for v in re.findall(r"0x([0-9a-f]+)", b)]
        if vals:
            out.append((name, vals))
    return freq, ver, out


def show(path):
    freq, ver, blocks = parse(path)
    print("%s" % path)
    print("   частота: %s   версия блоба: %s" % (
        ("%d МГц" % freq) if freq else "не найдена", ver or "?"))
    if not blocks:
        print("   окон обучения в журнале нет — обучение до финальной частоты не дошло")
    for name, v in blocks:
        print("   %-12s линий %2d   мин %3d   средн %5.1f   макс %3d"
              % (name, len(v), min(v), sum(v) / len(v), max(v)))
    return freq, blocks


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)

    f1, b1 = show(sys.argv[1])
    if len(sys.argv) < 3:
        return

    print()
    f2, b2 = show(sys.argv[2])
    if not (f1 and f2 and b1 and b2):
        return

    print()
    # Период обратно пропорционален частоте: при росте частоты окна вправе
    # сузиться во столько же раз, всё что хуже - потеря запаса.
    expect = f1 / f2
    print("== сравнение (ожидаемое сужение по периоду: до %.0f%%)" % (expect * 100))
    for (n1, v1), (n2, v2) in zip(b1, b2):
        a1 = sum(v1) / len(v1)
        a2 = sum(v2) / len(v2)
        got = a2 / a1
        verdict = "запас в норме" if got >= expect * 0.92 else "ЗАПАС ПРОСЕЛ"
        print("   %-12s %5.1f -> %5.1f  = %3.0f%%   %s"
              % (n1, a1, a2, got * 100, verdict))


if __name__ == "__main__":
    main()
