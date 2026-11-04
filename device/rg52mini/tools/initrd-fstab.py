#!/usr/bin/env python3
"""initrd-fstab.py <initrd.zst> <out.zst>

Mounts /cache in first-stage init: adds first_stage_mount to the /cache line of
fstab.rk30board in the initrd (the root copy and first_stage_ramdisk/), so that
first-stage init finds the `adb remount` overlays in /cache/overlay and mounts
them over /system and /vendor on every boot, as on devices whose overlay lives
on a scratch partition. /metadata is already mounted the same way.

The newc cpio is rewritten entry by entry without unpacking it: every other
file keeps its bytes, owner, mode and inode as they are. Idempotent: a line that
already has first_stage_mount is left alone.
"""
import subprocess
import sys

FSTABS = {"fstab.rk30board", "first_stage_ramdisk/fstab.rk30board"}
HDR = 110  # newc header: magic + 13 fields of 8 hex digits


def pad4(n):
    return (4 - n % 4) % 4


def fix_fstab(text):
    out, changed = [], 0
    for line in text.split("\n"):
        f = line.split()
        if len(f) >= 5 and not line.lstrip().startswith("#") and f[1] == "/cache" \
                and "first_stage_mount" not in f[4].split(","):
            # the flags are the last field: append to it, keep the column layout
            i = line.rstrip().rfind(f[4])
            line = line[:i] + f[4] + ",first_stage_mount" + line[i + len(f[4]):]
            changed += 1
        out.append(line)
    return "\n".join(out), changed


def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = subprocess.run(["zstd", "-dc", src], check=True, capture_output=True).stdout
    pos, out, patched = 0, bytearray(), []
    while True:
        h = data[pos:pos + HDR]
        if h[:6] not in (b"070701", b"070702"):
            sys.exit("initrd-fstab: not a newc cpio at offset %d" % pos)
        fields = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
        filesize, namesize = fields[6], fields[11]
        name_end = pos + HDR + namesize
        name = data[pos + HDR:name_end - 1].decode()
        body_start = name_end + pad4(HDR + namesize)
        body = data[body_start:body_start + filesize]
        nxt = body_start + filesize + pad4(filesize)
        if name in FSTABS:
            text, n = fix_fstab(body.decode())
            if n:
                body = text.encode()
                fields[6] = len(body)
                patched.append(name)
        hdr = h[:6] + b"".join(b"%08X" % v for v in fields)
        out += hdr + data[pos + HDR:name_end] + b"\0" * pad4(HDR + namesize)
        out += body + b"\0" * pad4(len(body))
        if name == "TRAILER!!!":
            out += data[nxt:]  # keep the trailing padding as it was
            break
        pos = nxt
    with open(dst, "wb") as f:
        f.write(subprocess.run(["zstd", "-19", "-c"], input=bytes(out), check=True,
                               capture_output=True).stdout)
    print("initrd-fstab: /cache in first stage: %s" % (", ".join(patched) or "already set"))


if __name__ == "__main__":
    main()
