#!/bin/bash
set -x
set -e

ADMIN_USERNAME=rasprint
ADMIN_PASSWORD=rasprint
ROOT=/u/pi/
ROOTFS=$ROOT/rootfs
BOOT=$ROOT/boot
DISTRO=trusty
INCLUDE="net-tools,wget,isc-dhcp-client,vim,busybox-static,iputils-ping,usbutils,sudo,ca-certificates,openssh-server" # FIXME - don't include openssh in final build?
GLOBAL_EXCLUDE_PATTERN=('usr/src' 'var/lib/apt/lists/*' 'var/cache/apt/archives/*' 'var/cache/apt/*.bin')

# Helper to execute in chroot
cexec()
{
  chroot $ROOTFS $@
}

####################################################################################
# Host side preparations
####################################################################################

setup()
{
  apt-get -f install -y qemu-user-static debootstrap git bc squashfs-tools mtools
  
  # Prepare the chroot
  mkdir -p $ROOTFS
  debootstrap --arch armhf --foreign --variant minbase --include $INCLUDE $DISTRO $ROOTFS http://ports.ubuntu.com
  cp `which qemu-arm-static` $ROOTFS/usr/bin/
  
  # Finish debootstrap in chroot with emulated arm processor
  cexec /debootstrap/debootstrap --second-stage
}

####################################################################################
# Start system setup
####################################################################################

config()
{
  # Set up core system config files
  echo "deb http://ports.ubuntu.com trusty main universe" > $ROOTFS/etc/apt/sources.list
  echo "/dev/mmcblk0p2 / ext4 auto,noatime,nobootwait 1 2" > $ROOTFS/etc/fstab
  cat > $ROOTFS/etc/network/interfaces.d/eth0 <<EOF
auto eth0
iface eth0 inet dhcp
EOF

  cat > $ROOTFS/etc/sudoers <<EOF
Defaults      !lecture,tty_tickets,!fqdn

# User privilege specification
root          ALL=(ALL) ALL

# Members of the group 'sysadmin' may gain root privileges
%sysadmin ALL=(ALL) NOPASSWD:ALL
# Members of the group 'admin' may gain root privileges
%admin ALL=(ALL) NOPASSWD:ALL
# Members of the group 'sudo' may gain root privileges
%sudo ALL=(ALL) NOPASSWD:ALL

#includedir /etc/sudoers.d
EOF

  # Update apt now that sources have been set
  cexec apt-get update

}

cups_setup()
{
  # Set up the dymo drivers
  cat > $ROOTFS/tmp/compile.sh <<EOF
apt-get -f install -y --force-yes build-essential cups libcups2-dev libcupsfilters-dev libcupsimage2-dev

cd /tmp
wget https://github.com/dalehamel/dymo-cups-drivers/archive/master.tar.gz
tar -xvpf master.tar.gz
cd dymo-cups-drivers-master/

./configure
make
make install
EOF
  cexec bash /tmp/compile.sh

  # Configure cups
  cat > $ROOTFS/etc/cups/cupsd.conf <<EOF
# Allow remote access
Port 631
Listen *:631  # If cups is only listening on localhost:631, then you won't be able to see any shared printers
Listen /var/run/cups/cups.sock

JobRetryInterval 5 # retry failed jobs after 5 seconds if retry policy set

# Share local printers on the local network.
Browsing On
BrowseLocalProtocols dnssd
BrowseOrder allow,deny
BrowseAllow @LOCAL
DefaultAuthType Basic

<Location />
  # Allow shared printing...
  Order allow,deny
  Allow @LOCAL  ## Allow local connections
  Require user @SYSTEM # Require user to authenticate as an actual system user on first use
</Location>
EOF

}

admin_user()
{
  # Set up admin user
  cexec useradd -G sudo -m $ADMIN_USERNAME || true
  cexec usermod -a -G lpadmin $ADMIN_USERNAME || true
  cexec passwd $ADMIN_USERNAME << EOF
$ADMIN_PASSWORD
$ADMIN_PASSWORD
EOF
}

usb_configure()
{
  # Configure dymo-printer specific udev and usb-modeswitch rules
  # this forces the printer into printer mode, rather than mass storage
  # from https://github.com/dalehamel/dymoprint
  cexec apt-get -f install -y usb-modeswitch usb-modeswitch-data

  cat > $ROOTFS/usr/local/bin/add_printer << EOF
#!/bin/bash

add_printer()
{
  printer=\$1

  if [[ \$printer == *"Wireless"* ]]; then
    ppd=/usr/share/cups/model/lmwpnp.ppd
  else
    ppd=/usr/share/cups/model/lmpnp.ppd
  fi

  if ! grep -q \$printer /etc/cups/printers.conf; then

    lpadmin \
          -p 'DymoPi' \
          -v \$printer \
          -m 'Dymo label manager' \
          -P \$ppd \
          -L 'Raspberry Pi' \
          -o 'job-sheets=none, none' \
          -o 'media=om_w18h252_6.21x88.9mm' \
          -o 'sides=one-sided' \
          -E
    lpadmin -p DymoPi -o printer-error-policy=retry-job
  fi
}

add_printers()
{
  lpinfo -v | grep 'direct usb' | awk '{print \$2}' | while read printer; do
    add_printer \$printer
  done
}

case \$1 in

"wired")
  /usr/sbin/usb_modeswitch -c /etc/usb_modeswitch.d/dymo-labelmanager-pnp.conf
  ;;
"wireless")
  /usr/sbin/usb_modeswitch -c /etc/usb_modeswitch.d/dymo-labelmanager-wifi-pnp.conf
  ;;
*)
  echo "Must specify wired or wireless"
  exit
esac

add_printers
EOF

  chmod +x $ROOTFS/usr/local/bin/add_printer
  
  cat > $ROOTFS/etc/udev/rules.d/91-dymo-labelmanager-pnp.rules << EOF
# DYMO LabelManager PNP
SUBSYSTEMS=="usb", ATTRS{idVendor}=="0922", ATTRS{idProduct}=="1001", \
RUN+="/usr/local/bin/add_printer wired"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="0922", ATTRS{idProduct}=="1002", MODE="0660", GROUP="plugdev"
#
#SUBSYSTEM=="hidraw", ACTION=="add", ATTRS{idVendor}=="0922", ATTRS{idProduct}=="1001", GROUP="plugdev"
EOF

  cat > $ROOTFS/etc/usb_modeswitch.d/dymo-labelmanager-pnp.conf << EOF
# Dymo LabelManager PnP

DefaultVendor= 0x0922
DefaultProduct=0x1001 # for wired

TargetVendor=  0x0922
DefaultProduct=0x1002 # for wired

MessageEndpoint= 0x01
ResponseEndpoint=0x01

MessageContent="1b5a01"
EOF

  cat > $ROOTFS/etc/udev/rules.d/92-dymo-labelmanager-wifi-pnp.rules << EOF
# DYMO LabelManager PNP
SUBSYSTEMS=="usb", ATTRS{idVendor}=="0922", ATTRS{idProduct}=="1007", \
RUN+="/usr/local/bin/add_printer wireless"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="0922", ATTRS{idProduct}=="1008", MODE="0660", GROUP="plugdev"
#
#SUBSYSTEM=="hidraw", ACTION=="add", ATTRS{idVendor}=="0922", ATTRS{idProduct}=="1007", GROUP="plugdev"
EOF

  cat > $ROOTFS/etc/usb_modeswitch.d/dymo-labelmanager-wifi-pnp.conf << EOF
# Dymo LabelManager Wireless PnP

DefaultVendor= 0x0922
DefaultProduct=0x1007 # for wireless

TargetVendor=  0x0922
TargetProduct= 0x1008 # for wireless

MessageEndpoint= 0x01
ResponseEndpoint=0x01

MessageContent="1b5a01"
EOF

}

locale_gen()
{
  cexec locale-gen en_US.UTF-8
}


####################################################################################
# End system setup
####################################################################################

####################################################################################
# Kernel setup
####################################################################################

kernel_build()
{
  rm -rf $BOOT
  mkdir -p $BOOT
  cd $ROOT
  
  # https://www.raspberrypi.org/documentation/linux/kernel/building.md
  # Get the arm cross-build toolchain
  [ -d $ROOT/tools ] || git clone https://github.com/raspberrypi/tools
  cd $ROOT/tools && git fetch && git reset --hard origin/master && cd $ROOT
  export PATH=$ROOT/tools/arm-bcm2708/gcc-linaro-arm-linux-gnueabihf-raspbian-x64/bin/:$PATH
  
  # Get the kernel
  [ -d $ROOT/linux ] || git clone --depth=1 https://github.com/raspberrypi/linux
  cd $ROOT/linux && git fetch && git reset --hard origin/master && cd $ROOT
  
  # Build the kernel
  cd $ROOT/linux
  KERNEL=kernel7 # ASSUMES RPi2
  cp $ROOT/kernconf $ROOT/linux/.config
  make -j`nproc` ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- zImage modules dtbs
  
  # Install modules
  make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- INSTALL_MOD_PATH=$ROOTFS modules_install
}


generate_initramfs()
{
  cd $ROOT/linux
  kversion=$(strings arch/arm/boot/Image  | grep -i modversions | awk '{print $1}')
  
  ########################
  # Initramfs setup
  ########################
  
  # Install live boot, which will be needed for generating live initramfs
  cexec apt-get -f install -y live-boot

  # Newer kernels renamed overlayfs to overlay, and require a workdir.
  patch  -B  /tmp/gargbage -r - --forward $ROOTFS/lib/live/boot/9990-misc-helpers.sh < $ROOT/9990-misc-helpers.patch

  cexec update-initramfs -c -k $kversion
  cp $ROOTFS/boot/initrd.img-$kversion $BOOT/initrd.img  
}

live_system()
{
  mkdir -p $BOOT/live
  mksquashfs $ROOTFS $BOOT/live/image.squashfs -wildcards -e ${GLOBAL_EXCLUDE_PATTERN[*]} ${EXCLUDE_PATTERN[*]}

  cat > $BOOT/live/boot.conf << EOF
toram # load entire system to ram
union=overlayfs  # Allow a r/w system using overlayfs
                 # Note overlayfs isn't documented, but appears to be supported
EOF
}

########################
# Boot directory setup
########################

package_boot_dir()
{
  cd $ROOT/linux
  echo "dwc_otg.lpm_enable=0 console=ttyAMA0,115200 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline rootwait boot=live live-media=/dev/mmcblk0p1 union=overlayfs ip=frommedia" > $BOOT/cmdline.txt

  cat > $BOOT/config.txt << EOF
initramfs initrd.img
EOF
  # Copy kernel to BOOT
  ./scripts/mkknlimg arch/arm/boot/zImage $BOOT/kernel.img
  
  # Set up device tree binaries
  cp arch/arm/boot/dts/*.dtb $BOOT
  mkdir -p $BOOT/overlays/
  cp arch/arm/boot/dts/overlays/*.dtb* $BOOT/overlays/
  
  # Copy magic firmware files
  
  cd /tmp
  wget https://github.com/raspberrypi/firmware/archive/master.tar.gz
  tar -xpf master.tar.gz
  cp /tmp/firmware-master/boot/bootcode.bin $BOOT
  cp /tmp/firmware-master/boot/fixup_x.dat $BOOT/fixup.dat
  cp /tmp/firmware-master/boot/start_x.elf $BOOT/start.elf
}

setup
config
cups_setup
admin_user
usb_configure
locale_gen
kernel_build
generate_initramfs
live_system
package_boot_dir

# Final install process (commented out intentionally)
# tar -C $ROOTFS -cpf - . | sudo tar -C /mnt/usb/ -xpf -
# tar -C $BOOT -cpf - . | sudo tar -C /mnt/boot -xpf -
