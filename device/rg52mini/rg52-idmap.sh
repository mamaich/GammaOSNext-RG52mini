#!/system/bin/sh
# RG52 Mini: сбросить кэш оверлеев ресурсов после обновления системы.
#
# Оверлеи ресурсов (RRO) применяются через файлы соответствия в
# /data/resource-cache (*@idmap). Для оверлеев самой платформы (цель - пакет
# android, у нас это framework-res__..._auto_generated_rro_product.apk из
# device/rg52mini/overlay) их создаёт zygote при предзагрузке ресурсов, от root.
# Если оверлей в образе изменился, файл устаревает и должен быть пересоздан.
#
# В обычной загрузке Android так и происходит. В оболочке nano загрузка урезана
# (sys.gammaos.minimal_boot=1): zygote ресурсы заранее не грузит, и idmap2
# запускают уже system_server и приложения - без прав root. Создать новый файл
# в каталоге system_server может (каталог system:system 0771), а переписать
# старый, принадлежащий root, - нет:
#
#     idmap2: failed to open idmap path /data/resource-cache/...@idmap
#     idmap2: uid 10079 does not have write access to ...
#
# Оверлей с устаревшим файлом система молча пропускает. Так после обновления,
# поставленного из nano, пропадали все наши значения framework-res разом:
# гнездо наушников, одна громкость, местоположение без microG, сон без нажатий, -
# и возвращались только после первой загрузки в обычный Android. Найдено
# 13.11.2026 на t44: config_attentiveTimeout читался как -1.
#
# Поэтому при первой загрузке после смены образа системы файлы соответствия
# удаляются до старта zygote, и их заново создаёт тот, кто первым загрузит
# ресурсы: zygote в обычной загрузке, system_server в nano. Это только кэш:
# на чистой установке его нет вовсе. Фабричные оверлеи тем (*.frro) не трогаем.
#
# Проверка: cmd overlay lookup android android:integer/config_attentiveTimeout
# (ожидаем 7200000), журнал - logcat -s rg52-idmap.

D=/data/resource-cache
S=/data/system/rg52-idmap-stamp
NEW="$(getprop ro.build.date.utc) $(getprop ro.build.fingerprint)"

[ -d "$D" ] || exit 0
[ "$(cat "$S" 2>/dev/null)" = "$NEW" ] && exit 0

n=0
for f in "$D"/*@idmap; do
    [ -e "$f" ] || continue
    rm -f "$f" && n=$((n + 1))
done
echo "$NEW" > "$S"
chmod 0644 "$S"
log -t rg52-idmap "system image changed: $n overlay idmap file(s) removed, they will be rebuilt"
