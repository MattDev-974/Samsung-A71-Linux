# Flash et rollback

Le build normal ne flashe jamais. Utiliser :

```sh
./install.sh --print-flash-command IMAGE
```

Le mode `--flash-local-boot` vérifie image privée, hash, recovery, PIT,
Heimdall, Download mode, BOOT, taille <= 67108864 et confirmation humaine.
Il n’exécute pas de flash en I2.

Cible unique :

```text
sudo heimdall flash --BOOT IMAGE
```

Jamais RECOVERY, DTBO, VBMETA, SUPER ou USERDATA. Fastboot n’est pas utilisé.

Rollback validé :

```text
boot-ipv6-HISTORICAL.img
04dfd20221f4d27cba545c1034720b672d5afd7c8069126bd200cb53ca63526e
PIT 0aec58fc7b6caf742ed952852e1d0c00bc2e751a18aa89a8eaafb6b42dc5e151
```

Aucun flash n’a été exécuté en I2.
