# Un vrai Alpine : OpenRC

Le système est un Alpine 3.22 complet qui démarre avec **busybox init +
OpenRC**, comme sur un Raspberry Pi.

## Chaîne de démarrage

```
sboot → BOOT (uniLoader + Image + DTB + initramfs)
      → noyau Linux 6.18
      → initramfs : sélecteur (carte SD ext4 / image / RAM)
      → switch_root sur le système
      → /init : monte /proc /sys /dev puis exec /sbin/init
      → busybox init lit /etc/inittab
      → openrc sysinit / boot / default
      → login: sur tty0 (ttyMSM0 absent de ce noyau)
```

## Services

| Service | Runlevel | Rôle |
|---|---|---|
| `a71-usb` | boot | gadget RNDIS + ECM |
| `a71-net` | default | adresses 172.16.42.1/43.1, dnsmasq, DHCP |
| `a71-route` | default | route par défaut vers le PC (auto-réparante) |
| `sshd` | default | serveur SSH |
| `chronyd` | default | heure (certificats TLS) |
| `crond`, `local`, `syslog`, `bootmisc`, `hostname`… | | standard Alpine |

Gestion :

```bash
rc-service sshd restart
rc-service a71-net restart
rc-update show
rc-status --all
```

## Le piège à ne jamais reproduire

Première version de `/init` : elle lançait `openrc` puis terminait par `wait`.
Le sous-shell de secours se terminait au bout de 30 s, `wait` retournait,
**PID 1 sortait** → `Attempted to kill init` → panique → **redémarrage en
boucle**.

Règle : **PID 1 ne doit jamais sortir**. La version correcte est simplement :

```sh
#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
exec /sbin/init        # busybox init ne sort jamais
```

Le filet de sécurité est déplacé dans `/etc/local.d/10-a71-rescue.start` :
après 90 s, si `sshd` n'écoute pas, l'ancien script `/sbin/a71-system` est
lancé en secours (sans bloquer le service `local`).

## Installation

L'assistant `scripts/a71-setup.sh` propose « OpenRC » et dépose
`a71-openrc-setup.sh`, exécuté au premier démarrage. Pour une machine déjà
installée :

```bash
scp scripts/a71-openrc-setup.sh root@172.16.42.1:/root/
ssh root@172.16.42.1 'sh /root/a71-openrc-setup.sh'
```

## Vérifications

```
PID1    : /sbin/init
sshd    : started        (rc-service sshd status)
usb0    : 172.16.42.1/24
internet: ping 1.1.1.1 → 4 ms
écran   : login:
```
