# Démarrage rapide (utilisateur standard)

Installer Linux sur un Galaxy A71 (SM-A715F) depuis un PC Linux, sans rien
compiler.

**Temps** : ~30 min. **À savoir** : la carte SD sera effacée, et le
téléphone ne démarrera plus sous Android tant que la partition `BOOT` contient
Linux (l'opération est réversible en reflashant un `boot.img` Android).

## Prérequis

- un PC sous Linux (Debian/Ubuntu, Fedora, Arch…) ;
- un câble USB **de données** ;
- une carte microSD **16 Go minimum** (elle sera entièrement effacée) ;
- le téléphone avec le bootloader déverrouillé (`verifiedbootstate=orange`) ;
- ~2 Go d'espace libre sur le PC.

## 1. Récupérer le projet

```bash
git clone https://github.com/MattDev-974/Samsung-A71-Linux
cd Samsung-A71-Linux
```

Les fichiers prêts à l'emploi sont dans `dist/` :

| Fichier | Rôle |
|---|---|
| `dist/boot.img` | noyau Linux 6.18 + chargeur + initramfs (partition `BOOT`) |
| `dist/a71-base.tar.gz` | base Alpine reproductible (OpenRC, apk, SSH, réseau USB, NTP, modules) |
| `dist/heimdall` | outil de flash (déjà patché pour ce modèle) |
| `dist/SHA256SUMS` | empreintes |

Vérifier :

```bash
cd dist && sha256sum -c SHA256SUMS && cd ..
```

## 2. Installer heimdall

Le binaire fourni suffit :

```bash
chmod +x dist/heimdall
sudo cp dist/heimdall /usr/local/bin/heimdall
```

(ou `sudo apt install heimdall-flash` sur Debian/Ubuntu)

## 3. Configurer et installer (une seule étape)

L'image de base est déjà un Alpine complet : OpenRC, `apk`, SSH, réseau USB,
horloge NTP, `tzdata`, `nano`, `htop`, `curl`, `btop`. L'assistant ne fait que
de la **configuration** : aucun paquet à installer au démarrage.

Brancher la carte SD au PC, repérer son périphérique :

```bash
lsblk            # la carte apparaît en /dev/sdX (taille ~29G)
```

Lancer l'assistant :

```bash
sudo ./scripts/a71-setup.sh
```

Réponses conseillées :

| Question | Réponse |
|---|---|
| Nom d'hôte | `a71` |
| Fuseau horaire | `Indian/Reunion` (ou `UTC`) |
| Serveur SSH | `1` (OpenSSH) |
| Authentification SSH | `1` (clé publique) |
| Clé publique | laisser `~/.ssh/id_ed25519.pub` |
| Connexion root | `1` (par clé uniquement) |
| Mot de passe root | vide (ou un mot de passe pour le login console) |
| Utilisateur normal | vide (ou ton prénom, il aura `sudo`) |
| Paquets supplémentaires | vide (nano, htop, curl, btop sont déjà présents) |
| Cible | `1` (carte SD) puis `/dev/sdX` |

**Attention** : la carte est formatée en ext4 et le système est copié dessus.
Si tu n'as pas de clé SSH, l'assistant te propose un mot de passe : choisis
alors l'authentification par mot de passe.

Au bout de quelques dizaines de secondes, la carte contient un système
complet et **déjà configuré**.

## 4. Passer le téléphone en Download mode

1. Éteindre le téléphone (Power 20 s).
2. Maintenir **Volume Haut + Volume Bas** et brancher le câble USB.
3. L'écran affiche un avertissement puis le mode Download.

Vérifier :

```bash
lsusb | grep 04e8:685d
```

## 5. Flasher le noyau

```bash
sudo ./scripts/a71-install.sh boot
```

Le script attend le Download mode et écrit `dist/boot.img` sur la partition
`BOOT`.

## 6. Premier démarrage

1. Débrancher le câble.
2. Maintenir **Power 20 s**.
3. Rebrancher le câble au PC et attendre ~60 s.

Le téléphone démarre sur la carte SD : OpenRC affiche la séquence de boot,
puis `login:` sur l'écran (si l'écran fonctionne). **Rien d'autre à faire** :
l'utilisateur, le SSH et le réseau sont déjà configurés.

## 7. Se connecter

```bash
ssh root@172.16.42.1
```

Sans clé (mot de passe choisi à l'étape 3), ssh demande le mot de passe.

Pour donner Internet au téléphone (partage de la connexion du PC) :

```bash
sudo ./scripts/host-nat.sh enp48s0f4u1     # interface USB côté PC
```

Puis, sur le téléphone :

```bash
apk update && apk add nano htop
```

## 8. Si ça ne démarre pas

| Symptôme | Piste |
|---|---|
| retour immédiat en Download mode | `BOOT` mal flashé → refaire l'étape 5 |
| écran noir, pas de réseau | attendre 90 s (carte lente) ou vérifier `lsusb` |
| pas de `172.16.42.x` sur le PC | `ip -br addr`, rebrancher le câble |
| SSH refusé | `ssh -i ~/.ssh/id_ed25519 root@172.16.42.1` |
| rien ne va | remettre un `boot.img` Android pour revenir à l'état d'origine |

## Revenir en arrière

```bash
# récupérer un boot.img d'origine (LineageOS ou stock) puis
sudo ./scripts/a71-install.sh boot        # avec A71_BOOT=/chemin/boot.img
```

Les données Android (`USERDATA`) ne sont pas touchées par cette installation :
elles restent sur la partition `userdata`, simplement inaccessibles tant que
Linux occupe `BOOT`.
