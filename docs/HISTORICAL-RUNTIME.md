# Runtime historique — inventaire et corrélation

Ce document est une synthèse en lecture seule. Aucune image, rootfs ou
partition n'a été modifiée.

## 1. Chaîne de démarrage

```text
sboot
  -> boot.img Android v2 (page 4096, DTB Android dans l'en-tête)
  -> kernel du boot.img = uniLoader
  -> uniLoader embarque Image mainline #35 + DTB mainline + initramfs
  -> /init du rootfs A71ROOT
```

Preuves :

- `work/boot-ipv6.img` : en-tête Android v2, `kernel_size=41280904`,
  `dtb_size=388050`, `ramdisk_size=97` ;
- son kernel extrait est identique octet pour octet à
  `work/uniLoader/uniLoader` (`sha256 18c93df9…`) ;
- `work/uniLoader/blob/Image` est identique à
  `work/kbuild/arch/arm64/boot/Image` (`fec0934f…`) et contient
  `#35 SMP PREEMPT Thu Oct 22 20:06:59 +04 2026` ;
- le DTB de l'en-tête est `repo/artifacts/android.dtb`
  (`451e5946…`) ;
- le rootfs runtime a monté `08299c3f-8560-5f08-9f68-5fe4fbd2c4e5`, UUID de
  `work/sdcard/A71ROOT-init.ext4` / `a71-sd-init.img`.

## 2. Meilleur candidat du boot installé

**`work/boot-ipv6.img` — `BEST_CORRELATED_CANDIDATE`.**

| Preuve | Valeur |
|---|---|
| `uname -a` runtime | `#35 SMP PREEMPT Thu Oct 22 20:06:59 +04 2026` |
| build #35 dans `boot-ipv6` | oui |
| kernel de `boot-ipv6` | identique à `work/uniLoader/uniLoader` |
| Image embarquée | `work/uniLoader/blob/Image` = `work/kbuild/.../Image` (#35) |
| racine runtime | `/dev/mmcblk2p1`, ext4, UUID `08299c3f…` |
| initramfs | `/init` sélecteur historique, hash `dba707e4…` |

Aucune autre image `work/boot-*.img` ne contient #35 : les images #33/#34
sont `INCOMPATIBLE`; les images sans version sont
`INSUFFICIENT_EVIDENCE`. Le hash du boot.img installé n'est pas exposé par
le téléphone : le classement reste **corrélé**, pas `MATCH_CONFIRMED`.

## 3. Inventaire des sources historiques

### Présents

- `repo/initramfs/init` : sélecteur RAM/SD, `exec switch_root /newroot /init` ;
- `repo/base/sbin/a71-system` : PID1 RAM, SSH, USB, route ;
- `repo/base/usr/local/sbin/usb-gadget.sh` : ConfigFS RNDIS + ECM ;
- `repo/base/etc/init.d/a71-{usb,net,route,clock}` ;
- `repo/base/etc/local.d/10-a71-rescue.start` ;
- `repo/base/etc/network/interfaces`, `repo/base/etc/resolv.conf` ;
- `repo/base/etc/modules`, `repo/base/init` ;
- `repo/base/usr/local/bin/wifi-connect`.

### Absents du dépôt statique mais générés par le build

- `etc/conf.d/` (répertoire absent) ;
- `etc/dnsmasq.conf` / `etc/dnsmasq.d` (configuration générée dans `/run`) ;
- `etc/ssh/sshd_config` (généré par `build-base.sh` / `a71-setup.sh`) ;
- `etc/inittab` (paquet Alpine busybox) ;
- `etc/runlevels/**` (créés par `build-base.sh`).

### Configurations et fragments inspectés

- `repo/configs/a71-proposed.config`, `repo/configs/a71-required-symbols.txt`,
  `repo/configs/upstream/pmaports-sm7150.config` ;
- `repo/artifacts/kernel.config` (variante historique, non #35) ;
- `work/config/final.config`, `work/config/merged/.config` (nouveau pipeline) ;
- `work/kbuild/.config` (config corrélée au noyau #35) ;
- `work/kernel-build/kbuild/.config` (nouveau build #1) ;
- `work/kbuild/{vmlinux,System.map,Module.symvers}` et
  `work/kernel-build/kbuild/{vmlinux,System.map,Module.symvers}`.

### Artefacts runtime

- `work/compat/ir-ipv6` : initramfs historique extrait de `boot-ipv6` ;
- `work/rootfs-sd` : rootfs SD historique avec `/init` ;
- `work/rootfs-functional-init-a` / `-b` : nouveau rootfs corrigé ;
- `work/boot-*.img` : 101 images historiques, classées dans
  `work/runtime-analysis/boot-candidate-comparison.tsv` ;
- `work/device-logs` : **absent**.

## 4. Journal runtime fourni

Les pièces jointes analysées :

| Fichier | Constat |
|---|---|
| `boot-diagnostic.txt` | capture à ~9 s ; `uname #35`, racine `/dev/mmcblk2p1` RW |
| `dmesg.txt` | noyau #35, DWC3 init OK, PF_INET6 intégré, 118 erreurs IPv6, erreurs DSI/MSM |
| `proc-modules.txt` | 8 modules, **pas d'`ipv6`** ; aucun module USB `usb_f_*` |
| `relevant-errors.txt` | 118 `ipv6: Unknown symbol` |

État OpenRC au moment de la capture :

- `syslog` : started (boot) ;
- `dhcpcd`, `chronyd`, `sshd`, `local` : stopped (default pas encore lancé) ;
- réseau : uniquement `lo`, aucun `usb0`/`usb1`.

Cette capture est **trop précoce** pour conclure sur l'état final de
`default`. Elle ne prouve pas un échec définitif de `sshd`/`local`.

## 5. Secrets historiques — métadonnées seulement

Aucun contenu n'est reproduit.

| Chemin | Taille | SHA-256 |
|---|---:|---|
| `work/compat/ir-ipv6/etc/ssh/ssh_host_ed25519_key` | 411 | `422e373d…` |
| `work/compat/ir-ipv6/etc/ssh/ssh_host_rsa_key` | 2602 | `7537c0ff…` |
| `work/compat/ir-ipv6/root/.ssh/authorized_keys` | 100 | `8712c6e2…` |
| `work/compat/ir-ipv6/etc/shadow` | 365 | `b3a8ebe3…` |

Ces clés/mot de passe ne doivent pas être réutilisés. Le nouveau rootfs
`rootfs-functional-init-a` ne contient aucune clé privée ; son firstboot
génère les clés hôte.

## 6. Conclusion

Le runtime est bien celui du rootfs corrigé A71ROOT, avec le noyau #35 de
`boot-ipv6`. Le problème USB est userspace ; le problème IPv6 est une
incompatibilité de configuration des exports entre noyau #35 (`IPV6=y`) et
module `ipv6.ko` (`IPV6=m`).
