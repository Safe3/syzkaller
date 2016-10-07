#!/bin/bash
# Copyright 2016 syzkaller project authors. All rights reserved.
# Use of this source code is governed by Apache 2 LICENSE that can be found in the LICENSE file.

# create-gce-image.sh creates a minimal bootable image suitable for syzkaller/GCE.
# The image will have password-less root login with gce.key key.
#
# Prerequisites:
# - you need a user-space system, a basic Debian system can be created with:
#   sudo debootstrap --include=openssh-server,curl,tar,time,strace stable debian
# - you need qemu-nbd, grub and maybe something else:
#   sudo apt-get install qemu-utils grub
# - you need nbd support in kernel, if it's compiled as module do:
#   sudo modprobe nbd
# - you need kernel to use with image (e.g. arch/x86/boot/bzImage)
#   note: kernel modules are not supported
#
# Usage:
#   sudo ./create-gce-image.sh /dir/with/user/space/system /path/to/bzImage
#
# The image can then be uploaded to GCS with:
#   gsutil cp disk.tar.gz gs://my-images
# and then my-images/disk.tar.gz can be used to create new GCE bootable image.
#
# The image can be tested locally with e.g.:
#   qemu-system-x86_64 -hda disk.raw -net user,host=10.0.2.10,hostfwd=tcp::10022-:22 -net nic -enable-kvm -m 2G -display none -serial stdio
# once the kernel boots, you can ssh into it with:
#   ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -p 10022 -i gce.key root@localhost

set -eux

if [ "$(id -u)" != "0" ]; then
	echo "create-gce-image.sh must be run under root"
	exit 1
fi

if [ ! -e $1/sbin/init ]; then
	echo "usage: create-gce-image.sh /dir/with/user/space/system /path/to/bzImage"
	exit 1
fi

if [ "$(basename $2)" != "bzImage" ]; then
	echo "usage: create-gce-image.sh /dir/with/user/space/system /path/to/bzImage"
	exit 1
fi

if [ "$(grep nbd0 /proc/partitions)" != "" ]; then
	echo "/dev/nbd0 is already in use, try sudo qemu-nbd -d /dev/nbd0"
	exit 1
fi

fallocate -l 2G disk.raw
qemu-nbd -c /dev/nbd0 --format=raw disk.raw
mkdir -p disk.mnt
echo -en "o\nn\np\n1\n2048\n\na\n1\nw\n" | fdisk /dev/nbd0
until [ -e /dev/nbd0p1 ]; do sleep 1; done
mkfs.ext4 /dev/nbd0p1
mount /dev/nbd0p1 disk.mnt
cp -a $1/. disk.mnt/.
cp $2 disk.mnt/vmlinuz
sed -i "/^root/ { s/:x:/::/ }" disk.mnt/etc/passwd
echo "V0:23:respawn:/sbin/getty 115200 hvc0" >> disk.mnt/etc/inittab
echo -en "\nauto eth0\niface eth0 inet dhcp\n" >> disk.mnt/etc/network/interfaces
echo "debugfs /sys/kernel/debug debugfs defaults 0 0" >> disk.mnt/etc/fstab
echo "debug.exception-trace = 0" >> disk.mnt/etc/sysctl.conf
echo -en "127.0.0.1\tlocalhost\n" > disk.mnt/etc/hosts
echo "nameserver 8.8.8.8" >> disk.mnt/etc/resolve.conf
echo "ClientAliveInterval 420" >> disk.mnt/etc/ssh/sshd_config
echo "syzkaller" > disk.mnt/etc/hostname
rm -f gce.key gce.key.pub
ssh-keygen -f gce.key -t rsa -N ""
mkdir -p disk.mnt/root/.ssh
cp gce.key.pub disk.mnt/root/.ssh/authorized_keys
mkdir -p disk.mnt/boot/grub
cat << EOF > disk.mnt/boot/grub/grub.cfg
terminal_input console
terminal_output console
set timeout=0
menuentry 'linux' --class gnu-linux --class gnu --class os {
	insmod vbe
	insmod vga
	insmod video_bochs
	insmod video_cirrus
	insmod gzio
	insmod part_msdos
	insmod ext2
	set root='(hd0,1)'
	linux /vmlinuz root=/dev/sda1 console=ttyS0,38400n8 debug console=ttyS0 earlyprintk=serial ftrace_dump_on_oops=orig_cpu oops=panic panic_on_warn=1 panic=86400
}
EOF
grub-install --boot-directory=disk.mnt/boot --no-floppy /dev/nbd0
umount disk.mnt
rm -rf disk.mnt
qemu-nbd -d /dev/nbd0
tar -Szcf disk.tar.gz disk.raw