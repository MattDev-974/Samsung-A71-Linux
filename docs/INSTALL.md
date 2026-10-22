# Assistant d'installation (`scripts/a71-setup.sh`)

Reproduit l'esprit de `setup-alpine` : on répond à quelques questions, le
système est généré puis installé.

```bash
./scripts/a71-setup.sh            # assistant interactif
./scripts/a71-setup.sh --defaults # tout par défaut (clé de l'utilisateur)
```

## Questions posées

| Question | Défaut | Effet |
|---|---|---|
| Nom d'hôte | `a71` | `/etc/hostname`, `/etc/hosts` |
| Fuseau horaire | `UTC` | `/etc/timezone`, `/etc/localtime` (installe `tzdata` si besoin) |
| Serveur SSH | `openssh` | seul proposé pour l'instant |
| Authentification SSH | clé | clé / mot de passe / les deux |
| Clé publique | `~/.ssh/id_ed25519.pub` | copiée dans `/root/.ssh/authorized_keys` |
| Connexion root | `prohibit-password` | `PermitRootLogin` (clé / mot de passe / interdit) |
| Mot de passe root | aucun | haché en SHA-512 dans `/etc/shadow` |
| Utilisateur normal | aucun | crée le compte + `doas` |
| Paquets | `nano htop` | installés au premier démarrage par `apk` |
| Cible | carte SD | carte SD (ext4) ou USERDATA |
| Système d'init | **OpenRC** | vrai Alpine : `rc-service`, `rc-update`, services |

## Ce que produit l'assistant

Un rootfs personnalisé (`work/a71-custom-rootfs.tar.gz`) contenant :

- `/etc/ssh/sshd_config.d/10-a71.conf` généré selon les réponses ;
- `/root/.ssh/authorized_keys` (droits 700/600) ;
- `/etc/shadow` avec le mot de passe root haché (ou `*` = verrouillé) ;
- `/etc/a71-install` : trace de la configuration ;
- `/etc/a71-packages` : paquets à installer ;
- `/etc/a71-firstboot.sh` : exécuté **une seule fois** au premier démarrage
  (propriétaires root, fuseau horaire, `apk add`).

L'installation elle-même est déléguée à `a71-install.sh` (formatage +
extraction), avec `sudo` si nécessaire.

## Bascule vers OpenRC

Si l'init OpenRC est choisi, l'assistant ajoute `openrc`, `alpine-conf` et
`chrony`, dépose `/etc/a71-openrc-setup.sh` et le fait exécuter au premier
démarrage. Ce script :

- enregistre les services (`sshd`, `chronyd`, `crond`, `syslog`, `local`) ;
- convertit l'init maison en services : `a71-usb` (gadget), `a71-net`
  (adresses + dnsmasq), `a71-route` (route par défaut auto-réparante) ;
- écrit `/etc/inittab` si absent ;
- remplace `/init` par un lanceur de `busybox init` (qui exécute `openrc`),
  l'ancien script restant disponible en `/init.a71-rescue`.

Au démarrage suivant, le système est un **vrai Alpine** : `rc-service sshd
status`, `rc-update show`, logs dans `/var/log`.

## Premier démarrage

L'init lance `/etc/a71-firstboot.sh` dès que le réseau répond, puis supprime le
marqueur. Les paquets choisis sont installés à ce moment-là (le téléphone a
Internet via le NAT du PC).
