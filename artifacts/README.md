# Artefacts compilés

Images prêtes à flasher, produites par `./build.sh` (noyau 6.18, branche
`2025-10-13-display` du fork, config postmarketOS SM7150, `DRM_MSM` désactivé).

| Fichier | Taille | Rôle |
|---|---|---|
| `boot-uniloader.img` | 36 M | image boot v2 : uniLoader + noyau + DTB + rootfs |
| `boot-direct.img` | 36 M | image boot v2 : noyau gzip + initramfs + DTB |
| `uniLoader.img` | 36 M | binaire uniLoader brut (payload embarqué) |
| `initramfs.cpio.gz` | 14 M | rootfs Alpine aarch64 (SSH, USB réseau, Wi-Fi) |
| `Image` | 23 M | noyau Linux 6.18 non compressé |
| `dtb` | 86 K | device tree `sm7150-samsung-a715f` |
| `kernel.config` | 226 K | configuration du noyau |
| `SHA256SUMS` | — | empreintes |

**État : ces images ne démarrent pas encore sur l'appareil** (voir
`docs/TESTLOG.md`) : le noyau s'exécute mais se fige avant la console/l'init.
`boot-uniloader.img` est l'image à privilégier pour continuer le débogage.

Restauration d'un téléphone fonctionnel : reflasher le `boot.img` du firmware
stock (ou de LineageOS) avec `heimdall flash --BOOT boot.img`.
