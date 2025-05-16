#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Device filter regex, defaults to match all devices
DEVICE_FILTER=${DEVICE_FILTER:-".*"}
# The path relative to /nvme to create a symlink to the device (e.g. my-disk)
RELATIVE_SYMLINK_PATH=${RELATIVE_SYMLINK_PATH:-"disk"}

ABSOLUTE_SYMLINK_PATH="/nvme/$RELATIVE_SYMLINK_PATH"

# TODO: grepping '/dev' here can potentially override the root disk if it's an NVMe device. We should make it configurable.
ALL_SSD_NVME_DEVICE_LIST=$(nvme list | grep "/dev" | cut -d " " -f 1 || true)

SSD_NVME_DEVICE_LIST=()

for device in $ALL_SSD_NVME_DEVICE_LIST; do
    # Check if the device matches the filter
    if [[ "$device" =~ $DEVICE_FILTER ]]; then
        # Check if the device has partitions
        if ! lsblk -n -o NAME | grep -q "$(basename $device)p"; then
            # Check if the device is mounted
            if ! mount | grep -q "$device"; then
                # If not mounted and no partitions, add to the array
                SSD_NVME_DEVICE_LIST+=("$device")
            fi
        fi
    else
        echo "Device $device does not match filter pattern $DEVICE_FILTER, skipping"
    fi
done

echo "Found ${#SSD_NVME_DEVICE_LIST[@]} NVMe devices matching filter pattern: $DEVICE_FILTER"
if [ ${#SSD_NVME_DEVICE_LIST[@]} -gt 0 ]; then
    echo "Devices: ${SSD_NVME_DEVICE_LIST[*]}"
fi

SSD_NVME_DEVICE_COUNT=${#SSD_NVME_DEVICE_LIST[@]}
RAID_DEVICE=${RAID_DEVICE:-/dev/md0}
RAID_CHUNK_SIZE=${RAID_CHUNK_SIZE:-512}  # Kilo Bytes
FILESYSTEM_BLOCK_SIZE=${FILESYSTEM_BLOCK_SIZE:-4096}  # Bytes
STRIDE=$((RAID_CHUNK_SIZE * 1024 / FILESYSTEM_BLOCK_SIZE))
STRIPE_WIDTH=$((SSD_NVME_DEVICE_COUNT * STRIDE))

mkdir -p /nvme
mkdir -p /pv-disks

# Checking if provisioning already happened for this instance
case $SSD_NVME_DEVICE_COUNT in
"0")
    echo "No devices found of type \"NVMe Instance Storage\""
    echo "Maybe your node selectors or device filter are not set correctly"
    exit 1
    ;;
"1")
    echo "Single device mode, no RAID device needed"
    # UUID will only be set if the device is already formatted
    UUID=$(blkid -s UUID -o value "${SSD_NVME_DEVICE_LIST[0]}")
    if [ -n "$UUID" ]; then
        echo "Device ${SSD_NVME_DEVICE_LIST[0]} is already formatted with UUID $UUID"
        DEVICE="${SSD_NVME_DEVICE_LIST[0]}"
        # Double check that the device is of type ext4
        TYPE=$(blkid -s TYPE -o value "$DEVICE")
        if [ "$TYPE" != "ext4" ]; then
            echo "Device $DEVICE is formatted but not of type ext4, exiting"
            exit 1
        fi
    else
        echo "Device ${SSD_NVME_DEVICE_LIST[0]} is not formatted, will format it"
    fi
    ;;
*)
    # On some system (OCI cloud) the raid device id might change after reboot. Try to guess it
    RAID_DEVICES_OUTPUT=$(mdadm --detail --scan | awk '{print $2}')
    RAID_DEVICES_COUNT=$(echo "$RAID_DEVICES_OUTPUT" | wc -l)
    case $RAID_DEVICES_COUNT in
    "0")
        echo "No RAID devices found, will create new one"
        ;;
    *)
        # If RAID devices exist, try to find the one with matching devices
        MATCHING_RAID_DEVICE=""
        for raid_device in $RAID_DEVICES_OUTPUT; do
            DEVICE_MEMBERS=$(mdadm --detail "$raid_device" | grep -o "/dev/[^ ]$*" | sort)
            EXPECTED_MEMBERS=$(echo "${SSD_NVME_DEVICE_LIST[@]}" | tr ' ' '\n' | sort)
            echo "Checking RAID device $raid_device with NVMe devices $DEVICE_MEMBERS"
            if [ "$DEVICE_MEMBERS" = "$EXPECTED_MEMBERS" ]; then
                MATCHING_RAID_DEVICE=$raid_device
                break
            fi
            if [ -n "$(comm -12 <(echo "$DEVICE_MEMBERS") <(echo "$EXPECTED_MEMBERS"))" ]; then
                echo "RAID device $raid_device has overlapping but not exactly matching NVMe devices, exiting to avoid corrupting it."
                exit 1
            fi
        done
        if [ -n "$MATCHING_RAID_DEVICE" ]; then
            RAID_DEVICE=$MATCHING_RAID_DEVICE
            echo "Found matching RAID device $RAID_DEVICE"
            echo "Trying to assemble $RAID_DEVICE"
            # check if raid has already been started and is clean, if not try to assemble
            mdadm --detail "$RAID_DEVICE" 2>/dev/null | grep clean >/dev/null || mdadm --assemble "$RAID_DEVICE" "${SSD_NVME_DEVICE_LIST[@]}"
            # print details to log
            mdadm --detail "$RAID_DEVICE"
            DEVICE=$RAID_DEVICE
        else
            echo "No matching RAID device found, will create new one"
        fi
        ;;
    esac

esac

if [ -n "${DEVICE:-}" ]; then
    # If the device exists and is already mounted, just go to sleep.
    if mount | grep "$DEVICE" > /dev/null; then
      echo "Device $DEVICE appears to be mounted already"
      UUID=$(blkid -s UUID -o value "$DEVICE")
      ln -s "/pv-disks/$UUID" "$ABSOLUTE_SYMLINK_PATH" || true
      echo "NVMe SSD provisioning is done and I will go to sleep now"
      while sleep 3600; do :; done
    fi
else
    # No matching device found, create a new one.
    case $SSD_NVME_DEVICE_COUNT in
    "0")
        echo 'No devices found of type "NVMe Instance Storage"'
        echo "Maybe your node selectors or device filter are not set correctly"
        exit 1
        ;;
    "1")
        mkfs.ext4 -m 0 -b "$FILESYSTEM_BLOCK_SIZE" "${SSD_NVME_DEVICE_LIST[0]}"
        DEVICE="${SSD_NVME_DEVICE_LIST[0]}"
        ;;
    *)
        mdadm --create --verbose "$RAID_DEVICE" --level=0 -c "${RAID_CHUNK_SIZE}" \
            --raid-devices=${#SSD_NVME_DEVICE_LIST[@]} "${SSD_NVME_DEVICE_LIST[@]}"
        while [ -n "$(mdadm --detail "$RAID_DEVICE" | grep -ioE 'State :.*resyncing')" ]; do
            echo "Raid is resyncing.."
            sleep 1
        done
        echo "Raid0 device $RAID_DEVICE has been created with disks ${SSD_NVME_DEVICE_LIST[*]}"
        mkfs.ext4 -m 0 -b "$FILESYSTEM_BLOCK_SIZE" -E "stride=$STRIDE,stripe-width=$STRIPE_WIDTH" "$RAID_DEVICE"
        DEVICE=$RAID_DEVICE
        ;;
    esac
    UUID=$(blkid -s UUID -o value "$DEVICE")
fi

mkdir -p "/pv-disks/$UUID"
mount -o defaults,noatime,discard,nobarrier --uuid "$UUID" "/pv-disks/$UUID"
ln -s "/pv-disks/$UUID" "$ABSOLUTE_SYMLINK_PATH"
echo "Device $DEVICE has been mounted to /pv-disks/$UUID"
echo "NVMe SSD provisioning is done and I will go to sleep now"

while sleep 3600; do :; done
