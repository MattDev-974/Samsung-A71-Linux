# État matériel A71 — synthèse M6

Observation passive du 2026-10-23, noyau `6.18.0-rc1-a71+ #35`.

| Domaine | État | Verdict |
|---|---|---|
| CPU SM7150 8 cœurs | PRESENT_AND_WORKING | pass |
| RAM 5.4 GiB, sans swap | PRESENT_AND_WORKING | pass |
| microSD / racine ext4 | PRESENT_AND_WORKING | pass |
| UFS interne | PRESENT_NOT_TESTED (jamais lu) | pass limité |
| USB RNDIS/ECM + SSH | PRESENT_AND_WORKING | pass |
| framebuffer / DRM | PRESENT_WITH_ERRORS | degraded |
| GPU Adreno | firmware installé M7B | validation reboot en attente |
| tactile | NOT_DETECTED | unknown |
| boutons | PRESENT_NOT_TESTED | unknown |
| Wi-Fi | DRIVER_MISSING / USERSPACE_GAP | unknown |
| Bluetooth | NOT_DETECTED | unknown |
| audio | NOT_DETECTED / DRIVER_MISSING | fail |
| caméra | NOT_DETECTED | unknown |
| capteurs | ADC PMIC seulement ; attentes NOT_DETECTED | unknown |
| LED | activité mmc2 seulement | unknown |
| alimentation/batterie | power_supply absent | unknown |
| RTC | NOT_DETECTED | horloge locale pass via M7A ; RTC absent |
| chronyd | corrigé M8 | pass |
| thermiques | PRESENT_AND_WORKING | pass |

Firmware manquant : `qcom/a630_sqe.fw` (`/lib/firmware` vide).
Erreurs noyau dégradées : DSI PLL, 10 fautes SMMU au boot, bridge DRM,
UFS sysfs/vreg. Aucun `Unknown symbol`, panic, OOM ou I/O error observé.

Voir `work/device-runtime/m6/reports/` pour les preuves et
`CLOCK-AND-RTC.md` pour l'horloge.


## Mises à jour M7B/M9/M10

- firmware officiel `qcom/a630_sqe.fw` installé depuis
  `linux-firmware-qcom` 1:20260916-1 (SHA-256
  `1c21b527d9183487cc550dabbb3f43e555df5a977a461934fc61f0635a9aa90c`) ;
  validation GPU en attente de redémarrage ;
- Wi-Fi/Bluetooth : drivers/modules présents, firmware WCN3990 et userspace
  absents ; runtime bloqué, aucune radio activée ;
- audio : drivers ASoC/QDSP6/WCD compilés, mais pas de nœud sound/codec
  complet dans le DTS a715f ni d'userspace ALSA ; rebuild DT requis, aucun
  test actif.


## M7B.1 — firmware GPU après reboot

Le fichier `/lib/firmware/qcom/a630_sqe.fw` est présent, 34188 octets,
0644 root:root, SHA-256
`1c21b527d9183487cc550dabbb3f43e555df5a977a461934fc61f0635a9aa90c`.

Le noyau le demande à **1.131759 s**, mais le rootfs ext4 n'est monté qu'à
**1.268439 s** : le chargement échoue toujours avec `-2`. Le fichier est donc
correct mais indisponible au moment du probe GPU.

```text
gpu_firmware_file = pass
gpu_firmware_load = fail
gpu_runtime       = unknown
drm_runtime       = degraded
display_runtime   = degraded
dsi_pll           = degraded (2, inchangé)
smmu_faults       = degraded (10, inchangé)
aux_bridge        = degraded (1, inchangé)
```

Aucun chargement/rechargement GPU, aucune écriture sysfs/debugfs.


## M7B.2 — initramfs GPU

L'initramfs avec firmware est produit et reproductible :

```text
work/initramfs-m7b2/build-a/initramfs.img
sha256 92945f85b10b8090024a254446ae2f0f66d2dd0e84eaf80f0aacba95045a55a2
```

Le firmware est présent une fois, `0644 0 0`, hash exact. La reconstruction
uniLoader est **fail-closed** : le toolchain Buildroot historique
`aarch64-buildroot-linux-gnu-gcc` 13.3.0 est absent. Aucun boot candidat
`boot-gpu-fw-UNTESTED.img` n'a été produit, aucun AVB/signature inventé.


## M7B.3 — candidat boot GPU hors appareil

La toolchain Bootlin `aarch64--glibc--stable-2024.05-1` est restaurée et
qualifiée (gcc 13.3.0, ld 2.41). Le contrôle uniLoader avec les blobs
historiques ne diffère que de 16 octets de version/date ; Image, DTB et
ramdisk embarqués sont identiques.

Le candidat `work/boot-candidates/m7b3/boot-gpu-fw-UNTESTED.img` est produit,
mais reste **UNTESTED / RESEARCH_ONLY / flashable=no**. Aucun test appareil.


## M9A — Wi-Fi WCN3990

```text
CONFIG_ATH10K=m, CONFIG_ATH10K_SNOC=m, cfg80211/mac80211/rfkill=m
DT 18800000.wifi status okay, compatible qcom,wcn3990-wifi
firmware-5.bin, board-2.bin, wlanmdsp.mbn installés (paquet officiel)
ath10k_snoc chargé et lié
phy80211/wlan/rfkill : aucun
wifi_runtime = blocked
```

Aucun scan, aucune association, aucune interface UP. Voir `docs/WIFI.md`.
