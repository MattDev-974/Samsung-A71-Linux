# Profil desktop-local

Desktop-open + import d’une archive Samsung fournie par l’utilisateur.
Validation stricte du modèle/build, extraction des quatre fichiers ZAP,
copie byte-for-byte du `.mdt` sous le nom logique `.mbn`, ajout des b00-b02.

```sh
./install.sh --profile desktop-local \
  --samsung-firmware "/chemin/firmware.zip" \
  --recovery-boot "/chemin/boot-historique.img"
```

Sortie :

```text
work/private/builds/<id>/boot.img
LOCAL_ONLY
NOT_REDISTRIBUTABLE
CONTAINS_USER_SUPPLIED_SAMSUNG_FIRMWARE
flashable=no
```

Ne jamais partager cette image ni copier les blobs dans `repo/`.
