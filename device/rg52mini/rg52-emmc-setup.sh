#!/system/bin/sh
# Настройка EmuELEC во внутренней памяти из GammaOS Toolbox.
#
# Toolbox при включении «Allow reboot to eMMC» предлагает подготовить EmuELEC
# на eMMC к работе рядом с картой GammaOS и, если пользователь согласен,
# выставляет sys.rg52.emmc_setup=1. Сам скрипт настройки
# (device/rg52mini/tools/emmc-restore/restore-emmc.sh, здесь
# /system/bin/rg52-restore-emmc.sh) монтирует разделы eMMC и потому требует
# root, а Toolbox работает от system - отсюда служба init, см.
# rg52-emmc-setup.rc.
#
# Ход и итог Toolbox узнаёт по sys.rg52.emmc_setup.state (running, затем
# done:<код выхода>) и показывает конец журнала. Журнал - по-английски, как и
# весь вывод скрипта.

LOG=/data/system/rg52-emmc-setup.log

setprop sys.rg52.emmc_setup.state running
/system/bin/sh /system/bin/rg52-restore-emmc.sh > "$LOG" 2>&1
rc=$?
chown system:system "$LOG"
chmod 0640 "$LOG"
log -t rg52-emmc-setup "restore-emmc.sh exit $rc"
setprop sys.rg52.emmc_setup.state "done:$rc"
