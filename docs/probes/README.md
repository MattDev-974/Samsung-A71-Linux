# Sondes bas niveau

Ces fichiers assembleur sont des « payloads » destinés à remplacer le noyau
dans une image uniLoader (`scripts/build-test-uni.sh` et builds manuels).
Ils s'exécutent à `CONFIG_PAYLOAD_ENTRY`, avec `x0` = pointeur DTB, et
peignent le framebuffer (`0x9c000000`, ARGB8888) pour répondre.

| Fichier | Question posée |
|---|---|
| `probe_dt.S`, `probe_dt2.S`, `probe_dt3.S`, `probe_dt5.S`, `probe_dt6.S` | le DTB passé est-il valide / quel pointeur ? |
| `probe_cpu.S` | niveau d'exception, MMU, caches à l'entrée |
| `probe_smc.S` | un appel `smc #0` (PSCI) fonctionne-t-il ? |
| `probe_tail.S` | le bootloader tronque-t-il les gros payloads ? |
| `probe_kentry.S`, `probe_kernel.S` | l'entrée du noyau s'exécute-t-elle ? |
| `probe_mem.S`, `probe_ramoops.S` | accessibilité de zones RAM hautes / ramoops |
| `probe_initrd.S`, `probe_pstore.S` | présence de `linux,initrd-start` / du log noyau |

Compilation type :

```bash
aarch64-buildroot-linux-gnu-gcc -c -nostdlib -o probe.o probe.S
aarch64-buildroot-linux-gnu-objcopy -O binary -j .text probe.o probe.bin
```

puis placer `probe.bin` dans `uniLoader/blob/Image` avant `make`.
