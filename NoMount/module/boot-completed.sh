#!/system/bin/sh

NOMOUNT_DATA="/data/adb/nomount"
LOG_FILE="$NOMOUNT_DATA/nomount.log"
BOOT_SEMAPHORE="$NOMOUNT_DATA/.booting"

if [ -f "$BOOT_SEMAPHORE" ]; then
    rm -f "$BOOT_SEMAPHORE"
    echo "[OK] Boot completed safely." >> "$LOG_FILE"
else
    # Module disabled / skip_mount this boot
    # or metamount.sh already cleaned up to avoid bootloop
    exit 0
fi
