# Linux « minimum syndical » pour Samsung Galaxy A71 (samsung-a71)

Image Linux bootable pour le **Galaxy A71 (SM-A715F / A715F/DS)**, construite
à partir des sources référencées par la page
[Nura Wiki — Samsung Galaxy A71](https://wiki.nura.eco/wiki/Samsung_Galaxy_A71_(samsung-a71)) :
noyau mainline [WiiPlayer2/linux-sm7150](https://github.com/WiiPlayer2/linux-sm7150)
(branche `device/samsung-a71`) et support
[uniLoader PR #130](https://github.com/ivoszbg/uniLoader/pull/130).

Objectif : **démarrer Linux, avoir un terminal et une connexion Internet**, rien
de plus. Pas d'interface graphique, pas de tactile, pas de téléphonie.

---

## 1. Résultat du build

Tout est dans `out/` :

| Fichier | Taille | Rôle |
|---|---|---|
| `Image` | 24 M | noyau Linux 6.11 (`-a71`), sans modules |
| `dtb` | 83 K | device tree `sm7150-samsung-a715f` + `bootargs` injectés |
| `initramfs.cpio.gz` | 14 M | système de fichiers complet (Alpine aarch64) |
| `uniLoader.img` | 38 M | chargeur uniLoader avec noyau + dtb + initramfs embarqués |
| `boot-uniloader.img` | 38 M | image boot Android v2, noyau = `uniLoader.img` |
| `boot-direct.img` | 38 M | image boot Android v2, noyau = `Image` (sans uniLoader) |
| `kernel.config` | 221 K | configuration du noyau utilisée |
| `SHA256SUMS` | — | empreintes des fichiers ci-dessus |

Les deux images font ~37 Mo, ce qui tient dans la partition `boot` d'un A71
(64 Mo) avec de la marge.

> **Vérifié sur appareil (21/10/2026)** : `artifacts/boot-uniloader-fixed.img`
> atteint « Booting kernel… » et ne retombe plus en Download mode.

**Important** : la section `dtb` du `boot.img` doit contenir le device tree
**Android/Lineage** (`android.dtb`, extrait du `boot.img` officiel), pas le DTB
mainline — sinon `sboot` retombe en Download mode. Le DTB mainline voyage
dans uniLoader.

### Ce que fait l'image au démarrage

1. Monte `proc`, `sysfs`, `devtmpfs`, `devpts`, `tmpfs`.
2. Expose le téléphone en carte réseau USB **RNDIS + CDC-ECM** (`configfs`),
   avec un serveur DHCP `dnsmasq` :
   - `172.16.42.1` sur `usb0` (RNDIS — Windows/Linux),
   - `172.16.43.1` sur `usb1` (ECM — Linux/macOS).
3. Lance **sshd** (clés d'hôte générées au build, pas de blocage entropie).
4. Lance un shell root sur la **console framebuffer** (`tty1`) et sur l'UART de
   debug (`ttyMSM0`).
5. Si `/etc/wpa_supplicant/wpa_supplicant.conf` existe, connecte le Wi-Fi
   (`wpa_supplicant` + `dhcpcd`), avec le firmware WCN3990 embarqué.

### Terminal et Internet : les deux chemins

- **Terminal** : `ssh root@172.16.42.1` par le câble USB (chemin le plus
  fiable, l'USB networking est marqué « Works » sur le wiki). Un clavier USB
  OTG ou un câble UART donnent aussi un shell local, mais l'écran seul ne
  suffit pas (pas de clavier intégré, tactile non supporté).
- **Internet** :
  - soit le téléphone se connecte en **Wi-Fi** (`wifi-connect "SSID" "motdepasse"`),
  - soit il **emprunte la connexion du PC** via le câble USB
    (`scripts/host-nat.sh` côté PC). Ce second chemin ne dépend pas du pilote
    Wi-Fi et fonctionne dès que l'USB réseau fonctionne.

---

## 2. Avertissement (à lire avant de flasher)

- **Déverrouillage du bootloader obligatoire** (option « Déverrouillage OEM »),
  ce qui **efface toutes les données** du téléphone et déclenche Knox.
- Flasher la partition `boot` avec une image non signée peut **briquer
  temporairement** l'appareil : gardez le firmware stock (`samloader`,
  SamFirm) pour restaurer `boot.img`.
- **Testée sur un A71 réel (SM-A715F) le 20/10/2026 : elle ne démarre pas
  encore.** Le bootloader accepte les images (voir §10), uniLoader s'exécute
  et affiche « Booting kernel... », mais le noyau mainline se fige juste
  après, sans sortie console et sans atteindre l'init. Le reste de la chaîne
  (rootfs, SSH, Wi-Fi) n'a donc pas pu être validé sur matériel.
- Le système vit **entièrement en RAM** (initramfs) : aucune persistance. La
  configuration Wi-Fi et tout fichier créé sont perdus au redémarrage.
- Aucune gestion de la batterie/charge, de l'audio, des caméras, du modem.

---

## 3. Construire

```bash
./build.sh
```

Prérequis : `bash`, `make`, `gcc`, `bison`, `flex`, `openssl`, `cpio`, `gzip`,
`python3`, `curl`, `tar`, `xz`, et la possibilité de créer un namespace
utilisateur (`unshare -r`, activé par défaut sur la plupart des distributions).
Compter ~10–15 min et ~1,5 Go d'espace libre (le toolchain et les sources sont
déjà dans le dépôt).

Le script enchaîne :

1. `scripts/build-kernel.sh` — cross-compile le noyau (GCC 13 Bootlin,
   `defconfig` + fragment `arch/arm64/configs/sm7150.config` + `configs/a71-extra.config`),
   puis injecte `bootargs` dans le DTB.
2. `scripts/build-rootfs.sh` — installe les paquets Alpine aarch64 avec
   `apk.static` (pas besoin de root), crée les liens busybox via qemu-user,
   configure sshd, génère les clés, emballe l'initramfs.
3. `scripts/build-boot.sh` — compile uniLoader (`a71_defconfig`), fabrique les
   images boot Android v2 avec `scripts/mkbootimg.py`.

Personnalisation :

```bash
ROOT_PASSWORD='autre-chose' ./scripts/build-rootfs.sh   # mot de passe root
ALPINE_BRANCH=v3.22 ./scripts/build-rootfs.sh           # version Alpine
A71_MODULES=1 ./scripts/build-kernel.sh                 # + modules (25 Mo)
```

> **Pourquoi ces détours ?** Le chemin du dépôt contient une espace
> (`Samsung A71`) et les Makefiles du noyau/uniLoader n'acceptent pas les
> espaces : les scripts se relancent dans `unshare -rm` en montant le dépôt
> sur `/mnt`. Le noyau est aussi le seul à exiger `bc` : un binaire `bc` est
> récupéré dans `build/tools/bcroot/` au premier build.

---

## 4. Flasher

1. Sauvegarder le firmware stock et vérifier que le bootloader est déverrouillé.
2. Éteindre le téléphone, puis **Volume Haut + Volume Bas + câble USB**
   (mode Download).
3. Flasher :

```bash
./scripts/flash.sh out/boot-uniloader.img     # chemin recommandé (uniLoader)
# ou, si uniLoader ne démarre pas :
./scripts/flash.sh out/boot-direct.img       # noyau mainline chargé en direct
```

Équivalent manuel :

```bash
heimdall detect
heimdall print-pit --no-reboot | grep -i boot
heimdall flash --BOOT out/boot-uniloader.img --no-reboot
```

Le script `flash.sh` demande confirmation et rappelle la commande de
restauration. Pour revenir en arrière : reflasher le `boot.img` du firmware
stock (`heimdall flash --BOOT boot.img`).

---

## 5. Utiliser

### Brancher le câble USB

Après démarrage, sur le PC :

```bash
dmesg | tail            # doit montrer un gadget 1d6b:0104
ip link                 # usb0 / enp0s20u1...
sudo ./scripts/host-nat.sh usb0   # (optionnel) partage Internet
ssh root@172.16.42.1
# mot de passe : a71
```

Sous Windows, l'interface RNDIS est configurée automatiquement en DHCP ; pour
l'Internet, activer le partage de connexion (ICS) sur cette interface.

### Wi-Fi

```bash
wifi-connect "MonSSID" "monMotDePasse"     # WPA2/WPA3-PSK
wifi-connect "ReseauOuvert"                # réseau ouvert
iw dev wlan0 link                          # état de l'association
ip -4 addr show wlan0
```

Le firmware `ath10k/WCN3990` est inclus (`.zst`, décompressé par le noyau).
Le pilote est compilé **dans** le noyau (`ATH10K_SNOC=y`), aucun module à
charger.

### Terminal local

- Écran : la console framebuffer (`simple-framebuffer` du bootloader) affiche
  le shell `tty1` — utilisable avec un clavier USB OTG.
- Debug : `ttyMSM0` sur les pads UART (si vous ouvrez le téléphone).

---

## 6. Détails techniques

### Noyau

- 6.11.0, branche `device/samsung-a71` (commit `a5cd6780b`), DTS
  `sm7150-samsung-a715f.dts`.
- Config : `defconfig` arm64 + `sm7150.config` (du dépôt noyau) +
  `configs/a71-extra.config` :
  - `CONFIG_CMDLINE_EXTEND`, `FRAMEBUFFER_CONSOLE`, `FB_SIMPLE` ;
  - gadget USB `CONFIGFS` RNDIS/ECM/NCM, `USB_DWC3_QCOM`, `PHY_QCOM_QUSB2` ;
  - Wi-Fi `ATH10K`/`ATH10K_SNOC` **built-in** (`RFKILL=y` et
    `QCOM_RPROC_COMMON=y` sont nécessaires pour éviter que Kconfig ne
    rétrograde cfg80211/mac80211 en modules) ;
  - `FW_LOADER_COMPRESS_ZSTD`, `DEVTMPFS_MOUNT`, initramfs gzip.
- `bootargs` injectés dans le DTB :
  `console=tty0 console=ttyMSM0,115200n8 consoleblank=0 loglevel=7`.

### Rootfs

Alpine 3.22 aarch64 (musl) : `busybox` (+ liens recréés), `openssh`
(client + serveur), `dnsmasq`, `dhcpcd`, `wpa_supplicant`, `iw`, `iproute2`,
`kmod`, `wireless-regdb`, `linux-firmware-ath10k` (pruné au WCN3990),
`ca-certificates`. Root SSH par mot de passe (`PermitRootLogin yes`), clés
d'hôte pré-générées.

### Image de boot

En-tête AOSP **v2** (magic `ANDROID!`, **page 4096**, section `dtb`).
`scripts/mkbootimg.py` est autonome (pas besoin de `mkbootimg`).

La section `dtb` de l'en-tête est le DTB **Android** (`android/dtb`, extrait
par `scripts/extract-dtb.py` depuis le `boot.img` LineageOS) : `sboot` refuse
le DTB mainline à cet endroit (retour Download mode). Le DTB mainline est
embarqué dans uniLoader.

Les adresses et la taille de page ont été relevées sur le `boot.img`
LineageOS 23.2 officiel de l'A71 (`kernel_addr=0x8000`,
`ramdisk_addr=0x1000000`, `tags=0x100`, `dtb_addr=0x1f00000`, page 4096,
en-tête v2) : nos images reproduisent ce profil. Ce `boot.img` fait
exactement 64 Mio (partition `boot`), ce qui confirme que nos 38 Mo passent.

### uniLoader

Compilé depuis `src/uniLoader` (branche `pr130`, commit `b253dc4`,
`a71_defconfig`). Il embarque `Image`, `dtb` et `initramfs`, copie le noyau en
`0xaa200000` et le ramdisk en `0xa1c17000`, puis démarre le noyau avec le DTB
patché (`linux,initrd-start/end`). Le framebuffer est déclaré en
`0x9c000000` (1080×2400, ARGB8888), comme dans le device tree.

---

## 7. Vérifications effectuées / non effectuées

Effectué :

- compilation complète du noyau (Image 23 Mo) et du DTB A71, avec la config
  postmarketOS officielle `config-postmarketos-qcom-sm7150.aarch64` ;
- rootfs aarch64 construit, busybox exécuté sous qemu-user (`uname -m` →
  `aarch64`), `dnsmasq --test` OK, scripts/configs vérifiés ;
- structure des images boot validée et comparée au `boot.img` LineageOS 23.2
  officiel de l'A71 (en-tête v2, page 4096, mêmes adresses, 64 Mio) ;
- flash réel via heimdall : `BOOT upload successful` à 100 % ;
- démarrage réel : LineageOS démarre (bootloader déverrouillé, images non
  signées acceptées), et un test « noyau LineageOS + notre initramfs » démarre
  bien le noyau.

Non effectué / bloqué :

- **le noyau mainline se fige immédiatement après « Booting kernel... »**,
  aucune sortie console, aucun panic enregistré dans pstore, et une sonde
  (init qui repeint l'écran) montre qu'il n'atteint jamais l'espace
  utilisateur. Testé avec deux configs (defconfig+fragments puis config pmOS)
  et deux adresses de chargement, sans changement ;
- le DTB mainline placé dans le `boot.img` est refusé par le bootloader
  Samsung (retour immédiat en Download mode) : seul le DTB Android/Lineage
  est accepté dans l'en-tête. D'où le montage uniLoader (DTB Android dans
  l'en-tête, DTB mainline embarqué dans uniLoader) ;
- écran/tactile/Wi-Fi/SSH sur matériel : non validés, puisque le noyau ne
  démarre pas.

## 8. Arborescence

```
build.sh                 orchestrateur (noyau → rootfs → images)
configs/a71-extra.config  fragments de config noyau ajoutés
rootfs/                   overlay du rootfs (init, usb-gadget, wifi-connect)
scripts/
  build-kernel.sh         cross-compile + DTB bootargs
  build-rootfs.sh         apk.static aarch64 + initramfs
  build-boot.sh           uniLoader + images boot
  mkbootimg.py            assembleur d'image boot Android v2
  dtb-bootargs.py         injection de /chosen/bootargs
  flash.sh                flash heimdall
  host-nat.sh             partage Internet côté PC
src/kernel                linux-sm7150 (device/samsung-a71)
src/uniLoader             uniLoader (pr130)
src/pmaports, src/pmbootstrap  clones upstream (non utilisés : le fork
                          pmaports-a71 du wiki n'est pas accessible publiquement)
toolchain/                GCC 13 Bootlin aarch64 (archive)
build/                    objets intermédiaires (supprimable)
out/                      livrables
```

## 9. Journal des tests sur l'appareil (20/10/2026)

Matériel : SM-A715F, bootloader déverrouillé, LineageOS 23.2 installé,
heimdall construit depuis les sources (voir plus bas).

1. `heimdall print-pit` : 74 partitions, dont `BOOT`, `VBMETA`,
   `VBMETA_SAMSUNG` ; `boot.img` LineageOS = exactement 64 Mio.
2. `heimdall flash --BOOT out/boot-uniloader.img` → 100 %, mais au reboot le
   téléphone revient en Download mode.
3. `boot-direct.img` → idem.
4. Image « noyau LineageOS + notre initramfs » → le noyau démarre (logo figé),
   ce qui prouve que le bootloader accepte nos images.
5. uniLoader + noyau mainline + mini-initramfs → uniLoader affiche
   `passed board initialization`, `trying to open fdt...`,
   `adding linux,initrd-start...`, `Booting kernel...` puis plus rien.
6. Tests complémentaires, tous négatifs : `nokaslr`, chargement du noyau à
   `0x80080000` au lieu de `0xaa200000`, config `VA_BITS=48` (pmOS) au lieu
   de 52, DTB d'origine (sans nos `bootargs`), mini-init qui repeint l'écran,
   qui redémarre après 30 s, ou qui redémarre immédiatement (`reboot -f`) :
   rien ne montre que le noyau atteint l'init. Le log pstore récupéré via
   `adb root` ne contient que des logs du noyau Android (aucun panic mainline).
7. Build « comme le porteur » : config pmOS + `make modules` +
   `modules_install` (25 Mo de modules dans `build/modroot`, release
   `6.11.0-a71+`). Les modules ne changent rien au blocage, qui se produit
   avant l'espace utilisateur.
8. Preuve que le noyau et le rootfs sont bons : le même `Image` + le même
   `initramfs.cpio.gz` démarrés dans QEMU (`-M virt`) affichent la bannière
   `Galaxy A71 (samsung-a71) - minimal Linux` et exécutent `/init`. Le
   blocage est donc spécifique au matériel A71 (bring-up précoce), pas à
   l'image.
9. Test avec la DTS complète de la branche liée par le wiki (2024-12-08,
   1037 lignes : régulateurs, `vph_pwr`, aliases, dalle), avec `DRM_MSM`
   désactivé et sans dépendance d'horloge sur le framebuffer : toujours figé,
   sans console.

### Sondes bas niveau (harness uniLoader)

uniLoader a servi de harnais : on remplace le noyau par un payload de quelques
dizaines d'octets qui répond en couleurs sur le framebuffer. Résultats :

| Sonde | Résultat | Interprétation |
|---|---|---|
| peinture (40 o) | jaune | uniLoader copie et saute correctement |
| état CPU | EL1, MMU off, caches off | état d'entrée attendu par Linux |
| magie FDT | vert | le DTB passé en x0 est un FDT valide |
| `smc #0` (PSCI_VERSION) | vert | les appels SMC depuis EL1 fonctionnent |
| copie du noyau vers `0xAA280000` | vert seulement | la copie s'arrête (RAM haute > 2,6 Go ?) |
| payload 21 Mo, stub à la fin | bleu | **aucune troncature** par le bootloader |
| DTB mainline dans l'en-tête boot.img | Download mode | **sboot refuse notre DTB** (seul le DTB Android est accepté) |
| noyau chargé à `0x80080000` (RAM basse) | figé | la RAM basse ne change rien au blocage |
| entrée du noyau patchée (copie en RAM basse, marqueurs vert/jaune/blanc/bleu) | **bleu** | **le noyau s'exécute** ; le blocage est après son entrée |
| lecture de `0xa1300000` (ramoops) depuis un payload | jaune (bloqué) | zone peut-être protégée, mais sondes devenues intermittentes → à confirmer |

À noter : la sonde « taille du FDT » avait d'abord donné rouge, mais
`fdt_open_into()` fait passer `totalsize` à la taille du buffer (500 000) :
c'était un faux négatif, le DTB est bien valide.

Par ailleurs, un `boot.img` de 9,9 Mo (noyau gzip + mini-initramfs + DTB
mainline) retourne aussi en Download mode : ce n'est pas un problème de
taille, mais le bootloader refuse le DTB mainline dans l'en-tête (il
n'accepte que le DTB Android/Lineage, comme le montre le test « noyau
LineageOS + notre initramfs » qui démarre).

### Vérifier le noyau dans QEMU

```bash
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 1G \
  -kernel out/Image -initrd out/initramfs.cpio.gz -nographic -net none \
  -append "console=ttyAMA0 earlycon=pl011,0x9000000"
```

(QEMU peut être récupéré sans root depuis les paquets Arch, comme fait ici
dans `build/qemu`.)

Pistes pour la suite :

- console série sur les pads UART (`ttyMSM0`) : c'est le seul moyen fiable de
  voir où le noyau se bloque ;
- reconstruire le noyau exactement comme le porteur (pmaports + pmbootstrap,
  avec les modules et la config `linux-postmarketos-qcom-sm7150` de l'époque) ;
- vérifier `CONFIG_ARM64_VA_BITS`, `CONFIG_RELOCATABLE`, les réservations
  mémoire du DTB et l'adresse de chargement attendue par uniLoader ;
- comparer avec une image postmarketOS existante pour un autre appareil
  sm7150 (davinci/surya) qui démarre sur le même SoC.

### heimdall

heimdall 1.4.2 (dernière version) a besoin de deux correctifs pour dialoguer
avec ce bootloader :

- `libusb_reset_device()` avant le handshake (PR #478) ;
- timeout du handshake porté à 5 s.

Sans cela : `Failed to receive handshake response` puis, après une session,
`Failed to send handshake` jusqu'au redémarrage du téléphone en Download mode.

## 10. Progression du démarrage et affichage

`docs/DISPLAY.md` documente la corruption de l'écran : constats, tests
réalisés et causes possibles (auto-rafraîchissement du panneau, alimentations
non gérées, mode incohérent, DSI/PHY non initialisés).

`docs/BOOT-PROGRESS.md` documente l'instrumentation du noyau (marqueurs
`a71_progress` + sonde de bandes) et les résultats : le noyau atteint
`start_kernel`, parse le DTB, détecte la RAM (après correctif du nœud
`memory@80000000`, qui vaut 0 dans le DTB mainline) et se bloque dans
`paging_init`/`map_mem`.

## 11. Dépôt et artefacts

- `artifacts/` : images compilées (36 M chacune) + `SHA256SUMS`, prêtes à
  flasher (elles ne démarrent pas encore, voir plus bas).
- `docs/SOURCES.md` : versions et commits épinglés de toutes les sources.
- `docs/TESTLOG.md` : journal détaillé des tests et des sondes.
- `docs/probes/` : sources assembleur des sondes.

## 11. Dépôt

- `docs/TESTLOG.md` : journal détaillé des tests sur appareil réel et des
  sondes bas niveau.
- `docs/probes/` : sources assembleur des sondes (payloads uniLoader).
- Le noyau 6.18 de la branche `2025-10-13-display` du fork a aussi été
  compilé et testé : même figement que 6.11.
- L'A71 n'est pas dans `sm7150-mainline/linux` upstream (DTS absente) et
  aucun fork public de pmaports ne contient de paquet `samsung-a71`.

## 11. Références

- [Nura Wiki — Samsung Galaxy A71](https://wiki.nura.eco/wiki/Samsung_Galaxy_A71_(samsung-a71))
- [Noyau : WiiPlayer2/linux-sm7150, branche device/samsung-a71](https://github.com/WiiPlayer2/linux-sm7150/tree/device/samsung-a71)
- [uniLoader — PR #130 (support A71)](https://github.com/ivoszbg/uniLoader/pull/130)
- [uniLoader](https://github.com/ivoszbg/uniLoader)
- [pmaports (fork A71, non accessible)](https://git.web.home.dark-link.info/a71-pmos/pmaports-a71/src/branch/device/samsung-a71)
- [LineageOS wiki — a71](https://wiki.lineageos.org/devices/a71/)
