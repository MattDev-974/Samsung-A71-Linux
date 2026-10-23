# Modèle de cache et d'acquisition

Document de **contrat**. Le code d'acquisition existe désormais :
`scripts/prepare-toolchain.sh` et `scripts/prepare-rootfs.sh` appliquent les
règles ci-dessous (cache adressé par SHA-256, vérification à chaque usage,
publication atomique). Le cache des paquets `.apk` est également conservé pour
relire les métadonnées de modes des paquets signés (voir D1).

## 1. Arborescence proposée

```
.cache/a71-linux/
├── downloads/
│   └── sha256/
│       └── <sha256>              # contenu adressé par hash (nom = hash)
├── git/
│   └── <id-depot>/               # dépôt nu (mirror) verrouillé par SHA
├── metadata/
│   └── <entree>.json             # provenance (voir docs/PROVENANCE.md)
└── locks/                        # verrous d'acquisition
```

`work/` reste réservé aux sorties de build et aux worktrees temporaires.
`.cache/` est supprimable sans casser le dépôt (il ne contient que des
sources re-téléchargeables et vérifiables).

## 2. Contenu adressé par hash

- un fichier téléchargé est stocké sous `downloads/sha256/<sha256>` ;
- **le nom d'origine n'est jamais une preuve** : seul le hash compte ;
- la présence d'un fichier dans le cache ne vaut pas validation : le hash est
  **recalculé à chaque réutilisation** et comparé à la valeur attendue ;
- si le hash diffère, le fichier est **supprimé** et l'acquisition échoue (pas
  de remplacement silencieux).

## 3. Acquisition (politique future)

1. vérifier la présence du hash attendu dans le manifeste — un `TODO_*`
   interdit l'acquisition ;
2. si l'objet est absent du cache : télécharger vers un fichier temporaire
   **dans le même système de fichiers** ;
3. vérifier le code HTTP (`curl --fail --show-error --silent --location`) ;
4. vérifier la taille minimale, puis le **SHA-256** ;
5. **renommer atomiquement** (`mv`) vers `downloads/sha256/<sha256>` ;
6. écrire les métadonnées de provenance dans `metadata/<entree>.json` ;
7. en cas d'échec à n'importe quelle étape : supprimer le fichier temporaire.

## 4. Dépôts Git

- clone **nu** (ou miroir) dans `git/<id-depot>/` ;
- `git fetch origin <sha>` (récupération d'un commit précis, pas d'une branche) ;
- vérification `rev-parse HEAD` == SHA attendu et `merge-base --is-ancestor` ;
- **worktree temporaire par build** (`git worktree add work/src/<id> <sha>`) :
  jamais de checkout dans le dépôt partagé, jamais de build dans `.cache/` ;
- le worktree est supprimé en fin de build (`git worktree remove`).

## 5. Métadonnées

Format **JSON** (`metadata/<entree>.json`) : lisible, parsable sans dépendance
nouvelle (`python3` est déjà requis pour les outils existants). Champs alignés
sur le rapport de provenance (`url`, `version`, `hash_expected`, `hash_origin`,
`hash_actual`, `size`, `fetched_at`, `tool`, `signature_status`, `git_commit`,
`validation_status`).

Aucune donnée sensible : ni chemin privé complet, ni secret, ni token.

## 6. Permissions et isolation

- `.cache/a71-linux/` en **700**, fichiers de métadonnées en **600** ;
- aucune exécution directe d'un fichier du cache avant validation : un binaire
  téléchargé n'est jamais lancé depuis `.cache/` (il est copié dans `work/`
  après vérification, puis utilisé) ;
- verrous dans `locks/` pour éviter deux acquisitions concurrentes.

## 7. Garanties attendues

| Garantie | Mécanisme |
|---|---|
| Intégrité | SHA-256 officiel épinglé, recalculé à chaque usage |
| Reproductibilité | version exacte + hash, jamais `latest` |
| Traçabilité | `metadata/<entree>.json` + rapport de build |
| Sûreté | refus de tout `TODO_*`, téléchargement atomique, pas d'exécution depuis le cache |
| Réversibilité | `.cache/` supprimable sans perte de données du dépôt |

## 7 bis. Application au minirootfs Alpine (3A-1)

`scripts/prepare-rootfs.sh` applique ce contrat :

| Élément | Valeur observée |
|---|---|
| cache | `work/rootfs-cache/downloads/sha256/7e9b34ff…` (700/600) |
| taille | 3 971 679 o (attendue = réelle) |
| SHA-256 | `7e9b34ff…` (manifeste = calculé) |
| SHA-512 | `b8a60e09…` (manifeste = calculé) |
| signature | `not_verified` (aucune vérification GPG dans cet incrément) |
| extraction | temporaire privé → publication atomique |
| reproductibilité | deux extractions identiques (`tree_match=yes`) |

Politique de liens pour un **rootfs** (différente d'une toolchain) : les liens
symboliques sont légitimes, y compris absolus (`/bin/busybox`) — un lien absolu
désigne un chemin **dans** le rootfs. Sont refusés : noms absolus ou contenant
`..`, cibles relatives remontant au-dessus de la racine, cibles absolues
absentes de l'archive, liens durs absolus ou sortants, et toute écriture **à
travers** un lien symbolique.

## 7 ter. Modules et métadonnées (3A-2)

Les modules ne passent pas par le cache de téléchargement : ils proviennent du
build local (`work/kernel-build`) et sont copiés dans une copie de travail du
rootfs. Le contrôle d'intégrité utilise deux inventaires déterministes
(`modules-source.sha256`, `modules-rootfs.sha256`) comparés par `diff` : le
fichier `modules-copy.diff` doit être vide.

`depmod` est un outil **hôte**, jamais celui du rootfs : son identifiant public
est `host-command:depmod`, sa version et son SHA-256 sont enregistrés, et son
exécution est isolée (`env -i`, `-b`, `-C /dev/null`).

## 8. Application actuelle

`prepare-rootfs.sh` et `prepare-toolchain.sh` implémentent l'acquisition
vérifiée. Les paquets `.apk` téléchargés par `build-rootfs-functional.sh` sont
conservés dans le cache et relus pour leurs métadonnées tar (modes, UID/GID)
dans `scripts/rootfs-modes.py`. Aucun fichier du cache n'est exécuté.

## 7 quater. Artefacts image (H2/H3)

Les images ne passent pas par le cache de téléchargement : elles sont
construites localement à partir de `work/rootfs/rootfs-functional`.

- `work/sdcard/A71ROOT.ext4` : ext4 1 GiB, label `A71ROOT`, UUID déterministe,
  propriétaires/modes appliqués par `debugfs` depuis le manifeste ;
- `work/sdcard/A71ROOT.ext4.sha256` et `A71ROOT.ext4.manifest` : intégrité et
  inventaire logique ;
- `work/sdcard/a71-sd.img` : MBR, une partition Linux au secteur 2048,
  contenant exactement `A71ROOT.ext4` ; aucun bootloader ;
- `work/sdcard/a71-sd.img.sha256`, `image-layout.txt`, `HUMAN-WRITE-INSTRUCTIONS.md`.

Aucun de ces fichiers n'est monté ni attaché à un loop device pendant la
construction. Le script d'écriture `scripts/write-sdcard.sh` refuse tout
périphérique autre que `/dev/sde` et vérifie `MAJ:MIN=8:64` avant toute
écriture.
