#!/bin/bash -ue

usage() {
  echo "Usage: $0 <device or path>" >&2
}

if [ -z "$1" ]; then
  usage
  exit 1
fi

TARGET="$1"

if [ ! -e "$TARGET" ]; then
  echo "Error: '$TARGET' does not exist or is not accessible." >&2
  usage
  exit 1
fi

DEV="$(df -P "$TARGET" | awk 'NR==2 {print $1}')"

if [ "${DEV:0:1}" != "/" ]; then # We delved too deep!
  DEV="$TARGET"
fi

if [[ "$DEV" =~ ^/dev/mapper ]]; then # LVS?
  lvs -o +devices "$DEV" | awk 'NR > 1 {print $NF}' | while read -r subdev; do
    subdev=$(echo "$subdev" | sed 's/([0-9][0-9]*)$//') # Strip "(0)" and similar.
    $0 "$(realpath "$subdev")" || exit $?
  done
  exit 0
fi

if [[ "$DEV" =~ /dev/md ]]; then # MD?
  mdadm --detail "$DEV" | awk 'p==1 {print $NF} $2 == "Major" && $3 == "Minor" {p=1}' | while read -r subdev; do
    $0 "$subdev" || exit $?
  done
  exit 0
fi

if [[ "$DEV" =~ /dev/dm- ]]; then # DM?
  dmsetup deps "$DEV" | sed 's#.*: ##g; s#) (#)\n(#g; s#[(,)]##g;' | while read -r maj min; do
    $0 "$(udevadm info -rq name /sys/dev/block/"${maj}":"${min}")"
  done
  exit 0
fi

# De-partition-ize
if [ "${DEV:0:5}" == "/dev/" ] && [ -e "/sys/class/block/$(basename "$DEV")/partition" ]; then
  # nvme and nbd devices, amongst others, use the "abcXXpYY" format.  Let's try that first.
  maybedev="$(echo "$DEV" | sed '/[0-9]p[0-9][0-9]*$/s/p[0-9][0-9]*$//')"
  if [ -e "/sys/class/block/$(basename "$maybedev")/device" ]; then
    exec $0 "$maybedev" || exit $?
  fi
  # Most other devices just stick the partition number on the end.  That's our next test.
  maybedev="$(echo "$DEV" | sed 's/[0-9][0-9]*$//')"
  if [ -e "/sys/class/block/$(basename "$maybedev")/device" ]; then
    exec $0 "$maybedev" || exit $?
  fi
  # It's a partition, apparently, but we can't find the device.  Explode usefully.
  echo "Error: Unable to determine owning device for partition '$DEV' (or it's not really a partition?)." >&2
  exit 1
fi

if [ "$DEV" == "$TARGET" ]; then
  echo "$DEV"
  exit 0
fi

exec $0 "$DEV"
