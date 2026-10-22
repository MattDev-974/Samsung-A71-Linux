# Ça marche : Linux sur Galaxy A71 avec terminal et Internet

État vérifié sur appareil (SM-A715F) :

```
Linux a71 6.18.0-rc1-a71+ #29 SMP PREEMPT aarch64
Mem: 1.6G total, 56M used       8 CPU
usb0 172.16.42.1/24   usb1 172.16.43.1/24
default via 172.16.42.150
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

Le téléphone récupère alors sa route par défaut via le PC (l'init lit le bail
DHCP dans `/run/dnsmasq.leases`).

### 4. Terminal

```bash
ssh root@172.16.42.1
```

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
