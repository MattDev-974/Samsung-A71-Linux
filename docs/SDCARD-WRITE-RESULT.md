# Résultat de l'écriture microSD — constat humain

Ce document ne consigne que les faits fournis par l'utilisateur lors de
l'écriture et de la vérification sur son hôte. Il ne constitue ni une
validation de démarrage, ni une validation du téléphone.

## Image source

| Élément | Valeur |
|---|---|
| Fichier | `work/sdcard/a71-sd.img` |
| Taille | `1 074 790 400` octets |
| SHA-256 source | `2a42768f5d81046bb96da5d0ad3447a1ddc77ef258207314d55e7a7631aeef9d` |
| SHA-256 relu après écriture | `2a42768f5d81046bb96da5d0ad3447a1ddc77ef258207314d55e7a7631aeef9d` |
| Table | MBR/DOS, identifiant `0xa71a71a7` |
| Partition | une seule, type Linux `83` |

## Cible au moment de l'écriture

| Élément | Valeur |
|---|---|
| Périphérique | `/dev/sde` |
| `MAJ:MIN` | `8:64` |
| `TYPE` | `disk` |
| `RM` / `RO` | `1` / `0` |
| Taille | `30 979 129 344` octets |
| Modèle | `STORAGE DEVICE` |
| Série | `000000000272` |
| Transport | `usb` |

`/dev/sde` est une identité éphémère : le nom, le numéro majeur/mineur et la
taille peuvent changer après rebranchement. Toute nouvelle écriture exige un
nouveau contrôle humain.

## Partition écrite

| Élément | Valeur |
|---|---|
| Partition | `/dev/sde1` |
| Système de fichiers | ext4 |
| Label | `A71ROOT` |
| UUID | `c1286da3-1e16-5e15-8c2d-053f625c541c` |
| Taille | `1 073 741 824` octets |
| Offset dans l'image | `1 048 576` octets (secteur 2048) |

## Résultat observé

- écriture de l'image disque : **réussie** ;
- relecture et comparaison du SHA-256 : **réussie** ;
- partition `/dev/sde1` détectée en ext4, label `A71ROOT`, UUID attendu ;
- montage automatique observé : **non rapporté par l'utilisateur** (à
  contrôler avant toute nouvelle opération) ;
- aucune validation de démarrage n'a été effectuée ;
- aucune validation du téléphone n'a été effectuée.

## Portée

Il s'agit d'un **résultat observé sur un hôte humain**. Il ne prouve pas que
le noyau, l'initramfs, uniLoader ou le rootfs démarrent sur l'appareil.

Les statuts restent :

- `runtime_status: not_tested` ;
- `validation_status: provisional`.
