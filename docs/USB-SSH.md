# Réseau USB et SSH — modèle prouvé

Ce document décrit l'implémentation historique réellement présente dans
`repo/base/` et dans l'initramfs historique extrait. Les valeurs non prouvées
sont marquées `UNKNOWN`.

## 1. Gadget USB

`repo/base/usr/local/sbin/usb-gadget.sh` crée un gadget configfs nommé `a71` :

| Élément | Valeur | Preuve |
|---|---|---|
| Backend | configfs `usb_gadget/a71` | `usb-gadget.sh:9-10` |
| Vendor ID | `0x1d6b` | `usb-gadget.sh:23` |
| Product ID | `0x0104` | `usb-gadget.sh:24` |
| Fabricant | `Nura` | `usb-gadget.sh:32` |
| Produit | `Galaxy A71` | `usb-gadget.sh:33` |
| Numéro de série gadget | `a71-0001` | `usb-gadget.sh:34` |
| Fonctions | RNDIS + CDC-ECM | `usb-gadget.sh:40-47` |
| MAC RNDIS | `02:1a:71:00:00:01` | `usb-gadget.sh:41` |
| MAC ECM device | `02:1a:71:00:00:02` | `usb-gadget.sh:43` |
| MAC ECM host | `02:1a:71:00:00:03` | `usb-gadget.sh:44` |
| UDC | découvert dans `/sys/class/udc`, attente 30 s | `usb-gadget.sh:50-70` |

Dépendances noyau : `CONFIG_USB_DWC3`, `CONFIG_USB_CONFIGFS`,
`CONFIG_USB_CONFIGFS_RNDIS` et `CONFIG_USB_CONFIGFS_ECM`
(`repo/artifacts/kernel.config` ; `repo/docs/KERNEL_CONFIG.md:36`). Le module
`libcomposite` est chargé par le script (`usb-gadget.sh:13`).

Le contrôleur attendu est `dwc3` ; `repo/docs/AUDIT.md:134` note l'UDC
`a600000.usb`, mais le script ne code pas ce nom en dur. Le nom réel de l'UDC
reste `UNKNOWN` tant qu'il n'est pas observé sur l'appareil.

## 2. Interfaces et adresses

| Côté | Interface | Adresse | Preuve |
|---|---|---|---|
| Téléphone RNDIS | `usb0` | `172.16.42.1/24` | `base/sbin/a71-system:43-50` ; `base/etc/init.d/a71-net:18-25` |
| Téléphone ECM | `usb1` | `172.16.43.1/24` | idem |
| Hôte RNDIS | nom dépendant du pilote | DHCP `172.16.42.100`–`172.16.42.150` | `base/sbin/a71-system:52-56` |
| Hôte ECM | nom dépendant du pilote | DHCP `172.16.43.100`–`172.16.43.150` | idem |

- masque : `255.255.255.0` (`base/sbin/a71-system:53`) ;
- mode : **DHCP côté hôte**, serveur `dnsmasq` côté téléphone ;
- passerelle annoncée par DHCP : l'adresse du téléphone (`.1`) ;
- DNS annoncés : `1.1.1.1`, `9.9.9.9` (`base/sbin/a71-system:55`) ;
- route par défaut du téléphone : vers le bail DHCP de l'hôte, interface
  `usb0` prioritaire puis `usb1` (`base/sbin/a71-system:157-174`).

L'adresse IP exacte de l'hôte **n'est pas fixe** : c'est un bail DHCP dans les
plages ci-dessus. Elle ne doit jamais être supposée. Le nom de l'interface
côté Arch Linux dépend du pilote RNDIS/ECM (`usb0`, `enp0s20u1`, etc.) ; il
faut le lire avec `ip -brief link`.

`repo/scripts/host-nat.sh:5-9,22-23` documente le partage Internet côté hôte :
le PC prend un bail `172.16.42.100-150` et fait du NAT vers son interface
montante. Ce NAT est optionnel pour SSH local.

## 3. SSH

### 3.1 Service

- binaire : `/usr/sbin/sshd` ;
- démarrage RAM : `sshd -e` dans `/sbin/a71-system:23-27` ;
- démarrage OpenRC : service `sshd` dans le runlevel `default`
  (`scripts/build-base.sh:90`) ;
- port : `22` (aucune directive `Port` dans les configurations inspectées ;
  c'est le défaut OpenSSH — à confirmer si une configuration locale le change) ;
- utilisateur historique autorisé : `root` ;
- `UseDNS no`, `X11Forwarding no`, `StrictModes no`
  (généré par `scripts/build-base.sh:127-136` ; l'initramfs historique
  contient sa propre copie).

### 3.2 Variantes d'authentification

| Source | PermitRootLogin | PasswordAuthentication | Clé |
|---|---|---|---|
| `repo/base` / `build-base.sh:127-136` | `prohibit-password` | `no` | oui |
| `scripts/build-rootfs.sh:107-117` (legacy) | `yes` | `yes` | selon image |
| `scripts/a71-setup.sh:199-217` | réponse utilisateur, défaut `prohibit-password` | `no` par défaut | `authorized_keys` si clé |
| initramfs historique `work/compat/ir-ipv6` | `yes` | `yes` | `root/.ssh/authorized_keys` présent |

La configuration exacte du système actuellement installé est `UNKNOWN` : le
workspace contient plusieurs variantes. Ne jamais supposer un mot de passe.

### 3.3 Clés et secrets

**Ne pas publier de contenu de clé privée ni de hash de mot de passe.**

Constats :

- l'initramfs historique extrait contient des clés **hôte privées**
  (`work/compat/ir-ipv6/etc/ssh/ssh_host_{rsa,ecdsa,ed25519,mldsa44_ed25519}_key`,
  hashes SHA-256 `7537c0ff…`, `0834d4a8…`, `422e373d…`, `9457f383…`) ;
- il contient `/etc/shadow` (hash `b3a8ebe3…` du fichier, pas son contenu) ;
- il contient `root/.ssh/authorized_keys` (clé **publique** autorisée,
  hash `8712c6e2…`, 100 octets) ;
- plusieurs `work/rootfs-*` historiques contiennent aussi des clés hôte
  privées et des `authorized_keys` ; ces artefacts ne doivent pas être
  publiés ;
- les images `repo/dist/` inspectées n'embarquent pas de clé hôte privée
  (l'archive `a71-base` n'en contient pas) ;
- le nouveau rootfs `work/rootfs/rootfs-functional` **ne contient aucune clé
  privée** (E1) ; il génère les clés hôte au premier démarrage via
  `etc/local.d/firstboot.start`.

Les clés hôte et les `authorized_keys` sont donc des secrets/présences
sensibles dans les artefacts historiques, pas dans le nouveau rootfs.

### 3.4 Disponibilité RAM/SD

| Mode | SSH | Réseau USB |
|---|---|---|
| RAM historique | `sshd` lancé par `/sbin/a71-system`, clés hôte présentes, `authorized_keys` présent | gadget + dnsmasq + adresses `.42.1/.43.1` |
| SD historique | dépend du rootfs ; `rootfs-sd` a `sshd` et le même réseau | dépend du rootfs |
| Nouveau rootfs A71ROOT | `sshd` activé mais `PermitRootLogin no`, `PasswordAuthentication no`, aucune `authorized_keys`, clés hôte générées seulement au firstboot | pas de serveur DHCP/dnsmasq ; réseau USB **incomplet** |

Le nouveau rootfs ne permet donc pas une connexion SSH immédiate : il faudrait
un provisionnement d'utilisateur/clé et un serveur réseau USB, non réalisés
dans K.

## 4. Arrêt

- gadget : `/usr/local/sbin/usb-gadget.sh stop` (détache l'UDC,
  `usb-gadget.sh:73-77`) ;
- réseau OpenRC : `rc-service a71-net stop` (arrête `dnsmasq`,
  `base/etc/init.d/a71-net:65-69`) ;
- SSH : `rc-service sshd stop` ou arrêt du système ;
- aucun de ces arrêts ne doit être exécuté depuis cet environnement.

## 5. Inconnues

- nom réel de l'interface hôte et bail DHCP effectif ;
- variante exacte d'authentification du système installé ;
- présence réelle de l'interface USB au prochain démarrage ;
- comportement du nouveau rootfs A71ROOT avec le sélecteur installé (absence
  de `/init`, voir `docs/BOOT-MODES.md`).
