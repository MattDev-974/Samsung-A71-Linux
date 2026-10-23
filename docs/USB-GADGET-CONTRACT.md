# Contrat USB gadget historique

Source de vérité : `repo/base/` et l'initramfs historique extrait
`work/compat/ir-ipv6`. Aucune valeur n'est supposée.

## 1. ConfigFS

`repo/base/usr/local/sbin/usb-gadget.sh` :

| Élément | Valeur | Ligne |
|---|---|---|
| ConfigFS | `/sys/kernel/config` | 9 |
| Gadget | `usb_gadget/a71` | 10 |
| `idVendor` | `0x1d6b` | 23 |
| `idProduct` | `0x0104` | 24 |
| `bcdDevice` / `bcdUSB` | `0x0100` / `0x0200` | 25-26 |
| classe appareil | `0xef/0x02/0x01` | 27-29 |
| manufacturer | `Nura` | 32 |
| product | `Galaxy A71` | 33 |
| serialnumber | `a71-0001` | 34 |
| configuration | `RNDIS + ECM` | 37 |
| MaxPower | `250` | 38 |
| RNDIS | `functions/rndis.usb0` | 40 |
| ECM | `functions/ecm.usb0` | 42 |
| MAC RNDIS device | `02:1a:71:00:00:01` | 41 |
| MAC ECM device | `02:1a:71:00:00:02` | 43 |
| MAC ECM host | `02:1a:71:00:00:03` | 44 |
| liens config | `configs/c.1/rndis.usb0`, `ecm.usb0` | 46-47 |

L'UDC n'est pas codé en dur : le script attend une entrée dans
`/sys/class/udc` pendant 30 s (`usb-gadget.sh:50-60`), puis écrit son nom
dans `UDC` (`:66-68`). L'UDC observé historiquement est `a600000.usb`
(`repo/docs/AUDIT.md:134`), mais le script accepte le nom réel.

## 2. Interfaces et IPv4

`repo/base/sbin/a71-system:35-83` et `repo/base/etc/init.d/a71-net:10-35` :

| Interface | Adresse | Rôle |
|---|---|---|
| `usb0` | `172.16.42.1/24` | RNDIS |
| `usb1` | `172.16.43.1/24` | ECM |
| hôte RNDIS | DHCP `172.16.42.100-150` | bail dnsmasq |
| hôte ECM | DHCP `172.16.43.100-150` | bail dnsmasq |

- masque : `255.255.255.0` (`a71-system:53`) ;
- passerelle DHCP : adresse du téléphone (`:54`) ;
- DNS : `1.1.1.1`, `9.9.9.9` (`:55`) ;
- route téléphone : pair DHCP, `usb0` puis `usb1` (`a71-system:157-174`) ;
- `repo/base/etc/resolv.conf` contient explicitement les deux DNS ;
- `repo/base/scripts/host-nat.sh` documente le NAT hôte optionnel
  (`host-nat.sh:5-9,22-23`).

Aucun `usb0`/`usb1` n'apparaît dans le journal runtime à 9 s. Le noyau dit
seulement `dwc3 ... gadget init OK` (`dmesg.txt:551-553`), sans UDC ni
configfs userspace.

## 3. OpenRC et ordre de démarrage

Services :

| Service | Rôle | Dépendances |
|---|---|---|
| `a71-usb` | démarre le gadget | `need localmount`, `after devfs`, `before sshd` ; **ne fournit pas `net`** |
| `a71-net` | adresses, dnsmasq, DHCP | `need a71-usb`, `before sshd`, `provide net` |
| `a71-route` | route par défaut auto-réparante | `need a71-net`, `after a71-net` |
| `a71-clock` | NTP par IP + RTC | `need a71-net a71-route`, `before sshd` |
| `sshd` | SSH | default |

La correction du conflit OpenRC est visible : `a71-usb` ne contient **pas**
`provide net` (`base/etc/init.d/a71-usb:4-8`) ; seul `a71-net` fournit `net`
(`base/etc/init.d/a71-net:4-8`). Cela évite deux fournisseurs de `net`.

Activation : `build-base.sh:85-90` crée les runlevels `sysinit`, `boot`,
`default`, `shutdown` et lie `a71-usb`, `a71-net`, `a71-route`, `a71-clock`
et `sshd`. Les scripts sont rendus exécutables (`build-base.sh:105-108`).

## 4. `/run`, PID1 et secours

- `/run` est monté tôt en tmpfs par `a71-system:12-19` et par le wrapper
  OpenRC `base/init:7-10` ;
- PID1 historique `a71-system` ne sort jamais : boucle `while true; do wait;
  done` (`a71-system:122-125`) ;
- le wrapper OpenRC fait `exec /sbin/init` et ne sort pas (`base/init:7-10`) ;
- filet de sécurité : `10-a71-rescue.start` attend 90 s, vérifie
  `/sys/class/net/usb0`, puis relance `/sbin/a71-system`
  (`base/etc/local.d/10-a71-rescue.start:5-10`) ;
- arrêt : `a71-net stop` tue dnsmasq (`a71-net:65-69`) ;
  `usb-gadget.sh stop` détache l'UDC (`usb-gadget.sh:73-77`).

## 5. IPv6 historique

Aucune configuration IPv6 n'est présente dans `a71-net`, `a71-system` ou
`usb-gadget.sh`. Le réseau historique est IPv4 uniquement. Le noyau #35 a
`CONFIG_IPV6=y`, mais le module `ipv6.ko` chargé par le nouveau rootfs est
incompatible (voir `KERNEL-MODULE-COMPATIBILITY.md`).

## 6. Comparaison avec le nouveau rootfs

Présent dans `work/rootfs/rootfs-functional-init-a` :

- `etc/network/interfaces` : `usb0` en **client** DHCP ;
- `etc/runlevels/default/sshd` ;
- `etc/local.d/firstboot.start` ;
- pas de `etc/resolv.conf`.

Absent :

- `etc/init.d/a71-usb`, `a71-net`, `a71-route`, `a71-clock` ;
- `usr/local/sbin/usb-gadget.sh` ;
- `etc/resolv.conf` ;
- dnsmasq / configuration DHCP serveur ;
- configuration `usb1`/ECM ;
- route par défaut vers le pair DHCP ;
- filet de sécurité `10-a71-rescue.start`.

Le nouveau rootfs ne peut donc pas créer le gadget ni fournir DHCP, même si
le noyau DWC3 est prêt. C'est la cause immédiate de l'absence de `usb0`/SSH.


## Correction M3

L'échec M2 venait de liens ConfigFS **relatifs**
(`../functions/...`) : le gadget était partiellement créé, puis
`a71-usb` échouait avant la liaison UDC. La référence utilise des liens
**absolus** (`$G/functions/...`) et attend l'UDC après création. Le script
`repo/rootfs/usr/local/sbin/a71-usb-gadget` applique désormais cette logique :
liens absolus et attente UDC de 30 s après création. Aucun secret de la
référence n'a été copié.
