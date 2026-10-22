# Modes de démarrage

Le choix du mode se fait par un fichier **`/a71.mode`** sur la carte SD, lu par
le sélecteur qui sert de PID 1 dans l'initramfs (`rootfs/init` de l'initramfs).

| Contenu de `/a71.mode` | Effet |
|---|---|
| `sd` | rootfs = `a71-rootfs.ext4` sur la carte SD (loop + `switch_root`) |
| `sd:<fichier>` | rootfs = image ext4 donnée sur la carte |
| absent / autre | mode RAM : rootfs de l'initramfs, rien n'est persisté |

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
