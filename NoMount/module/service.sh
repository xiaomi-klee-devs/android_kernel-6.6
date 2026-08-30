#!/system/bin/sh

MODDIR=${0%/*}
NM_BIN="$MODDIR/bin/nm"
EXCLUSION_JSON="/data/adb/nomount/.exclusion_list.json"

[ -x "$NM_BIN" ] || exit 0
[ -f "$EXCLUSION_JSON" ] || exit 0

grep -o '"uid":"[0-9]*"' "$EXCLUSION_JSON" | cut -d'"' -f4 | while IFS= read -r uid; do
    [ -n "$uid" ] && "$NM_BIN" uid add "$uid" >/dev/null 2>&1
done
