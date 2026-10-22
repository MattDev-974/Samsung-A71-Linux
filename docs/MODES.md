# Modes de démarrage

Le choix du mode se fait par un fichier **`/a71.mode`** sur la carte SD, lu par
le sélecteur qui sert de PID 1 dans l'initramfs (`rootfs/init` de l'initramfs).

Le sélecteur teste d'abord une **partition ext4** sur la carte (montage
direct, pas de loop). Si elle existe, il démarre dessus sans condition.

Sinon il lit `/a71.mode` :

| Contenu de `/a71.mode` | Effet |
|---|---|
| `sd` | rootfs = `a71-rootfs.ext4` sur la carte SD (loop + `switch_root`) |
| `sd:<fichier>` | rootfs = image ext4 donnée sur la carte |
| absent / autre | mode RAM : rootfs de l'initramfs, rien n'est persisté |

## Mode ext4 direct (recommandé)

Toute la carte devient un système de fichiers ext4 : pas de loop, capacité
totale, écriture directe.

```bash
# sur le PC, avec root (EFFACE la carte)
sudo ./scripts/make-sd-ext4.sh /dev/sdX ../work/a71-rootfs.tar.gz
```

Le script formate **le périphérique entier** (label `a71root`) et y extrait le
rootfs. Au démarrage :

```
a71: direct ext4 root on /dev/mmcblk2
/dev/mmcblk2 on / type ext4 (rw,relatime)
28.5G total, 27G libres
```

### Pièges rencontrés

- `blkid` de busybox **ignore `-s TYPE -o value`** et renvoie la ligne
  complète : ne pas l'utiliser pour la détection, tester le montage ext4
  directement ;
- formater le périphérique entier ne crée **pas** de partition : le candidat
  est `/dev/mmcblk2`, pas `/dev/mmcblk2p1`.

## Mode SD (persistant)

1. Construire l'image rootfs sur le PC :

```bash
mke2fs -q -t ext4 -d rootfs/ -L a71root a71-rootfs.ext4 384M
```

2. La copier sur la carte SD (FAT32) avec `a71.mode` contenant `sd` :

```bash
cp a71-rootfs.ext4 /media/SD/
echo sd > /media/SD/a71.mode
```

3. Démarrer : le sélecteur monte l'image en `/dev/loop0`, déplace `/mnt/sd`,
   puis `switch_root`.

### Ce qui a été nécessaire

- busybox `losetup` n'a pas `-j` : utiliser directement `/dev/loop0` ;
- l'image est construite sans root, donc `/root/.ssh/authorized_keys`
  appartient à l'utilisateur : ajouter **`StrictModes no`** dans
  `sshd_config.d/10-a71.conf` ;
- garder un fallback RAM si l'image est absente ou illisible.

## Vérifications

```
a71: mode=[sd]
a71: switch_root to /mnt/sd/a71-rootfs.ext4
/dev/loop0 on / type ext4 (rw,relatime)
/persist.txt survit au redémarrage
```
