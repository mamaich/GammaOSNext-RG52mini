<#
    Консоль u-boot через отладочный порт.

    В этой сборке CONFIG_BOOTDELAY=0, то есть задержки автозагрузки нет вовсе.
    Перехват всё равно возможен: Rockchip правит __abortboot() так, что проверка
    ctrlc() стоит ДО цикла задержки и выполняется даже при нулевом bootdelay.
    Но проверка одна и мгновенная, поэтому Ctrl+C должен уже лежать в приёмном
    буфере, когда загрузчик до неё доходит. Отсюда способ: сыпать Ctrl+C в порт
    непрерывно и включить устройство уже после запуска скрипта.

    Как только приглашение поймано, Ctrl+C прекращаем немедленно - иначе он
    оборвёт первую же длинную команду вроде mtest.

    Примеры:
        .\uboot-shell.ps1 -Commands "version","bdinfo"
        .\uboot-shell.ps1 -Commands "mtest 0x10000000 0x11000000 0 1" -MaxSeconds 900
        .\uboot-shell.ps1 -Commands "boot"        # отпустить устройство грузиться

    Порт занимается монопольно.
#>
param(
    [string]   $Port          = "COM4",
    [int]      $Baud          = 1500000,
    [string[]] $Commands      = @(),
    [int]      $CatchSeconds  = 120,   # сколько ждать включения питания
    [int]      $IdleMs        = 3000,  # тишина, после которой вывод считаем законченным
    [int]      $MaxSeconds    = 600,   # предел на одну команду
    [switch]   $KeepSpamming,         # не прекращать Ctrl+C (для отладки перехвата)
    [switch]   $UntilPrompt           # не обрывать команду по тишине: ждать приглашения
)

$ErrorActionPreference = "Stop"
$PROMPT = "=> "
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, "None", 8, "One"
$sp.Handshake    = "None"
$sp.DtrEnable    = $true
$sp.RtsEnable    = $true
$sp.NewLine      = "`n"
$sp.ReadTimeout  = 200
$sp.WriteTimeout = 2000

try { $sp.Open() } catch {
    Write-Output "не удалось открыть $Port : $($_.Exception.Message)"
    exit 1
}

function Read-Available {
    if ($sp.BytesToRead -gt 0) { return $sp.ReadExisting() }
    return ""
}

try {
    $sp.DiscardInBuffer()
    $ctrlC = [byte[]] @(3)

    # ------------------------------------------- уже стоим в приглашении?
    # Загрузчик ждёт в приглашении бесконечно, а порт между запусками скрипта
    # закрывается. Сыпать Ctrl+C в этом случае вредно: он оборвёт первую же
    # длинную команду. Поэтому сначала спрашиваем пустой строкой.
    $sp.WriteLine("")
    Start-Sleep -Milliseconds 600
    $probe = Read-Available
    if ($probe.Contains($PROMPT)) {
        Write-Output "приглашение уже на месте, перехват не нужен"
        $sp.DiscardInBuffer()
        $skipCatch = $true
    } else {
        $skipCatch = $false
    }

    # ---------------------------------------------------------- перехват
  if (-not $skipCatch) {
    Write-Output "ловлю приглашение u-boot на $Port, до $CatchSeconds с."
    Write-Output "ВКЛЮЧАЙТЕ ПИТАНИЕ СЕЙЧАС."
    $buf      = New-Object System.Text.StringBuilder
    $deadline = (Get-Date).AddSeconds($CatchSeconds)
    $caught   = $false
    $sawAny   = $false

    while ((Get-Date) -lt $deadline) {
        try { $sp.Write($ctrlC, 0, 1) } catch { }
        Start-Sleep -Milliseconds 25
        $chunk = Read-Available
        if ($chunk -ne "") {
            if (-not $sawAny) { Write-Output "порт ожил, идёт вывод загрузчика"; $sawAny = $true }
            [void] $buf.Append($chunk)
            if ($buf.ToString().Contains($PROMPT)) { $caught = $true; break }
        }
    }

    Write-Output "----- вывод загрузчика -----"
    Write-Output $buf.ToString()
    Write-Output "----------------------------"

    if (-not $caught) {
        if (-not $sawAny) { Write-Output "порт молчал: устройство не включалось или UART не на этом порту" }
        else { Write-Output "приглашение не поймано - загрузчик ушёл грузить систему" }
        exit 2
    }
    Write-Output "приглашение поймано, Ctrl+C прекращён"

    # Ctrl+C мог остаться в приёмном буфере устройства и оборвал бы mtest.
    # Пустая строка добирает остатки, дальше чистим свою сторону.
    if (-not $KeepSpamming) {
        Start-Sleep -Milliseconds 600
        $sp.WriteLine("")
        Start-Sleep -Milliseconds 400
        [void] (Read-Available)
        $sp.DiscardInBuffer()
    }
  }

    # ---------------------------------------------------------- команды
    foreach ($cmd in $Commands) {
        Write-Output ""
        Write-Output "===== $cmd"
        $started = Get-Date
        $sp.WriteLine($cmd)
        $out      = New-Object System.Text.StringBuilder
        $lastData = Get-Date
        $hard     = (Get-Date).AddSeconds($MaxSeconds)
        while ((Get-Date) -lt $hard) {
            $chunk = Read-Available
            if ($chunk -ne "") {
                [void] $out.Append($chunk)
                $lastData = Get-Date
                # Приглашение в самом конце - команда отработала, ждать нечего.
                $t = $out.ToString()
                if ($t.EndsWith($PROMPT)) { break }
            } else {
                # mtest за время работы не печатает ничего, поэтому обрыв по
                # тишине съел бы результат. -UntilPrompt отключает его совсем.
                if (-not $UntilPrompt -and
                    ((Get-Date) - $lastData).TotalMilliseconds -gt $IdleMs) { break }
                Start-Sleep -Milliseconds 100
            }
        }
        Write-Output $out.ToString()
        Write-Output ("[заняло {0:N1} с]" -f ((Get-Date) - $started).TotalSeconds)
    }
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
}
