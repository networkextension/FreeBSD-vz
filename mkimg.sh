#!/bin/sh
# Build a bootable FreeBSD/arm64 disk image for Apple Virtualization.framework.
#
# Run this AS ROOT on a FreeBSD build host that has already run, for a checkout
# containing the VZ patches (see README):
#     make -j<n> buildworld    TARGET=arm64 TARGET_ARCH=aarch64
#     make -j<n> buildkernel   TARGET=arm64 TARGET_ARCH=aarch64 KERNCONF=VZ
#
# Produces $IMG, a raw image with an EFI + UFS layout, configured headless with
# a getty on the virtio console (ttyV0.0) and root SSH key login.
#
# Environment overrides: SRC (src tree), IMG (output), SSHKEY (authorized key),
# IMGSIZE.
set -e

SRC="${SRC:-/usr/src}"
IMG="${IMG:-/tmp/freebsd-vz.img}"
IMGSIZE="${IMGSIZE:-8G}"
MNT=/mnt/vzimg
ESP=/mnt/vzesp
export TARGET=arm64 TARGET_ARCH=aarch64

if [ -z "${SSHKEY:-}" ]; then
	echo "Set SSHKEY to an authorized public key line, e.g.:" >&2
	echo "  SSHKEY=\"\$(cat ~/.ssh/id_ed25519.pub)\" doas sh mkimg.sh" >&2
	exit 1
fi

echo "=== create + partition $IMG ($IMGSIZE) ==="
rm -f "$IMG"
truncate -s "$IMGSIZE" "$IMG"
md=$(mdconfig -a -t vnode -f "$IMG")
gpart create -s gpt "$md"
gpart add -t efi        -s 100M -l efiboot "$md"
gpart add -t freebsd-ufs        -l rootfs  "$md"
newfs -U -L rootfs "/dev/${md}p2" >/dev/null

echo "=== mount ==="
mkdir -p "$MNT" "$ESP"
mount "/dev/${md}p2" "$MNT"
newfs_msdos -F 16 "/dev/${md}p1" >/dev/null   # FAT16: a 100M ESP is too small for FAT32
mount -t msdosfs "/dev/${md}p1" "$ESP"

echo "=== installworld / installkernel(VZ) / distribution ==="
make -C "$SRC" installworld  DESTDIR="$MNT" >/dev/null
make -C "$SRC" installkernel KERNCONF=VZ DESTDIR="$MNT" >/dev/null
make -C "$SRC" distribution  DESTDIR="$MNT" >/dev/null

echo "=== EFI loader ==="
mkdir -p "$ESP/EFI/BOOT"
cp "$MNT/boot/loader.efi" "$ESP/EFI/BOOT/BOOTAA64.EFI"

echo "=== system config ==="
cat > "$MNT/etc/fstab" <<EOF
/dev/gpt/rootfs   /   ufs   rw   1   1
EOF

cat > "$MNT/etc/rc.conf" <<EOF
hostname="fbsdvz"
ifconfig_vtnet0="DHCP"
sshd_enable="YES"
growfs_enable="YES"
EOF

# Apple VZ workarounds:
#  - boot_verbose MUST stay unset (verbose early enumeration spins forever).
#  - VZ's virtio-net rejects the full offload feature set; trim it or vtnet0
#    fails feature negotiation (attach error 45).
cat > "$MNT/boot/loader.conf" <<EOF
autoboot_delay="3"
hw.vtnet.csum_disable="1"
hw.vtnet.tso_disable="1"
hw.vtnet.lro_disable="1"
hw.vtnet.mq_disable="1"
EOF

# Force a getty on the virtio console so a login is always available there.
if grep -q '^ttyV0.0' "$MNT/etc/ttys"; then
	sed -i '' 's|^ttyV0.0.*|ttyV0.0 "/usr/libexec/getty 3wire" vt100 on secure|' "$MNT/etc/ttys"
else
	echo 'ttyV0.0 "/usr/libexec/getty 3wire" vt100 on secure' >> "$MNT/etc/ttys"
fi

echo "=== root ssh key ==="
mkdir -p "$MNT/root/.ssh"; chmod 700 "$MNT/root/.ssh"
echo "$SSHKEY" > "$MNT/root/.ssh/authorized_keys"; chmod 600 "$MNT/root/.ssh/authorized_keys"
cat >> "$MNT/etc/ssh/sshd_config" <<EOF
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
EOF
# Empty root password so console login also works (SSH stays key-only).
sed -i '' 's|^root:[^:]*:|root::|' "$MNT/etc/master.passwd"
pwd_mkdb -d "$MNT/etc" -p "$MNT/etc/master.passwd"

echo "=== unmount ==="
umount "$ESP"; umount "$MNT"; mdconfig -d -u "${md#md}"
echo "=== DONE: $IMG ==="
ls -lh "$IMG"
