# Où le noyau se bloque : instrumentation et résultats

## Méthode

Le noyau est instrumenté avec un marqueur global (`a71_progress`, dans
l'image elle-même) écrit à chaque étape, suivi de `dc civac` pour le pousser
hors des caches CPU. Après un démarrage raté, on redémarre en Download mode
(RAM conservée) et une sonde uniLoader relit la valeur et l'affiche en
**nombre de bandes blanches**.

C'est indispensable : sans le `dc civac`, les valeurs restent dans le cache et
la lecture est fausse (premiers résultats « bleu = 5 » erratiques).

### Table des marqueurs

| Valeur | Point de passage |
|---|---|
| 1-4 | `primary_entry` : entrée, boot args, EL, `__cpu_setup` (assembleur, MMU off) |
| 5 | entrée `start_kernel` |
| 6 | entrée `setup_arch` |
| 7 | après `setup_initial_init_mm` |
| 8 | après `early_fixmap_init` |
| 9 | après `early_ioremap_init` |
| 10 | entrée `setup_machine_fdt` |
| 11 | après `fixmap_remap_fdt` |
| 12 | `early_init_dt_scan` OK |
| 13 | fin de `setup_machine_fdt` |
| 14 | après `jump_label_init` |
| 15 | après `parse_early_param` |
| 16 | après `local_daif_restore` |
| 17 | après `cpu_uninstall_idmap` |
| 18 | après `arm64_memblock_init` |
| 19 | entrée `paging_init` |
| 20 | entrée `map_mem` |
| 21 | après pool kfence |
| 22 | après `memblock_mark_nomap` (avant la boucle de mapping) |
| 23 | après la boucle `for_each_mem_range` |
| 24 | fin de `map_mem` |
| 25-28 | suite de `paging_init` |
| 29-31 | retour dans `setup_arch`, PSCI, fin |
| 99 | `early_init_dt_scan` a échoué (boucle infinie de `setup_machine_fdt`) |

## Résultats mesurés

- Le noyau **atteint `start_kernel`**, parse le DTB et va jusqu'à
  `arm64_memblock_init` (marqueur **18**).
- Avec le DTB d'origine, le nœud `memory@80000000` a une **taille de 0** : le
  bootloader Samsung le remplit au moment de démarrer Android, mais uniLoader
  passe le DTB embarqué sans cette mise à jour. Le noyau n'a donc aucune RAM.
- Après avoir patché le nœud mémoire à **6 Gio**, le noyau détecte bien 6 Gio
  et progresse jusqu'au marqueur **22**, puis se bloque dans la boucle de
  `map_mem()` (`__map_memblock`).

## Correctif du nœud mémoire

`scripts/patch-dtb-mem.py` écrit la taille de RAM dans le DTB :

```bash
./scripts/patch-dtb-mem.py out/dtb out/dtb-mem --size 0x180000000
```

UniLoader devrait à terme récupérer cette taille depuis le DTB que lui passe
le bootloader (celui-ci est déjà patché) au lieu de la coder en dur.

## Le noyau démarre en espace utilisateur (2 Gio)

Avec le nœud mémoire patché à **2 Gio** (au lieu de 6), le noyau va au bout :

- la console fbcon s'affiche (`Console: switching to colour frame buffer
  device 135x50`, logo Tux), le début du log est lisible ;
- le marqueur atteint **50** = juste avant `run_init_process("/init")` ;
- une image de test dont `/init` ne fait que `reboot -f` provoque bien un
  **redémarrage** : l'espace utilisateur est atteint.

Avec 6 Gio, le blocage reste dans `map_mem` (marqueur 22) : probablement les
mappings 4 Kio de `force_pte_mapping()` sur une zone beaucoup plus grande.

Problèmes restants :

- l'écran se corrompt quelques secondes après le passage en fbcon ;
- le gadget USB (RNDIS/ECM) n'apparaît pas encore — l'init réel tourne mais
  `/sys/class/udc/*` est probablement vide (contrôleur dwc3 non sondé).

## Instrumentation de l'init

L'init écrit son avancement dans la **dernière ligne du framebuffer**
(physique `0xA09E2320`, hors zone console) avec `dd` sur `/dev/fb0`. Une sonde
uniLoader relit cette valeur après redémarrage :

| Valeur | Étape |
|---|---|
| 1 | init lancé |
| 2 | montages faits |
| 3 | sshd démarré |
| 4 | script gadget exécuté |
| 5 | UDC présent |

## Piste suivante

Le blocage restant est dans la construction des tables de pages de la mémoire
linéaire (`map_mem`). Vérifier : découpage `force_pte_mapping()` (mappings 4K
pour 6 Gio), allocations `memblock` des tables, ou passer en mappages de blocs
2 Mio (`CONFIG_RODATA_FULL_DEFAULT_ENABLED=n`).
