#!/usr/bin/env python3
# Обои новых платформ: набор BB-1 Dark (BrunoBelmonte) из TapiocaFox/Daijishou -
# из него же обои 15 платформ, с которыми GammaOS пришла (совпадают с набором после
# уменьшения до 1080x720). Скачивает нужные картинки и уменьшает так же.
#   walls.py <walls.json от platforms.py> <каталог для <id>.png>
import io
import json
import os
import sys
import urllib.parse
import urllib.request

from PIL import Image

PACK = "https://raw.githubusercontent.com/TapiocaFox/Daijishou/main/themes/platform_wallpapers_packs/BB1-Dark/"

m = json.load(open(sys.argv[1]))
os.makedirs(sys.argv[2], exist_ok=True)
for pid, name in sorted(m.items(), key=lambda kv: int(kv[0])):
    data = urllib.request.urlopen(PACK + urllib.parse.quote(name + ".png"), timeout=120).read()
    im = Image.open(io.BytesIO(data)).convert("RGBA").resize((1080, 720), Image.LANCZOS)
    im.save(os.path.join(sys.argv[2], pid + ".png"), optimize=True)
    print(pid, name)
