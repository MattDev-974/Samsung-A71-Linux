# Contrat `switch_root /newroot /init` — verdict

## Verdict

**`SYMLINK_SUFFICIENT`**

Le lien `/init -> /sbin/init` suffit. Aucun wrapper `/init` n'est nécessaire.

## Preuves

### Sélecteur historique

`repo/initramfs/init:20` et `:46` exécutent exactement :

```sh
exec switch_root /newroot /init
```

Aucun argument n'est passé à `/init`.

### `/sbin/init` réel

Dans `work/rootfs/rootfs-functional-init-a` :

```text
/init       -> /sbin/init
/sbin/init  -> /bin/busybox
/bin/busybox : ELF 64-bit LSB pie, ARM aarch64, dynamique,
               interpréteur /lib/ld-musl-aarch64.so.1
/lib/ld-musl-aarch64.so.1 : présent, exécutable
```

`/sbin/init` est le lien standard Alpine vers BusyBox ; BusyBox contient
l'applet `init` et lit `/etc/inittab`. Le noyau résout `/init` vers
`/sbin/init` puis `/bin/busybox` ; `argv[0]` reste le chemin d'entrée et
BusyBox sélectionne l'applet `init`.

### `/etc/inittab`

Le fichier contient les trois lignes OpenRC nécessaires :

```text
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
```

et la console `tty0`. `ttyMSM0` reste dans la cmdline historique mais n'est pas enregistrée ; son entrée getty est commentée. `/sbin/openrc` est présent et exécutable ;
les runlevels `sysinit`, `boot`, `default`, `shutdown` existent, avec
`devfs`, `procfs`, `sysfs`, `mdev`, `networking`, `local`, `dhcpcd`, `sshd`,
`chronyd`.

### Firstboot

`/etc/local.d/firstboot.start` est idempotent :

```sh
[ -f "$k" ] || ssh-keygen ...
rc-update add sshd default 2>/dev/null || true
```

Il ne dépend pas de `/init` et ne modifie pas le lien.

### Absence de wrapper

Le rootfs ne dépend d'aucun script `/init` historique : le lien est direct,
sans argument, sans logique de montage, sans réseau. Le sélecteur a déjà monté
`/proc`, `/sys`, `/dev` et le rootfs avant `switch_root`.

## Vérification statique

`scripts/validate-rootfs.sh` exige et vérifie :

- `/init` est un lien symbolique ;
- cible textuelle exacte `/sbin/init` ;
- résolution interne vers un fichier régulier exécutable ;
- résolution confinée dans le rootfs ;
- `/sbin/init` présent et exécutable ;
- `/etc/inittab` valide ;
- absence de boucle et de lien sortant.

## Limite

Le rootfs n'a pas été démarré sur le téléphone. `runtime_status=not_tested`,
`validation_status=provisional`.
