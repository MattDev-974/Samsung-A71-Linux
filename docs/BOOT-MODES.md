# Modèle de démarrage réel — RAM et SD

Ce document décrit **uniquement ce qui est prouvé par les fichiers et
artefacts présents**. Les points non prouvés sont marqués `UNKNOWN`.

## 1. Chaîne de démarrage observée

```
sboot (bootloader Samsung)
  -> partition BOOT : boot.img v2
       kernel = uniLoader brut (pas le noyau Linux)
       dtb    = DTB Android/Lineage
       ramdisk= cpio.gz vide
  -> uniLoader (embarque Image + DTB mainline + initramfs)
  -> noyau Linux 6.18.0-rc1-a71+
  -> initramfs : /init (sélecteur de mode)
  -> RAM : exec /sbin/a71-system
     ou SD : switch_root /newroot /init
```

Preuves :

- `work/boot-ipv6.img` : en-tête Android v2, `kernel_size=41280904`,
  `dtb_size=388050`, `ramdisk_size=97` (`work/compat/boot-analysis/boot-ipv6/stock-boot-analysis.txt`).
- Son kernel extrait est **bit à bit** `work/uniLoader/uniLoader`
  (`sha256 18c93df95bc8a475f388e76509567fc10e6c3530d335edefbc625c67f1c478dd`).
- Son DTB extrait est `repo/artifacts/android.dtb`
  (`sha256 451e5946f841fab9ad8b65b16e328e03560c64001c4d5600bcac3d016a023c14`).
- Son initramfs extrait contient `/init` de hash
  `dba707e45f2df2e529ead65f3201ba9a4099755d7e5961b7852623e894a841ae`,
  identique à `repo/initramfs/init`.
- La construction historique est décrite dans `repo/scripts/build-boot.sh:3-5`,
  `:58-68` : le kernel du boot.img est `uniLoader.img`, le ramdisk est vide et
  le DTB est l'Android DTB.

L'image **réellement installée** n'est pas prouvée par le workspace : plusieurs
`work/boot-*.img` existent ; `boot-ipv6.img` est le candidat dont le contenu
correspond exactement aux sources et à `work/uniLoader/uniLoader`. Ce point
reste `UNKNOWN` et interdit toute conclusion sur l'état matériel.

## 2. Sélecteur `/init`

Le sélecteur est `repo/initramfs/init` (identique à
`work/compat/ir-ipv6/init`).

### 2.1 Mode ext4 direct — priorité absolue

Lignes 15-22 :

```sh
# 1) direct ext4 partition on the card -> use it as the root filesystem
for d in /dev/mmcblk2p2 /dev/mmcblk2p1 /dev/mmcblk2 /dev/mmcblk1p2 /dev/mmcblk1p1 /dev/mmcblk1; do
    [ -b "$d" ] || continue
    if mount -t ext4 "$d" /newroot 2>/dev/null; then
        echo "a71: direct ext4 root on $d" > /dev/kmsg
        exec switch_root /newroot /init
    fi
done
```

Conséquences prouvées :

- toute partition ext4 de cette liste est montée **avant** la lecture de
  `/a71.mode` ;
- le root identifier est le **chemin de périphérique**, pas un label ni un
  UUID ;
- si `mmcblk2p1` est ext4, elle est utilisée directement ;
- le handoff est **`/newroot/init`**.

### 2.2 Mode fichier image — `a71.mode`

Lignes 24-51 :

```sh
for d in /dev/mmcblk2p1 /dev/mmcblk2 /dev/mmcblk1p1 /dev/mmcblk1; do
    mount "$d" /mnt/sd || mount -t vfat "$d" /mnt/sd || continue
    break
done
mode=$(tr -d ' \r\n' < /mnt/sd/a71.mode 2>/dev/null)
case "$mode" in
  sd*)
    img=/mnt/sd/a71-rootfs.ext4
    case "$mode" in sd:*) img="/mnt/sd/${mode#sd:}";; esac
    losetup /dev/loop0 "$img"
    mount -t ext4 /dev/loop0 /newroot
    exec switch_root /newroot /init
```

Valeurs documentées dans `repo/docs/MODES.md:11-15` :

| `/a71.mode` | Effet |
|---|---|
| `sd` | image `a71-rootfs.ext4` sur la carte, loop + `switch_root` |
| `sd:<fichier>` | image ext4 indiquée |
| absent / autre | mode RAM |

Le montage de l'image utilise `/dev/loop0` car le `losetup` BusyBox n'a pas
`-j` (`repo/docs/MODES.md:64`).

### 2.3 Repli RAM

Lignes 49-54 :

```sh
echo "a71: $img unusable, falling back to RAM" > /dev/kmsg
...
echo "a71: RAM mode" > /dev/kmsg
exec /sbin/a71-system
```

Le mode RAM est aussi choisi si aucune partition ext4 n'est montée, si aucun
`système de fichiers FAT` n'est monté, ou si `/a71.mode` est absent/vide.
Il n'y a **aucun bouton, GPIO, délai ou menu** dans le sélecteur.

## 3. Mode RAM

`/sbin/a71-system` (version historique extraite de `boot-ipv6`, hash
`8436c6d7…` ; la copie `repo/base/sbin/a71-system` est une variante, hash
`37188ea4…`) est exécuté comme PID 1. Il :

- monte `/proc`, `/sys`, `/dev`, `/dev/pts`, `/tmp`, `/run`
  (`repo/base/sbin/a71-system:12-19`) ;
- démarre `sshd -e` (`:23-27`) ;
- démarre le gadget USB et configure `usb0`/`usb1` (`:29-83`) ;
- ouvre des shells locaux sur `tty1` et `ttyMSM0` (`:93-108`) ;
- maintient PID 1 en vie par `while true; do wait; done` (`:122-125`) ;
- ajoute une route par défaut vers le pair DHCP (`:157-174`).

La version historique embarquée dans `boot-ipv6` est l'initramfs complet :
rootfs en RAM, pas de `switch_root`.

## 4. Mode SD

Le mode SD suppose que le rootfs contient un `/init` exécutable : le sélecteur
fait `exec switch_root /newroot /init` (lignes 20 et 46). Le rootfs historique
`work/rootfs-sd` contient bien `/init` (5806 octets) ; `repo/base/init` est le
wrapper OpenRC (10 lignes) qui fait `exec /sbin/init`.

### 4.1 Nouvelle carte A71ROOT — incompatibilité constatée

La nouvelle image `work/rootfs/rootfs-functional` **ne contient pas `/init`** :

```
$ ls work/rootfs/rootfs-functional/init
ls: ... No such file or directory
$ ls -l work/rootfs/rootfs-functional/sbin/init
... /sbin/init -> /bin/busybox
```

Or le sélecteur installé exécute `switch_root /newroot /init`. Le nouveau
rootfs n'a que `/sbin/init` et `/etc/inittab`. **Le mode SD avec la nouvelle
carte n'est donc pas compatible avec le sélecteur historique**, sauf preuve
contraire d'un initramfs installé différent.

Ce point produit `ROOT_IDENTIFIER_MISMATCH` (handoff `/init` absent) dans le
vérificateur K4 et **bloquait le protocole SD**.

Correction L : `work/rootfs/rootfs-functional-init-a` (et `-init-b`) contient
maintenant le lien exact `/init -> /sbin/init` (manifeste 2087 entrées), et
l'image `work/sdcard/A71ROOT-init.ext4` / `a71-sd-init.img` l'embarque. Voir
`docs/INIT-CONTRACT.md` et `work/compat/SD-MODE-TEST-init.md`. La carte
corrigée reste **non testée sur appareil**.

## 5. Absence de carte, erreurs et secours

| Situation | Comportement prouvé |
|---|---|
| aucune carte / aucun ext4 | boucle ext4 échoue, montage FAT échoue, `mode` vide → RAM (`init:15-54`) |
| carte ext4 mais montage échoue | essai du candidat suivant puis FAT, sinon RAM |
| `a71.mode=sd` mais image absente/illisible | message `unusable, falling back to RAM` (`init:49`) |
| rootfs SD sans `/init` | `switch_root` échoue ; **pas de repli automatique** |
| RAM sans interface USB | `setup_usb` échoue après 120 s ; shell local toujours disponible (`a71-system:76-83`) |
| OpenRC sans USB | `a71-net` échoue après 60 s (`base/etc/init.d/a71-net:37-44`) ; rescue local après 90 s (`base/etc/local.d/10-a71-rescue.start:5-10`) |

## 6. Identifiant root de la nouvelle carte

`work/sdcard/A71ROOT.ext4` a le label `A71ROOT` et l'UUID
`c1286da3-1e16-5e15-8c2d-053f625c541c`. Le sélecteur historique **n'utilise
ni ce label ni cet UUID** : il essaie les chemins `/dev/mmcblk2p2`,
`/dev/mmcblk2p1`, `/dev/mmcblk2`, etc. Sur la carte observée historiquement,
`/dev/mmcblk2p1` était la partition (`work/sd-dmesg.txt:2-3,422-424,464`).

Le nom réel sur le téléphone au prochain démarrage reste `UNKNOWN` ; il ne faut
pas le supposer.

## 7. Inconnues

- image boot réellement installée (le workspace contient plusieurs candidates) ;
- variante exacte du rootfs historique installé (plusieurs archives) ;
- nom de périphérique au prochain démarrage ;
- comportement de la nouvelle carte A71ROOT avec le sélecteur installé, qui
  exige `/init` et ne le trouve pas dans `rootfs-functional`.
