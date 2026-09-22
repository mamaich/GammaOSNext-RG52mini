#!/bin/bash
# Загрузка apk microG. В репозитории их нет: GmsCore весит 103 МБ, а это и
# тяжело, и всё равно не проходит через Contents API, которым мы обновляем
# файлы. Версии и контрольные суммы зафиксированы здесь, так что сборка
# воспроизводима.
#
# Какие именно apk брать, сказано в примечаниях к выпуску microG: для
# кастомных прошивок - обычные com.google.android.gms и com.android.vending,
# вариант -hw предназначен для устройств Huawei.
#
#     ./fetch.sh
set -euo pipefail

cd "$(dirname "$0")"

REL=v0.3.16.252432
declare -A WANT=(
  ["com.google.android.gms-252432032.apk"]="169a53df557e6577322e7cc8aa3389cb82b3d6408dd162433cc94f1d084a73d4"
  ["com.android.vending-84022632.apk"]="638f712d267bb9bc57311acbc49e769932bdea9f7fdda26a6ea98b921e632916"
)

for f in "${!WANT[@]}"; do
    if [ -f "$f" ] && echo "${WANT[$f]}  $f" | sha256sum -c --status; then
        echo "уже на месте: $f"
        continue
    fi
    echo "качаю: $f"
    gh release download "$REL" -R microg/GmsCore -p "$f" --clobber
    echo "${WANT[$f]}  $f" | sha256sum -c
done

echo
echo "Подпись проверяется самой системой: ComputerEngine.isMicrogSigned требует"
echo "точного совпадения с зашитым в дерево ключом microG, иначе подмена"
echo "подписи молча не сработает."
