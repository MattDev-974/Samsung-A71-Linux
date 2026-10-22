# Pannes connues et correctifs

Chaque ligne correspond à un symptôme réellement rencontré pendant la mise au
point, avec sa cause et le correctif appliqué.

## Démarrage

| Symptôme | Cause | Correctif |
|---|---|---|
| Retour immédiat en Download mode | DTB mainline dans la section `dtb` du `boot.img` | mettre le **DTB Android/Lineage** (`artifacts/android.dtb`) |
| Figement avant `start_kernel` | nœud `memory@80000000` de taille **0** | le bootloader le remplit pour Android, pas pour uniLoader : déclarer la mémoire |
| Blocage dans `map_mem` à 6 Gio | une seule plage couvrant le **trou** 0xC0000000–0x1_00000000 | déclarer les **deux plages** du DT downstream |
| Redémarrage en boucle après migration OpenRC | `/init` terminait par `wait` → PID 1 sortait → panique | `exec /sbin/init` (PID 1 ne doit jamais sortir) |

## Affichage

| Symptôme | Cause | Correctif |
|---|---|---|
| Écran corrompu / noir | aucun pilote ne possède le panneau | `DRM_MSM` + pilote panneau + `vdds` + `REGULATOR_QCOM_REFGEN` |
| `Failed to get supply 'vdds'` | phandle pointant sur le PHY lui-même | référence LDO4 (`vreg_l4a_0p88`) |
| `DSI PLL(0) lock failed` | `REGULATOR_QCOM_REFGEN` absent | activer la config |

## USB / réseau

| Symptôme | Cause | Correctif |
|---|---|---|
| `dwc3: failed to initialize core` | PHY USB3 en module et nœud DT `disabled` | `PHY_QCOM_QMP_COMBO=y` + nœud `okay` |
| Pas d'UDC, pas de gadget | initramfs sans `/sys`, `/proc`, `/dev` | créer les points de montage |
| Gadget présent mais pas d'IP | dnsmasq démarre avant l'interface | boucle d'attente dans `a71-net` |
| Route par défaut perdue | reconfiguration de l'interface USB | `a71-route` revérifie toutes les 10 s |
| SSH refuse la clé | `authorized_keys` appartient à un autre uid | `--owner=0:0` à l'archivage, `StrictModes no` |

## Paquets / TLS

| Symptôme | Cause | Correctif |
|---|---|---|
| `apk` : `certificate verify failed` puis `Permission denied` | horloge à **1970** | NTP par IP au démarrage (`a71-clock`) |
| TLS échoue malgré l'heure | `/etc/ssl/cert.pem` manquant | lien vers `certs/ca-certificates.crt` |
| `btop` : *No UTF-8 locale* | pas de locale | `musl-locales` + `LANG=C.UTF-8` (profil + `SetEnv` sshd) |
| `hwclock -w` : ioctl `No such device` | pilote pm8xxx sans écriture RTC | l'heure est réglée par NTP à chaque boot |

## Divers

| Symptôme | Cause | Correctif |
|---|---|---|
| `losetup -j` inconnu | busybox sans cette option | utiliser `/dev/loop0` |
| `blkid -s TYPE -o value` renvoie la ligne complète | busybox ignore `-s`/`-o` | tester le montage ext4 directement |
| Formater le disque entier ne crée pas `p1` | pas de table de partitions | cibler `/dev/mmcblk2` |
