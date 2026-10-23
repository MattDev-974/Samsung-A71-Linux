# Contrat DTB fonctionnel A715F

## Trois DTB distincts

### Android externe

`work/lin.dtb` (388 050 octets, `451e5946…`) est le DTB Android/Lineage
placé dans l’en-tête du boot. Il décrit `qcom,icnss@18800000`, pas le nœud
mainline `qcom,wcn3990-wifi`.

### Mainline actif

`work/uniLoader/blob/dtb` (88 332 octets, `1a06b9e4…`) est le DTB mainline
embarqué dans l’uniLoader historique. Il est `status="okay"` avec cinq
supplies Wi-Fi. Ce n’est pas le DTB produit par le source A715F courant.

### Source reconstruit

Le rebuild M9D2 (`ba854c16…`) applique :

```text
memory 6 GiB
MMC no-1-8-v / max-frequency 50 MHz
USB dr_mode peripheral
USB QMP PHY status okay
DSI PHY vdds-supply = vreg_l4a_0p88
Wi-Fi supplies + status okay
```

Il est identique entre deux copies indépendantes, mais pas bit-identique au
blob. Les différences résiduelles sont des phandles, l’ordre des propriétés,
l’encodage historique du status USB QMP et `ldo16` non canonique.

## Nécessaire au boot / expérimental

- Mémoire/MMC/USB/DSI : contrat de plateforme à documenter comme nécessaire
  au boot et aux périphériques.
- Wi-Fi : activation DT **expérimentale**. `wifi_dt_enabled=yes`,
  `wifi_runtime_functional=no` ; WLFW/ICNSS/calibration non résolus.
- Aucun DTB reconstruit ne remplace le blob historique.

## Règle

Toute reproduction doit conserver le DTB Android dans l’en-tête et le DTB
mainline dans uniLoader. Ne pas publier de boot flashable à partir du rebuild
partiel M9D2.
