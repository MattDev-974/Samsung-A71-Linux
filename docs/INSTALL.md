# Assistant d'installation (`scripts/a71-setup.sh`)

Tout est préparé **sur le PC** : la base (`dist/a71-base.tar.gz`) est un Alpine
déjà fonctionnel (OpenRC, `apk`, SSH, réseau USB, NTP, modules). L'assistant ne
fait que de la **configuration**, puis installe sur la cible. Après le flash du
noyau, il n'y a plus rien à faire sur le téléphone.

```bash
sudo ./scripts/a71-setup.sh            # interactif
sudo ./scripts/a71-setup.sh --defaults # clé SSH de l'utilisateur, tout par défaut
sudo ./scripts/a71-setup.sh --flash    # installe puis flashe le noyau
```

## Questions posées

| Question | Défaut | Effet |
|---|---|---|
| Nom d'hôte | `a71` | `/etc/hostname`, `/etc/hosts` |
| Fuseau horaire | `UTC` | `/etc/timezone`, `/etc/localtime` (tzdata inclus) |
| Serveur SSH | OpenSSH | `sshd` dans le runlevel, ou **aucun** (service retiré) |
| Authentification SSH | clé | `PasswordAuthentication yes/no` |
| Clé publique | `~/.ssh/id_ed25519.pub` | `/root/.ssh/authorized_keys` |
| Connexion root | `prohibit-password` | `PermitRootLogin` : clé / mot de passe / interdit |
| Mot de passe root | aucun (`*`) | haché SHA-512 dans `/etc/shadow` |
| Utilisateur normal | aucun | compte + groupe `wheel` + `/etc/sudoers.d/` |
| Paquets supplémentaires | aucun | **optionnel** : installés au 1er démarrage si le réseau est là |
| Cible | carte SD | carte SD (ext4) ou `USERDATA` (écrase Android) |

Sans paquets supplémentaires, l'image est **autonome** : rien n'est téléchargé
au démarrage.

## Ce que produit l'assistant

Un rootfs personnalisé (`work/a71-custom-rootfs.tar.gz`) puis son installation :

- `/etc/ssh/sshd_config.d/10-a71.conf` généré selon les réponses ;
- `/root/.ssh/authorized_keys` et, si demandé, celui de l'utilisateur ;
- `/etc/shadow` : mot de passe haché ou `*` (verrouillé, clé uniquement) ;
- `/etc/sudoers.d/10-<utilisateur>` pour l'utilisateur créé ;
- `sshd` retiré de `/etc/runlevels/default` si « pas de serveur SSH » ;
- `/etc/a71-install` : trace de la configuration (hôte, fuseau, auth…).

## En ligne de commande, sans interaction

```bash
A71_BASE=dist/a71-base.tar.gz \
A71_OUT=/tmp/a71-rootfs.tar.gz \
  ./scripts/a71-setup.sh --defaults --flash
```

Variables utiles : `A71_BASE` (rootfs de base), `A71_OUT` (archive produite),
`A71_BOOT` (image noyau), `HEIMDALL` (binaire), `A71_NO_INSTALL=1` (générer
sans installer).
