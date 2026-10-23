# Audit du dépôt — état observé avant migration

**Date de l'audit** : 2026-10-22
**Portée** : dépôt `MattDev-974/Samsung-A71-Linux`, commit examiné
`3521250eae2decc6b9fa2fdf4256b753e575ecba` (SHA complet, observé localement avec
`git rev-parse HEAD`)
(branche `main`, 40 commits, aucun tag, aucune CI).
**Nature** : état **avant** migration. Ce document décrit ce qui existait à
cette date ; il ne correspond pas à l'état cible.

Ce document ne contient aucun secret.

## Comment lire ce document

Trois catégories sont distinguées de façon stricte :

| Marqueur | Signification |
|---|---|
| **[dépôt]** | observé directement dans les fichiers du dépôt |
| **[historique]** | documenté dans les docs du projet, non revérifié pendant cet audit |
| **[non vérifié]** | ni observé, ni documenté de façon fiable : à confirmer |

Aucune mesure sur appareil n'a été exécutée pendant cet audit. Les valeurs
« mesurées sur appareil » des documents historiques sont signalées comme telles
et ne sont pas présentées ici comme des vérifications.

## 1. Ce que le dépôt contient

- **deux chaînes de construction** :
  - chaîne « sources » : `build.sh` → `scripts/build-kernel.sh`,
    `scripts/build-rootfs.sh`, `scripts/build-boot.sh` — **[dépôt]** ;
  - chaîne « artefact » : `scripts/a71-setup.sh` + `scripts/a71-install.sh`,
    alimentée par `dist/` — **[dépôt]** ;
- une surcouche rootfs déclarative `base/` (init, services OpenRC, modules
  binaires, certificats) — **[dépôt]** ;
- un sélecteur d'initramfs `initramfs/init` — **[dépôt]** ;
- 15 scripts, 12 documents, 20 fichiers de sondes — **[dépôt]** ;
- `dist/` : `boot.img` (64 Mio), `a71-base.tar.gz` (21 Mo), `heimdall`
  (151 Ko), `SHA256SUMS` — **[dépôt]**.

## 2. Constats majeurs

| # | Constat | Catégorie |
|---|---|---|
| 1 | `build-kernel.sh` attend `src/kernel/`, `src/pmaports/`, `toolchain/…` : **absents du dépôt** | [dépôt] |
| 2 | `build-rootfs.sh` fait `cp -a "$ROOT/rootfs/."` alors que `rootfs/` a été supprimé → **script cassé** | [dépôt] |
| 3 | `build-boot.sh` attend `build/uniloader`, `android/dtb` : **absents** | [dépôt] |
| 4 | `a71-install.sh` a des chemins par défaut **hors dépôt** (`../work/…`) | [dépôt] |
| 5 | `initramfs/init` **n'est emballé par aucun script** (seul `docs/MODES.md` le cite) | [dépôt] |
| 6 | Détection de racine par **essais de montage ext4** sur une liste codée en dur ; aucun `LABEL=`/`UUID=` | [dépôt] |
| 7 | **Aucune vérification SHA-256** d'un téléchargement dans le dépôt | [dépôt] |
| 8 | `configs/a71-extra.config` contient `# CONFIG_DRM_MSM is not set`, **contraire** à l'image publiée (écran DRM fonctionnel d'après les docs) | [dépôt] |
| 9 | La configuration noyau complète de l'image publiée **n'est pas dans le dépôt** | [dépôt] |
| 10 | `base/lib/modules/*.ko` : 14 modules **binaires**, sans source ni commit vérifié | [dépôt] |
| 11 | `dist/` committé : artefacts finaux **non reproductibles** | [dépôt] |
| 12 | Pas de `install.sh`, pas de `manifest.yaml`, pas de tests, pas de CI | [dépôt] |

## 3. Paramètres matériels

### Vérifiés dans le dépôt

| Paramètre | Valeur | Où |
|---|---|---|
| Modèle | SM-A715F / SM-A715F/DS | `README.md`, `manifest.yaml` |
| Codename | `a71` | partout |
| SoC | Qualcomm SM7150 | `README.md`, DTS |
| Architecture | arm64 | scripts |
| Format boot.img | header **v2**, page **4096** | `scripts/mkbootimg.py` ; relevé dans `dist/boot.img` |
| DTB Android obligatoire dans la section `dtb` | oui | `scripts/build-boot.sh` |

### Vérifiés sur la source amont choisie par le projet (dépôt noyau tiers)

| Paramètre | Valeur | Méthode |
|---|---|---|
| Branche `2025-10-13-display` du dépôt noyau | SHA `5d80fcdbbb3fbf399d3db66b0f14497d11c9489a` | voir commande 1 |
| DTS du SM-A715F dans ce commit | `arch/arm64/boot/dts/qcom/sm7150-samsung-a715f.dts`, 20 100 octets, `compatible = "samsung,a715f", "qcom,sm7150"` | voir commande 2 |
| Version **déclarée** par les sources | `VERSION=6 PATCHLEVEL=18 SUBLEVEL=0 EXTRAVERSION=-rc1` → `6.18.0-rc1` | voir commande 3 |

Ce qui a été vérifié, et ce qui ne l'a pas été :

- le serveur GitHub **a annoncé** ce SHA pour cette branche (`git ls-remote` sous
  HTTPS) ;
- le **contenu HTTP** du fichier DTS à ce SHA était disponible (HTTP 200) ;
- **aucune signature Git** du commit ou de la branche n'a été vérifiée ;
- la provenance cryptographique du contenu n'est donc **pas** établie ;
- le contenu n'a pas été acquis par le futur pipeline vérifié (sha256/signature) :
  ce sera le rôle de la phase 2.

Commandes exactes exécutées le 2026-10-22 (**action réseau, informative, non
destructive**) :

```bash
# 1. verifier que le commit existe et quel est son SHA complet
git ls-remote https://github.com/WiiPlayer2/linux-sm7150 \
    refs/heads/2025-10-13-display
# -> 5d80fcdbbb3fbf399d3db66b0f14497d11c9489a	refs/heads/2025-10-13-display

# 2. verifier la presence de la DTS au meme commit
curl -sS -o /dev/null -w 'HTTP %{http_code} taille=%{size_download}\n' \
  https://raw.githubusercontent.com/WiiPlayer2/linux-sm7150/5d80fcdbbb3fbf399d3db66b0f14497d11c9489a/arch/arm64/boot/dts/qcom/sm7150-samsung-a715f.dts
# -> HTTP 200 taille=20100
curl -sS https://raw.githubusercontent.com/WiiPlayer2/linux-sm7150/5d80fcdbbb3fbf399d3db66b0f14497d11c9489a/arch/arm64/boot/dts/qcom/sm7150-samsung-a715f.dts | grep -E 'model|compatible'
# -> model = "Samsung Galaxy A71" ; compatible = "samsung,a715f", "qcom,sm7150"

# 3. verifier la version declaree par les sources
curl -sS https://raw.githubusercontent.com/WiiPlayer2/linux-sm7150/5d80fcdbbb3fbf399d3db66b0f14497d11c9489a/Makefile | head -5
# -> VERSION = 6 / PATCHLEVEL = 18 / SUBLEVEL = 0 / EXTRAVERSION = -rc1
```

Ces commandes utilisaient `curl -sS` en mode **informatif** : aucun artefact
produit par ces commandes n'est utilisé par la construction. Un HTTP 200 ne
constitue pas une validation d'intégrité. Les futurs scripts d'acquisition
devront utiliser `curl --fail --show-error --silent --location` **et** vérifier
un SHA-256 ou une signature avant tout usage.

**DTS n'est pas DTB** : la présence du fichier source `.dts` est vérifiée ; le
`.dtb` correspondant **n'a pas été compilé** dans cet environnement. Le manifeste
distingue donc `kernel.dts_source` (vérifié) et `kernel.dtb_output` (chemin
attendu, non produit ici).

**Version déclarée ≠ release construite** : `kernel.source_version` est lue dans
le `Makefile` du commit ; `kernel.expected_release` (`6.18.0-rc1-a71+`) est la
valeur historiquement observée dans `base/lib/modules/` ; `kernel.built_release`
vaut `TODO_BUILD` et ne pourra être renseigné que par une compilation réelle.
Le suffixe `+` est le marqueur ajouté par `scripts/setlocalversion` quand l'arbre
n'est pas sur un tag : cohérent, mais non reproduit ici.

### Documentés historiquement, non revérifiés

| Paramètre | Valeur | Source |
|---|---|---|
| RAM utilisable | 5,4 Gio (deux plages : 0x80000000 + 0x1_00000000) | `docs/TROUBLESHOOTING.md` [historique] |
| Taille de BOOT | 64 Mio | utilisé pour le padding, **aucun PIT dans le dépôt** [non vérifié] |
| Réseau USB | usb0 172.16.42.1, usb1 172.16.43.1, UDC `a600000.usb` | `base/`, `docs/` [historique] |
| Adresses boot.img | `0x8000`, `0x1000000`, `0x100`, `0x1f00000` | `scripts/mkbootimg.py`, commentaire « copiées de LineageOS 23.2 » [non vérifié] |
| Adresses uniLoader | `0xa4c00000`, `0xaa200000`, `0xa1c17000` | **absentes du dépôt** [non vérifié] |
| Wi-Fi | pilote `ath10k_snoc` compilé, service QMI WLFW indisponible | `docs/` [historique] |

## 4. Risques

1. **Destructif sans garde-fou** : `a71-install.sh sd` formate le périphérique
   passé en argument sans vérifier qu'il est amovible ni qu'il ne porte pas le
   système ; `make-sd-ext4.sh` fait `wipefs -a` après 5 secondes.
2. **`install_userdata`** formate `/dev/sda32` (données Android), valeur codée
   en dur, avec repli `mkfs.ext2` [dépôt].
3. **Flash sans contrôle** : pas de `print-pit`, pas de vérification de taille
   de BOOT, pas de vérification de modèle (SM-A716* non rejeté), pas de
   confirmation `FLASHER`, pas d'avertissement sur l'absence de restauration.
4. **Mot de passe root par défaut `a71`** dans `build-rootfs.sh`, **affiché**
   en fin de build.
5. **Binaires non tracés** : `qemu-aarch64-static`, `bc`, `apk.static`,
   `heimdall`, `android.dtb` — sans SHA-256 ni signature.
6. **Modules binaires** dans `base/` : incompatibilité silencieuse possible si
   le noyau change.

## 5. Écarts par rapport au cahier des charges

Absents : `install.sh`, `manifest.yaml`, `--dry-run`, `--check`, protections
de disque, `LABEL=A71ROOT`, vérification de taille de BOOT, reprise,
invalidation, tests, CI, avertissement de non-restauration Android.
Contraires : artefacts finaux committés, téléchargements non vérifiés,
versions flottantes (`v3.22`).

## 6. Plan de migration retenu

Sept phases : fondations → sources/noyau → rootfs → initramfs/boot.img →
microSD → heimdall → qualité. Chaque phase est validée avant la suivante ; la
chaîne legacy reste intacte pendant toute la migration.

## 7. Tests du socle (phase 1)

`tests/phase1/run-tests.sh` couvre, sans effet de bord (répertoire temporaire
supprimé à la fin) : parseur de manifeste (absent, vide, invalide, dupliqué,
valeurs piégées), analyse des options et de leur ordre, traps et codes de
sortie. Il ne télécharge rien, ne compile rien, ne monte rien.

ShellCheck : **non exécuté** (binaire absent de l'environnement d'audit) ;
statut à considérer comme « en attente ».

## 8. Décisions actées pour la migration

- noyau : commit complet `5d80fcdbbb3fbf399d3db66b0f14497d11c9489a`, statut
  `provisional` ;
- toolchain : Bootlin `aarch64--glibc--stable-2024.05-1` conservée, non
  téléchargée pour l'instant ;
- DTB Android : fourni par l'utilisateur, jamais téléchargé ni committé ;
- Alpine : série `v3.22`, version exacte à figer lors de la phase d'acquisition ;
- `dist/` : conservé temporairement, marqué legacy, non utilisé par le nouveau
  pipeline ;
- mode RAM : conservé, non par défaut, à réévaluer ;
- config noyau : non résolue, `config_status: TODO_VERIFIER` ;
- modules binaires : conservés temporairement, jamais copiés par le nouveau
  pipeline.
