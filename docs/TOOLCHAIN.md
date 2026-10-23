# Toolchain Bootlin A71

## Provenance

```text
version      aarch64--glibc--stable-2024.05-1
URL          https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/aarch64--glibc--stable-2024.05-1.tar.xz
archive      aarch64--glibc--stable-2024.05-1.tar.xz
taille       83 754 052 octets
SHA-256      b0fad860eb94b503a56d66ca8b9ba06d2d4826943e37ebd1d7217423f6ea5bb2
signature    indisponible (aucun .asc publié)
cache        work/toolchain-cache/downloads/sha256/b0fad860…ea5bb2
```

## Composants qualifiés

```text
compilateur  aarch64-buildroot-linux-gnu-gcc
version      gcc 13.3.0 (Buildroot 2021.11-12449-g1bef613319)
ld           GNU ld (GNU Binutils) 2.41
cible        aarch64-buildroot-linux-gnu
glibc        2.39-74-g198632a05f6c7b9ab67d3331d8caace9ceabb685
sysroot      work/toolchain/toolchain-root/aarch64-buildroot-linux-gnu/sysroot
test ELF     binaire AArch64 confirmé
```

L'archive n'est jamais exécutée avant validation. Aucun compilateur système
n'est utilisé comme substitut silencieux.

## M7B.3

Le contrôle uniLoader historique diffère de 16 octets seulement dans le champ
version/date (`b253dc4 / 2026-10-22` vs `4c626a7 / 2025-10-13`) ; Image, DTB et
ramdisk embarqués sont identiques. Le candidat utilise le commit 4c626a7 et
le toolchain ci-dessus.
