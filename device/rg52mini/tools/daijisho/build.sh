#!/bin/bash
# Исходная база Daijishō gammaos/daijisho/daijisho.tar.zst (новые установки - setup.sh
# распаковывает её один раз) и SQL переноса для уже установленных систем:
#   - папки-синонимы dArkOS/EmuELEC в путях поиска РОМов (aliases.py);
#   - новые платформы для папок dArkOS/EmuELEC (platforms.py, описания в platforms/);
#   - их обои (walls.py, нужен python3-pil и доступ к GitHub);
#   - device/rg52mini/daijisho/: aliases.sql, platforms.sql и walls.txt для
#     rg52-daijisho.sh (перенос на системе, обновлённой по воздуху).
# Повторный запуск ничего не меняет: архив переписывается, только если база в нём
# изменилась. Разбор - в doc/rg52mini/02-план.md, «Daijishō: папки и платформы dArkOS».
#   build.sh            рабочий каталог - временный, удаляется
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
T=$(cd "$D/../../../.." && pwd)
A=$T/gammaos/daijisho/daijisho.tar.zst
M=$T/device/rg52mini/daijisho
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
P=data/data/com.magneticchen.daijishou/databases
cd "$W"; mkdir x walls
zstd -dc "$A" > orig.tar
tar xf orig.tar -C x $P/Daijishou.db
q() { sqlite3 x/$P/Daijishou.db "$@"; }
[ "$(q 'pragma integrity_check')" = ok ]
before=$(q "select * from PlatformEntity; select * from PlayerEntity" | md5sum)
python3 -I "$D/aliases.py" > aliases.sql
q < aliases.sql
mkdir -p "$M"
python3 -I "$D/platforms.py" x/$P/Daijishou.db "$D/platforms" walls.json \
    "$M/platforms.sql" "$M/walls.txt" > platforms.sql
cp aliases.sql "$M/aliases.sql"
grep -- '^-- [0-9]' platforms.sql || true
q < platforms.sql
q "pragma wal_checkpoint(TRUNCATE)" >/dev/null
[ "$(q 'pragma integrity_check')" = ok ]
echo "platforms: $(q "select shortname || (case when is_visible then '' else '(hidden)' end) from PlatformEntity order by id" | tr '\n' ' ')"
if [ "$(q "select * from PlatformEntity; select * from PlayerEntity" | md5sum)" = "$before" ]; then
    echo "archive: no changes"
else
    [ -f walls.json ] && python3 -I "$D/walls.py" walls.json walls
    python3 -I "$D/retar.py" orig.tar x/$P/Daijishou.db new.tar walls
    zstd -19 -T0 -q -f new.tar -o new.tar.zst
    zstd -t new.tar.zst
    mv new.tar.zst "$A"
    ls -la "$A"
fi
ls -la "$M"
