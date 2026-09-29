#!/usr/bin/env python3
"""Загрузочная анимация GammaOS с кадром в размер экрана.

В vendor/lineage/bootanimation/bootanimation.tar лежит кадр 2880x2880, а
desc.txt велит рисовать его квадратом 480x480. На экране RG52 Mini это и есть
480x480 точек, но в память GPU кадр загружается целиком - 32 МиБ - и
выбирается с уменьшением в шесть раз без мип-уровней на каждом кадре. Кадров
при удержании анимации до лаунчера 60 в секунду (BootAnimation.cpp), и всё это
время на единственном ядре Mali-G52 рядом запускается Daijisho.

Уменьшаем заранее: цвет, который видно на экране поверх чёрного фона,
усредняется по блокам 6x6 в линейной яркости (так линии выходят ровными, а
не рваными, как при выборке GPU) и сохраняется непрозрачным кадром 480x480.
На вид анимация та же, только без лесенки на линиях.

Запуск из корня дерева:
    python3 device/rg52mini/tools/bootanim-480.py device/rg52mini/bootanimation.zip
Нужен Pillow (apt install python3-pil).
"""
import io
import sys
import tarfile
import zipfile

from PIL import Image

TAR = "vendor/lineage/bootanimation/bootanimation.tar"
DESC = "vendor/lineage/bootanimation/desc.txt"
FRAME = "part0/000000001.png"


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def linear_to_srgb(c):
    c = min(max(c, 0.0), 1.0)
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def main(out):
    with open(DESC) as f:
        desc = f.read()
    # Первая строка desc.txt: ширина, высота, частота кадров.
    width, height = (int(v) for v in desc.split()[:2])

    with tarfile.open(TAR) as tar:
        src = Image.open(io.BytesIO(tar.extractfile(FRAME).read())).convert("RGBA")
    if src.width % width or src.height % height or src.width // width != src.height // height:
        sys.exit(f"{FRAME}: {src.size} не делится на {width}x{height}")
    k = src.width // width

    # Что видно на экране: шейдер умножает цвет на альфу, смешивание
    # (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA) - ещё раз, фон очищен в чёрный.
    # Переводим в линейную яркость таблицей: значений всего 256 на канал.
    lin = [srgb_to_linear(i / 255) for i in range(256)]
    px = src.load()
    acc = [[0.0, 0.0, 0.0] for _ in range(width * height)]
    for y in range(src.height):
        row = (y // k) * width
        for x in range(src.width):
            r, g, b, a = px[x, y]
            aa = (a / 255) ** 2
            cell = acc[row + x // k]
            cell[0] += lin[r] * aa
            cell[1] += lin[g] * aa
            cell[2] += lin[b] * aa

    n = k * k
    dst = Image.new("RGB", (width, height))
    dst.putdata([tuple(round(linear_to_srgb(v / n) * 255) for v in cell) for cell in acc])
    png = io.BytesIO()
    dst.save(png, "PNG", optimize=True)

    # BootAnimation читает кадры только несжатыми (ZIP_STORED).
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        z.writestr("desc.txt", desc)
        z.writestr(FRAME, png.getvalue())
    print(f"{out}: {FRAME} {src.size} -> {dst.size}, {len(png.getvalue())} байт")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
