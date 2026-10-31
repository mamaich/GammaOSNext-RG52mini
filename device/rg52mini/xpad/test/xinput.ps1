param([string]$Cmd = "state", [int]$Sec = 10, [int]$L = 0, [int]$R = 0)
# XInput check on the PC side: state | watch -Sec N | rumble -L 0..65535 -R 0..65535 -Sec N | pnp
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class XI {
  [StructLayout(LayoutKind.Sequential)] public struct GP { public ushort b; public byte lt; public byte rt; public short lx, ly, rx, ry; }
  [StructLayout(LayoutKind.Sequential)] public struct ST { public uint pkt; public GP gp; }
  [StructLayout(LayoutKind.Sequential)] public struct VIB { public ushort l, r; }
  [StructLayout(LayoutKind.Sequential)] public struct CAPS { public byte Type, SubType; public ushort Flags; public GP gp; public VIB vib; }
  [DllImport("xinput1_4.dll")] public static extern uint XInputGetState(uint i, out ST s);
  [DllImport("xinput1_4.dll")] public static extern uint XInputSetState(uint i, ref VIB v);
  [DllImport("xinput1_4.dll")] public static extern uint XInputGetCapabilities(uint i, uint f, out CAPS c);
}
"@
function Fmt($i, $s) { $g = $s.gp; "pad{0} pkt={1} btn=0x{2:X4} lt={3} rt={4} lx={5} ly={6} rx={7} ry={8}" -f $i, $s.pkt, $g.b, $g.lt, $g.rt, $g.lx, $g.ly, $g.rx, $g.ry }
function Pads { 0..3 | Where-Object { $s = New-Object XI+ST; [XI]::XInputGetState($_, [ref]$s) -eq 0 } }
switch ($Cmd) {
  "pnp" {
    Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_045E&PID_028E*' -or $_.FriendlyName -like '*Xbox*' } |
      Format-Table -AutoSize Status, Class, FriendlyName, InstanceId | Out-String -Width 200
  }
  "state" {
    $found = $false
    foreach ($i in 0..3) {
      $s = New-Object XI+ST
      $rc = [XI]::XInputGetState($i, [ref]$s)
      if ($rc -eq 0) {
        $found = $true; Fmt $i $s
        $c = New-Object XI+CAPS
        $rc2 = [XI]::XInputGetCapabilities($i, 0, [ref]$c)
        "  caps rc=$rc2 type=$($c.Type) subtype=$($c.SubType) flags=0x{0:X} btnmask=0x{1:X4} lt={2} rt={3} lx=0x{4:X4} vib={5}/{6}" -f $c.Flags, $c.gp.b, $c.gp.lt, $c.gp.rt, ($c.gp.lx -band 0xFFFF), $c.vib.l, $c.vib.r
      }
    }
    if (-not $found) { "no XInput controller" }
  }
  "watch" {
    $last = @{}; $end = (Get-Date).AddSeconds($Sec)
    while ((Get-Date) -lt $end) {
      foreach ($i in 0..3) {
        $s = New-Object XI+ST
        if ([XI]::XInputGetState($i, [ref]$s) -eq 0 -and $last[$i] -ne $s.pkt) {
          $last[$i] = $s.pkt; "{0:HH:mm:ss.fff} {1}" -f (Get-Date), (Fmt $i $s)
        }
      }
      Start-Sleep -Milliseconds 5
    }
  }
  "rumble" {
    $p = @(Pads)
    if ($p.Count -eq 0) { "no XInput controller"; break }
    $v = New-Object XI+VIB; $v.l = $L; $v.r = $R
    "pad$($p[0]) rumble L=$L R=$R for $Sec s: rc=" + [XI]::XInputSetState($p[0], [ref]$v)
    Start-Sleep -Seconds $Sec
    $v.l = 0; $v.r = 0; "stop: rc=" + [XI]::XInputSetState($p[0], [ref]$v)
  }
}
