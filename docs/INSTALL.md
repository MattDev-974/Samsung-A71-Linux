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

## Premier démarrage

L'init lance `/etc/a71-firstboot.sh` dès que le réseau répond, puis supprime le
marqueur. Les paquets choisis sont installés à ce moment-là (le téléphone a
Internet via le NAT du PC).
