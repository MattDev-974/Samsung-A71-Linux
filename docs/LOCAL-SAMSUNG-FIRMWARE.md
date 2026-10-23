# Firmware Samsung local

Contrat validé : SM-A715F, A715FXXSBDXB1, CSC A715FOXMBDXB1, XEO/OXM,
Android 13, binary B11.

Fichiers requis : `a615_zap.mdt`, `.b00`, `.b01`, `.b02`.

Contrôles : ZIP/répertoire, CRC, zip-slip, symlink, taille, modèle, build,
ELF/MDT, segments, hashes exacts. Une autre build exige
`--allow-unvalidated-samsung-build` et reste `UNVALIDATED_SAMSUNG_BUILD`.
Un autre modèle est toujours refusé.

Le `.mdt` est copié byte-for-byte sous `.mbn` ; aucune transformation.
Rien n’est placé dans `repo/rootfs`, `repo/dist`, Git ou une release.
