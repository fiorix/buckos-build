#!/bin/bash
# Generate BuckOS Live System Init Scripts
# This script creates all the configuration files needed for the live environment

set -e

OUT="$1"

if [ -z "$OUT" ]; then
    echo "Usage: $0 <output_directory>"
    exit 1
fi

mkdir -p "$OUT/etc/init.d"
mkdir -p "$OUT/etc/rc.d"
mkdir -p "$OUT/sbin"
mkdir -p "$OUT/etc/sddm.conf.d"
mkdir -p "$OUT/etc/xdg/autostart"
mkdir -p "$OUT/usr/share/applications"
mkdir -p "$OUT/etc/systemd/system/getty@tty1.service.d"
mkdir -p "$OUT/etc/systemd/system/multi-user.target.wants"

# Create inittab for busybox init (live environment)
cat > "$OUT/etc/inittab" << 'INITTAB'
# /etc/inittab - BuckOS Live System Configuration
# System initialization
::sysinit:/etc/init.d/rcS

# Start getty on console
tty1::respawn:/sbin/getty 38400 tty1
tty2::respawn:/sbin/getty 38400 tty2

# Start display manager (for graphical session)
::once:/etc/init.d/display-manager start

# What to do when restarting the init process
::restart:/sbin/init

# What to do before rebooting
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
::shutdown:/sbin/swapoff -a
INITTAB

# Create rcS startup script for live system
cat > "$OUT/etc/init.d/rcS" << 'RCS'
#!/bin/sh
# BuckOS Live System - System initialization script

# Set PATH first - essential for finding commands
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "BuckOS Live System - Booting..."

# Mount essential filesystems (skip if already mounted by initramfs)
mountpoint -q /proc  || mount -t proc proc /proc 2>/dev/null || true
mountpoint -q /sys   || mount -t sysfs sysfs /sys 2>/dev/null || true
mountpoint -q /dev   || mount -t devtmpfs devtmpfs /dev 2>/dev/null || mount -t tmpfs tmpfs /dev

# Create essential device nodes if devtmpfs failed
if [ ! -c /dev/null ]; then
    mknod -m 666 /dev/null c 1 3
    mknod -m 666 /dev/zero c 1 5
    mknod -m 666 /dev/random c 1 8
    mknod -m 666 /dev/urandom c 1 9
    mknod -m 600 /dev/console c 5 1
    mknod -m 666 /dev/tty c 5 0
    mknod -m 666 /dev/tty1 c 4 1
    mknod -m 666 /dev/tty2 c 4 2
    mknod -m 660 /dev/ttyS0 c 4 64
fi

# Mount /dev/pts for pseudo-terminals (skip if already mounted)
mkdir -p /dev/pts /dev/shm
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts 2>/dev/null || true
mountpoint -q /dev/shm || mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true

# Mount /run and /tmp (skip if already mounted)
mountpoint -q /run || mount -t tmpfs tmpfs /run 2>/dev/null || true
mountpoint -q /tmp || mount -t tmpfs tmpfs /tmp 2>/dev/null || true

# Set hostname
hostname buckos-live

# Configure loopback
ip link set lo up 2>/dev/null || ifconfig lo up 2>/dev/null

# Load kernel modules for hardware support
modprobe -a i915 amdgpu nouveau radeon 2>/dev/null || true
modprobe -a virtio virtio_pci virtio_blk virtio_net 2>/dev/null || true
modprobe -a usbhid hid-generic 2>/dev/null || true
modprobe -a overlay squashfs loop 2>/dev/null || true

# Start udev or eudev for device management
if [ -x /sbin/udevd ]; then
    /sbin/udevd --daemon
    udevadm trigger
    udevadm settle
elif [ -x /usr/lib/systemd/systemd-udevd ]; then
    /usr/lib/systemd/systemd-udevd --daemon
    udevadm trigger
    udevadm settle
fi

# Configure network (DHCP)
for iface in eth0 enp0s3 ens3; do
    if [ -e "/sys/class/net/$iface" ]; then
        ip link set "$iface" up 2>/dev/null
        dhcpcd "$iface" 2>/dev/null &
        break
    fi
done

# Create live user home
mkdir -p /home/live/Desktop
chown -R 1000:1000 /home/live 2>/dev/null || true

echo "System initialization complete."
echo "Starting graphical environment..."
RCS
chmod +x "$OUT/etc/init.d/rcS"

# Create display manager init script
cat > "$OUT/etc/init.d/display-manager" << 'DM'
#!/bin/sh
# Display manager control script
case "$1" in
    start)
        # Try SDDM first (KDE default), then fallback to simpler options
        if [ -x /usr/bin/sddm ]; then
            exec /usr/bin/sddm
        elif [ -x /usr/bin/startplasma-wayland ]; then
            su - live -c "XDG_SESSION_TYPE=wayland exec /usr/bin/startplasma-wayland"
        elif [ -x /usr/bin/sway ]; then
            su - live -c "exec /usr/bin/sway"
        elif [ -x /usr/bin/startx ]; then
            su - live -c "exec startx"
        else
            echo "No display manager or compositor found!"
            echo "Starting console shell..."
            exec /bin/sh
        fi
        ;;
    stop)
        killall sddm startplasma-wayland sway 2>/dev/null
        ;;
    *)
        echo "Usage: $0 {start|stop}"
        exit 1
        ;;
esac
DM
chmod +x "$OUT/etc/init.d/display-manager"

# Create fstab for live system
cat > "$OUT/etc/fstab" << 'FSTAB'
# /etc/fstab - BuckOS Live System
# Note: Root filesystem is a squashfs overlay mounted by initramfs
proc             /proc          proc    defaults          0       0
sysfs            /sys           sysfs   defaults          0       0
devtmpfs         /dev           devtmpfs defaults         0       0
tmpfs            /tmp           tmpfs   defaults,nodev    0       0
tmpfs            /run           tmpfs   defaults,nodev    0       0
FSTAB

# Create live user entries
cat > "$OUT/etc/passwd" << 'PASSWD'
root:x:0:0:root:/root:/bin/bash
live:x:1000:1000:Live User:/home/live:/bin/bash
nobody:x:65534:65534:Nobody:/:/bin/false
sddm:x:990:990:SDDM Display Manager:/var/lib/sddm:/sbin/nologin
PASSWD

cat > "$OUT/etc/group" << 'GROUP'
root:x:0:
wheel:x:10:root,live
audio:x:11:live,root
video:x:12:live,root
input:x:13:live,root
seat:x:985:root
render:x:986:root
live:x:1000:
nobody:x:65534:
sddm:x:990:
GROUP

# Password for root and live user is "buckos"
# Hash generated with: python3 -c "import crypt; print(crypt.crypt('buckos', crypt.mksalt(crypt.METHOD_SHA512)))"
cat > "$OUT/etc/shadow" << 'SHADOW'
root:$6$S3r4QEYFJnjXqTwW$.Bh.r8p/9uOYytWpTunEfcOYPd3LdC.cyKUTkrRDd/xqnbcMobFJTHR8C3TNROE3I7Vxm07qGjVAl/9scARyY0:19000:0:99999:7:::
live:$6$S3r4QEYFJnjXqTwW$.Bh.r8p/9uOYytWpTunEfcOYPd3LdC.cyKUTkrRDd/xqnbcMobFJTHR8C3TNROE3I7Vxm07qGjVAl/9scARyY0:19000:0:99999:7:::
nobody:!:19000:0:99999:7:::
sddm:!:19000:0:99999:7:::
SHADOW
chmod 640 "$OUT/etc/shadow"

# Create os-release
cat > "$OUT/etc/os-release" << 'OSRELEASE'
NAME="BuckOS Linux"
VERSION="0.1 Live"
ID=buckos
ID_LIKE=gentoo
PRETTY_NAME="BuckOS Linux 0.1 Live"
HOME_URL="https://github.com/buck-os/buckos-build"
VARIANT="Live"
VARIANT_ID=live
OSRELEASE

# Create hostname
echo "buckos-live" > "$OUT/etc/hostname"

# Create hosts
cat > "$OUT/etc/hosts" << 'HOSTS'
127.0.0.1   localhost buckos-live
::1         localhost ip6-localhost ip6-loopback
HOSTS

# Create profile
cat > "$OUT/etc/profile" << 'PROFILE'
# /etc/profile - BuckOS Live System
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PS1='\[\033[01;32m\]live@buckos-live\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
export TERM=linux
export XDG_RUNTIME_DIR=/run/user/1000
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland

# Create runtime dir for live user
if [ "$(id -u)" = "1000" ]; then
    mkdir -p /run/user/1000
    chmod 700 /run/user/1000
fi
PROFILE

# Create issue (login banner)
# Note: Backslashes are doubled because getty interprets escape sequences
cat > "$OUT/etc/issue" << 'ISSUE'

  ____             _     ___  ____    _     _
 | __ ) _   _  ___| | __/ _ \\/ ___|  | |   (_)_   _____
 |  _ \\| | | |/ __| |/ / | | \\___ \\  | |   | \\ \\ / / _ \\
 | |_) | |_| | (__|   <| |_| |___) | | |___| |\\ V /  __/
 |____/ \\__,_|\\___|_|\\_\\\\___/|____/  |_____|_| \\_/ \\___|

 Welcome to BuckOS Linux Live System!

 To install BuckOS to your hard drive, run the installer:
   - Click the "Install BuckOS" icon on the desktop
   - Or run: sudo buckos-installer

 Kernel \r on \m

ISSUE

# Create SDDM autologin configuration
cat > "$OUT/etc/sddm.conf.d/autologin.conf" << 'SDDMCONF'
[Autologin]
User=live
Session=plasma.desktop
Relogin=false

[Theme]
Current=breeze

[General]
HaltCommand=/sbin/poweroff
RebootCommand=/sbin/reboot
SDDMCONF

# Create XDG autostart for installer notification
cat > "$OUT/etc/xdg/autostart/buckos-installer-notify.desktop" << 'AUTOSTART'
[Desktop Entry]
Type=Application
Name=BuckOS Installer Notification
Exec=notify-send -i system-software-install "Welcome to BuckOS Live" "Click the 'Install BuckOS' icon on your desktop to install BuckOS to your computer."
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
AUTOSTART

# Create desktop entry for installer
cat > "$OUT/usr/share/applications/buckos-installer.desktop" << 'DESKTOPENTRY'
[Desktop Entry]
Type=Application
Name=Install BuckOS
GenericName=System Installer
Comment=Install BuckOS to your computer
Exec=pkexec /usr/bin/buckos-installer
Icon=system-software-install
Terminal=false
Categories=System;
Keywords=install;installer;setup;system;
StartupNotify=true
X-KDE-StartupNotify=true
DESKTOPENTRY

# Create simple Sway init script (alternative to busybox init)
# This can be used as /sbin/init for a minimal Sway-based live system
cat > "$OUT/sbin/sway-init" << 'SWAYINIT'
#!/bin/bash
# BuckOS Live CD with Sway - Simple init script
# Use this as /sbin/init for a minimal Sway desktop

# Set PATH first - essential for finding commands
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Set up console - try multiple devices for both x86_64 and aarch64
for console in /dev/console /dev/ttyAMA0 /dev/ttyS0 /dev/tty0 /dev/tty1; do
    if [ -c "$console" ]; then
        exec 0<"$console" 1>"$console" 2>"$console"
        break
    fi
done

# Set LD_LIBRARY_PATH for aarch64 compatibility
# Some packages install to lib64 which is x86_64 convention
export LD_LIBRARY_PATH=/lib:/usr/lib:/lib64:/usr/lib64

# Mount essential filesystems (skip if already mounted by initramfs)
mountpoint -q /proc  || mount -t proc proc /proc
mountpoint -q /sys   || mount -t sysfs sys /sys
mountpoint -q /dev   || mount -t devtmpfs dev /dev
mkdir -p /dev/pts /dev/shm
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts
mountpoint -q /dev/shm || mount -t tmpfs tmpfs /dev/shm
mountpoint -q /tmp     || mount -t tmpfs tmpfs /tmp
mountpoint -q /run     || mount -t tmpfs tmpfs /run

# Set hostname
hostname buckos-live

# Create XDG runtime directory
export XDG_RUNTIME_DIR=/run/user/0
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

# Export environment
export HOME=/root
export TERM=linux

# Start udev if available
if [ -x /sbin/udevd ]; then
    /sbin/udevd --daemon
    udevadm trigger --action=add
    udevadm settle
fi

# Print welcome message
echo ""
echo "======================================"
echo "  Welcome to BuckOS Live CD"
echo "======================================"
echo ""

# Check if we have a display (DRM device)
if [ -e /dev/dri/card0 ]; then
    echo "Starting Sway Wayland compositor..."
    echo ""
    cd /root
    sway || {
        echo ""
        echo "Sway failed to start. Dropping to shell..."
        echo "You can try 'sway' again if you have a display."
        echo ""
    }
else
    echo "No display detected (no /dev/dri/card0)"
    echo "Skipping Sway, dropping to shell..."
    echo ""
fi

# Drop to interactive shell
echo "BuckOS shell ready. Type 'sway' to start desktop (if display available)."
cd /root
exec /bin/bash --noediting -i
SWAYINIT
chmod +x "$OUT/sbin/sway-init"

# Create /sbin/init symlink to systemd for live boot
# systemd handles console, getty, and service management properly
ln -sf ../usr/lib/systemd/systemd "$OUT/sbin/init"

# =============================================================================
# Systemd configuration for live boot (when systemd is PID 1)
# =============================================================================

# Getty autologin on tty1 - auto-login as root for live session
cat > "$OUT/etc/systemd/system/getty@tty1.service.d/autologin.conf" << 'GETTYCONF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
Type=idle
GETTYCONF

# Seatd service for session management (needed by sway/wlroots)
cat > "$OUT/etc/systemd/system/seatd.service" << 'SEATD'
[Unit]
Description=Seat management daemon
Documentation=man:seatd(1)

[Service]
Type=simple
ExecStart=/usr/bin/seatd -g seat
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
SEATD

# Enable seatd at boot
ln -sf ../seatd.service "$OUT/etc/systemd/system/multi-user.target.wants/seatd.service"

# Create root's profile to auto-start sway on tty1
mkdir -p "$OUT/root"
cat > "$OUT/root/.bash_profile" << 'ROOTPROFILE'
# Auto-start Sway on tty1 in live session
if [ "$(tty)" = "/dev/tty1" ] && [ -z "$WAYLAND_DISPLAY" ]; then
    export XDG_RUNTIME_DIR=/run/user/0
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 0700 "$XDG_RUNTIME_DIR"
    export XDG_SESSION_TYPE=wayland
    export QT_QPA_PLATFORM=wayland
    export GDK_BACKEND=wayland

    echo ""
    echo "======================================"
    echo "  Welcome to BuckOS Live"
    echo "======================================"
    echo ""

    if [ -e /dev/dri/card0 ]; then
        echo "Starting Sway Wayland compositor..."
        exec sway
    else
        echo "No display detected (no /dev/dri/card0)"
        echo "Dropping to shell. Type 'sway' to try manually."
    fi
fi
ROOTPROFILE

# Disable systemd-firstboot (live system is pre-configured)
# Create the machine-id and locale so firstboot doesn't trigger
mkdir -p "$OUT/etc"
echo "buckos-live" > "$OUT/etc/machine-id"
echo "LANG=C.UTF-8" > "$OUT/etc/locale.conf"
echo "UTC" > "$OUT/etc/timezone"
ln -sf /usr/share/zoneinfo/UTC "$OUT/etc/localtime" 2>/dev/null || true

# Mask systemd-firstboot so it never runs on live system
mkdir -p "$OUT/etc/systemd/system"
ln -sf /dev/null "$OUT/etc/systemd/system/systemd-firstboot.service"

# Mask systemd-vconsole-setup - requires kbd package (setfont/loadkeys)
# Console works fine with kernel defaults
ln -sf /dev/null "$OUT/etc/systemd/system/systemd-vconsole-setup.service"

# Set default target to multi-user (console) - sway starts via bash_profile
# graphical.target requires a display manager which we don't have
ln -sf /usr/lib/systemd/system/multi-user.target "$OUT/etc/systemd/system/default.target"

# Enable getty on tty1 explicitly
mkdir -p "$OUT/etc/systemd/system/getty.target.wants"
ln -sf /usr/lib/systemd/system/getty@.service "$OUT/etc/systemd/system/getty.target.wants/getty@tty1.service"

# Enable serial console for aarch64 (QEMU uses ttyAMA0)
ln -sf /usr/lib/systemd/system/serial-getty@.service "$OUT/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service"

# Create autologin override for serial console too
mkdir -p "$OUT/etc/systemd/system/serial-getty@ttyAMA0.service.d"
cat > "$OUT/etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf" << 'SERIALCONF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
Type=idle
SERIALCONF

# Create /sbin/ldconfig symlink (systemd expects /sbin/ldconfig but glibc installs to /usr/sbin)
mkdir -p "$OUT/sbin"
ln -sf ../usr/sbin/ldconfig "$OUT/sbin/ldconfig"

# Create empty ld.so.cache so ldconfig.service is skipped on live boot
# (avoids startup delay and potential issues with read-only squashfs)
touch "$OUT/etc/ld.so.cache"

# Create /etc/securetty to allow root login on console and serial ports
# Required by pam_securetty.so which is used by login PAM config
cat > "$OUT/etc/securetty" << 'SECURETTY'
# Console terminals
console
tty1
tty2
tty3
tty4
tty5
tty6
# Serial terminals (for QEMU and real hardware)
ttyS0
ttyS1
ttyAMA0
ttyAMA1
hvc0
SECURETTY

# Note: PAM configs (system-auth, login) are now in the pam package

echo "Live init scripts generated successfully in $OUT"
