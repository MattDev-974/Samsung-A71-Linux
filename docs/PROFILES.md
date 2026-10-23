# Profils

| Profil | Défaut | Redistribuable | ZAP | Mesa |
|---|---:|---:|---:|---:|
| server | oui | oui | non | non |
| desktop-open | non | oui | non | oui |
| desktop-local | non | non | local | oui |

`desktop-open` étend server, `desktop-local` étend desktop-open.
Wi-Fi, Bluetooth et audio ne sont dans aucun profil ni menu.

Matrice :

- supported : rootfs, OpenRC, ECM/RNDIS, SSH, Internet, DNS, chrony,
  a71-clock, logs, noyau #35, rootfix ;
- supported-local : ZAP A615 local et boot local ;
- available-not-fully-validated : Mesa/Freedreno, libdrm, EGL render-node ;
- experimental-disabled : Wi-Fi, Bluetooth, audio, tactile, batterie, caméra,
  capteurs, DSI/SMMU/aux_bridge, UFS interne.
