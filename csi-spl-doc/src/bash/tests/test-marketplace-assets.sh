#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: Verify marketplace branding assets (Spec 156 GAP-08).
#          Checks PNG transparency (an alpha channel, and real holes on the
#          logos), exact pixel dimensions, and an sRGB profile.
#          MKT_ASSET_DIR overrides the asset directory (red control only).
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)
ASSET_DIR=${MKT_ASSET_DIR:-$REPO_ROOT/csi-spl-doc/doc/marketplace/assets}

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

WORK=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/pngfacts.py" <<'PY'
import struct
import sys
import zlib


def predict(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def unfilter(raw, width, height, bpp):
    stride = width * bpp
    rows = []
    i = 0
    prev = bytearray(stride)
    need = height * (stride + 1)
    if len(raw) < need:
        raise ValueError(f"short image data {len(raw)} < {need}")
    for _ in range(height):
        filt = raw[i]
        i += 1
        row = bytearray(raw[i:i + stride])
        i += stride
        if filt == 0:
            pass
        elif filt == 1:
            for x in range(stride):
                left = row[x - bpp] if x >= bpp else 0
                row[x] = (row[x] + left) & 255
        elif filt == 2:
            for x in range(stride):
                row[x] = (row[x] + prev[x]) & 255
        elif filt == 3:
            for x in range(stride):
                left = row[x - bpp] if x >= bpp else 0
                row[x] = (row[x] + ((left + prev[x]) // 2)) & 255
        elif filt == 4:
            for x in range(stride):
                left = row[x - bpp] if x >= bpp else 0
                up = prev[x]
                ul = prev[x - bpp] if x >= bpp else 0
                row[x] = (row[x] + predict(left, up, ul)) & 255
        else:
            raise ValueError(f"bad filter {filt}")
        prev = row
        rows.append(row)
    return rows


def chunks(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a png")
    i = 8
    while i + 8 <= len(data):
        length = struct.unpack(">I", data[i:i + 4])[0]
        kind = data[i + 4:i + 8]
        start = i + 8
        end = start + length
        if end + 4 > len(data):
            raise ValueError("truncated chunk")
        yield kind, data[start:end]
        i = end + 4
        if kind == b"IEND":
            return
    raise ValueError("missing IEND")


def facts(path):
    data = open(path, "rb").read()
    ihdr = None
    srgb = False
    iccp = b""
    idat = b""
    for kind, body in chunks(data):
        if kind == b"IHDR":
            if len(body) != 13:
                raise ValueError("bad IHDR")
            w, h, bit, color, comp, filt, inter = struct.unpack(">IIBBBBB", body)
            ihdr = (w, h, bit, color, comp, filt, inter)
        elif kind == b"sRGB":
            srgb = True
        elif kind == b"iCCP":
            iccp += body
        elif kind == b"IDAT":
            idat += body
    if ihdr is None:
        raise ValueError("no IHDR")
    w, h, bit, color, comp, filt, inter = ihdr
    if bit != 8 or comp != 0 or filt != 0 or inter != 0:
        raise ValueError(f"want 8-bit non-interlaced, got bit={bit} comp={comp} filt={filt} inter={inter}")
    if color != 6:
        raise ValueError(f"want color type 6 (RGBA), got {color}")
    if b"sRGB" in iccp or b"IEC61966-2.1" in iccp:
        srgb = True
    raw = zlib.decompress(idat)
    rows = unfilter(raw, w, h, 4)
    zeros = 0
    opaque = 0
    for row in rows:
        for x in range(3, len(row), 4):
            if row[x] == 0:
                zeros += 1
            elif row[x] == 255:
                opaque += 1
    return w, h, color, 1 if srgb else 0, zeros, opaque


def main():
    try:
        w, h, color, srgb, zeros, opaque = facts(sys.argv[1])
    except (OSError, ValueError, zlib.error) as exc:
        print(f"ERR {exc}", file=sys.stderr)
        return 1
    print(f"{w} {h} {color} {srgb} {zeros} {opaque}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY

check_logo_alpha() {
  local name="$1" zeros="$2" opaque="$3"
  if [[ "$zeros" -gt 0 && "$opaque" -gt 0 ]]; then
    pass "$name has transparent and opaque pixels"
  else
    fail "$name has transparent and opaque pixels" "transparent=$zeros opaque=$opaque"
  fi
}

check_asset() {
  local name="$1" want_w="$2" want_h="$3" kind="$4"
  local path="$ASSET_DIR/$name" line w h color srgb zeros opaque err
  if [[ ! -f "$path" ]]; then
    fail "$name exists" "missing"
    return 0
  fi
  if ! line=$(python3 "$WORK/pngfacts.py" "$path" 2>"$WORK/err"); then
    err=$(tr '\n' ' ' <"$WORK/err")
    fail "$name is an 8-bit non-interlaced RGBA PNG" "$err"
    return 0
  fi
  read -r w h color srgb zeros opaque <<<"$line"
  if [[ "$w" == "$want_w" && "$h" == "$want_h" ]]; then
    pass "$name is ${want_w}x${want_h}"
  else
    fail "$name is ${want_w}x${want_h}" "got ${w}x${h}"
  fi
  if [[ "$color" == "6" ]]; then
    pass "$name has an alpha channel"
  else
    fail "$name has an alpha channel" "color type $color"
  fi
  if [[ "$srgb" == "1" ]]; then
    pass "$name names sRGB"
  else
    fail "$name names sRGB" "no sRGB chunk and no sRGB profile"
  fi
  if [[ "$kind" == "logo" ]]; then
    check_logo_alpha "$name" "$zeros" "$opaque"
  fi
}

check_asset logo_128x128.png 128 128 logo
check_asset logo_256x256.png 256 256 logo
check_asset screenshot_01.png 1280 800 shot
check_asset screenshot_02.png 1280 800 shot
check_asset screenshot_03.png 1280 800 shot
check_asset screenshot_04.png 1280 800 shot

if [[ "$fails" -gt 0 ]]; then
  echo "FAILED $fails"
  exit 1
fi
echo "OK marketplace assets"
exit 0
