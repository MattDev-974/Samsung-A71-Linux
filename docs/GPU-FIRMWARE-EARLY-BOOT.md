# Firmware GPU et initramfs

## Constat M7B.1

`/lib/firmware/qcom/a630_sqe.fw` est présent sur le rootfs (34188 octets,
SHA-256 `1c21b527…`), mais le probe GPU le demande à **1.131759 s**, avant le
montage ext4 du rootfs à **1.268439 s**. Le chargeur renvoie `-2`.

## Conséquence M7B.2

Le firmware doit être présent dans l'initramfs, pas seulement dans le rootfs.

`repo/scripts/build-initramfs.sh --firmware FILE` :

- vérifie taille 34188, hash exact et absence de symlink ;
- installe `lib/firmware/qcom/a630_sqe.fw` en 0644, uid/gid 0:0 ;
- fixe le timestamp à `SOURCE_DATE_EPOCH` ;
- refuse tout autre firmware ;
- produit deux builds sous umask 077/022 et exige leur identité bit à bit.

## État

Initramfs produit :

```text
work/initramfs-m7b2/build-a/initramfs.img
sha256 92945f85b10b8090024a254446ae2f0f66d2dd0e84eaf80f0aacba95045a55a2
```

## Blocage boot candidat

uniLoader doit être reconstruit avec le toolchain historique
`aarch64-buildroot-linux-gnu-gcc` 13.3.0 (Buildroot). Ce toolchain est absent
de l'hôte ; `build-uniloader.sh` échoue volontairement (`toolchain/bin absent`,
code 3). Aucun candidat boot non corrélé n'est produit.

**Aucun flash, aucun boot candidat, aucune validation runtime GPU.**
