# Affichage : corruption de l'écran — constats et causes possibles

## Observation

- Avec `simplefb` + console, le début du log est **parfaitement lisible**
  (logo Tux, lignes `[0.1] …` jusqu'à `fb0: simplefb registered`), puis
  l'image se corrompt dès que le noyau a fini d'écrire.
- **Sans aucun pilote d'affichage** (nœud `framebuffer@9c000000` retiré du
  DTB, pas de console, pas de DRM), l'écran se corrompt **immédiatement**.
- Le noyau, lui, continue de tourner : les marqueurs RAM montrent qu'il
  atteint `/init`.

Autrement dit : l'image ne tient que tant que **quelqu'un écrit dans le
framebuffer** ; dès que les écritures s'arrêtent, le panneau décroche.

## Tests réalisés (tous sans effet sur la corruption)

| Test | Résultat |
|---|---|
| `height = 800` dans le nœud framebuffer | corrompu |
| suppression de `clocks` du nœud framebuffer | corrompu |
| `clk_ignore_unused` + `pd_ignore_unused` | corrompu |
| `regulator_ignore_unused` | corrompu |
| `CONFIG_DRM_MSM=y` + `mdss`/`dsi` activés + pilote panneau `samsung,s6e3fa9-amb667um06` | corrompu (le probe msm/panneau n'a pas pris la main) |
| console désactivée | corrompu |
| nœud framebuffer supprimé du DTB | corrompu **immédiatement** |

## Causes possibles, par ordre de vraisemblance

1. **Auto-rafraîchissement (PSR) laissé actif par le bootloader.** Le
   contrôleur DSI met le panneau en self-refresh et arrête de lire le
   framebuffer ; sans pilote DRM pour le désactiver et reprendre la main,
   l'image se fige puis se corrompt.
2. **Le pipeline d'affichage du bootloader n'est pas repris proprement.**
   `simplefb` n'active qu'une horloge ; il ne possède ni le CRTC, ni le DSI,
   ni le PHY. Les initialisations d'horloges/régulateurs du noyau peuvent
   remettre le contrôleur dans un état incohérent.
3. **Alimentation du panneau non gérée.** Le pilote généré ne récupère que
   `reset-gpios` ; les rails du panneau (vddi, vdd, vci…) ne sont pas
   déclarés dans le nœud, donc le noyau peut les couper.
4. **Mode annoncé incohérent.** La console annonce `135x50` (800 lignes)
   alors que le DTB déclare 1080x2400 : le mode réellement programmé par le
   bootloader n'est peut-être pas celui qu'on décrit (scanout partiel).
5. **DSI/PHY non initialisés.** `dsi@ae94000` était `status = "disabled"`
   dans le DTB ; l'activer sans alimentations/refgen corrects peut laisser
   le contrôleur dans un état intermédiaire.

## Ce qu'il faudrait pour trancher

- un **canal de log** indépendant de l'écran : la sonde `probe_log.c`
  (affiche ramoops depuis la RAM) ou l'UART ;
- vérifier dans ce log si `msm`/`dsi`/`panel` apparaissent (probe réussi ou
  erreur `-EPROBE_DEFER`/`-ENODEV`) ;
- ajouter au nœud panneau les alimentations issues du DT downstream
  (`vddi`, `vdd`, `vci`) et les `pinctrl` du reset ;
- comparer avec le Pixel 4a (`sm7150-google-sunfish.dts`) qui utilise le même
  DSI et un panneau AMS581VF01 piloté par DRM.

## SOLUTION : le noyau pilote l'écran via DRM (vérifié sur appareil)

L'écran est **stable et lisible** avec cette configuration :

### Config noyau (toutes en dur, pas de modules)

```
CONFIG_DRM=y
CONFIG_DRM_KMS_HELPER=y
CONFIG_DRM_MSM=y
CONFIG_DRM_PANEL_SAMSUNG_S6E3FA9_AMB667UM06=y
CONFIG_REGULATOR_QCOM_REFGEN=y
```

`REGULATOR_QCOM_REFGEN` est indispensable : sans lui le DSI diffère
indéfiniment (`Failed to get supply 'refgen'`) et la PLL DSI ne verrouille
pas (`DSI PLL(0) lock failed`).

### Device tree

- `&mdss`, `&mdss_dsi0`, `&mdss_dsi0_phy` en `status = "okay"` ;
- nœud panneau sous `dsi@ae94000` :
  `compatible = "samsung,s6e3fa9-amb667um06"`, `reset-gpios = <&pm6150l_gpios 9 GPIO_ACTIVE_LOW>` ;
- `&mdss_dsi0_out { data-lanes = <0 1 2 3>; }` ;
- **`vdds-supply = <&vreg_l4a_0p88>`** sur `&mdss_dsi0_phy` (LDO4, 0,88 V — la
  PLL DSI) : sans lui, `msm_dsi_phy: Failed to get supply 'vdds'`.

### Log de référence

```
msm_dpu: bound ae94000.dsi (ops dsi_ops)
[drm:dpu_kms_hw_init] dpu hardware revision:0x50020000
[drm] Initialized msm 1.13.0 for ae01000.display-controller on minor 0
Console: switching to colour frame buffer device 135x150
msm_dpu: [drm] fb0: msmdrmfb frame buffer device
```

Le firmware GPU `a630_sqe.fw` manque (pas de 3D), sans effet sur l'affichage.

### Conséquence importante pour la cmdline

Le noyau utilise **`/chosen/bootargs` du DTB**, pas la cmdline du `boot.img` :
les options passées à `mkbootimg --cmdline` étaient ignorées. Il faut patcher
le DTB (`dtb-bootargs.py` / `scripts/patch-dtb-mem.py`) pour changer les
paramètres de démarrage.
