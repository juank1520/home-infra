#!/bin/sh
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root (sudo)"
    exit 1
fi

MOUNT_POINT="/mnt/media"

# Never offer the disk the OS itself is running from.
ROOT_SRC=$(findmnt -no SOURCE /)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null || true)
[ -z "$ROOT_DISK" ] && ROOT_DISK=$(basename "$ROOT_SRC")

echo "Looking for connected disks (excluding the system disk: /dev/${ROOT_DISK})..."
echo

CANDIDATES=""
for name in $(lsblk -rno NAME); do
    [ "$name" = "$ROOT_DISK" ] && continue
    pkname=$(lsblk -no PKNAME "/dev/$name" 2>/dev/null || true)
    [ "$pkname" = "$ROOT_DISK" ] && continue
    type=$(lsblk -no TYPE "/dev/$name")
    [ "$type" = "disk" ] || [ "$type" = "part" ] || continue
    # If a whole disk has partitions, offer the partitions instead of the raw disk.
    if [ "$type" = "disk" ] && lsblk -rno NAME "/dev/$name" | grep -qv "^${name}\$"; then
        continue
    fi
    CANDIDATES="$CANDIDATES $name"
done

set -- $CANDIDATES

if [ "$#" -eq 0 ]; then
    echo "No external disks found (other than the system disk)."
    echo "Connect the disk over USB and run this script again."
    exit 1
fi

i=0
for name in "$@"; do
    i=$((i + 1))
    size=$(lsblk -no SIZE "/dev/$name")
    fstype=$(lsblk -no FSTYPE "/dev/$name")
    label=$(lsblk -no LABEL "/dev/$name")
    mountpoint=$(lsblk -no MOUNTPOINT "/dev/$name")
    info="fs=${fstype:-unformatted}"
    [ -n "$label" ] && info="$info label=$label"
    [ -n "$mountpoint" ] && info="$info (already mounted at $mountpoint)"
    printf "  [%d] /dev/%-12s %6s  %s\n" "$i" "$name" "$size" "$info"
done

echo
printf "Pick the number of the disk to mount at %s (or 'q' to quit): " "$MOUNT_POINT"
read -r choice
if [ "$choice" = "q" ]; then
    echo "Cancelled."
    exit 0
fi

case "$choice" in
    '' | *[!0-9]*)
        echo "Invalid selection"
        exit 1
        ;;
esac
if [ "$choice" -lt 1 ] || [ "$choice" -gt "$#" ]; then
    echo "Invalid selection"
    exit 1
fi

eval "SELECTED_NAME=\${$choice}"
DEVICE="/dev/${SELECTED_NAME}"

echo
printf "You're about to use %s for %s. Continue? [y/N]: " "$DEVICE" "$MOUNT_POINT"
read -r confirm
case "$confirm" in
    y | Y | yes | Yes | YES) ;;
    *)
        echo "Cancelled."
        exit 0
        ;;
esac

FSTYPE=$(lsblk -no FSTYPE "$DEVICE")

if [ -z "$FSTYPE" ]; then
    echo
    echo "$DEVICE has no filesystem."
    printf "Format as ext4 now? THIS ERASES ALL ITS CONTENTS. Type 'yes' to confirm: "
    read -r format_confirm
    if [ "$format_confirm" != "yes" ]; then
        echo "Cancelled."
        exit 1
    fi
    mkfs.ext4 -L medialibrary "$DEVICE"
    FSTYPE="ext4"
elif [ "$FSTYPE" != "ext4" ]; then
    echo "Notice: $DEVICE already has filesystem '$FSTYPE' (using it as-is, not reformatting)."
fi

CURRENT_MP=$(lsblk -no MOUNTPOINT "$DEVICE")
if [ -n "$CURRENT_MP" ] && [ "$CURRENT_MP" != "$MOUNT_POINT" ]; then
    umount "$DEVICE"
fi

UUID=$(blkid -s UUID -o value "$DEVICE")
if [ -z "$UUID" ]; then
    echo "ERROR: could not read UUID for $DEVICE"
    exit 1
fi

# exFAT/NTFS have no real Unix ownership — set it via mount options instead of chown.
case "$FSTYPE" in
    ext4 | ext3 | ext2 | xfs | btrfs)
        OPTS="defaults,nofail"
        DO_CHOWN=1
        ;;
    vfat | exfat | ntfs | ntfs3)
        OPTS="defaults,nofail,uid=1000,gid=1000"
        DO_CHOWN=0
        ;;
    *)
        OPTS="defaults,nofail"
        DO_CHOWN=1
        ;;
esac

FSTAB_LINE="UUID=${UUID}  ${MOUNT_POINT}  ${FSTYPE}  ${OPTS}  0  2"

mkdir -p "$MOUNT_POINT"

if grep -q "UUID=${UUID}" /etc/fstab; then
    echo "fstab entry for UUID=${UUID} already present, skipping"
else
    echo "$FSTAB_LINE" >> /etc/fstab
    echo "Added fstab entry: $FSTAB_LINE"
fi

mount -a

if ! mountpoint -q "$MOUNT_POINT"; then
    echo "ERROR: ${MOUNT_POINT} did not mount. Check 'dmesg' and /etc/fstab."
    exit 1
fi

mkdir -p "$MOUNT_POINT/movies" "$MOUNT_POINT/tv" "$MOUNT_POINT/downloads"
[ "$DO_CHOWN" -eq 1 ] && chown -R 1000:1000 "$MOUNT_POINT"

echo "Mounted and ready: $MOUNT_POINT (movies, tv, downloads)"

# Refuse to start these stacks unless the drive is actually mounted — otherwise, since the
# fstab entry uses `nofail`, they'd silently write into the empty mountpoint directory on the
# SD card and fill it up.
for stack in jellyfin qbittorrent sonarr radarr; do
    OVERRIDE_DIR="/etc/systemd/system/docker-compose@${stack}.service.d"
    mkdir -p "$OVERRIDE_DIR"
    cat > "${OVERRIDE_DIR}/override.conf" <<EOF
[Unit]
RequiresMountsFor=${MOUNT_POINT}
EOF
    echo "Added RequiresMountsFor=${MOUNT_POINT} override for docker-compose@${stack}"
done

systemctl daemon-reload

echo "Done. Restart the media stacks to pick up the new mount dependency:"
echo "  sudo systemctl restart docker-compose@jellyfin docker-compose@qbittorrent docker-compose@sonarr docker-compose@radarr"
