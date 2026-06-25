#!/bin/bash
set -e

ORANGEPI_IP=$1
KERNEL_VERSION="6.18.24-current-sunxi"
BOOT_MOUNT="/media/mmcblk0p1"

# Módulos extras para carregar no boot
EXTRA_MODULES="sun8i_thermal"

if [ -z "$ORANGEPI_IP" ]; then
    echo "Usage: ./install.sh <orangepi-ip>"
    exit 1
fi

echo "==> Copying kernel..."
rsync -av output/vmlinuz-${KERNEL_VERSION} root@${ORANGEPI_IP}:${BOOT_MOUNT}/boot/

echo "==> Copying u-boot img..."
rsync -av u-boot/u-boot-armbian.bin root@${ORANGEPI_IP}:${BOOT_MOUNT}/u-boot-armbian.bin

echo "==> Copying DTBs..."
rsync -av output/dtbs/ root@${ORANGEPI_IP}:${BOOT_MOUNT}/boot/dtbs-lts/

echo "==> Copying modules to RAM..."
ssh root@${ORANGEPI_IP} "
    # /lib/modules é symlink para /.modloop (squashfs, RO)
    # Remove symlink para permitir escrita no tmpfs
    rm -f /lib/modules
    mkdir -p /lib/modules/${KERNEL_VERSION}
"
rsync -av --no-links \
    output/lib/modules/${KERNEL_VERSION}/ \
    root@${ORANGEPI_IP}:/lib/modules/${KERNEL_VERSION}/

echo "==> Installing dependencies..."
ssh root@${ORANGEPI_IP} "apk add squashfs-tools mkinitfs"

echo "==> Creating new modloop..."
ssh root@${ORANGEPI_IP} "mksquashfs /lib/modules ${BOOT_MOUNT}/boot/modloop-sunxi -comp xz -noappend"

echo "==> Configuring mkinitfs..."
ssh root@${ORANGEPI_IP} "cat > /etc/mkinitfs/mkinitfs.conf << 'EOFCONF'
features=\"ata base ide scsi usb virtio ext4 mmc sunxi squashfs overlayfs\"
EOFCONF"

ssh root@${ORANGEPI_IP} "cat > /etc/mkinitfs/features.d/mmc.modules << 'EOFCONF'
kernel/drivers/mmc
kernel/drivers/mmc/core/mmc_block.ko.gz
kernel/drivers/regulator
EOFCONF"

ssh root@${ORANGEPI_IP} "cat > /etc/mkinitfs/features.d/sunxi.modules << 'EOFCONF'
kernel/drivers/mmc/host/sunxi-mmc.ko.gz
EOFCONF"

echo "==> Generating initramfs..."
# Gera ANTES de restaurar o symlink, enquanto /lib/modules ainda está no tmpfs
ssh root@${ORANGEPI_IP} "
    mkdir -p /boot
    mkinitfs -k ${KERNEL_VERSION} -o /boot/initramfs-sunxi
    cp /boot/initramfs-sunxi ${BOOT_MOUNT}/boot/initramfs-sunxi
"

echo "==> Restoring /lib/modules symlink..."
# Restaura DEPOIS de gerar o initramfs
ssh root@${ORANGEPI_IP} "
    rm -rf /lib/modules
    ln -sf /.modloop /lib/modules
"

echo "==> Updating extlinux.conf..."
ssh root@${ORANGEPI_IP} "cat > ${BOOT_MOUNT}/extlinux/extlinux.conf << EOFCONF
TIMEOUT 10
PROMPT 1
DEFAULT sunxi
LABEL sunxi
MENU LABEL Linux current-sunxi
KERNEL /boot/vmlinuz-${KERNEL_VERSION}
INITRD /boot/initramfs-sunxi
FDTDIR /boot/dtbs-lts
APPEND modules=loop,squashfs,sd-mod,usb-storage,mmc_block,sunxi-mmc modloop=/boot/modloop-sunxi modloop_sign=no console=ttyS0,115200 quiet
EOFCONF"

echo ""
echo "==> Verifying extlinux.conf..."
ssh root@${ORANGEPI_IP} "cat ${BOOT_MOUNT}/extlinux/extlinux.conf"
echo ""

echo "==> Configuring extra modules via local.d..."
ssh root@${ORANGEPI_IP} "
    # Remover workaround do /etc/profile se existir
    sed -i '/modloop\|sun8i_thermal/d' /etc/profile

    # Criar script de init para symlink e módulos extras
    mkdir -p /etc/local.d
    cat > /etc/local.d/modules.start << 'EOF'
#!/bin/sh
# Garantir que /lib/modules aponta para o modloop
ln -sf /.modloop /lib/modules

# Carregar módulos extras
for mod in ${EXTRA_MODULES}; do
    modprobe \$mod 2>/dev/null || true
done
EOF
    chmod +x /etc/local.d/modules.start

    # Habilitar serviço local no boot
    rc-update add local default 2>/dev/null || true
"

echo "==> Configuring lbu..."
ssh root@${ORANGEPI_IP} "
    grep -q '^LBU_BACKUPDIR' /etc/lbu/lbu.conf \
        && sed -i 's|^LBU_BACKUPDIR=.*|LBU_BACKUPDIR=${BOOT_MOUNT}|' /etc/lbu/lbu.conf \
        || echo 'LBU_BACKUPDIR=${BOOT_MOUNT}' >> /etc/lbu/lbu.conf
    sed -i 's|^LBU_MEDIA=.*||' /etc/lbu/lbu.conf
"

echo "==> Configuring fstab..."
ssh root@${ORANGEPI_IP} "
    grep -q mmcblk0p1 /etc/fstab \
        || echo '/dev/mmcblk0p1  /media/mmcblk0p1  vfat  noauto  0  0' >> /etc/fstab
"

echo "==> Configuring apk cache..."
ssh root@${ORANGEPI_IP} "setup-apkcache ${BOOT_MOUNT}/cache"

echo "==> Committing state to disk (lbu)..."
ssh root@${ORANGEPI_IP} "lbu commit -d"

echo "==> Updating u-boot..."
ssh root@${ORANGEPI_IP} "dd if=${BOOT_MOUNT}/u-boot-armbian.bin of=/dev/mmcblk0 bs=8k seek=1"

echo "==> Installation complete!"
echo "    Review the output above before rebooting."
echo "    To reboot: ssh root@${ORANGEPI_IP} reboot"
