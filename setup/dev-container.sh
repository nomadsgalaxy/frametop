#!/usr/bin/env bash
# Create or update the "dev" build container on the Steam Frame (Fedora 44 toolbox,
# aarch64, via distrobox). Safe to re-run: it only creates what's missing and dnf
# skips installed packages. This package list is the source of truth for rebuilding
# the container.
# Usage: setup/dev-container.sh   (on the Frame, or from a PC over SSH)
# Needs distrobox in ~/.local/bin on the Frame (see the top-level README).
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$root/scripts/_env.sh"

packages=(
  # toolchains
  gcc gcc-c++ clang clang-devel cmake meson ninja-build make pkgconf-pkg-config cargo rust git
  # libraries for Frametop's native pieces
  pipewire-devel libxkbcommon-devel libinput-devel systemd-devel dbus-devel libdrm-devel
  mesa-libgbm-devel wayland-devel vulkan-loader-devel vulkan-headers plasma-wayland-protocols wlroots-devel
  # ft_pointer SteamVR driver: static C++ runtime (the host has an older glibc)
  libstdc++-static
  # Frametop Input Settings app (Kirigami, PySide6)
  python3-pyside6 kf6-kirigami kf6-qqc2-desktop-style qt6-qtwayland breeze-icon-theme plasma-breeze
  # Frametop remote desktop (VNC bridge through krdp)
  krdp freerdp tigervnc-x11-server
  # diagnostics and remote UI testing
  wayland-utils xorg-x11-server-Xvfb ImageMagick xdotool
)

on_frame_script "$FRAME_REPO" "${packages[@]}" <<'EOF'
set -euo pipefail
repo=$1
shift
distrobox=$HOME/.local/bin/distrobox
[ -x "$distrobox" ] || { echo "distrobox not found at $distrobox (see the top-level README)" >&2; exit 1; }
if ! podman container exists dev; then
  echo "creating the dev container (Fedora 44 toolbox)"
  "$distrobox" create --yes --name dev --image registry.fedoraproject.org/fedora-toolbox:44
fi
"$repo/scripts/container-up.sh"  # in a scope of its own, not this shell's
# distrobox enter only waits for the container's first-boot init when it starts the container
# itself; container-up.sh started it, so wait here, or sudo below runs before init sets it up.
for _ in $(seq 600); do podman logs dev 2>&1 | grep -q container_setup_done && break; sleep 1; done
"$distrobox" enter dev -- bash -c '
set -euo pipefail
echo "installing ${#@} packages (already-installed ones are skipped)"
# A rootless container cannot trigger udev, so some %post scriptlets (udisks2) fail and dnf
# reports the transaction failed though every package installed. Trust rpm -q instead.
{ sudo dnf install -y -q "$@" 2>&1 || true; } | { grep -vE "is already installed|^Nothing to do|^$" || true; }
rpm -q "$@" >/dev/null || { rpm -q "$@" | grep "not installed" >&2; exit 1; }
# OpenVR programs built here (the pointer helper and probe) look for the runtime at /opt/steamvr.
[ -e /opt/steamvr ] || sudo ln -s /run/host/opt/steamvr /opt/steamvr
echo "dev container ready: $(. /etc/os-release; echo $PRETTY_NAME), glibc $(ldd --version | head -1 | grep -oE "[0-9.]+$")"
' dev "$@"
EOF
