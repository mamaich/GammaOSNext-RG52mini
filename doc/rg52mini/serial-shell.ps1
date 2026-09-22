<#
    Оболочка устройства через отладочный порт.

    Нужна ровно для того случая, когда adb недоступен: экран чёрный, система
    жива, а посмотреть состояние нечем. В образе с 2026-09-22 служба console
    поднимается после загрузки и отдаёт на ttyFIQ0 интерактивный shell
    (см. device/rg52mini/rg52-console.rc).

    Примеры:
        .\serial-shell.ps1 -Command "getprop sys.boot_completed"
        .\serial-shell.ps1 -Command "dumpsys window | grep mCurrentFocus"
        .\serial-shell.ps1 -Listen -Seconds 30        # просто слушать порт

    Порт занимается монопольно, так что serial-capture.ps1 в это время
    запускать не нужно.
#>
param(
    [string] $Port    = "COM4",
    [int]    $Baud    = 1500000,
    [string] $Command = "",
    [switch] $Listen,
    [int]    $Seconds = 8
)

$ErrorActionPreference = "Stop"

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, "None", 8, "One"
$sp.Handshake    = "None"
$sp.DtrEnable    = $true
$sp.RtsEnable    = $true
$sp.NewLine      = "`n"
$sp.ReadTimeout  = 500
$sp.WriteTimeout = 2000

try {
    $sp.Open()
} catch {
    Write-Output "не удалось открыть $Port : $($_.Exception.Message)"
    exit 1
}

try {
    $sp.DiscardInBuffer()

    if (-not $Listen -and $Command -ne "") {
        # Пустая строка будит приглашение, затем сама команда. Маркер в конце
        # даёт понять, что вывод закончился, не дожидаясь всего таймаута.
        $sp.WriteLine("")
        Start-Sleep -Milliseconds 150
        # Маркер собирается из двух кусков: оболочка эхом возвращает набранную
        # строку, и цельный маркер в этом эхе совпал бы с искомым - чтение
        # обрывалось бы до того, как придёт сам вывод. В эхе видно
        # __RG52_DO""NE__, а в выводе - склеенный __RG52_DONE__.
        $sp.WriteLine("$Command; echo __RG52_DO`"`"NE__")
    }

    $deadline = (Get-Date).AddSeconds($Seconds)
    $buf = New-Object System.Text.StringBuilder

    while ((Get-Date) -lt $deadline) {
        try {
            $chunk = $sp.ReadExisting()
        } catch {
            $chunk = ""
        }
        if ($chunk.Length -gt 0) {
            [void]$buf.Append($chunk)
            if (-not $Listen -and $buf.ToString() -match "__RG52_DONE__") { break }
        } else {
            Start-Sleep -Milliseconds 100
        }
    }

    $text = $buf.ToString() -replace "`r`n", "`n"
    # Убираем эхо самой команды и маркер, чтобы остался только полезный вывод.
    # Убираем маркер, эхо команды и сообщения ядра - они сыплются в ту же консоль.
    $text = $text -replace "(?m)^.*__RG52_DO.*$", ""
    $text = $text -replace "(?m)^\[\s*\d+\.\d+\].*$", ""
    $text = ($text -split "`n" | Where-Object { $_.Trim() -ne "" }) -join "`n"
    $text.Trim()
} finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}

