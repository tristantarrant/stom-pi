#!/bin/bash
# Stage the stom-pi-ui package tree under debian/stom-pi-ui/:
#   usr/lib/stom-pi/venv                   self-contained python env (pinned 3rd-party deps)
#   usr/lib/stom-pi/libmod_utils.so        C extension (JACK/LILV bridge used via ctypes by modtools.utils)
#   usr/share/stom-pi/html                 all of mod-ui/html
#   usr/share/stom-pi/factory-pedalboards  factory pedalboard content
#   usr/bin/stom-pi                       launcher script (sources: FHS-mirror dirs at repo root)
#   etc/default/stom-pi                   operator overrides for the launcher (conffile)
#   usr/lib/systemd/system/stom-pi.service systemd unit; dh_installsystemd handles enable/disable
set -euo pipefail

STAGE="$1"
SRC="$(cd "$2" && pwd)"
PIP_FLAGS="${3:-}"

VENV="$STAGE/usr/lib/stom-pi/venv"

echo ">> building libmod_utils.so (JACK/LILV bridge) from mod-ui/utils"
make -C "$SRC/mod-ui/utils" clean >/dev/null 2>&1 || true
make -C "$SRC/mod-ui/utils"
mkdir -p "$STAGE/usr/lib/stom-pi"
cp "$SRC/mod-ui/utils/libmod_utils.so" "$STAGE/usr/lib/stom-pi/"

echo ">> creating self-contained venv + installing pinned third-party deps (requirements.txt)"
python3 -m venv "$VENV"
SP="$(ls -d "$VENV"/lib/python3.*/site-packages | head -n1)"
# shellcheck disable=SC2086  # PIP_FLAGS is intentionally word-split (offline --no-index flag)
"$VENV/bin/pip" install --disable-pip-version-check --no-cache-dir $PIP_FLAGS \
    -r "$SRC/mod-ui/requirements.txt"

echo ">> installing first-party packages (mod/, modtools/) into venv site-packages"
cp -a "$SRC/mod-ui/mod"      "$SP/"
cp -a "$SRC/mod-ui/modtools" "$SP/"

# modtools/utils.py loads libmod_utils.so from a path relative to its own file
# (see tryPath1 in utils.py); point that at the canonical copy in /usr/lib/stom-pi/.
PYVER="$(basename "$(ls -d "$VENV"/lib/python3.*)" )"
FINAL_MODTOOLS="/usr/lib/stom-pi/venv/lib/$PYVER/site-packages/modtools"
REL_DIR="$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1], sys.argv[2]))' /usr/lib/stom-pi "$FINAL_MODTOOLS")"
ln -sfn "${REL_DIR%/}/libmod_utils.so" "$SP/modtools/libmod_utils.so"

# Compatibility patches for pre-3.10 code in the pinned third-party deps AND the
# first-party packages (both now live under site-packages):
echo ">> patching removed 'collections' ABC imports/usages in installed python code"
"$VENV/bin/python" "$SRC/debian/scripts/tornado-abc-fix.py" "$SP"

# Python >= 3.12 removed ssl.match_hostname; tornado <5 then falls back to the PyPI
# backport at import time (tornado/netutil.py). Install it only when needed.
if ! "$VENV/bin/python" -c "import ssl,sys; sys.exit(0 if hasattr(ssl,'match_hostname') else 1)"; then
    echo ">> installing backports.ssl-match-hostname (required by tornado <5 on Python >= 3.12)"
    # shellcheck disable=SC2086
    "$VENV/bin/pip" install --disable-pip-version-check --no-cache-dir $PIP_FLAGS \
        backports.ssl-match-hostname
fi

echo ">> staging HTML assets (all of mod-ui/html) and factory pedalboards"
mkdir -p "$STAGE/usr/share/stom-pi/html"
cp -a "$SRC/mod-ui/html/." "$STAGE/usr/share/stom-pi/html/"
mkdir -p "$STAGE/usr/share/stom-pi/factory-pedalboards"
cp -a "$SRC/factory-pedalboards/." "$STAGE/usr/share/stom-pi/factory-pedalboards/"

# Build identifier shown on the settings page (feature in our mod-ui fork);
# falls back to "unknown" when building from a non-git checkout.
echo ">> recording UI build identifier (mod-ui commit) for the settings page"
printf '%s\n' "$(git -C "$SRC/mod-ui" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)" \
    > "$STAGE/usr/share/stom-pi/build"

# Launcher (/usr/bin/stom-pi), operator-override conffile (/etc/default/stom-pi) and systemd unit
# (stom-pi.service). Sources live in FHS-mirror dirs at the repo root; dh_installsystemd
# finds the staged .service in this build dir and generates enable/disable snippets for us.
echo ">> staging launcher, conffile and systemd unit"
mkdir -p "$STAGE/usr/bin" "$STAGE/etc/default" "$STAGE/usr/lib/systemd/system"
cp "$SRC/usr/bin/stom-pi"                     "$STAGE/usr/bin/"
chmod 755 "$STAGE/usr/bin/stom-pi"
cp "$SRC/etc/default/stom-pi"                 "$STAGE/etc/default/"
cp "$SRC/usr/lib/systemd/system/stom-pi.service" "$STAGE/usr/lib/systemd/system/"

echo ">> smoke test: import webserver + ctypes bridge inside the venv"
SMOKE_DIR="$(mktemp -d)"
trap 'rm -rf "$SMOKE_DIR"' EXIT
MOD_HTML_DIR="$STAGE/usr/share/stom-pi/html" \
MOD_DATA_DIR="$SMOKE_DIR" \
    "$VENV/bin/python" -c "import mod.webserver, modtools.utils; print('smoke test OK')"

echo ">> staging complete: $STAGE"
