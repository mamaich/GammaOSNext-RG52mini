#!/system/bin/sh
# Перенос папок и платформ dArkOS в уже установленную базу Daijishō.
#
# Исходная база Daijishō (/system/etc/daijisho.tar.zst) распаковывается только при
# первой установке, и система, обновлённая по воздуху, папок-синонимов и платформ
# dArkOS (17.10.2026, doc/rg52mini/02-план.md, «Daijishō: папки и платформы dArkOS»)
# не получала бы. Скрипт добавляет их в установленную базу тем же SQL, из которого
# собрана исходная (device/rg52mini/tools/daijisho, build.sh кладёт его в
# device/rg52mini/daijisho/): недостающие пути у прежних платформ и платформы, которых
# в базе нет (по unique_id), со своими эмуляторами; номера записей раздаёт сама база -
# у пользователя могут быть свои платформы. Обои новых платформ берутся из того же
# архива. Свои правки пользователя (пути, эмуляторы по умолчанию, скрытые платформы)
# не трогаются. Игры в новых папках появятся после синхронизации в Daijishō.
#
# Один раз на установку (persist.rg52.daijisho_rev): на загрузке и по окончании
# setup.sh (rg52-daijisho.rc). На новой установке база уже из нового архива, и скрипт
# ничего не добавляет. База в режиме WAL, sqlite3 пишет в неё при работающем
# Daijishō; если что-то добавилось, Daijishō перезапускается, чтобы перечитать базу.
#
# Проверка без устройства-«жертвы»: RG52_DJ_DIR=<каталог с databases/ и files/> -
# тогда ни отметки, ни перезапуска, ни restorecon.
#
# Вывод - в logcat (тег rg52-daijisho), по-английски.

TAG=rg52-daijisho
# 2 - платформа Nintendo 3DS с azahar-nano (v1.14): SQL тот же, добавляется только её не было.
REV=2
PKG=com.magneticchen.daijishou
DIR=${RG52_DJ_DIR:-/data/data/$PKG}
DB=$DIR/databases/Daijishou.db
ETC=${RG52_DJ_ETC:-/system/etc/rg52-daijisho}
ARCH=${RG52_DJ_ARCH:-/system/etc/daijisho.tar.zst}
WP=data/data/$PKG/files/platform_wallpapers

say() { log -t $TAG "$*" 2>/dev/null; echo "$*"; }
mark() { [ -n "$RG52_DJ_DIR" ] || setprop persist.rg52.daijisho_rev $REV; }

if [ -z "$RG52_DJ_DIR" ]; then
    [ "$(getprop persist.rg52.daijisho_rev)" = $REV ] && exit 0
    [ -d /data/setupcompleted ] || { say "setup is not finished, will retry"; exit 0; }
fi
[ -f "$DB" ] || { say "no $DB, nothing to migrate"; mark; exit 0; }

q() { sqlite3 "$DB" "$@"; }
sig() { q "select count(*) || '/' || (select count(*) from PlayerEntity) || '/' || sum(json_array_length(items_sync_tree_uri_list)) from PlatformEntity"; }
had=" $(q "select unique_id from PlatformEntity" | tr '\n' ' ') "
before=$(sig)
q < $ETC/aliases.sql && q < $ETC/platforms.sql || { say "sqlite3 failed, will retry"; exit 1; }
after=$(sig)
say "platforms/players/paths: $before -> $after"

# обои платформ, которых до переноса не было: <unique_id> <номер обоев в архиве>
tmp=/data/local/tmp/rg52-daijisho.$$
rm -rf $tmp; mkdir -p $tmp
need=""
while read uid base; do
    case "$had" in *" $uid "*) continue ;; esac
    id=$(q "select id from PlatformEntity where unique_id = '$uid'")
    [ -n "$id" ] || continue
    need="$need $uid:$id:$base"
done < $ETC/walls.txt
if [ -n "$need" ]; then
    names=""
    for n in $need; do names="$names $WP/${n##*:}.png"; done
    zstd -dc $ARCH | tar -xf - -C $tmp $names 2>/dev/null
    owner=$(stat -c %u:%g "$DIR")
    mkdir -p "$DIR/files/platform_wallpapers"
    for n in $need; do
        base=${n##*:}; id=${n#*:}; id=${id%%:*}
        f="$DIR/files/platform_wallpapers/$id.png"
        [ -f "$f" ] && continue
        cp "$tmp/$WP/$base.png" "$f" && chown "$owner" "$f" && chmod 600 "$f" \
            || say "no wallpaper for ${n%%:*}"
    done
    [ -n "$RG52_DJ_DIR" ] || restorecon -R "$DIR/files/platform_wallpapers"
fi
rm -rf $tmp

if [ "$before" != "$after" ] && [ -z "$RG52_DJ_DIR" ]; then
    say "database changed, restarting Daijisho"
    am force-stop $PKG
fi
mark
