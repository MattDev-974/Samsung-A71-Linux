# Compatibilité noyau / modules

## Verdict

**`KERNEL_MODULE_MISMATCH_CONFIRMED`**

Le noyau runtime est le **#35** ; les modules de la carte proviennent d'un
build configuré avec `CONFIG_IPV6=m`. Le noyau #35 a `CONFIG_IPV6=y`. Le
module `ipv6.ko` est chargé et échoue sur 118 exports qui n'existent que
lorsque IPv6 est un module.

## 1. Noyau runtime

| Élément | Valeur | Preuve |
|---|---|---|
| release | `6.18.0-rc1-a71+` | `dmesg.txt:2` |
| build | `#35 SMP PREEMPT Thu Oct 22 20:06:59 +04 2026` | `dmesg.txt:2` |
| Image | `work/uniLoader/blob/Image` | SHA `fec0934f…` |
| même image | `work/kbuild/arch/arm64/boot/Image` | SHA `fec0934f…` (identiques) |
| config corrélée | `work/kbuild/.config` | `CONFIG_IPV6=y`, `CONFIG_DRM_MSM=y`, `CONFIG_DRM_SIMPLEDRM` absent |
| vmlinux | `work/kbuild/vmlinux` | SHA `cb032d9f…` |
| System.map | `work/kbuild/System.map` | SHA (voir artefacts) |

La config `work/kbuild/.config` est antérieure de deux minutes à l'Image #35
(`.config` 20:05:12, Image 20:07:04) et reproduit les fonctions observées :
IPv6 intégré (`NET: Registered PF_INET6`, `dmesg.txt:324`) et DRM MSM actif
(erreurs DSI `dmesg.txt:500-501`). C'est la config historique la plus
corrélée, sans être un hash de build signé.

**Contradiction à conserver :** le contexte indique une configuration
historique avec `DRM_MSM` désactivé, mais `work/kbuild/.config` indique
`CONFIG_DRM_MSM=y` et `CONFIG_DRM_SIMPLEDRM` non défini, et le runtime #35
montre bien `msm_dsi_phy`/`msm_dpu`. `repo/artifacts/kernel.config` a
`CONFIG_DRM_MSM` non défini mais `CONFIG_IPV6=m`, ce qui ne correspond pas
au runtime #35. La configuration exacte du #35 reste donc corrélée, pas
`MATCH_CONFIRMED` ; ne pas appliquer l'affirmation DRM sans preuve
supplémentaire.

## 2. Nouveau build

| Élément | Valeur |
|---|---|
| Image | `work/kernel-build/artifacts/Image` SHA `3f913942…` |
| build | `#1 SMP PREEMPT 2025-10-13 15:39:19 UTC` |
| config | `work/kernel-build/kbuild/.config` SHA `847ff3d2…` |
| vmlinux | `work/kernel-build/kbuild/vmlinux` SHA `77b6306e…` |
| `CONFIG_IPV6` | `m` |
| `CONFIG_DRM_SIMPLEDRM` | `y` |
| `CONFIG_DRM_MSM` | `m` |

Les modules de `rootfs-functional-init-a` viennent de
`work/kernel-build/modules-install`.

## 3. Tableau de configuration

| Symbole | #35 (`work/kbuild/.config`) | nouveau (`work/kernel-build/kbuild/.config`) |
|---|---|---|
| `CONFIG_IPV6` | `y` | `m` |
| `CONFIG_MODVERSIONS` | non défini | non défini |
| `CONFIG_MODULE_UNLOAD` | `y` | `y` |
| `CONFIG_MODULE_COMPRESS` | non défini | non défini |
| `CONFIG_DRM` | `y` | `y` |
| `CONFIG_DRM_SIMPLEDRM` | non défini | `y` |
| `CONFIG_DRM_MSM` | `y` | `m` |
| `CONFIG_DRM_FBDEV_EMULATION` | `y` | `y` |
| `CONFIG_USB_CONFIGFS` | `y` | `y` |
| `CONFIG_USB_CONFIGFS_RNDIS` | `y` | `y` |
| `CONFIG_USB_CONFIGFS_ECM` | `y` | `y` |
| `CONFIG_USB_DWC3` | `y` | `y` |
| `CONFIG_DEVTMPFS` | `y` | `y` |
| `CONFIG_EXT4_FS` | `y` | `y` |
| `CONFIG_MMC` | `y` | `y` |

## 4. Pourquoi le module échoue

`work/rootfs/rootfs-functional-init-a/lib/modules/6.18.0-rc1-a71+/kernel/net/ipv6/ipv6.ko` :

- taille `726 280` octets ;
- SHA-256 `ad99e7a8f0aafd80b9f898623ae11f2ed628698a8c7a0d2e4b330bc6f5fc6261` ;
- vermagic `6.18.0-rc1-a71+ SMP preempt mod_unload aarch64` ;
- 626 symboles UND, dont 118 signalés inconnus ;
- hash identique dans `work/kbuild`, `work/kernel-build` et le rootfs : le
  module n'est pas neuf, il a été compilé pour `IPV6=m` puis copié dans le
  rootfs.

`CONFIG_MODVERSIONS` est absent des deux noyaux : il n'y a pas de CRC
`__versions`. Le module est donc accepté par le vermagic, puis le loader
échoue sur les symboles non exportés.

`work/kernel/include/net/ip.h:695-700` :

```c
#if IS_MODULE(CONFIG_IPV6)
#define EXPORT_IPV6_MOD(X) EXPORT_SYMBOL(X)
#define EXPORT_IPV6_MOD_GPL(X) EXPORT_SYMBOL_GPL(X)
#else
#define EXPORT_IPV6_MOD(X)
#define EXPORT_IPV6_MOD_GPL(X)
#endif
```

Avec `CONFIG_IPV6=y`, ces exports sont **compilés à vide**. Vérification
directe :

```text
# noyau #35
ffff800080d06a30 T inet_bhash2_reset_saddr
# aucun __ksymtab_inet_bhash2_reset_saddr

# nouveau noyau
ffff800080c47314 T inet_bhash2_reset_saddr
ffff8000811c1a94 r __ksymtab_inet_bhash2_reset_saddr
```

Les 118 symboles inconnus sont tous dans ce cas ; 115 sont explicitement
`EXPORT_IPV6_MOD*`, 3 sont sous `#if !IS_BUILTIN(CONFIG_IPV6)`
(`net/ipv6/ip6_icmp.c:10-48`). Détail complet :
`work/runtime-analysis/ipv6-unknown-symbols.tsv`.

## 5. Module.symvers

`work/kbuild/Module.symvers` contient certains de ces symboles, mais il est
daté du **18:17**, avant l'Image #35 (20:07). Il ne représente donc pas
nécessairement les exports du binaire #35. La preuve fiable est `vmlinux` /
`System.map` du build #35, qui ne contient pas les `__ksymtab_*` concernés.

## 6. Conséquence USB

Les options USB sont identiques (`CONFIG_USB_CONFIGFS=y`, RNDIS/ECM=y,
DWC3=y) dans les deux configs. L'absence de `usb0` n'est **pas** un problème
de module USB : c'est l'absence de configuration userspace ConfigFS dans le
nouveau rootfs.

## 7. Verdict opérationnel

- ne pas charger `ipv6.ko` sur le noyau #35 ;
- IPv6 est déjà intégré dans #35 ;
- si des modules sont nécessaires, les reconstruire avec la config exacte du
  noyau #35 (donc sans `ipv6.ko`) ;
- ne pas mélanger les modules du build #1 avec le noyau #35.
