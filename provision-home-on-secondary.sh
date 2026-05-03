cat << 'EOF' > provision-home-on-secondary.sh
#!/usr/bin/env bash
set -euo pipefail

LOG="/var/log/provision-home.log"
exec > >(tee -a "$LOG") 2>&1

YES=0
DEVICE_OVERRIDE="${DEVICE_OVERRIDE:-}"   # contoh: /dev/mmcblk1
PART_OVERRIDE="${PART_OVERRIDE:-}"       # contoh: /dev/mmcblk1p1
FS_LABEL="${FS_LABEL:-HOME_SD}"
MNT_TMP="/mnt/_home_migrate"
FSTAB="/etc/fstab"

usage() {
  echo "Usage: $0 [--yes] [--device /dev/xxx] [--part /dev/xxx1]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --device) DEVICE_OVERRIDE="$2"; shift 2 ;;
    --part) PART_OVERRIDE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

echo "[i] Starting provisioning at $(date)"

root_src="$(findmnt -no SOURCE /)"
root_disk="/dev/$(lsblk -no PKNAME "$root_src")"
echo "[i] Root source: $root_src (disk: $root_disk)"

pick_device() {
  if [[ -n "$DEVICE_OVERRIDE" ]]; then
    echo "$DEVICE_OVERRIDE"; return
  fi
  # Ambil disk non-removable? Untuk SBC, mmcblk1 biasanya SD.
  # Pilih disk terbesar yang BUKAN root_disk.
  lsblk -dn -o NAME,SIZE,TYPE | awk '$3=="disk"{print "/dev/"$1" "$2}' \
    | while read -r dev size; do
        if [[ "$dev" != "$root_disk" ]]; then
          echo "$dev"
        fi
      done \
    | sort -k2 -h | tail -n1 | awk '{print $1}'
}

DEVICE="$(pick_device)"
if [[ -z "${DEVICE:-}" ]]; then
  echo "[-] Tidak menemukan device target."
  exit 1
fi

echo "[i] Target device: $DEVICE"

# Tentukan partisi target
if [[ -n "$PART_OVERRIDE" ]]; then
  PART="$PART_OVERRIDE"
else
  # gunakan partisi pertama jika ada, kalau tidak buat
  if lsblk -no NAME "$DEVICE" | grep -qE "^$(basename "$DEVICE")p?1$"; then
    # handle mmcblkX (p1) vs sdX (1)
    if [[ "$DEVICE" =~ mmcblk ]]; then PART="${DEVICE}p1"; else PART="${DEVICE}1"; fi
  else
    PART=""
  fi
fi

confirm() {
  local msg="$1"
  if [[ "$YES" -eq 1 ]]; then return 0; fi
  read -r -p "$msg [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# Buat partisi jika belum ada
if [[ -z "$PART" ]]; then
  echo "[i] Membuat partisi tunggal pada $DEVICE"
  confirm "Ini akan menghapus isi $DEVICE. Lanjut?" || exit 1
  # wipe signature agar fdisk bersih
  wipefs -a "$DEVICE"
  # buat 1 partisi linux
  if command -v sfdisk >/dev/null 2>&1; then
    echo ',,L' | sfdisk "$DEVICE"
  else
    fdisk "$DEVICE" <<FDISK
g
n


w
FDISK
  fi
  partprobe "$DEVICE"
  sleep 2
  if [[ "$DEVICE" =~ mmcblk ]]; then PART="${DEVICE}p1"; else PART="${DEVICE}1"; fi
fi

echo "[i] Target partition: $PART"

# Cek filesystem
FSTYPE="$(blkid -o value -s TYPE "$PART" || true)"
if [[ "$FSTYPE" != "ext4" ]]; then
  echo "[i] Format $PART ke ext4"
  confirm "Format $PART (hapus data)? Lanjut?" || exit 1
  mkfs.ext4 -L "$FS_LABEL" -F "$PART"
fi

# Mount sementara
mkdir -p "$MNT_TMP"
if mount | grep -q "on $MNT_TMP "; then umount "$MNT_TMP"; fi
mount "$PART" "$MNT_TMP"

# Copy /home
echo "[i] Rsync /home -> $MNT_TMP"
rsync -aAXH --delete /home/ "$MNT_TMP/"

# Backup /home jika belum
if [[ ! -d /home_backup ]]; then
  echo "[i] Backup /home -> /home_backup"
  mv /home /home_backup
  mkdir /home
fi

# Ambil UUID
UUID="$(blkid -s UUID -o value "$PART")"
echo "[i] UUID: $UUID"

# Tambah/replace entry fstab
ENTRY="UUID=$UUID  /home  ext4  defaults,noatime,nodiratime,nofail  0  2"

if grep -qE "\s/home\s" "$FSTAB"; then
  echo "[i] Updating existing /home entry in fstab"
  # ganti baris /home
  sed -i -E "s#^.*\s/home\s.*#${ENTRY//#/\\#}#g" "$FSTAB"
else
  echo "[i] Adding new /home entry to fstab"
  echo "$ENTRY" >> "$FSTAB"
fi

# Test mount
echo "[i] Testing mount -a"
umount /home || true
mount -a

# Verifikasi
if mount | grep -q "on /home type ext4"; then
  echo "[+] /home mounted successfully"
else
  echo "[-] /home mount failed, attempting rollback"
  umount "$MNT_TMP" || true
  rm -rf /home
  mv /home_backup /home
  exit 1
fi

echo "[+] Done. Reboot recommended."
echo "[i] Log: $LOG"
EOF
