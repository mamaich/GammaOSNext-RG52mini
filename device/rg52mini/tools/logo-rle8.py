#!/usr/bin/env python3
# Переводит одноцветный загрузочный логотип (24 бита) в 8-битный BMP с RLE8 и
# палитрой из 16 ступеней между фоном и цветом рисунка.
#
#   logo-rle8.py исходный.bmp logo.bmp [ступеней]
#
# Зачем. u-boot читает файлы с раздела FAT медленно, и logo.bmp на 2,7 МБ
# стоил 1,4-1,5 с загрузки. Логотип одноцветный: 96 % пикселей - ровно фон и
# цвет рисунка, остальное - сглаживание краёв и шум сжатия исходника. Каждый
# пиксель проецируется на отрезок фон -> цвет и ставится на ближайшую из
# ступеней, так края остаются сглаженными. Файл выходит около 22 КБ, читается
# за 15 мс, отличие от исходника на краях не больше 11 из 255.
#
# Декодер u-boot Rockchip (drivers/video/drm/libnsbmp.c) понимает RLE8 с
# палитрой; в том же формате сделаны картинки зарядки battery_*.bmp. Строки
# идут снизу вверх, как в исходнике, поэтому ориентация не меняется.
import struct, sys
from PIL import Image

src = Image.open(sys.argv[1]).convert("RGB")
out_path = sys.argv[2]
N = int(sys.argv[3]) if len(sys.argv) > 3 else 16
cols = sorted(src.getcolors(1 << 24), reverse=True)
BG, FG = cols[0][1], cols[1][1]
W, H = src.size
pal = [tuple(round(BG[c] + (FG[c] - BG[c]) * i / (N - 1)) for c in range(3)) for i in range(N)]
d = [FG[c] - BG[c] for c in range(3)]
dd = sum(x * x for x in d)
px = src.load()
data = bytearray()
for y in range(H - 1, -1, -1):
    row = []
    for x in range(W):
        p = px[x, y]
        t = sum((p[c] - BG[c]) * d[c] for c in range(3)) / dd
        row.append(min(N - 1, max(0, round(t * (N - 1)))))
    x = 0
    while x < W:
        v = row[x]
        n = 1
        while x + n < W and row[x + n] == v and n < 255:
            n += 1
        data += bytes((n, v))
        x += n
    data += b"\x00\x00"          # конец строки
data[-2:] = b"\x00\x01"          # конец картинки
palette = b"".join(bytes((b, g, r, 0)) for (r, g, b) in pal)
off = 14 + 40 + len(palette)
hdr = b"BM" + struct.pack("<IHHI", off + len(data), 0, 0, off)
dib = struct.pack("<IiiHHIIiiII", 40, W, H, 1, 8, 1, len(data), 3780, 3780, N, N)
open(out_path, "wb").write(hdr + dib + palette + data)
print("%s: %dx%d, фон #%02x%02x%02x, рисунок #%02x%02x%02x, %d ступеней, %d байт" %
      (out_path, W, H, *BG, *FG, N, off + len(data)))
