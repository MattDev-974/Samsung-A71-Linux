# Construction des images (approche reproductible)

Deux couches, comme un `pmbootstrap` simplifié :

```
base/                    surcouche déclarative (fichiers versionnés)
scripts/build-base.sh    Alpine + surcouche  ->  out/a71-base.tar.gz
scripts/a71-setup.sh     base + configuration ->  rootfs installé sur la carte
scripts/a71-install.sh   flash du noyau (BOOT) et installation
```

## 1. La base (`scripts/build-base.sh`)

Construite **sans root et sans émulateur** : `apk.static` (x86_64) installe des
paquets `aarch64` avec `--no-scripts`, puis le script rejoue explicitement ce
que les scripts post-install feraient :

| Étape rejouée | Détail |
|---|---|
| utilisateur `sshd` | `/etc/passwd`, `/etc/group`, `/var/empty` |
| liens busybox | 518 applets (`/bin/ls`, `/sbin/init`, …) depuis `base/busybox-links.txt` |
| runlevels OpenRC | `sysinit` (devfs, dmesg, hwdrivers), `boot` (hostname, modules, syslog…), `default` (sshd, chronyd, crond, local, a71-*) |
| dépôts + clés apk | `/etc/apk/repositories`, `/etc/apk/keys` |
| certificats | bundle CA + `/etc/ssl/cert.pem` (sinon TLS échoue) |
| locale | `LANG=C.UTF-8` |

Contenu de `base/` :

```
base/init                        PID 1 -> exec /sbin/init (OpenRC)
base/etc/init.d/a71-{usb,net,route,clock}   services du téléphone
base/etc/local.d/10-a71-rescue.start        filet de sécurité (sshd)
base/etc/modules                 rtc-pm8xxx
base/etc/ssl/…                   bundle CA + cert.pem
base/lib/modules/<kernel>/       rtc + wifi (14 modules)
base/busybox-links.txt           applets busybox
```

Paquets : `alpine-base openrc openssh chrony tzdata nano htop curl btop sudo
ca-certificates dnsmasq musl-locales ncurses-terminfo e2fsprogs util-linux`.

Archive déterministe : `--owner=0 --group=0 --sort=name --mtime` fixe.

## 2. L'image (`scripts/a71-setup.sh`)

Ne fait **que de la configuration** (écriture de fichiers) :

- `/etc/hostname`, `/etc/hosts`, `/etc/timezone`, `/etc/localtime` ;
- `/etc/shadow` (mot de passe root haché SHA-512, ou `*` verrouillé) ;
- `/etc/ssh/sshd_config.d/10-a71.conf` (root login, auth par clé/mot de passe) ;
- `/root/.ssh/authorized_keys` (+ celui de l'utilisateur créé) ;
- utilisateur normal + groupe `wheel` + `/etc/sudoers.d/` ;
- `sshd` retiré du runlevel si « pas de serveur SSH » ;
- `/etc/a71-install` (trace) et `/etc/a71-version`.

Puis installation sur la carte (ext4) ou USERDATA.

## 3. Validation

Avant publication, l'image est extraite sur le téléphone et testée en `chroot` :

```
busybox OK / shell OK / OpenSSH_10.0p2 / apk-tools 2.14.12 aarch64
rc-service --list -> a71-clock a71-net a71-route a71-usb
```

## 4. Publication

`dist/` contient les artefacts prêts à l'emploi (`boot.img`, `a71-base.tar.gz`,
`heimdall`, `SHA256SUMS`). L'utilisateur final ne construit rien : il lance
`scripts/a71-setup.sh` qui compose la base avec sa configuration.
