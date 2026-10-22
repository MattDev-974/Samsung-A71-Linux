# Chargeur d'amorçage (initramfs)

`init` est le **PID 1 de l'initramfs** embarqué dans `boot.img` (via
uniLoader). Il choisit la racine puis passe la main au système.

```
1. ext4 directement sur la carte   /dev/mmcblk2[p1/p2]  → switch_root
2. sinon, partition FAT32 + /a71.mode :
     sd            → image /a71-rootfs.ext4 montée en loop
     sd:<fichier>  → image donnée
3. sinon                              → mode RAM (/sbin/a71-system)
```

Le fichier est copié dans l'initramfs sous `/init` par `scripts/build-rootfs.sh`,
puis uniLoader l'embarque dans `boot.img`.

Détails des modes : [../docs/MODES.md](../docs/MODES.md).
