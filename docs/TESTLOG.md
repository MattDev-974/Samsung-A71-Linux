# Journal des tests sur appareil réel

Matériel : Samsung Galaxy A71 (SM-A715F), bootloader déverrouillé
(`verifiedbootstate=orange`), 6 Go, révision 6, bootloader
`A715FXXSBDXB1`, région XEO. LineageOS 23.2 installé dans `super`.
Partition `boot` = 64 Mio (PIT : 74 partitions, dont `BOOT`, `RECOVERY`,
`VBMETA`, `VBMETA_SAMSUNG`).

## Outils

- **heimdall 1.4.2** compilé depuis les sources, avec deux correctifs :
  `libusb_reset_device()` avant le handshake (PR #478) et timeout du
  handshake porté à 5 s. Sans cela : `Failed to receive handshake response`
  puis `Failed to send handshake` jusqu'au redémarrage du téléphone.
- **odin4** testé (handshake échoue également).
- QEMU `-M virt` pour valider le noyau et le rootfs hors matériel.

## Chronologie

1. Flash de `boot-uniloader.img` (uniLoader + noyau + DTB + initramfs) :
   `BOOT upload successful` à 100 %, mais au redémarrage le téléphone revient
   en Download mode.
2. Variantes testées sans succès :
   - `boot-direct.img` (noyau gzip + initramfs + DTB mainline) ;
   - image « noyau LineageOS + notre initramfs » → le noyau LineageOS démarre
     (logo figé), ce qui prouve que le bootloader accepte nos images ;
   - configs `defconfig` + fragment `sm7150.config` puis config postmarketOS
     `config-postmarketos-qcom-sm7150.aarch64` ;
   - `VA_BITS` 52 puis 48, `nokaslr`, `DRM_MSM` désactivé, framebuffer sans
     horloge, DTS 696 / 1037 / 931 lignes, `clk_ignore_unused
     pd_ignore_unused` ;
   - chargement en RAM haute (`0xaa200000`) puis basse (`0x80080000`).
3. Noyau 6.18 (branche `2025-10-13-display` du fork) : même figement.
4. QEMU : le même `Image` + `initramfs.cpio.gz` démarre et exécute `/init`
   (bannière affichée) → l'image est saine, le blocage est spécifique au
   matériel.

## Sondes bas niveau (harnais uniLoader)

uniLoader est remplacé par un payload de quelques dizaines d'octets qui
répond en couleurs sur le framebuffer (`docs/probes/`).

| Sonde | Résultat | Interprétation |
|---|---|---|
| peinture 40 o | jaune | uniLoader copie et saute correctement |
| état CPU | EL1, MMU off, caches off | état d'entrée attendu par Linux |
| magie FDT | vert | le DTB passé en x0 est un FDT valide |
| `smc #0` (PSCI_VERSION) | vert | les appels SMC depuis EL1 fonctionnent |
| payload 21 Mo, stub à la fin | bleu | aucune troncature par le bootloader |
| DTB mainline dans l'en-tête boot.img | Download mode | sboot refuse notre DTB |
| entrée du noyau patchée (marqueurs) | bleu | **le noyau s'exécute** |
| lecture `0xa1300000` (ramoops) | bloqué | zone peut-être protégée, à confirmer |

## Cause du « uniLoader ne démarre même pas » (retour Download mode)

Le `boot.img` produit initialement mettait le **DTB mainline** dans la section
`dtb` de l'en-tête. `sboot` le refuse et retombe en Download mode. Vérifié
avec une sonde : uniLoader minuscule (payload peinture) + DTB mainline dans
l'en-tête → Download mode ; avec le DTB Android/Lineage → uniLoader s'exécute
et affiche « Booting kernel… ».

Correctif : `android.dtb` (extrait du `boot.img` LineageOS par
`scripts/extract-dtb.py`) dans l'en-tête, DTB mainline embarqué dans
uniLoader. Voir `artifacts/boot-uniloader-fixed.img` et
`artifacts/boot-uniloader-small.img`.

**Vérifié sur appareil (21/10/2026)** : `boot-uniloader-fixed.img`
(créneau noyau 37 Mo) flashe à 100 % et atteint bien « Booting kernel… » ;
il ne retombe plus en Download mode. Le noyau se fige ensuite, comme avant.

## Conclusions

- La chaîne de boot est correcte jusqu'au saut dans le noyau.
- Le noyau mainline **s'exécute** mais n'atteint ni la console ni l'init.
- Le bootloader Samsung n'accepte que le DTB Android/Lineage dans l'en-tête
  `boot.img` : le boot direct est impossible, uniLoader est obligatoire.
- Le fork du porteur (`device/samsung-a71`) contient l'historique de mise au
  point (« Kernel boots somehow », « Device does not crash anymore after
  booting », « USB gadget is now working »…) mais notre build reproduit un
  figement précoce.

## Pistes ouvertes

- Console série `ttyMSM0` (non documentée pour ce modèle).
- Paquet pmaports du porteur (`git.web.home.dark-link.info`, inaccessible).
- Noyau minimal (fbcon + initramfs + USB uniquement).
- Lecture fiable de ramoops/pstore.
