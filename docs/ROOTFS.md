# Rootfs fonctionnel — spécification (incrément B)

Spécification du système cible. Aucune valeur secrète n'y figure : ni mot de
passe, ni clé privée, ni clé SSH hôte.

## Identité

| Élément | Valeur retenue |
|---|---|
| Nom d'hôte | `a71` |
| Fuseau horaire | `UTC` (aucun fichier `/etc/localtime` imposé) |
| Locale | `C.UTF-8` (musl Alpine) |
| Clavier | non configuré (pas de `loadkeys` dans l'image minimale) |
| Série Alpine | `v3.22`, version `3.22.7`, arch `aarch64` |
| Dépôts | `main` + `community` officiels v3.22 uniquement |

## Paquets (liste minimale justifiée)

| Paquet | Justification |
|---|---|
| `alpine-base` | métapaquet de base (openrc, busybox, alpine-baselayout, etc.) |
| `busybox` / `busybox-openrc` | shell et applets, scripts OpenRC |
| `openrc` | système d'init |
| `ca-certificates` | confiance TLS pour `apk` et `ssh` |
| `iproute2` | `ip`, diagnostic réseau |
| `openssh-server` | accès distant |
| `e2fsprogs` | `fsck`/`mkfs` ext4 (racine A71ROOT) |
| `util-linux` | `mount`, `blkid`, `switch_root` |
| `kmod` | `modprobe`/`depmod` pour la release noyau |
| `dhcpcd` | client DHCP sur `usb0`/`usb1` |
| `chrony` | synchronisation temporelle |

Aucun paquet « au cas où ». Chaque paquet devra être enregistré dans un
inventaire déterministe avec version et dépôt d'origine.

## Matériel et noyau

| Élément | Valeur |
|---|---|
| Release noyau | `6.18.0-rc1-a71+` (unique autorisée) |
| Modules | 607, intégrés par `scripts/integrate-kernel-modules.sh` |
| Console locale | `tty0` (`console=tty0`) |
| Console série | `ttyMSM0,115200n8` dans la cmdline, **non enregistrée** sur le noyau #35 ; entrée getty commentée en M5 |
| Racine | partition ext4 étiquetée `A71ROOT` |

## Réseau

- interfaces USB gadget côté appareil : `usb0` (`172.16.42.1`), `usb1` (`172.16.43.1`) ;
- **DHCP** activé sur `usb0` (le client obtient son adresse côté hôte) ;
- DNS : `/etc/resolv.conf` statique `nameserver 1.1.1.1` **ou** fourni par DHCP —
  politique à trancher : par défaut, `dhcpcd` gère `/etc/resolv.conf` ;
- aucune route par défaut imposée sans bail DHCP.

## Comptes et sécurité

| Règle | Politique |
|---|---|
| Mot de passe par défaut | **aucun** |
| `root` distant | **verrouillé** : `PermitRootLogin no`, `PasswordAuthentication no` |
| Clés privées | **aucune** préinstallée |
| Clés SSH hôte | **générées au premier démarrage**, jamais copiées depuis la machine de build |
| Utilisateur administrateur | créé seulement si une méthode sûre de provisionnement existe ; sinon mécanisme de premier démarrage préparé **sans** mot de passe |
| Secrets dans le dépôt | interdits |

## Services OpenRC

`devfs`, `procfs`, `sysfs`, `mdev`, `networking`, `dhcpcd`, `sshd`, `chronyd`.
Les services dont le paquet n'est pas installé ne doivent **pas** être activés
(pas de configuration incohérente).

## Montages

`/proc`, `/sys`, `/dev`, `/run` montés par l'init ; `/etc/fstab` minimal
(`A71ROOT` sur `/`), sans entrée superflue.

## Premier démarrage

Script idempotent (`/etc/local.d/firstboot.start` ou équivalent) :
génération des clés SSH hôte si absentes, création de l'utilisateur si un
provisionnement sûr est fourni, marqueur de fin pour ne rien refaire.

## Propriétaires et modes (D1)

La copie non privilégiée ne restaure pas les UID/GID d'origine.
`ownership-manifest.txt` décrit les propriétaires **logiques de l'image**
attendus au format `uid:gid:mode:type:path`; il ne prétend jamais que l'hôte
les porte réellement.

Les modes ne viennent **jamais** de l'umask de l'hôte. L'umask `077` est
réservé aux temporaires et rapports privés ; le rootfs cible est construit avec
`022`, puis chaque mode est appliqué chemin par chemin depuis :

1. l'archive `alpine-minirootfs-3.22.7-aarch64.tar.gz` vérifiée par SHA-256 et
   SHA-512 ;
2. les métadonnées tar des paquets `.apk` signés (pas l'extraction de l'hôte) ;
3. `configs/rootfs-mode-policy.txt` pour les chemins sensibles et les fichiers
   créés par le projet.

| Chemin | Mode cible | Source |
|---|---|---|
| `/` | `0755` | minirootfs |
| `/root` | `0700` | minirootfs |
| `/tmp`, `/var/tmp` | `01777` | minirootfs |
| `/bin/busybox` | `0755` | paquet `busybox` 1.37.0-r20 |
| `/bin/bbsuid` | `04111` | paquet `busybox-suid` 1.37.0-r20 (setuid root) |
| `/bin/mount`, `/bin/umount` | `04755` | paquets `mount`/`umount` 2.41.6-r1 |
| `/usr/sbin/unix_chkpwd` | `02755` (gid 42) | paquet `linux-pam` 1.7.0-r4 |
| `/usr/bin/wall` | `02755` (gid 5) | paquet `util-linux-misc` 2.41.6-r1 |
| `/var/log/chrony` | `02750` (gid 10) | paquet `chrony` 4.6.1-r1 |
| `/etc/passwd`, `/etc/group` | `0644` | paquet `alpine-baselayout-data` |
| `/etc/shadow` | `0640` | paquet `alpine-baselayout-data` |
| `/lib/modules/**/*.ko` | `0644` | politique projet (modules noyau) |

Aucun `chmod -R` général n'est utilisé. `/etc/gshadow` est absent de cette
image Alpine (aucun paquet `shadow`) ; s'il est présent, il doit rester non
lisible par les autres. La reconstruction D1 est reproductible : deux sorties
indépendantes ont les mêmes chemins, contenus, liens, modes, UID/GID logiques et
paquets.

## Image ext4 (H2)

`work/sdcard/A71ROOT.ext4` est construite sans montage ni loop device :
`mke2fs -d` copie l'arbre, puis `debugfs sif` applique les 2 086 entrées du
manifeste (UID/GID/mode/type). Caractéristiques :

| Élément | Valeur |
|---|---|
| Taille | 1 GiB (1 073 741 824 octets) |
| Label | `A71ROOT` |
| UUID | déterministe (UUIDv5 du projet) |
| Bloc / inode | 4 096 / 256 octets |
| Inodes | 16 384 |
| Journal | désactivé (`^has_journal`) |
| Options | `lazy_itable_init=0`, `nodiscard`, `hash_seed` fixe, `root_owner=0:0` |
| Propriétaires | logiques, appliqués par `debugfs` |
| `bin/bbsuid` | `04111` (contenu extrait du paquet signé, non lu depuis l'hôte) |

Deux constructions indépendantes ont le même contenu, les mêmes modes,
UID/GID, label et UUID. Les images ne sont pas bit à bit identiques : les
champs ext4 de timestamps/checksums (`s_wtime`, tables d'inodes spéciales)
varient ; la reproductibilité **logique** est vérifiée (2 086 entrées,
`e2fsck -fn`, arbre extrait, contenu, modes). Voir
`work/sdcard/reports/ext4-reproducibility.txt`.

## Limites

- Aucun test matériel : `runtime_status: not_tested`, `validation_status: provisional`.
- Aucun `chroot`, montage, QEMU ou `sudo` dans la construction.


## Contrat `/init` (L)

Le rootfs corrigé contient exactement `/init -> /sbin/init`, avec UID/GID
logiques `0:0`, et `/sbin/init -> /bin/busybox`. Le manifeste de propriétaires
passe à **2087 entrées** ; le lien est aussi présent dans `reports/symlinks.txt`
et `reports/init-link.txt`. Voir `docs/INIT-CONTRACT.md`.

Le rootfs historique `work/rootfs/rootfs-functional` (2086 entrées, sans
`/init`) reste inchangé et n'est plus la cible du test SD.

## M1 — rootfs USB/SSH

Le rootfs `work/rootfs/rootfs-functional-usb-c` (et `-d` pour la
reproductibilité) contient **100 paquets** : les 97 précédents plus
`dnsmasq`, `dnsmasq-common` et `dnsmasq-openrc`.

Services ajoutés : `a71-usb`, `a71-net`, `a71-ssh-keys`, `a71-bootlog`.
Le manifeste passe à **2106 entrées**. `/init -> /sbin/init` est conservé.
`ipv6.ko` est neutralisé par `etc/modprobe.d/a71-historical-kernel.conf`
(`blacklist ipv6`, `install ipv6 /bin/false`) ; IPv6 intégré au noyau #35
n'est pas désactivé. Aucune clé privée ni `authorized_keys` n'est embarquée.
