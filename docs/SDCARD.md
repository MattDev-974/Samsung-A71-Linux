# Image SD et écriture contrôlée

## Contenu

`work/sdcard/a71-sd.img` est une image MBR de **1 074 790 400 octets**
(1 025 MiB), bien inférieure à la carte de référence de 30 979 129 344 octets.

| Élément | Valeur |
|---|---|
| Table | MBR/DOS |
| Identifiant disque | `0xa71a71a7` |
| Partition | 1, type Linux `83` |
| Début | secteur 2048 (1 MiB) |
| Taille | 2 097 152 secteurs (1 GiB) |
| Contenu | `A71ROOT.ext4`, label `A71ROOT` |
| Bootloader | aucun |
| Données après partition | aucune |

Le SHA-256 publié est dans `work/sdcard/a71-sd.img.sha256`. Aucun `boot.img`
n'est produit ni déclaré flashable : cette image ne concerne que le rootfs.

## Construction

```bash
./scripts/build-rootfs-image.sh \
  --rootfs work/rootfs/rootfs-functional \
  --ownership-manifest work/rootfs/rootfs-functional/reports/ownership-manifest.txt \
  --output work/sdcard/A71ROOT.ext4 \
  --source-date-epoch 1760369959

./scripts/build-sd-image.sh \
  --rootfs-image work/sdcard/A71ROOT.ext4 \
  --output work/sdcard/a71-sd.img
```

H2 utilise `mke2fs -d` puis `debugfs sif` (2 086 entrées), sans montage, loop,
sudo ni chroot. H3 écrit le MBR avec `sfdisk` sur un fichier régulier et copie
`A71ROOT.ext4` à l'offset 1 MiB avec `dd`.

## Écriture humaine

Le mode opératoire complet, avec l'avertissement d'effacement total et les
commandes exactes, est dans
[`work/sdcard/HUMAN-WRITE-INSTRUCTIONS.md`](../work/sdcard/HUMAN-WRITE-INSTRUCTIONS.md).

Résumé :

```bash
lsblk -b -o NAME,PATH,MAJ:MIN,RM,RO,TYPE,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS /dev/sde
sudo ./scripts/write-sdcard.sh --image work/sdcard/a71-sd.img --device /dev/sde --verify-only
sudo ./scripts/write-sdcard.sh --image work/sdcard/a71-sd.img --device /dev/sde
# confirmation exacte : ECRIRE /dev/sde
```

Le script refuse `/dev/sda`, `/dev/sdb`, `/dev/sdc`, `/dev/nvme*`,
`/dev/mmcblk*`, tout autre chemin et tout `MAJ:MIN` différent de `8:64`.
Il ne démonte que les partitions dont `PKNAME=sde`, ne monte jamais la cible
et ne retente jamais automatiquement.

## Limites

Aucune écriture réelle n'est exécutée dans cet environnement. Les scripts sont
testés avec des commandes bouchonnées ; `runtime_status` reste `not_tested` et
`validation_status` reste `provisional`.

## Agrandissement après écriture

L'image de 1 025 MiB laisse le reste de la carte libre. Pour l'utiliser plus
tard, agrandir la partition 1 sans changer son début `2048`, puis
`e2fsck -f /dev/sde1` et `resize2fs /dev/sde1`. La procédure détaillée et les
avertissements figurent dans
[`work/sdcard/HUMAN-WRITE-INSTRUCTIONS.md`](../work/sdcard/HUMAN-WRITE-INSTRUCTIONS.md).


## Résultat d'écriture humain

Le constat de l'écriture réelle et de la relecture sur `/dev/sde` est consigné
dans [`docs/SDCARD-WRITE-RESULT.md`](SDCARD-WRITE-RESULT.md). Il ne prouve pas
un démarrage sur le téléphone.


## Image corrigée `/init` (L)

- ext4 : `work/sdcard/A71ROOT-init.ext4` (1 GiB, label `A71ROOT`, UUID
  `08299c3f-8560-5f08-9f68-5fe4fbd2c4e5`) ;
- disque : `work/sdcard/a71-sd-init.img` (1 074 790 400 octets, MBR
  `0xa71a71a7`, partition 2048/+2097152/83) ;
- UUID déterministe : `uuid5(NAMESPACE_URL,
  "a71-linux|A71ROOT|ext4|6.18.0-rc1-a71+|2087|init-link|source-date-epoch:1760369959")`
  = `08299c3f-8560-5f08-9f68-5fe4fbd2c4e5` ;
- `/init -> /sbin/init` vérifié par `debugfs` dans l'image et la partition
  extraite ;
- l'ancienne image `a71-sd.img` reste intacte et n'est **pas** compatible
  (`/init` absent).

Voir `work/sdcard/HUMAN-WRITE-INSTRUCTIONS-init.md` et
`work/compat/SD-MODE-TEST-init.md`.

## M1 — image USB/SSH

| Élément | Valeur |
|---|---|
| ext4 | `work/sdcard/A71ROOT-usb.ext4`, `1 073 741 824` octets |
| SHA ext4 | `2c919f1058801f2a5db43561a87254ed0d5a6372268d64a18c64670a3e481d62` |
| disque | `work/sdcard/a71-sd-usb.img`, `1 074 790 400` octets |
| SHA disque | `7af93a145494c5d61b2a45296ae8f19a80e5c2b4c9a71868e38bd7ac88cd4ccf` |
| UUID | `d8903bca-5ee9-5319-82eb-a49bd5387af2` |
| label | `A71ROOT` |
| partition | 2048 / 2097152 / type 83 |
| manifeste | 2106 entrées |

Les images précédentes (`a71-sd.img`, `a71-sd-init.img`, `A71ROOT.ext4`,
`A71ROOT-init.ext4`) restent intactes. La nouvelle carte n'a pas été testée
sur appareil.
