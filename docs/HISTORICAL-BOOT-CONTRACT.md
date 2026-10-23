# Contrat du boot historique A71

Statut de la reproduction : **BIT_IDENTICAL**, `RESEARCH_ONLY`, `NOT_FLASHABLE`.

## Chaîne observée

```text
sboot
  -> boot.img AOSP v2
  -> kernel = uniLoader historique
  -> ramdisk = empty.cpio.gz (97 octets)
  -> dtb = DTB Android/Lineage (work/lin.dtb)
  -> uniLoader embarque Image mainline + DTB mainline + initramfs
```

Le DTB d'en-tête n'est **pas** le DTB mainline.

## En-tête v2

```text
page_size=4096 header_version=2 header_size=1660
kernel_size=41280904 kernel_addr=0x8000
ramdisk_size=97 ramdisk_addr=0x1000000
second_size=0 second_addr=0x0 tags_addr=0x100
dtb_size=388050 dtb_addr=0x1f00000
os_version=0x1e000000 name=a71
cmdline=console=tty0
id=26def0e88e6dd6aa48c0ec5c85816cf33793e8ca000000000000000000000000
taille=67108864 trailing=25427968 octets nuls
AVB footer=absent
```

## Reproduction

`repo/scripts/reproduce-historical-boot.sh` exige chaque entrée et son hash,
refuse les symlinks et produit deux builds. Les deux builds et la référence
ont le même SHA-256 global. Aucun outil de flash n'est appelé.

Aucune modification de `boot_image.validated.*` ni du statut global.
