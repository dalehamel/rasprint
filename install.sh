#!/bin/bash

set -x -e

SYSTEM_SIZE=512
STORAGE_SIZE=32 # STORAGE_SIZE must be >= 32 !
DISK_SIZE=$(( $SYSTEM_SIZE + $STORAGE_SIZE + 4 ))
DISK="os.img"

# create an image
echo "image: creating file $(basename $DISK)..."
dd if=/dev/zero of="$DISK" bs=1M count="$DISK_SIZE" conv=fsync

parted -s "$DISK" mklabel msdos
sync

# create part1
echo "image: creating part1..."
SYSTEM_PART_END=$(( $SYSTEM_SIZE * 1024 * 1024 / 512 + 2048 ))
parted -s "$DISK" -a min unit s mkpart primary fat32 2048 $SYSTEM_PART_END
parted -s "$DISK" set 1 boot on
sync

## create part2
#  echo "image: creating part2..."
#  STORAGE_PART_START=$(( $SYSTEM_PART_END + 2048 ))
#  STORAGE_PART_END=$(( $STORAGE_PART_START + (( $STORAGE_SIZE * 1024 * 1024 / 512 )) ))
#  parted -s "$DISK" -a min unit s mkpart primary ext4 $STORAGE_PART_START $STORAGE_PART_END
#  sync

OFFSET=$(( 2048 * 512 ))
HEADS=4
TRACKS=32
SECTORS=$(( $SYSTEM_SIZE * 1024 * 1024 / 512 / $HEADS / $TRACKS ))

mformat -i $DISK@@$OFFSET -h $HEADS -t $TRACKS -s $SECTORS ::

find boot ! -name boot | while read file; do
  target="${file//boot}"
  echo $target
  if [ -d $file ];then
    destdir=$target
  else
    destdir=$(dirname $target)
  fi
  mmd -D s -i $DISK@@$OFFSET $destdir || true
  [ ! -d $file ] && mcopy -i $DISK@@$OFFSET $file "::$(dirname $target)"
done

## extract part2 from image to format and copy files
#  echo "image: extracting part2 from image..."
#  STORAGE_PART_COUNT=$(( $STORAGE_PART_END - $STORAGE_PART_START + 1 ))
#  sync
#  dd if="$DISK" of="$OE_TMP/part2.ext4" bs=512 skip="$STORAGE_PART_START" count="$STORAGE_PART_COUNT" conv=fsync >"$SAVE_ERROR" 2>&1 || show_error
#
## create filesystem on part2
#  echo "image: creating filesystem on part2..."
#  mke2fs -F -q -t ext4 -m 0 "$OE_TMP/part2.ext4"
#  tune2fs -U $UUID_STORAGE "$OE_TMP/part2.ext4" >"$SAVE_ERROR" 2>&1 || show_error
#  e2fsck -n "$OE_TMP/part2.ext4" >"$SAVE_ERROR" 2>&1 || show_error
#  sync
