# Ça marche : Linux sur Galaxy A71 avec terminal et Internet

État vérifié sur appareil (SM-A715F) — **RAM complète et Internet
automatique** :

```
Linux a71 6.18.0-rc1-a71+ #29 SMP PREEMPT aarch64
Mem: 5.4G total, 73M used       8 CPU
usb0 172.16.42.1/24   usb1 172.16.43.1/24
default via 172.16.42.x   (posée automatiquement depuis le bail DHCP)
$ ssh root@172.16.42.1      → terminal
$ ping 8.8.8.8               → 43 ms
$ wget -qO- http://example.com → page reçue
```

## Recette complète

### 1. Image

- noyau 6.18 du fork `WiiPlayer2/linux-sm7150`, branche `2025-10-13-display` ;
- config pmOS SM7150 + extras, avec **en dur** :
  `DRM_MSM`, `DRM_PANEL_SAMSUNG_S6E3FA9_AMB667UM06`, `REGULATOR_QCOM_REFGEN`,
  `TYPEC`, `TYPEC_TCPM`, `TYPEC_QCOM_PMIC`, `PHY_QCOM_QMP_COMBO`,
  `USB_DWC3`, `USB_CONFIGFS_RNDIS`, `USB_CONFIGFS_ECM`, `MMC_SDHCI_MSM`,
  `VFAT_FS`, `PSTORE_RAM` ;
- DTB : `mdss`/`dsi`/`phy` en `okay`, nœud panneau `samsung,s6e3fa9-amb667um06`
  (reset GPIO), `vdds-supply = <&vreg_l4a_0p88>`, PHY USB3 `okay`,
  `dr_mode = "peripheral"`, nœud mémoire à **2 Gio**, carte SD en
  `no-1-8-v` ;
- `boot.img` v2 page 4096 dont la section `dtb` contient le **DTB
  Android/Lineage** (obligatoire pour `sboot`), uniLoader portant le DTB
  mainline en interne ;
- rootfs Alpine dans l'initramfs : busybox, openssh (clé publique autorisée
  pour root), dnsmasq, gadget RNDIS+ECM, `usb-gadget.sh`.

### 2. Flash

```bash
heimdall flash --BOOT boot.img --no-reboot
```

### 3. Internet

Sur le PC, une fois le téléphone démarré :

```bash
sudo ./scripts/host-nat.sh enp48s0f4u1     # interface USB côté PC
```

Le téléphone pose alors sa route par défaut **automatiquement** : l'init lit le
bail DHCP du PC dans `/run/dnsmasq.leases` et préfère l'interface RNDIS
(`usb0`, 172.16.42.x), celle que le script NAT configure.

### 4. Terminal

```bash
ssh root@172.16.42.1
```

## RAM complète (5,4 Gio utilisables)

Le nœud mémoire du DTB mainline est un simple placeholder. Le DT **downstream**
donne la vraie carte :

```
memory {
    reg = <0x00 0x80000000 0x00 0x80000000     /*  2 Gio à 0x80000000  */
           0x01 0x00      0x00 0xfcb00000>;   /* ~4 Gio à 0x1_00000000 */
};
```

Deux plages séparées par un **trou** (0xC0000000–0x1_00000000). Déclarer une
seule plage de 6 Gio à 0x80000000 couvre ce trou et le noyau se bloque dans
`map_mem`. Avec les deux plages : `MemTotal: 5 634 500 kB`.

## Wi-Fi (en cours)

`ATH10K_SNOC` est compilé en dur (il a fallu désactiver les pilotes remoteproc
qui forçaient `QCOM_RPROC_COMMON=m`), le nœud `wcn3990-wifi` est activé avec
ses 5 alimentations et le firmware est dans l'initramfs. Il reste :

```
ath10k_snoc 18800000.wifi: failed to register wlfw qmi client: -517
```

Le service QMI WLFW n'est pas disponible : sur SM7150 il est fourni par le
sous-système WCSS, dont le pilote remoteproc ne peut être construit qu'en
module (contrainte Kconfig). Solution : construire les modules `qcom_q6v5_wcss`
+ `ath10k_snoc` et les charger depuis l'init.

## Ce qui a débloqué chaque partie

| Symptôme | Cause | Correctif |
|---|---|---|
| retour immédiat en Download mode | DTB mainline dans l'en-tête du boot.img | DTB Android dans l'en-tête |
| figement avant `start_kernel` | nœud mémoire à taille 0 | patch 2 Gio (le bootloader le remplit pour Android, pas pour uniLoader) |
| écran corrompu | aucun pilote ne possède le panneau | DRM_MSM + panneau + `vdds` + **REFGEN** |
| pas d'UDC / `dwc3: failed to initialize core` | PHY USB3 en module et nœud `disabled` | `PHY_QCOM_QMP_COMBO=y` + nœud `okay` |
| pas de gadget | initramfs sans `/sys`, `/proc`, `/dev` | créer les points de montage |
| clé SSH refusée | `authorized_keys` créé avec l'uid utilisateur | `cpio --owner=0:0` |
| pas d'Internet | pas de passerelle | NAT PC + route par défaut via le bail DHCP |
