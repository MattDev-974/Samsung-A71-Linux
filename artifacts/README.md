# Artefacts compilés

Images prêtes à flasher, produites à partir du noyau 6.18 (branche
`2025-10-13-display` du fork), config postmarketOS SM7150, `DRM_MSM` désactivé.

| Fichier | Taille | Rôle |
|---|---|---|
| `boot-uniloader-fixed.img` | 37 M | **image corrigée** : uniLoader + noyau + rootfs complet, DTB Android dans l'en-tête |
| `boot-uniloader-small.img` | 24 M | même chose mais initramfs vide (diagnostic, atteint « Booting kernel… ») |
| `boot-direct.img` | 36 M | noyau gzip + initramfs + DTB Android dans l'en-tête |
| `uniLoader.img` | 36 M | binaire uniLoader brut (noyau + DTB mainline + rootfs embarqués) |
| `initramfs.cpio.gz` | 14 M | rootfs Alpine aarch64 (SSH, USB réseau, Wi-Fi) |
| `Image` | 23 M | noyau Linux 6.18 non compressé |
| `dtb` | 86 K | device tree mainline `sm7150-samsung-a715f` (pour uniLoader) |
| `android.dtb` | 388 K | device tree Android/Lineage, **obligatoire dans l'en-tête du boot.img** |
| `kernel.config` | 226 K | configuration du noyau |
| `SHA256SUMS` | — | empreintes |

## Pourquoi deux DTB ?

Le bootloader Samsung (`sboot`) refuse un `boot.img` dont la section `dtb`
contient le device tree mainline : il retombe immédiatement en Download mode.
C'est la cause du symptôme « uniLoader ne démarre même pas ».

La solution : mettre le **DTB Android/Lineage** (`android.dtb`, extrait du
`boot.img` LineageOS) dans l'en-tête, et laisser uniLoader embarquer le DTB
mainline (au-dessus du noyau).

## État

Ces images **atteignent « Booting kernel… »** mais le noyau se fige ensuite
avant la console/l'init (`docs/TESTLOG.md`).
`boot-uniloader-small.img` est le meilleur candidat pour continuer le
débogage (créneau noyau de 24 Mo, taille déjà validée).

Restauration d'un téléphone fonctionnel : reflasher le `boot.img` du firmware
stock ou de LineageOS.
