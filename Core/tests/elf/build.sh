#!/bin/sh
# Builds the tiny ARM ELF test programs with clang + lld (no devkitARM needed).
set -e
cd "$(dirname "$0")"
# The ELFs are checked in; without lld (stock macOS) keep them instead of failing.
if ! command -v ld.lld >/dev/null 2>&1 && ! clang -fuse-ld=lld -v -x c /dev/null -o /dev/null >/dev/null 2>&1; then
  for f in spin exit paint alu solid-red solid-green; do [ -f "$f.elf" ] || { echo "lld missing and $f.elf not built" >&2; exit 1; }; done
  echo "lld not found: using the prebuilt test ELFs"; exit 0
fi
for p in spin exit; do
  clang --target=armv6k-none-eabi -march=armv6k -marm -nostdlib -static -fuse-ld=lld \
        -Wl,-T,link.ld -Wl,-z,norelro -o "$p.elf" "$p.S"
done
clang --target=armv6k-none-eabi -march=armv6k -marm -mfloat-abi=soft -O2 -fropi -ffreestanding -fno-builtin \
      -nostdlib -static -fuse-ld=lld -Wl,-T,link.ld -Wl,-z,norelro -o paint.elf paint.c
# Interpreter self-check: hashes the instruction forms the specialised dyncom handlers cover.
clang --target=armv6k-none-eabi -march=armv6k -marm -mfloat-abi=soft -O2 -fropi -ffreestanding -fno-builtin \
      -nostdlib -static -fuse-ld=lld -Wl,-T,link.ld -Wl,-z,norelro -o alu.elf alu.c
# Flat-colour variants for the CIA install/update tests (base = red, update = green).
for v in red:0xE02020 green:0x20C040; do
  clang --target=armv6k-none-eabi -march=armv6k -marm -mfloat-abi=soft -O2 -fropi -ffreestanding -fno-builtin \
        -DSOLID=${v#*:} -nostdlib -static -fuse-ld=lld -Wl,-T,link.ld -Wl,-z,norelro -o "solid-${v%%:*}.elf" paint.c
done
