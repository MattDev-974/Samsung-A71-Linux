# Sources et versions épinglées

| Composant | Origine | Référence |
|---|---|---|
| Noyau (A71) | https://github.com/WiiPlayer2/linux-sm7150 | `device/samsung-a71` @ `a5cd6780b` (6.11), `2024-12-08` @ `d6fff7a3`, `2025-10-13-display` @ `5d80fcdbb` (6.18) |
| uniLoader | https://github.com/ivoszbg/uniLoader | `pr130` @ `b253dc4` (`a71_defconfig`) |
| pmaports (config noyau) | https://gitlab.com/postmarketOS/pmaports | config `device/testing/linux-postmarketos-qcom-sm7150/config-postmarketos-qcom-sm7150.aarch64` |
| heimdall | https://github.com/Benjamin-Dobell/Heimdall | `v1.4.2` + PR #478 (reset USB) + handshake 5 s |
| Toolchain | Bootlin | `aarch64--glibc--stable-2024.05-1` (GCC 13.3) |
| Rootfs | Alpine Linux | `v3.22` aarch64 (musl) |
| QEMU (validation) | paquets Arch | `qemu-system-aarch64` 11.1.2 |

Le fork pmaports du porteur (`git.web.home.dark-link.info/a71-pmos/pmaports-a71`)
n'est pas accessible publiquement et n'a pas été utilisé.
