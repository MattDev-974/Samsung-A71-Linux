# Linux sur Samsung Galaxy A71 (SM-A715F)

Alpine + OpenRC sur carte SD, noyau #35, USB ECM/RNDIS, SSH, Internet.

> **État** : serveur USB/SSH validé ; GPU initialisé avec les firmwares
> locaux, mais **aucun rendu GLES validé** (`eglChooseConfig` a échoué).
> Wi-Fi, Bluetooth et audio sont expérimentaux et bloqués.

## Installateur

```sh
git clone git@github.com:MattDev-974/Samsung-A71-Linux.git
cd Samsung-A71-Linux
./install.sh --profile server       # recommandé
./install.sh --profile desktop-open # Mesa/Freedreno, GPU complet non garanti
./install.sh --profile desktop-local --samsung-firmware ZIP --recovery-boot IMG
```

- `server` : rootfs/OpenRC/ECM/RNDIS/SSH/chrony/a71-clock, sans Mesa ni ZAP.
- `desktop-open` : server + Mesa/Freedreno + SQE/GMU redistribuables.
- `desktop-local` : ajoute le ZAP Samsung fourni localement ; sortie privée
  `LOCAL_ONLY / NOT_REDISTRIBUTABLE`.

Wi-Fi, Bluetooth et audio ne sont proposés ni dans les profils ni dans le menu.
Aucun firmware Samsung n’est distribué. Aucun flash automatique.

## Réseau

- ECM principal : téléphone `10.71.0.2/30`, hôte `10.71.0.1` ;
- RNDIS secours : téléphone `172.16.42.1/24`.

## GPU

SQE et GMU officiels sont chargés ; le ZAP local est accepté au boot observé.
Le test Mesa s’arrête à `eglChooseConfig` ; aucun contexte/FBO/soumission GLES
n’est validé. Le développement GPU est gelé.

## Documentation

- [INSTALLER](docs/INSTALLER.md)
- [PROFILES](docs/PROFILES.md)
- [SERVER](docs/SERVER.md)
- [DESKTOP-OPEN](docs/DESKTOP-OPEN.md)
- [DESKTOP-LOCAL](docs/DESKTOP-LOCAL.md)
- [INSTALLER-MIGRATION](docs/INSTALLER-MIGRATION.md)
- [GPU](docs/GPU.md)
- [EXPERIMENTAL-WIFI](docs/EXPERIMENTAL-WIFI.md)
- [EXPERIMENTAL-AUDIO](docs/EXPERIMENTAL-AUDIO.md)

## Licence

Voir [LICENSE](LICENSE).
