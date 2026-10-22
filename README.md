# Linux sur Samsung Galaxy A71 (SM-A715F)

Faire tourner un **vrai Linux** (Alpine + OpenRC) sur un Galaxy A71 : terminal,
SSH, Internet — sans Android.

> **État** : Linux 6.18 démarre, l'écran est piloté par DRM, **5,4 Gio de RAM**
> utilisables, réseau USB (RNDIS + ECM), **SSH + Internet**, système
> persistant sur carte SD en ext4, **Alpine avec OpenRC**, `apk` fonctionnel.
> Wi-Fi : pilote présent, service QMI WLFW non disponible sur SM7150.

## 🚀 Installer

👉 **[docs/QUICKSTART.md](docs/QUICKSTART.md)** — ~30 min, sans rien compiler.
Les fichiers prêts sont dans [`dist/`](dist).

```bash
git clone https://github.com/MattDev-974/Samsung-A71-Linux
cd Samsung-A71-Linux
sudo ./scripts/a71-setup.sh          # questions + écriture sur la carte SD
sudo ./scripts/a71-install.sh boot   # flash du noyau (Download mode)
ssh root@172.16.42.1                 # après démarrage
```

## Ce qui fonctionne

| Domaine | Détail |
|---|---|
| Noyau | 6.18.0-rc1, fork `WiiPlayer2/linux-sm7150` |
| Mémoire | 5,4 Gio utilisables (carte mémoire réelle du DT downstream) |
| Écran | DRM `msm_dpu` + panneau `s6e3fa9-amb667um06` |
| Réseau | gadget USB RNDIS (`172.16.42.1`) + ECM (`172.16.43.1`) |
| SSH | OpenSSH, clé et/ou mot de passe, réglable à l'installation |
| Système | Alpine 3.22, OpenRC, `apk`, `chronyd`, `dnsmasq`, `tzdata` |
| Persistance | carte SD ext4 directe (27 Go libres) ou image loop |
| Horloge | NTP par IP au démarrage (sans DNS ni TLS) |
| Wi-Fi | `ath10k_snoc` compilé, modules chargés — **QMI WLFW manquant** |

## Architecture

```
sboot → BOOT (boot.img)
          └── uniLoader  →  Image + DTB mainline + initramfs
                → noyau → sélecteur (carte SD / image / RAM)
                → /init → /sbin/init (busybox) → OpenRC
```

Images construites en deux couches (voir [docs/BUILD.md](docs/BUILD.md)) :

```
base/                  surcouche déclarative versionnée
scripts/build-base.sh  Alpine + surcouche → out/a71-base.tar.gz
scripts/a71-setup.sh   base + configuration → carte SD
scripts/a71-install.sh flash du noyau / installation
```

## Documentation

| Document | Contenu |
|---|---|
| [QUICKSTART](docs/QUICKSTART.md) | installation pas à pas pour utilisateur |
| [INSTALL](docs/INSTALL.md) | détail de l'assistant (questions, effets) |
| [BUILD](docs/BUILD.md) | construction reproductible des images |
| [MODES](docs/MODES.md) | modes de démarrage (RAM, SD, image, USERDATA) |
| [OPENRC](docs/OPENRC.md) | init, services, piège du PID 1 |
| [PACKAGES](docs/PACKAGES.md) | `apk`, certificats, horloge |
| [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) | pannes connues et correctifs |
| [DISPLAY](docs/DISPLAY.md) | mise au point de l'affichage |
| [BOOT-PROGRESS](docs/BOOT-PROGRESS.md) | journal de mise au point du boot |
| [probes/](docs/probes/) | sondes assembleur et journalisation sur carte SD |

## Dépôt

```
base/        surcouche rootfs (init, services, modules, CA…)
dist/        artefacts publiés (boot.img, base, heimdall, SHA256SUMS)
scripts/     build, installation, flash, utilitaires
docs/        documentation
artifacts/   entrées de build (android.dtb, kernel.config)
```

## Crédits

- noyau : [WiiPlayer2/linux-sm7150](https://github.com/WiiPlayer2/linux-sm7150)
- chargeur : [ivoszbg/uniLoader](https://github.com/ivoszbg/uniLoader) (PR #130)
- référence : [Nura Wiki — Samsung Galaxy A71](https://wiki.nura.eco/wiki/Samsung_Galaxy_A71_(samsung-a71))

## Licence

Voir [LICENSE](LICENSE).
