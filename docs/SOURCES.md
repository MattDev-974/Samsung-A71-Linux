# Sources et versions épinglées

> **État (incrément 2A-2)** : les entrées résolues avec preuve officielle sont
> décrites dans [`PROVENANCE.md`](PROVENANCE.md) et verrouillées dans
> `manifest.yaml` (Alpine 3.22.7, toolchain Bootlin `.tar.xz`, uniLoader au
> commit de fusion). Le tableau ci-dessous reste la **référence historique** de
> la mise au point ; il n'est pas la source de vérité du nouveau pipeline.

| Composant | Origine | Référence |
|---|---|---|
| Noyau (A71) | https://github.com/WiiPlayer2/linux-sm7150 | `device/samsung-a71` @ `a5cd6780b` (6.11), `2024-12-08` @ `d6fff7a3`, `2025-10-13-display` @ `5d80fcdbb` (6.18) |
| uniLoader | https://github.com/ivoszbg/uniLoader | PR #130 **fusionnée** : épinglé au commit de fusion `4c626a7…` ; tête de PR `b253dc4…` conservée comme provenance (`a71_defconfig`) |
| pmaports (config noyau) | https://gitlab.com/postmarketOS/pmaports | config `device/testing/linux-postmarketos-qcom-sm7150/config-postmarketos-qcom-sm7150.aarch64` |
| heimdall | https://github.com/Benjamin-Dobell/Heimdall | `v1.4.2` + PR #478 (reset USB) + handshake 5 s |
| Toolchain | Bootlin | `aarch64--glibc--stable-2024.05-1.tar.xz` — gcc 13.3.0, binutils 2.41, glibc 2.39 (SHA-256 officiel publié) |
| Rootfs | Alpine Linux | **3.22.7** aarch64 (minirootfs officiel, SHA-256/SHA-512 publiés) |
| QEMU (validation) | paquets Arch | `qemu-system-aarch64` 11.1.2 |

Le fork pmaports du porteur (`git.web.home.dark-link.info/a71-pmos/pmaports-a71`)
n'est pas accessible publiquement et n'a pas été utilisé.
