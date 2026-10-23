# Wi-Fi WCN3990 — M9A

## Contrat matériel

```text
plateforme   18800000.wifi
compatible   qcom,wcn3990-wifi
DT status    okay
module       ath10k_snoc
vermagic     6.18.0-rc1-a71+ SMP preempt mod_unload aarch64
interface    non créée
```

DT runtime et DTB mainline concordent. Les clocks/resets/interconnects ne sont
pas exposés ; le pilote utilise des clocks optionnelles. Le nœud DT est
`degraded`, pas prouvé bloquant.

## Firmware exact

```text
lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin
lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin
lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn
lib/firmware/ath10k/WCN3990/hw1.0/notice.txt_wlanmdsp
```

Provenance : paquet officiel `linux-firmware-atheros 1:20260916-1`, source
`https://gitlab.com/kernel-firmware/linux-firmware`, signature pacman vérifiée.
Hash et tailles dans `repo/manifest.yaml` et
`work/device-runtime/m9a/reports/firmware-provenance.txt`.

`firmware-5.bin` est un blob WCN3990 de 60 octets avec en-tête `QCA-ATH10K`.
Aucun fichier de calibration A71 séparé n'est identifié ; `board-2.bin` est la
base board officielle. Ne pas substituer un board générique d'un autre appareil.

## Installation

```text
root:root, 0644
répertoires 0755
installation atomique + sync
sauvegarde /root/a71-backups/m9a/firmware-before
```

Les fichiers sont aussi dans `repo/rootfs/lib/firmware/ath10k/WCN3990/hw1.0/`.
Ils ne sont **pas** ajoutés à l'initramfs : le probe ath10k arrive après le
montage du rootfs.

## Runtime observé

```text
ath10k_snoc chargé et lié
phy80211 absent
wlan absent
rfkill vide
aucune requête firmware observée
aucun service QMI WCN3990 observé
aucune nouvelle faute SMMU
SSH ECM/RNDIS stable
```

Verdicts :

```text
wifi_kernel_support       pass
wifi_module_compatibility pass
wifi_device_tree          degraded
wifi_firmware_provenance  pass
wifi_firmware_install     pass
wifi_remoteproc           blocked
wifi_phy                  blocked
wifi_interface            blocked
wifi_rfkill               not_tested
wifi_runtime              blocked
```

## Userspace

`rfkill` déjà présent ; `iw` absent. Aucun `wpa_supplicant`, profil, SSID,
clé ou scan n'a été créé. Aucune interface n'a été mise UP.

## Prochaine étape

Diagnostiquer le service QMI/remoteproc WCN3990 (transport QRTR/GLINK/SMD et
éventuel firmware ADSP/WLAN amont) avant toute association. Ne pas scanner et
ne pas installer de firmware d'un autre appareil.

## M9B — blocage QMI

```text
ath10k_snoc lié              oui
/sys/class/remoteproc        vide
ADSP/CDSP/MPSS DT            okay mais non liés
qcom_q6v5_pas                module présent, non chargé
firmware adsp/cdsp/modem     absent
QRTR endpoint                absent
QMI WLFW service             absent
phy80211 / wlan              absent
```

Premier événement manquant : service **QMI WLFW** (`WLFW_SERVICE_ID_V01`),
faute d’endpoint QRTR/remoteproc. `qcom_q6v5_pas` n’a pas été chargé : il
pilote des DSP critiques et les firmwares board-specific sont absents.
Aucun scan, aucune association, aucune modification DT/boot.

## M9C — analyse Android hors appareil

Le DTB Android `work/lin.dtb` décrit `qcom,icnss@18800000` avec
`qcom,wlan-msa-fixed-region` et `smp2p-wlan`; le DTB mainline décrit
`qcom,wcn3990-wifi` sans ICNSS. Le loader exact de `wlanmdsp.mbn` n’est pas
prouvé.

Identité locale : bootloader `A715FXXSBDXB1`, XEO, LineageOS 23.2. AP/CP/
baseband/build complets : **inconnus**. Aucun firmware stock n’est présent
dans le workspace.

`qcom_q6v5_pas` n’a pas été chargé : ADSP et CDSP seraient auto-démarrés,
MPSS enregistré sans auto-boot, et le nœud WLAN ne matche pas ce module.
M9D n’est pas autorisé.
