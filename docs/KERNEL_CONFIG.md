# Configuration du noyau : symboles vérifiés, fragment proposé, contrat de fusion

## 1. Constat

Le seul usage de pmaports dans le dépôt historique est la configuration noyau.
La configuration de l'image fonctionnelle n'est **pas** dans le dépôt : le
projet ne peut pas la revendiquer comme reproduite.

## 2. Base vendue

`configs/upstream/pmaports-sm7150.config` — copie exacte du commit pmaports
`5664c3237ca1d9f22b384a997cfb02facde72ed7` (2024-07-31), 219 110 octets,
SHA-256 `bdc559602cf689d0f600d69b00ceb67f2d81605ac4893384468f9e15673ca523`,
cible 6.7.4. Provenance : `configs/upstream/pmaports-sm7150.provenance`.

## 3. Symboles vérifiés dans le noyau épinglé

Vérification faite dans `https://github.com/WiiPlayer2/linux-sm7150` au commit
`5d80fcdbbb3fbf399d3db66b0f14497d11c9489a`, par clone partiel
(`--filter=tree:0 --depth 1`) et `sparse-checkout` des répertoires Kconfig
concernés. Relevé conservé dans `configs/a71-symbols-verified.txt`.

| Symbole | Kconfig | Type | Base | Proposé |
|---|---|---|---|---|
| `DRM_MSM` | `drivers/gpu/drm/msm/Kconfig` | tristate | y | **m** |
| `DRM_SIMPLEDRM` | `drivers/gpu/drm/sysfb/Kconfig` | tristate | absent | **y** |
| `DRM_PANEL_SAMSUNG_S6E3FA9_AMB667UM06` | `drivers/gpu/drm/panel/Kconfig` | tristate | absent | absent |
| `REGULATOR_QCOM_REFGEN` | `drivers/regulator/Kconfig` | tristate | absent | absent |
| `PHY_QCOM_QMP_COMBO` | `drivers/phy/qualcomm/Kconfig` | tristate | m | m |
| `TYPEC_QCOM_PMIC` | `drivers/usb/typec/tcpm/Kconfig` | tristate | m | m |
| `MMC_SDHCI_MSM` | `drivers/mmc/host/Kconfig` | tristate | y | y |
| `EXT4_FS` | `fs/ext4/Kconfig` | tristate | y | y |
| `BLK_DEV_INITRD` | `init/Kconfig` | bool | y | y |
| `DEVTMPFS` | `drivers/base/Kconfig` | bool | y | y |
| `USB_DWC3` | `drivers/usb/dwc3/Kconfig` | tristate | y | y |
| `USB_CONFIGFS` / `_RNDIS` / `_ECM` | `drivers/usb/gadget/Kconfig` | tristate | y | y |
| `VT`, `VT_CONSOLE` | `drivers/tty/Kconfig` | bool | y | y |
| `FRAMEBUFFER_CONSOLE` | `drivers/video/console/Kconfig` | tristate | y | y |
| `LOCALVERSION_AUTO` | `init/Kconfig` | bool | absent | **n** |

**Correction importante** : le symbole du panneau A71 n'est **pas**
`DRM_PANEL_SAMSUNG_S6E3FA9` (inexistant) mais
`DRM_PANEL_SAMSUNG_S6E3FA9_AMB667UM06` (« Samsung AMB667UM06 panel with
S6E3FA9 controller », *dependencies* : `OF`, `DRM_MIPI_DSI`,
`BACKLIGHT_CLASS_DEVICE`). Le nom avait été supposé dans l'incrément précédent ;
il est ici vérifié.

Dépendances notables lues dans les Kconfig :

- `DRM_MSM` : `tristate`, dépend de `DRM`, `ARCH_QCOM`, `COMMON_CLK`,
  `IOMMU_SUPPORT`, `OF`, `PM` ; `select` IOMMU_IO_PGTABLE, QCOM_MDT_LOADER,
  REGULATOR, DRM_EXEC, DRM_GPUVM, DRM_SCHED, SHMEM, TMPFS, QCOM_SCM,
  QCOM_UBWC_CONFIG, WANT_DEV_COREDUMP, SND_SOC_HDMI_CODEC (si SND_SOC),
  SYNC_FILE, PM_OPP, NVMEM, PM_GENERIC_DOMAINS, TRACE_GPU_MEM.
- `DRM_SIMPLEDRM` : `tristate`, dépend de `DRM && MMU`.
- `REGULATOR_QCOM_REFGEN` : `tristate`, `ARCH_QCOM || COMPILE_TEST`, `HAS_IOMEM`, `REGMAP`.
- `PHY_QCOM_QMP_COMBO` : `tristate`, `default PHY_QCOM_QMP`, `TYPEC || TYPEC=n`, `DRM || DRM=n`.
- `TYPEC_QCOM_PMIC` : `tristate`, `ARCH_QCOM || COMPILE_TEST`, `DRM || DRM=n`.

## 4. Analyse DTS et pilotes — ce qui est réellement utilisé

Source : `arch/arm64/boot/dts/qcom/sm7150-samsung-a715f.dts` (931 lignes) et
`sm7150.dtsi`, au commit épinglé.

| Constat | Preuve | Conséquence |
|---|---|---|
| Aucun nœud de panneau DSI | aucun `panel`, `dsi`, `mdss` dans le DTS A71 | le pilote `…S6E3FA9_AMB667UM06` **n'est pas instancié** → non requis |
| Framebuffer fourni par le bootloader | `framebuffer@9c000000 { compatible = "simple-framebuffer"; }` (l. 66) | l'affichage texte passe par `DRM_SIMPLEDRM` |
| `refgen` consommé par le DSI uniquement | `refgen-supply = <&refgen>` dans `sm7150.dtsi` (l. 3951 et 4030, nœuds DSI) | `REGULATOR_QCOM_REFGEN` inutile sans DSI actif |
| USB limité au high-speed | `&usb_1 { qcom,select-utmi-as-pipe-clk; }`, `&usb_1_dwc3 { maximum-speed = "high-speed"; dr_mode = "otg"; usb-role-switch; }` | `PHY_QCOM_QMP_COMBO` (USB3/DP) **non requis** |
| Rôle USB piloté par le Type-C | `&pm6150_typec` + `usb-role-switch` + `remote-endpoint = <&pm6150_role_switch_in>` | `TYPEC_QCOM_PMIC` utile ; déjà `=m` dans la base |

## 5. Politique noyau / initramfs / modules

**A. Obligatoires en dur avant le montage de `LABEL=A71ROOT`** — `=y` exigé :
`MMC_SDHCI_MSM`, `EXT4_FS`, `BLK_DEV_INITRD`, `DEVTMPFS`, plus la console
(`VT`, `VT_CONSOLE`, `FRAMEBUFFER_CONSOLE`).

**B. Intégrés ou présents dans l'initramfs** : le pilote MMC, ext4 et
devtmpfs (ci-dessus) ; rien d'autre n'est indispensable avant le montage.

**C. Chargeables après montage** — `=m` suffisant : `DRM_MSM`,
`PHY_QCOM_QMP_COMBO`, `TYPEC_QCOM_PMIC`, ainsi que le gadget USB
(`USB_DWC3`, `USB_CONFIGFS`, `RNDIS`, `ECM`) si l'on choisit de ne pas les
intégrer — la base les a en `=y`, ce qui reste acceptable (`m|y`).

## 6. Contradiction historique (toujours documentée)

`configs/a71-extra.config` contient :

```
# Keep the bootloader's framebuffer alive for a text console: DRM/MSM would
# take over the display (and its panel driver is a module we do not ship),
# leaving no console at all.
# CONFIG_DRM_MSM is not set
```

Ce n'est pas une erreur isolée : c'est un **arbitrage délibéré** (console
contre DRM). Il **contredit** la base vendue (`CONFIG_DRM_MSM=y`) et rendait
toute activation DRM impossible. Le fragment historique reste **inchangé**.

Le fragment proposé résout la tension autrement : `DRM_MSM=m` (donc **non
désactivé**), chargé seulement après montage, pendant que `DRM_SIMPLEDRM=y`
conserve la console au démarrage.

## 7. Fragment proposé

`configs/a71-proposed.config` (proposition, non appliquée) — quatre groupes :
identité (`LOCALVERSION`), console de secours (`CMDLINE` seul — voir ci-dessous),
affichage (`DRM_SIMPLEDRM=y`, `DRM_MSM=m`), build (`DEBUG_INFO_NONE=y`).
Le reste est **volontairement absent** : déjà conforme dans la base, donc
vérifié par la liste d'exigences plutôt que recopié.

### 7 bis. Symbole inexistant dans le fragment historique

`configs/a71-extra.config` contient `CONFIG_CMDLINE_EXTEND=y`. **Ce symbole
n'existe pas sur arm64 dans le noyau épinglé** : `arch/arm64/Kconfig` définit un
*choice* « Kernel command line type » entre `CMDLINE_FROM_BOOTLOADER` (défaut)
et `CMDLINE_FORCE` ; aucune entrée `CMDLINE_EXTEND` n'est présente.

Conséquence : la ligne historique était au mieux sans effet. Le fragment
proposé la retire et s'appuie sur `CMDLINE` non vide, ce qui active le *choice*
et sélectionne `CMDLINE_FROM_BOOTLOADER` par défaut — le bootloader prime, la
chaîne intégrée sert de repli, sans symbole inexistant.

## 8. Contrat de fusion (futur, non exécuté en 2C)

```
  configs/upstream/pmaports-sm7150.config      (base vendue)
  configs/a71-proposed.config                  (fragment A71)
        │
        ├─ scripts/kconfig/merge_config.sh -m -O "$OUT" base fragment
        │        → "$OUT/.config.merged"        (conservé)
        │
        ├─ make ARCH=arm64 olddefconfig          (répertoire de build complet)
        │        → "$OUT/.config.final"         (conservé)
        │
        ├─ rapport de différences :
        │     base    vs merged   (ce que le fragment change)
        │     merged  vs final    (ce que olddefconfig corrige)
        │
        └─ vérification des exigences :
              configs/a71-required-symbols.txt vs "$OUT/.config.final"
```

Règles :

1. `merge_config.sh` et `scripts/kconfig/` proviennent **du noyau épinglé**,
   jamais du système hôte ;
2. `.config.merged` et `.config.final` sont **toujours conservés** (traçabilité) ;
3. le rapport de différences est produit même en cas de succès ;
4. un symbole **absent** du `.config` final, **rétrogradé** (`y`→`m` ou `m`→`n`)
   ou **supprimé** par `olddefconfig` est signalé ;
5. **échec** si une exigence critique n'est pas satisfaite (le cas
   `CONFIG_CMDLINE_EXTEND` du fragment historique montre qu'un symbole
   inexistant doit être détecté, pas ignoré) :
   - valeur finale ≠ valeur exigée ;
   - symbole exigé absent du `.config` ;
   - symbole du fragment introuvable dans les Kconfig du noyau ;
   - `CONFIG_LOCALVERSION_AUTO` non désactivé (release non reproductible) ;
6. aucun statut `validated` sans compilation **et** test appareil ;
7. `merge_status` reste `not_built` tant que rien n'a été compilé.

## 8 bis. Vérificateur statique

`scripts/check-config.sh` (lecture seule) vérifie un `.config` contre
`configs/a71-required-symbols.txt` :

```
./scripts/check-config.sh --config FILE --requirements FILE [--report FILE] [--quiet]
```

Codes : `0` satisfait, `1` non satisfait, `2` usage, `3` exigences invalides,
`4` .config invalide, `5` rapport impossible. Il distingue valeur incorrecte,
désactivation, rétrogradation, symbole absent (échec même pour une exigence
`n`), doublons et lignes invalides. Rapport déterministe (sans date, sans
chemin absolu), écrit par fichier temporaire + renommage atomique.

Constat sur la base vendue : le vérificateur **échoue** (`CONFIG_DRM_SIMPLEDRM`
désactivé) — c'est le rôle du fragment proposé de le corriger.

## 9. Liste d'exigences

`configs/a71-required-symbols.txt` — format `CONFIG_SYM=valeur`, `#` en début
de ligne, valeurs `y`, `m`, `m|y`, `n`. C'est une **déclaration d'exigences**,
pas une configuration : elle ne recopie ni la base ni le fragment, et elle est
vérifiée **après** fusion.

Exigences actuelles : stockage/racine et console en `=y` ; gadget USB en
`m|y` ; `LOCALVERSION_AUTO=n` (reproductibilité).

## 9 bis. Première fusion réelle (incrément 2E)

Exécutée avec le `merge_config.sh` du noyau épinglé et `make olddefconfig`,
sans aucune compilation :

| Étape | Résultat |
|---|---|
| `merge_config.sh -m` | 5 redéfinitions (LOCALVERSION, CMDLINE, DRM_SIMPLEDRM, DRM_MSM, DEBUG_INFO_NONE) |
| `merged.config` | 8 125 lignes |
| `olddefconfig` | 8 656 lignes, 894 lignes ajoutées (`conf` construit : HOSTCC/LEX/YACC) |
| directives du fragment | 5/5 appliquées, **0** modifiée par `olddefconfig` |
| `kernelrelease` calculée | **`6.18.0-rc1-a71+`** (identique à `kernel.expected_release`) |
| exigences (`check-config.sh`) | **19/19 satisfaites** |
| compilation | **aucune** |

**Limitation découverte** : le système de build du noyau refuse tout chemin
contenant un espace ou deux-points (`Makefile:217`), et `merge_config.sh` teste
`[ -d $2 ]` sans guillemets. `scripts/merge-kernel-config.sh` refuse donc ces
chemins (codes 3 et 5) et doit être exécuté depuis un arbre et une sortie
**sans espace**. Les artefacts de la fusion sont publiés dans
`work/config/` (hors dépôt, non versionné).

## 9 ter. Compilation (script `scripts/kernel-build.sh`)

Commande prévue :

```bash
./scripts/kernel-build.sh \
  --kernel-source <arbre sans espace> \
  --config work/config/final.config \
  --toolchain-root <toolchain>/toolchain-root \
  --output work/kernel-build \
  --requirements configs/a71-required-symbols.txt \
  --jobs 12
```

Séquence : contrôles source/config/toolchain/sortie → `check-config` entrée →
`olddefconfig` → `kernelrelease` (comparée à `6.18.0-rc1-a71+`) →
`make -jN Image modules dtbs` → `modules_install` (dans la sortie) →
validations Image/DTB/modules → `check-config` final → rapports.

Outils hôte requis : `bash make git sha256sum find grep sed awk bc bison flex
openssl perl python3 rsync file readelf`, plus `dtc` **ou** `fdtdump`, et
`pahole` si `CONFIG_DEBUG_INFO_BTF=y`.

### Reproductibilité (2F-3b) — vérifiée

Politique : `KBUILD_BUILD_TIMESTAMP` dérivé du **commit épinglé** (jamais la date
courante), `KBUILD_BUILD_USER=a71-builder`, `KBUILD_BUILD_HOST=a71-build`,
`KBUILD_BUILD_VERSION=1`, `SOURCE_DATE_EPOCH` exporté. Ces variables sont
centralisées dans un tableau `MAKE_COMMON` utilisé par **tous** les appels
`make` (olddefconfig, kernelrelease ×2, build, modules_install).

| Métadonnée | Valeur |
|---|---|
| `SOURCE_DATE_EPOCH` | `1760369959` (`git show -s --format=%ct 5d80fcdb…`) |
| `kbuild_build_timestamp` | `2025-10-13 15:39:19 UTC` |
| `kbuild_build_user` | `a71-builder` |
| `kbuild_build_host` | `a71-build` |

Deux builds **propres** dans deux staging distincts (`/tmp/rb/a`, `/tmp/rb/b`),
même commit, même config, même toolchain, `-j12` :

| Élément | A | B | Match |
|---|---|---|---|
| `Image` | `3f913942…` | `3f913942…` | **oui** |
| DTB A71 | `02ff9e74…` | `02ff9e74…` | **oui** |
| modules | 607 | 607 | **oui** (arborescence + SHA-256 de chaque fichier) |
| configuration | `847ff3d2…` | `847ff3d2…` | **oui** |
| release | `6.18.0-rc1-a71+` | `6.18.0-rc1-a71+` | **oui** |

`overall_reproducible=yes` → `reproducibility_validation_status: verified`.
Rapport : `work/kernel-build/reports/reproducibility.txt` (+ `modules-a.sha256`,
`modules-b.sha256`, `modules.diff` vide).

Note : le SHA de l'`Image` a changé par rapport aux builds 2F-3/2F-3a
(`d741f0c5…` → `456eb5e3…` → `3f913942…`) **parce que** les métadonnées sont
désormais épinglées ; c'est le contenu injecté (UTS_VERSION, builder) qui
change, pas le code compilé.

### Consolidation (2F-3a) — build propre rejoué

Second build **propre** (sortie vide, staging neuf), même commit, même
configuration, même toolchain, `-j12`, **6 min 21 s** :

| Élément | 2F-3 | 2F-3a (consolidé) |
|---|---|---|
| release | `6.18.0-rc1-a71+` | `6.18.0-rc1-a71+` |
| `Image` | 23 769 600 o / `d741f0c5…` | 23 769 600 o / `456eb5e3…` |
| DTB A71 | 87 798 o / `02ff9e74…` | 87 798 o / `02ff9e74…` (**identique**) |
| modules | 607 (`.ko`) | 607 (`.ko`), gz/xz/zst = 0, `none` |
| exigences | 19/19 | 19/19 |
| configuration | inchangée | inchangée |

**Non-reproductibilité partielle constatée** : le `Image` diffère d'un build à
l'autre à source et configuration identiques, alors que le DTB est identique.
La cause est l'horodatage de build embarqué (`KBUILD_BUILD_TIMESTAMP` non
épinglé). Ce n'est pas un défaut de la chaîne, mais une limite à traiter
(épingler `KBUILD_BUILD_TIMESTAMP` sur la date du commit) si la reproductibilité
bit-à-bit devient un objectif.

Rapports désormais **sans chemin absolu** : `image_path`, `dtb_path`,
`module_release_directory`, `sysroot` et `cross` sont relatifs ou des noms
d'outils ; `module_count_{ko,gz,xz,zst}` sont mesurés séparément et leur somme
est contrôlée.

### Résultats de la compilation réelle (2F-3)

Exécutée le 2026-10-22 depuis un staging sans espace (obligatoire : `Makefile:217`),
avec `bc 1.08.2`, `dtc 1.8.1`, `fdump`/`pahole` présents.

| Élément | Résultat |
|---|---|
| commit | `5d80fcdbbb3fbf399d3db66b0f14497d11c9489a` (arbre propre) |
| toolchain | `aarch64-buildroot-linux-gnu-`, gcc 13.3.0, cible `aarch64-buildroot-linux-gnu` |
| `olddefconfig` | completed |
| release calculée avant build | `6.18.0-rc1-a71+` |
| release construite | `6.18.0-rc1-a71+` (**match**) |
| `Image` | 23 769 600 octets, SHA-256 `d741f0c5ab758154b877238640a9097d74602457df89b8cd0f7997e900609d3c` |
| DTB A71 | 87 798 octets, SHA-256 `02ff9e744e45325681c071a4126afe1e51f78fe9ff0863f6958c298c098be7e8` |
| modules | **607**, aucun compressé, tous ELF AArch64 |
| exigences | 19 / 19, 0 échec |
| configuration | inchangée pendant le build (`match`) |
| durée | 6 min 25 s à `-j12` |

**Correction nécessaire découverte pendant le build** : `CONFIG_DRM_PANEL_HUAXING_NT36672C=y`
(panneau Xiaomi, inutile pour le A71) provoquait un échec de lien
`undefined reference to 'drm_dsc_pps_payload_pack'` — son entrée Kconfig ne fait
pas `select DRM_DSC_HELPER`. Le fragment proposé désactive ce pilote, avec
justification.

### État antérieur (2F-2a)

**Test d'intégration lancé, arrêté avant build lors du contrôle des prérequis
hôte.**

Deux catégories distinctes de prérequis sont contrôlées :

| Catégorie | Outil | Effet de l'absence |
|---|---|---|
| Compilation | `bc` | **bloque la compilation** : `kernel/Kbuild:21` génère `include/generated/timeconst.h` avec `echo $(CONFIG_HZ) \| bc -q timeconst.bc` |
| Validation post-build | `dtc` **ou** `fdtdump` | n'empêche pas le noyau de produire le DTB (il a son propre DTC), mais empêche la **validation indépendante** du DTB produit |
| Conditionnel | `pahole` | bloquant seulement si la configuration normalisée active `CONFIG_DEBUG_INFO_BTF` |

Sur cette machine : `bc`, `dtc` et `fdtdump` sont **absents**, l'installation de
paquets est interdite au pipeline. Le script s'arrête avec le code **7** et
enregistre `pahole_requirement=not_checked` (l'évaluation exige la
configuration normalisée, non atteinte).

Les étapes non atteintes sont marquées explicitement `not_started` /
`not_checked` / `not_produced` — jamais `failed` ni `non` :

```
result=FAILED
failed_step=host
requirements_input=not_started
olddefconfig=not_started
kernelrelease_before_build=not_checked
build=not_started
modules_install=not_started
kernelrelease_after_build=not_checked
artifacts_validation=not_started
requirements_final=not_started
release_match=not_checked
config_unchanged_during_build=not_checked
built_release=not_produced
requirements_total=not_checked
module_count=not_checked
```

**Aucune conclusion sur la compilabilité du noyau ne peut être tirée** de cet
arrêt : la source, le commit et la toolchain ont été validés, mais aucune cible
`make` de compilation n'a été exécutée.

`Image`, modules et DTB restent **non produits** ; `kernel.built_release` reste
`TODO_BUILD`.

Installation des paquets : **action manuelle de l'utilisateur**, jamais exécutée
par le pipeline. Exemples documentaires (Debian/Ubuntu) :

```bash
sudo apt update
sudo apt install bc device-tree-compiler
```

## 9 quater. Intégration au rootfs (3A-2)

`scripts/integrate-kernel-modules.sh` copie le rootfs de base, y installe les
607 modules de `6.18.0-rc1-a71+` et génère les métadonnées `depmod`.

| Élément | Valeur observée |
|---|---|
| modules source | `work/kernel-build/modules-install/lib/modules/6.18.0-rc1-a71+` |
| modules copiés | 607 → 607 (`modules-copy.diff` vide) |
| rootfs de base | **inchangé** (`rootfs_base_unchanged=yes`) |
| depmod | `kmod version 34.2` (`/usr/bin/depmod`), SHA-256 `c0d22548…` |
| isolation | `env -i LC_ALL=C LANG=C TZ=UTC PATH=/usr/bin:/bin`, `-b <rootfs> -C /dev/null` |
| fichiers générés | 14 (dont `modules.dep{,.bin}`, `modules.alias{,.bin}`, `modules.softdep`, `modules.symbols{,.bin}`) |
| reproductibilité depmod | texte **et** binaire identiques sur deux intégrations |
| chroot/mount/qemu/apk | aucun |

**Limite de reproductibilité** : les métadonnées binaires dépendent de la
version de `kmod` ; deux hôtes avec des versions différentes peuvent produire
des `.bin` différents à texte identique. Ici les deux exécutions sont sur le
même hôte, même version.

## 10. Statuts

`source_status: pinned` · `integrity_status: verified` ·
`reproducibility_validation_status: verified` · `runtime_status: not_tested` ·
`validation_status: provisional`.

La fusion Kconfig, `olddefconfig`, la compilation `Image modules dtbs` et la
reconstruction D1 ont réellement été exécutés. Deux builds indépendants
donnent la même `Image` (`3f913942…`), le même DTB (`02ff9e74…`), les mêmes
607 modules et la même configuration. Le manifeste conserve
`kernel.built_release: TODO_BUILD` : il ne reçoit pas un résultat local. Aucun
test sur appareil n'a été effectué : `runtime_status: not_tested`,
`validation_status: provisional`.


## 11. initramfs et uniLoader (F1/G1)

L'initramfs `work/initramfs/initramfs.img` est un cpio newc compressé
`gzip -n -9`, reproductible (deux builds identiques), sans module car les
huit pilotes critiques sont `=y`. Il contient `/init`, BusyBox AArch64, le
chargeur musl (BusyBox est dynamique), les liens BusyBox et les répertoires
`dev/proc/sys/run/newroot`. Le SHA-256 publié est
`8c5f596a8c2572681de718194bbf2af76c6f4bb5bd00a9b477b8901b7b5a1798`.

uniLoader est compilé depuis le commit épinglé
`4c626a73cc38308227b5c28e75558b3da574312b` avec la toolchain validée. Le
contrat réel est celui du linker : `blob/Image`, `blob/dtb` et
`blob/ramdisk` sont intégrés dans la sortie brute `uniLoader` (en-tête Linux
ARM64 Image), puis `uniLoader.gz` est sa compression normalisée. Aucun
`boot.img` n'est produit ; l'assemblage de la partition BOOT reste hors
périmètre.


## 12. Contrat de démarrage Samsung (J)

Les outils de contrat boot sont en lecture seule :

- `scripts/audit-boot-artifacts.sh` (J2) vérifie les artefacts et produit
  `work/boot/reports/boot-artifacts.txt` ;
- `scripts/analyze-stock-boot.sh` (J3) analyse un `boot.img` Android d'origine
  (headers v0-v4) et extrait les composants sans les exécuter ;
- `scripts/check-boot-contract.sh` (J4) compare stock, uniLoader, manifeste et
  taille de partition ; il est fail-closed ;
- `scripts/package-boot-candidate.sh` (J5) ne produit une image
  `boot-a71-UNTESTED.img` que si J4 retourne `READY_TO_PACKAGE`.

Aucun `work/input/stock-boot.img` n'étant fourni, l'état actuel est
`BLOCKED_MISSING_STOCK_BOOT` ; voir `work/boot/NEEDED-FROM-USER.md`. Aucun
`boot.img` n'est déclaré flashable.
