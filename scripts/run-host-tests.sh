#!/usr/bin/env bash
# Builds Azahar + AzaharCore for the host (Linux or macOS, no GPU needed) and runs the
# integration tests: boot (JIT + interpreter), dedicated-room multiplayer, device-hosted rooms
# and the self-hosted lobby. This is how the frontend layer is verified without an iPhone.
#
# Requirements: CMake ≥ 3.25, Ninja, a C++20 compiler, clang + lld (to build the test ELFs),
#               python3 with PyJWT + cryptography (for the lobby test).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${AZAHAR_SRC:-$ROOT/external/azahar}"
BUILD="${HOST_BUILD_DIR:-$ROOT/build/host}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { set +e; for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

[ -d "$SRC/src/azios" ] || "$ROOT/scripts/bootstrap.sh"

cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_QT=OFF -DENABLE_SDL2=OFF -DENABLE_TESTS=OFF -DENABLE_OPENGL=OFF -DENABLE_VULKAN=ON \
  -DENABLE_CUBEB=OFF -DENABLE_OPENAL=OFF -DENABLE_LIBUSB=OFF -DENABLE_ROOM=ON \
  -DENABLE_WEB_SERVICE=ON -DENABLE_GDBSTUB=OFF -DCITRA_WARNINGS_AS_ERRORS=OFF \
  -DCITRA_USE_PRECOMPILED_HEADERS=OFF -DENABLE_LTO=OFF -DENABLE_AZIOS=ON >/dev/null
cmake --build "$BUILD" --target azios_test citra_room_standalone -j "$JOBS"

BIN="$BUILD/bin/Release"
[ -x "$BIN/azios_test" ] || BIN="$BUILD/bin"
T="$BIN/azios_test"
ROOM="$BIN/azahar-room"
"$ROOT/Core/tests/elf/build.sh"
ELF="$ROOT/Core/tests/elf"
pass=0; fail=0
check() { if "$@" >>"$TMP/tests.log" 2>&1; then echo "PASS  $NAME"; pass=$((pass+1)); else echo "FAIL  $NAME"; fail=$((fail+1)); fi; }

export AZ_TEST_USERDIR="$TMP/userA"
NAME="game info";            check "$T" info "$ELF/spin.elf"
NAME="boot with JIT";        check "$T" boot "$ELF/spin.elf" 4 1
NAME="boot with interpreter"; check "$T" boot "$ELF/spin.elf" 4 0
NAME="exit program";         check "$T" exit "$ELF/exit.elf"
NAME="input reaches HID";    check "$T" input
mkdir -p "$TMP/dump"
NAME="framebuffer output";   check env AZ_TEST_DUMP="$TMP/dump" "$T" boot "$ELF/paint.elf" 2 0
NAME="frame dumped";         check test -s "$TMP/dump/top.ppm"
# alu.elf draws a hash of ADD/SUB/CMP/MOV/LDR/STR results and flags: the interpreter with and
# without its specialised handlers, and the JIT, must draw the same frame.
mkdir -p "$TMP/alu1" "$TMP/alu0" "$TMP/aluj"
AZ_TEST_DUMP="$TMP/alu1" "$T" boot "$ELF/alu.elf" 3 0 >/dev/null 2>&1 || true
AZ_DYNCOM_NO_SPECIAL=1 AZ_TEST_DUMP="$TMP/alu0" "$T" boot "$ELF/alu.elf" 3 0 >/dev/null 2>&1 || true
AZ_TEST_DUMP="$TMP/aluj" "$T" boot "$ELF/alu.elf" 3 1 >/dev/null 2>&1 || true
NAME="interpreter: specialised = generic"; check cmp "$TMP/alu1/top.ppm" "$TMP/alu0/top.ppm"
NAME="interpreter = JIT (alu.elf)";        check cmp "$TMP/alu1/top.ppm" "$TMP/aluj/top.ppm"
NAME="save state + 3 loads";  check "$T" savestate "$ELF/paint.elf"
NAME="screenshot (software renderer)"; check sh -c "AZ_TEST_SHOT='$TMP/shot.png' '$T' boot '$ELF/paint.elf' 2 0 | grep -q screenshot=1 && head -c 4 '$TMP/shot.png' | od -An -tx1 | grep -q '89 50 4e 47'"

# CIA install, update overlay and DLC (test CIAs built by scripts/tools/mkcia.py).
MK="python3 $ROOT/scripts/tools/mkcia.py"
$MK app    --elf "$ELF/solid-red.elf"   --tid 0004000000B1F000 --name "CIA test" -o "$TMP/base.cia"   >/dev/null
$MK update --elf "$ELF/solid-green.elf" --tid 0004000E00B1F000 --version 1040 -o "$TMP/update.cia" >/dev/null
$MK dlc    --tid 0004008C00B1F000 -o "$TMP/dlc.cia" >/dev/null
# centre_is <ppm> "<r> <g> <b>": colour of the centre pixel of a dumped frame.
centre_is() {
  [ "$(python3 - "$1" <<'EOF'
import sys
d = open(sys.argv[1], "rb").read()
i = d.index(b"255\n") + 4
n = (len(d) - i) // 3
print(*d[i + (n // 2) * 3:i + (n // 2) * 3 + 3])
EOF
)" = "$2" ]
}
titles_has() { "$T" titles 2>/dev/null | grep -q "$1"; }
$MK update --elf "$ELF/solid-green.elf" --tid 0004000E00B1F100 --mark-ncch-encrypted -o "$TMP/enc.cia" >/dev/null
export AZ_TEST_USERDIR="$TMP/userC"
NAME="ncch-encrypted cia rejected"; check sh -c "'$T' install '$TMP/enc.cia'; [ \$? -eq 2 ]"
NAME="cia info";               check sh -c "'$T' ciainfo '$TMP/update.cia' | grep -q 'version=1040 kind=1'"
NAME="install base cia";       check "$T" install "$TMP/base.cia"
INSTALLED=$("$T" titles 2>/dev/null | sed -n 's/^titles=\[{"path":"\([^"]*\)".*/\1/p')
NAME="installed title listed"; check test -n "$INSTALLED"
mkdir -p "$TMP/c1" "$TMP/c2"
AZ_TEST_DUMP="$TMP/c1" "$T" boot "$INSTALLED" 2 0 >/dev/null 2>&1
NAME="base boots (red)";       check centre_is "$TMP/c1/top.ppm" "224 32 32"
NAME="install update cia";     check "$T" install "$TMP/update.cia"
AZ_TEST_DUMP="$TMP/c2" "$T" boot "$INSTALLED" 2 0 >/dev/null 2>&1
NAME="update replaces code (green)"; check centre_is "$TMP/c2/top.ppm" "32 192 64"
NAME="install dlc cia";        check "$T" install "$TMP/dlc.cia"
NAME="update listed";          check titles_has '"kind":"update","version":1040'
NAME="dlc listed";             check titles_has '"kind":"dlc"'
NAME="only the game is bootable"; check sh -c "[ \$('$T' titles 2>/dev/null | grep -o '\"path\"' | wc -l) -eq 1 ]"

# Dedicated room (official azahar-room binary) + two clients.
# (azahar-room keeps running when stdin closes, so it is killed explicitly on exit)
"$ROOM" --room-name Dedicated --port 24950 --preferred-app Any --preferred-app-id 0 </dev/null >"$TMP/room.log" 2>&1 &
PIDS+=($!)
sleep 2
AZ_TEST_USERDIR="$TMP/userB" "$T" join 127.0.0.1 24950 PlayerTwo "hi from two" 8 >"$TMP/b.log" 2>&1 &
B_PID=$!; PIDS+=($B_PID)
sleep 1.5
NAME="join dedicated room";  check "$T" join 127.0.0.1 24950 PlayerOne "hello from one" 3
wait "$B_PID" 2>/dev/null || true
NAME="chat delivered";       check grep -q '"message":"hello from one"' "$TMP/b.log"

# Device-hosted room.
AZ_TEST_USERDIR="$TMP/userA" "$T" host 24951 HostPhone 8 >"$TMP/host.log" 2>&1 &
H_PID=$!; PIDS+=($H_PID)
sleep 2
NAME="join device-hosted room"; check env AZ_TEST_USERDIR="$TMP/userB" "$T" join 127.0.0.1 24951 GuestPhone "ping" 4
wait "$H_PID" 2>/dev/null || true
NAME="host saw guest";       check grep -q "host_joins=1" "$TMP/host.log"

# Lobby: our client and the official dedicated room both announce to Server/lobby.
(cd "$ROOT/Server/lobby" && exec env LOBBY_PORT=5098 LOBBY_DATA_DIR="$TMP/lobby" python3 lobby.py) >"$TMP/lobby.log" 2>&1 &
PIDS+=($!)
sleep 1.5
AZ_TEST_USERDIR="$TMP/userA" "$T" host 24952 HostPhone 20 http://127.0.0.1:5098 sometoken >/dev/null 2>&1 &
PIDS+=($!)
"$ROOM" --room-name "VPS Room" --port 24953 --preferred-app Any --preferred-app-id 0 \
   --username vps --token secret --web-api-url http://127.0.0.1:5098 </dev/null >/dev/null 2>&1 &
PIDS+=($!)
sleep 4
AZ_TEST_USERDIR="$TMP/userB" "$T" lobby http://127.0.0.1:5098 >"$TMP/lobby-list.log"
NAME="lobby lists device room"; check grep -q '"name":"iOS test room"' "$TMP/lobby-list.log"
NAME="lobby lists azahar-room"; check grep -q '"name":"VPS Room"' "$TMP/lobby-list.log"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "--- log ---"; tail -n 60 "$TMP/tests.log"; }
[ "$fail" -eq 0 ]
