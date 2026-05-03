▶️ Cara pakai

Mode interaktif (aman):

chmod +x provision-home-on-secondary.sh
sudo ./provision-home-on-secondary.sh

Mode otomatis (CI / provisioning):

sudo ./provision-home-on-secondary.sh --yes

Override device (kalau mau spesifik):

sudo DEVICE_OVERRIDE=/dev/mmcblk1 ./provision-home-on-secondary.sh --yes


---

🧠 Catatan desain

Proteksi root disk: script membaca findmnt / lalu menghindari disk tersebut.

Idempotent: jika /home sudah ada di fstab, akan di-update, bukan diduplikasi.

Rollback: kalau mount gagal, /home dikembalikan dari /home_backup.

Opsi mount: noatime,nodiratime,nofail → cocok untuk SD (minim write & boot tetap lanjut).

rsync flags: -aAXH menjaga permission, ACL, xattr, hardlink.

---
