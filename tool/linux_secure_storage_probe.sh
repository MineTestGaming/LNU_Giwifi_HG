#!/usr/bin/env bash
set -euo pipefail

# Requires a Linux Flutter SDK, clang/LLVM/lld, GTK/libsecret development libraries,
# gnome-keyring, dbus-run-session, xvfb-run, xauth, and python3.
# All credentials, D-Bus connections, and keyring files belong to this probe.
script_path=$(realpath "$0")
project_root=$(dirname "$(dirname "$script_path")")

if [[ ${1:-} == --phase ]]; then
  phase=$2
  probe_root=$3
  [[ -f "$probe_root/.giwifi-storage-probe" ]] || exit 2
  export XDG_DATA_HOME="$probe_root/data"
  export XDG_CONFIG_HOME="$probe_root/desktop-config"
  export XDG_CACHE_HOME="$probe_root/cache"
  export XDG_RUNTIME_DIR="$probe_root/runtime-$phase"
  export GIWIFI_STORAGE_PROBE_ROOT="$probe_root"
  export GIWIFI_STORAGE_PROBE_PHASE="$phase"
  export GDK_BACKEND=x11
  export LIBGL_ALWAYS_SOFTWARE=1
  unset GNOME_KEYRING_CONTROL GNOME_KEYRING_PID
  mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR"
  gnome-keyring-daemon --foreground --unlock --components=secrets \
    --control-directory "$XDG_RUNTIME_DIR/keyring" \
    < "$probe_root/keyring-password" > "$probe_root/keyring-$phase.log" 2>&1 &
  keyring_pid=$!
  trap 'kill "$keyring_pid" 2>/dev/null || true; wait "$keyring_pid" 2>/dev/null || true' EXIT
  timeout 15s gdbus wait --session org.freedesktop.secrets
  timeout 90s xvfb-run -a "$probe_root/bundle/giwifi_ua_switcher"
  exit 0
fi

[[ $(uname -s) == Linux ]] || { printf 'Linux is required\n' >&2; exit 2; }
for executable in flutter dbus-run-session gnome-keyring-daemon xvfb-run xauth python3 gdbus; do
  command -v "$executable" >/dev/null || { printf 'Missing dependency: %s\n' "$executable" >&2; exit 2; }
done
probe_root=$(mktemp -d "${TMPDIR:-/tmp}/giwifi-native-storage.XXXXXX")
chmod 700 "$probe_root"
touch "$probe_root/.giwifi-storage-probe"
trap 'rm -f -- "$probe_root/keyring-password"' EXIT
python3 - "$probe_root" <<'PY'
import os
import pathlib
import secrets
import sys

password_file = pathlib.Path(sys.argv[1]) / 'keyring-password'
password_file.write_text(secrets.token_urlsafe(32))
os.chmod(password_file, 0o600)
PY

cd "$project_root"
flutter build linux --debug --target tool/secure_storage_probe.dart
cp -a build/linux/x64/debug/bundle "$probe_root/bundle"
# Restore the normal application entry point in the regular build directory.
flutter build linux --debug

for phase in write read; do
  dbus-run-session -- bash "$script_path" --phase "$phase" "$probe_root"
  if [[ $phase == write ]]; then
    python3 - "$probe_root" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
keyrings = list((root / 'data' / 'keyrings').glob('*.keyring'))
assert keyrings, 'No persistent keyring file was created'
markers = (b'WSL-NATIVE-PASSWORD-PROBE-6c419d', b'WSL-NATIVE-COOKIE-PROBE-b93e27')
for keyring in keyrings:
    content = keyring.read_bytes()
    assert all(marker not in content for marker in markers), 'Plaintext credential found in keyring file'
print('PASS: persistent keyring files contain neither plaintext password nor Cookie')
PY
  fi
done
printf 'LINUX_NATIVE_STORAGE_PASS\nProbe artifacts: %s\n' "$probe_root"
