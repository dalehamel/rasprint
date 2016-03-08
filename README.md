[![ci status](https://travis-ci.org/dalehamel/rasprint.svg)](https://travis-ci.org/dalehamel/rasprint)

# RasPrint

RasPrint creates a single-purpose OS that runs an AirPrint server.

[![oh god](http://i.imgur.com/mSG1f72.jpg)](https://www.youtube.com/watch?v=8d_hveJL4mU&t=0m21s)

# Building

It's recommended to set up a debian-based LXC container (for a clean build environment), or else run in some debian-based system where you have root.

Once you've got that, just run build.sh. This will:

* Set up an arm rootfs with debootstrap
* Grab qemu-arm-static, so that you can fake being an arm processor
* Build the rootfs and kernel

# Printer support

I specifically needed this to work with Dymo LabelManager printers, so I added some extra plug'n'play support for them.

Other printers should be supported as well, but you'll need to manually configure them via the CUPS web address.
