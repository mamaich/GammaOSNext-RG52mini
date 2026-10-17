#!/usr/bin/env python3
# Копирует tar Daijishō запись в запись, подменяя Daijishou.db и выбрасывая
# его -wal/-shm (журнал уже влит в базу). Порядок, владельцы, права и даты
# остальных записей не меняются. Необязательный 4-й аргумент - каталог с
# обоями <id>.png новых платформ: они добавляются вслед за последними обоями
# архива, с владельцем, правами и датой соседних.
#   retar.py <orig.tar> <new Daijishou.db> <out.tar> [<wallpapers dir>]
import copy
import io
import os
import sys
import tarfile

src, newdb, dst = sys.argv[1:4]
walls = sys.argv[4] if len(sys.argv) > 4 else None
DB = "data/data/com.magneticchen.daijishou/databases/Daijishou.db"
WP = "data/data/com.magneticchen.daijishou/files/platform_wallpapers/"
data = open(newdb, "rb").read()

with tarfile.open(src, "r:") as tin:
    members = tin.getmembers()
    last_wp = max(i for i, m in enumerate(members) if m.name.startswith(WP) and m.isfile())
    have = {m.name for m in members}
    n_in, n_out, added = len(members), 0, []
    with tarfile.open(dst, "w:", format=tin.format) as tout:
        for i, m in enumerate(members):
            if m.name in (DB + "-wal", DB + "-shm"):
                continue
            if m.name == DB:
                m.size = len(data)
                tout.addfile(m, io.BytesIO(data))
            elif m.isfile():
                tout.addfile(m, tin.extractfile(m))
            else:
                tout.addfile(m)
            n_out += 1
            if i == last_wp and walls:
                for f in sorted(os.listdir(walls), key=lambda x: int(x.split(".")[0])):
                    name = WP + f
                    assert name not in have, name
                    body = open(os.path.join(walls, f), "rb").read()
                    t = copy.copy(m)
                    t.name, t.size = name, len(body)
                    tout.addfile(t, io.BytesIO(body))
                    added.append(f)
                    n_out += 1
print("entries %d -> %d, wallpapers added: %s" % (n_in, n_out, " ".join(added)))
