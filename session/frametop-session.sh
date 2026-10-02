#!/bin/bash
# Runs on the Frame host (not in the container). Starts a Plasma desktop with several
# screens, each its own SteamVR panel. Modeled on /usr/bin/steamos-nested-desktop, which
# does the same with one screen in gamescope.
#
# Backends (BACKEND in ~/.config/frametop.conf):
#   screens    (default) ft-screens (screens), our own compositor: KWin opens a
#              window per screen, ft-screens gives each its size (from the layout, see
#              layout) and shows it as its own panel. Any resolution and shape.
#   gamescope  gamescope in PerWindow mode: every screen one size, at most 1920x1080
#              worth of pixels, panels owned by the SteamVR dashboard.
#
# Settings come from ~/.config/frametop.conf (see frametop.conf.example) and, for the
# screens backend, ~/.config/frametop-layout.json (Frametop Display Settings writes both).
# FT_BACKEND, FT_SCREENS, FT_WIDTH, FT_HEIGHT, and FT_PHYS_WIDTH override them.
set -eu

here=$(dirname "$(readlink -f "$0")")

# Started from the VR launcher, the desktop inherits the Steam client's environment. Apps in
# it should see the system as a normal login does, so drop the client's runtime: its
# LD_LIBRARY_PATH put Steam's own libraries ahead of the system's (Steam's libavcodec has no
# H.264 decoder, so VLC couldn't play most videos), and its overlay and launch settings are
# meant for games. SteamOS's own defaults (/usr/share/deckard/mesavars.sh) stay.
for var in $(compgen -e); do
  case $var in
    LD_LIBRARY_PATH | LD_PRELOAD | STEAM_* | Steam* | SRT_* | PRESSURE_VESSEL_* | MANGOHUD_* | \
      ENABLE_VK_LAYER_VALVE_steam_overlay_* | STEAMVIDEOTOKEN) unset "$var" ;;
  esac
done

conf=$HOME/.config/frametop.conf
BACKEND=screens SCREENS=2 WIDTH=1920 HEIGHT=1080 PHYS_WIDTH=1.6 REMOTE=0
# shellcheck disable=SC1090
[ -f "$conf" ] && . "$conf"
backend=${FT_BACKEND:-$BACKEND}
screens=${FT_SCREENS:-$SCREENS}
width=${FT_WIDTH:-$WIDTH}
height=${FT_HEIGHT:-$HEIGHT}
phys_width=${FT_PHYS_WIDTH:-$PHYS_WIDTH}
remote=${FT_REMOTE:-$REMOTE}
if [ "$backend" = gamescope ] && [ $((width * height)) -gt $((1920 * 1080)) ]; then
  # gamescope's VR backend aborts above 1920x1080 worth of pixels (its upload buffer;
  # see docs/design.md). Shrink a bigger size to fit, keeping its shape.
  read -r width height < <(awk -v w="$width" -v h="$height" 'BEGIN { k = sqrt(1920 * 1080 / (w * h));
    printf "%d %d\n", int(w * k / 8) * 8, int(h * k / 8) * 8 }')
  echo "frametop: resolution too big for gamescope's VR mode; using ${width}x${height}" >&2
fi

if [ "${1:-}" != --inner ]; then
  # One instance at a time. The launcher can be clicked twice.
  if pgrep -f '[v]r-overlay-key frametop ' >/dev/null || pgrep -x ft-screens >/dev/null; then
    echo "Frametop is already running" >&2
    exit 0
  fi
  set -a; . /usr/share/deckard/mesavars.sh; set +a
  # Flatpak apps (Chromium) publish their launcher entries under the Flatpak
  # exports dirs. SSH and launcher environments may lack XDG_DATA_DIRS, and then
  # Plasma can't find them and opens Discover instead.
  export XDG_DATA_DIRS=${XDG_DATA_DIRS:-/usr/local/share:/usr/share}
  set +u; . /etc/profile.d/flatpak.sh; set -u
  # Arrange the screens in the saved layout once they're up (layout; skipped
  # when auto-arrange is off).
  setsid "$here/../layout/ft-layout" apply --wait 90 > /tmp/frametop-layout.log 2>&1 < /dev/null &

  if [ "$backend" = gamescope ]; then
    export ENABLE_GAMESCOPE_WSI=1 GAMESCOPE_MANGOAPP_SOCKET_DISABLE=1
    exec gamescope --backend openvr --virtual-connector-strategy PerWindow \
      -W "$width" -H "$height" -w "$width" -h "$height" \
      --vr-overlay-key frametop --vr-overlay-default-name frametop \
      --vr-overlay-physical-width "$phys_width" \
      --vr-overlay-show-immediately --vr-overlay-enable-click-stabilization \
      --vr-overlay-enable-control-bar --vr-overlay-enable-control-bar-keyboard \
      --expose-wayland \
      --cursor-hotspot 5,3 --cursor /usr/share/steamos/steamos-cursor.png \
      -- "$0" --inner
  fi

  # ft-screens runs in the dev container (it's built against Fedora's wlroots); KWin and
  # Plasma stay on the host and connect to its socket.
  socket=ft-screens-0
  read -ra screen_args <<< "$("$here/../layout/ft-layout" screen-args)"
  export FT_SCREEN_COUNT=$(( ${#screen_args[@]} / 2 ))
  "$here/../scripts/container-up.sh"  # not owned by this desktop, or stopping it would stop the container
  "$HOME/.local/bin/distrobox" enter dev -- "$here/../screens/build/ft-screens" --socket "$socket" \
    "${screen_args[@]}" > /tmp/frametop-screens.log 2>&1 < /dev/null &
  stop_screens() { pkill -x ft-screens 2>/dev/null || true; }
  trap stop_screens EXIT
  for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/$socket" ] && break; sleep 0.2; done
  [ -S "$XDG_RUNTIME_DIR/$socket" ] || { echo "ft-screens didn't start (see /tmp/frametop-screens.log)" >&2; exit 1; }
  WAYLAND_DISPLAY=$XDG_RUNTIME_DIR/$socket "$0" --inner
  exit
fi

# Inside the host compositor (ft-screens or gamescope) from here on. The desktop isn't a
# gamescope client with ft-screens, so the gamescope session's Vulkan layer stays off, and
# the gamescope session's portal config isn't Plasma's.
[ "$backend" = gamescope ] || unset ENABLE_GAMESCOPE_WSI
unset XDG_DESKTOP_PORTAL_DIR
[ "$backend" = gamescope ] || screens=${FT_SCREEN_COUNT:-$screens}

host_runtime=$XDG_RUNTIME_DIR
runtime=$host_runtime/frametop

cleanup() {
  pkill -f '[k]rdpserver --plasma' 2>/dev/null || true
  pkill -f '[X]vnc :20 ' 2>/dev/null || true
  pkill -f '[x]freerdp /v:.*:3390' 2>/dev/null || true
  fusermount3 -u -z "$runtime/doc" 2>/dev/null || true
  umount --recursive "$runtime" 2>/dev/null || true
  rm -rf "$runtime"
}
trap cleanup EXIT
cleanup
mkdir -m 0700 "$runtime" "$runtime/pulse" "$runtime/bin"
ln -s "$host_runtime/pulse/native" "$runtime/pulse/native"
ln -s "$host_runtime"/pipewire* "$runtime/"
# Daemons that must be one per user, inside this desktop or not: systemd (systemctl --user),
# gortex and Claude Code's session sockets. Otherwise each side starts or looks for its own.
mkdir -p -m 0700 "$host_runtime/cc-socks"
for f in systemd gortex.sock cc-socks; do
  if [ -e "$host_runtime/$f" ]; then ln -s "$host_runtime/$f" "$runtime/$f"; fi
done

# plasma-session starts KWin through kwin_wayland_wrapper. Shadow it to add our outputs.
# With ft-screens the size is only the starting one: ft-screens sets each screen's own.
cat > "$runtime/bin/kwin_wayland_wrapper" <<EOF
#!/bin/sh
exec /usr/bin/kwin_wayland_wrapper --width $width --height $height --output-count $screens --no-lockscreen "\$@"
EOF
chmod +x "$runtime/bin/kwin_wayland_wrapper"
export PATH=$runtime/bin:$PATH

# Keep the host compositor's Wayland socket reachable after moving XDG_RUNTIME_DIR.
case ${WAYLAND_DISPLAY:-gamescope-0} in
  /*) ;;
  *) export WAYLAND_DISPLAY=$host_runtime/${WAYLAND_DISPLAY:-gamescope-0} ;;
esac
export XDG_RUNTIME_DIR=$runtime

# Separate Plasma/KWin config and state, so this session and the built-in
# desktop never overwrite each other's screen layout or panels.
export XDG_CONFIG_HOME=$HOME/.config/frametop
export XDG_STATE_HOME=$HOME/.local/state/frametop
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"

# Remote desktop over VNC: session/remote-desktop.sh captures the desktop with
# krdp on 127.0.0.1, and session/vnc-bridge.sh re-serves it over VNC. krdpserver runs from the container, so KWin can't
# match it to an installed app. KWin's permission check for screencast and fake
# input is turned off for this nested session only.
if [ "$remote" = 1 ]; then
  export KWIN_WAYLAND_NO_PERMISSION_CHECKS=1
  "$here/remote-desktop.sh" "$runtime" > /tmp/frametop-remote.log 2>&1 &
  "$here/vnc-bridge.sh" "$width" "$height" > /tmp/frametop-vnc.log 2>&1 &
fi

dbus-run-session startplasma-wayland
