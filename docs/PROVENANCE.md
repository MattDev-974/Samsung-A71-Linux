# Provenance des sources

Ce document décrit **ce qui a été observé**, **où**, **comment**, et **ce qui
n'est pas établi**. Il ne remplace pas une vérification cryptographique.

## 0. Nature des sources — ne pas tout appeler « officiel »

| Catégorie | Exemple | Ce que cela établit |
|---|---|---|
| **Checksum publié par le fournisseur** | `alpine-minirootfs-3.22.7-aarch64.tar.gz.sha256` | l'éditeur de la distribution déclare ce hash pour ce fichier |
| **Source amont Git** | `git ls-remote` sur le dépôt du noyau | le serveur annonce ce SHA pour cette référence |
| **Métadonnée d'API** | API GitHub / GitLab (date, signature, licence) | la forge rapporte ces informations ; ce n'est pas une preuve cryptographique locale |
| **Observation historique du dépôt** | `dist/boot.img`, `base/lib/modules` | ce que le dépôt contenait à un instant donné, non reproduit ici |
| **Résultat local** | `sha256sum` d'un fichier présent | l'intégrité du fichier **local**, pas sa provenance |

Le dépôt du noyau est **tiers** : il n'est ni Samsung, ni kernel.org, ni une
distribution. Il est « amont » au sens de « source choisie par le projet ».

Consultation initiale : **2026-10-22** (horloge système).

## 1. Règles du projet

1. Seules des sources **primaires** sont utilisées : CDN Alpine, site Bootlin,
   dépôts Git d'origine retenus par le projet.
2. Chaque entrée est verrouillée par une **version exacte** (jamais `latest`,
   jamais une branche seule).
3. Chaque archive est vérifiée par un **SHA-256** ; quand le fournisseur publie
   un checksum, c'est **le sien** qui fait foi.
4. Un hash **calculé localement** n'est jamais présenté comme « officiel ».
5. Une **signature** n'est déclarée vérifiée que si elle a réellement été
   vérifiée avec la clé attendue.
6. Aucun hash, aucune URL, aucune version ne sont inventés : une valeur
   inconnue reste `TODO_VERIFIER`.

## 2. Noyau Linux

| Champ | Valeur |
|---|---|
| Dépôt | `https://github.com/WiiPlayer2/linux-sm7150` |
| Nature | **dépôt tiers retenu par le projet** — ni Samsung, ni kernel.org |
| Branche documentaire | `2025-10-13-display` |
| Commit | `5d80fcdbbb3fbf399d3db66b0f14497d11c9489a` |
| Date du commit | `2025-10-13T15:14:09Z` |
| Signature | **non signé** (`verified: false`, `reason: unsigned`) |
| Version déclarée par les sources | `6.18.0-rc1` (Makefile du commit) |

**Vérifié** : le serveur GitHub annonce ce SHA pour cette branche
(`git ls-remote`), l'API GitHub confirme le commit, sa date et l'**absence de
signature**, la DTS `sm7150-samsung-a715f.dts` existe à ce commit et son
Makefile déclare `6.18.0-rc1`.

**Non vérifié / non affirmé** : aucune signature Git n'a été vérifiée ; la
provenance repose sur **HTTPS + SHA complet épinglé**. La compilation a été
réalisée depuis ce commit (`work/kernel-build`, reproductibilité vérifiée sur
deux builds). Le manifeste conserve néanmoins `kernel.built_release:
TODO_BUILD` : un résultat local de build n'est pas une valeur de manifeste.

## 3. uniLoader

| Champ | Valeur |
|---|---|
| Dépôt | `https://github.com/ivoszbg/uniLoader` |
| Licence | `GPL-2.0` (SPDX, via l'API GitHub) |
| PR | **#130 « board: Add support for Samsung Galaxy A71 » — fusionnée** |
| Tête de PR (provenance) | `b253dc48f9d297786df60d4389552752ccfb65da` (ref `a71`) |
| **Commit épinglé** | `4c626a73cc38308227b5c28e75558b3da574312b` (commit de fusion) |
| Atteignable depuis `master` | oui (`compare` : ahead 26, behind 0) |
| Defconfig | `configs/a71_defconfig` (190 octets) |
| Code board | `board/samsung/board-a71.c` |
| Signature | **non signé** |

La PR étant fusionnée, la référence mouvante disparaît : le pipeline épingle le
**commit de fusion**. Aucun binaire uniLoader précompilé n'est utilisé.

## 3 bis. pmaports (configuration noyau)

| Champ | Valeur |
|---|---|
| Dépôt | `https://gitlab.com/postmarketOS/pmaports` |
| Commit | `5664c3237ca1d9f22b384a997cfb02facde72ed7` |
| Date | 2024-07-31 |
| Titre | `linux-postmarketos-qcom-sm7150: enable zstd firmware compression support (MR 5447)` |
| Signature | **PGP vérifiée par GitLab** (`verification_status: verified`, clé `8A700086A9FE41FD`) — **aucune vérification locale** |
| Fichier copié | `device/testing/linux-postmarketos-qcom-sm7150/config-postmarketos-qcom-sm7150.aarch64` |
| SHA-256 du fichier vendu | `bdc559602cf689d0f600d69b00ceb67f2d81605ac4893384468f9e15673ca523` (calculé localement) |
| Taille | 219 110 octets |
| Statut | `provisional` — cible noyau 6.7.4, projet sur 6.18.0-rc1 |

## 3 ter. uniLoader : build reproductible (G1)

| Champ | Valeur |
|---|---|
| Dépôt | `https://github.com/ivoszbg/uniLoader` |
| Commit compilé | `4c626a73cc38308227b5c28e75558b3da574312b` |
| Référence publique | atteignable depuis `origin/master` |
| Défconfig / board | `configs/a71_defconfig` / `board/samsung/board-a71.c` |
| Toolchain | Bootlin `aarch64-buildroot-linux-gnu-`, gcc 13.3.0 |
| Entrées | `blob/Image` (Image noyau), `blob/dtb` (DTB mainline), `blob/ramdisk` (initramfs cpio.gz) |
| Sortie | `uniLoader` brut ARM64 Image + `uniLoader.gz` |
| SHA-256 | `33e28da39dc5084014be482fb6f974eb3298f1442e75670f8d06a3f0494cd21d` |
| Reproductibilité | deux builds identiques (brut, `.o`, `.gz`) |
| Signature | non signé ; licence rapportée GPL-2.0, SPDX `TODO_VERIFIER` |
| Statut | `provisional`, aucun test sur appareil |

Les entrées sont copiées dans `blob/` et ne sont jamais modifiées ; leurs
hashes avant/après sont comparés. `uniLoader.gz` est recompressé avec
`gzip -n -9` car la règle du Makefile conserve sinon le mtime.

## 4. Alpine Linux

| Champ | Valeur |
|---|---|
| Version | **3.22.7** (série `v3.22`) |
| Index | `https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/` |
| Fichier | `alpine-minirootfs-3.22.7-aarch64.tar.gz` |
| URL directe | `https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/alpine-minirootfs-3.22.7-aarch64.tar.gz` |
| Taille | 3 971 679 octets |
| Publication | 21-Oct-2026 19:49 GMT |
| SHA-256 **officiel publié** | `7e9b34ff3304381909e566e2c93de450664ccc724191261423974fc121c11623` |
| SHA-512 **officiel publié** | `b8a60e09…fdb533c` (valeur complète dans le manifeste) |
| Signature GPG | `.asc` présent (870 o) — **non vérifiée** |
| Dépôts | `main` + `community`, `aarch64`, APKINDEX HTTP 200 |

Origine du hash : **publié par le fournisseur** (`.sha256`/`.sha512` adjacents),
pas calculé localement.

## 5. Toolchain Bootlin

| Champ | Valeur |
|---|---|
| Archive | `aarch64--glibc--stable-2024.05-1.tar.xz` |
| Index | `https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/` |
| URL directe | `https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/aarch64--glibc--stable-2024.05-1.tar.xz` |
| Taille | 83 754 052 octets |
| Publication | 18-Aug-2024 03:24 GMT |
| SHA-256 **officiel publié** | `b0fad860eb94b503a56d66ca8b9ba06d2d4826943e37ebd1d7217423f6ea5bb2` |
| Fichier du checksum | `…-2024.05-1.sha256` (**sans** `.tar.xz` dans le nom) |
| Signature | **aucune** (`….tar.xz.asc` → 404) |
| Composants (metadata officielle) | gcc 13.3.0, binutils 2.41, gdb 14.2, glibc 2.39-74-g198632a…, linux-headers 4.19.315, `TEST-OK` |
| Hôte | `x86_64` — **metadata_only** (jamais exécutée ici) |

Aucun `CROSS_COMPILE` n'est inventé : le préfixe exact sera constaté en
inspectant l'archive, pas supposé.

## 5 bis. Toolchain : acquisition vérifiée (2F-1)

`scripts/prepare-toolchain.sh` applique la politique du §7 : cache adressé par
SHA-256, vérification à chaque usage, extraction sûre, test ELF réel.

| Contrôle | Résultat |
|---|---|
| SHA-256 du manifeste | `b0fad860…ea5bb2` |
| SHA-256 publié par Bootlin (`.sha256`) | identique (`coherent`) |
| SHA-256 calculé localement | identique |
| Taille attendue / locale | 83 754 052 / 83 754 052 |
| Signature | **indisponible** (aucun `.asc`) |
| Extraction | validée (chemins, liens, entrées spéciales inspectés) |
| Compilateur | `aarch64-buildroot-linux-gnu-gcc` (gcc 13.3.0, Buildroot) |
| Cible | `aarch64-buildroot-linux-gnu` |
| Test ELF | binaire AArch64 confirmé (`file` + `readelf -h`) |

## 5 ter. Alpine minirootfs : acquisition vérifiée (3A-1)

| Contrôle | Résultat |
|---|---|
| Fichier | `alpine-minirootfs-3.22.7-aarch64.tar.gz` |
| Taille | 3 971 679 o (attendue = réelle) |
| SHA-256 (publié, épinglé au manifeste) | `7e9b34ff3304381909e566e2c93de450664ccc724191261423974fc121c11623` |
| SHA-256 calculé localement | identique |
| SHA-512 (publié) | `b8a60e09…fdb533c` |
| SHA-512 calculé localement | identique |
| Signature GPG | **`not_verified`** — non téléchargée, non vérifiée |
| Origine des hashes | `manifest_official_published` (fichiers `.sha256`/`.sha512` d'Alpine) |

Le hash **calculé** n'est jamais présenté comme officiel : les rapports
distinguent `sha256_expected`/`sha256_origin` de `sha256_actual`.

## 5 quater. Modules noyau et depmod (3A-2)

| Élément | Valeur |
|---|---|
| Origine des modules | build reproductible `work/kernel-build` (commit `5d80fcdb…`) |
| Release | `6.18.0-rc1-a71+` |
| Nombre | 607, tous `.ko` non compressés, ELF AArch64 |
| `depmod` | outil **hôte**, `kmod 34.2`, SHA-256 `c0d22548…` |
| Isolation | `env -i` + `-b <rootfs>` + `-C /dev/null` |
| Reproductibilité | métadonnées texte et binaires identiques sur deux intégrations |

Les modules sont **reproductibles** (mêmes entrées → mêmes binaires), mais ils
ne sont **pas testés à l'exécution** sur l'appareil : `runtime_status:
not_tested`.

## 6. Politique Git

Pour tout dépôt Git (noyau, uniLoader, pmaports) :

1. cloner ou mettre à jour l'URL exacte (clone filtré), puis récupérer une
   **référence publique** (`git fetch origin <branche>` ou `<sha>` si le serveur
   l'autorise) ;
2. vérifier que le commit **existe** et est **atteignable** depuis la référence
   publique documentée, puis faire un **checkout détaché du SHA exact**
   (`git checkout --detach <sha>`) ;
3. vérifier `git merge-base --is-ancestor <sha> origin/<branche>` ;
4. exécuter `git verify-commit <sha>` et **enregistrer le résultat réel**
   (y compris « unsigned ») ;
5. si non signé : ne jamais prétendre à une authentification, accepter
   uniquement le **verrouillage par SHA complet**, et documenter que la
   provenance repose sur HTTPS/GitHub + SHA ;
6. enregistrer l'URL distante, le SHA, la branche informative et le statut de
   signature dans le rapport de provenance ;
7. **refuser tout changement silencieux** : jamais de repli sur une tête de
   branche, jamais de « dernier commit disponible ».

## 7. Modèle de confiance (résumé)

| Origine du hash | Statut | Utilisation |
|---|---|---|
| Publié par le fournisseur (Alpine `.sha256`/`.sha512`, Bootlin `.sha256`) | `official` | foi |
| Calculé localement sur un fichier téléchargé | `local` | contrôle d'intégrité du transfert, **jamais** présenté comme officiel |
| Aucun hash publié | `none` | entrée refusée par le pipeline, sauf décision explicite documentée |

Signatures : Alpine `not_verified`, Bootlin `unavailable`, noyau `unsigned`,
uniLoader `unsigned`. **Aucune signature n'est déclarée vérifiée.**

## 8. Ce que ce document n'affirme pas

- que le contenu du dépôt noyau provient de Samsung ou de kernel.org ;
- que les commits sont authentifiés (ils ne sont pas signés) ;
- que l'archive Bootlin s'exécute sur cette machine (jamais lancée) ;
- qu'un build produit est validé à l'exécution : le noyau et l'initramfs sont
  reproductibles, mais `runtime_status` reste `not_tested` et
  `validation_status` reste `provisional` ;
- que le manifeste contient un résultat local : `kernel.built_release` reste
  `TODO_BUILD` et `boot_image.validation_status` reste `TODO_VERIFIER` →
  **flash bloqué** ;
- que l'image SD contient un bootloader : `a71-sd.img` ne contient qu'une
  partition Linux avec `A71ROOT.ext4`, aucun code de boot dans le MBR.
