# Artefacts de référence

Ce dossier ne contient plus de binaires de build (ils étaient lourds et
obsolètes). Les images publiées sont dans [`../dist`](../dist) et se
reconstruisent avec `scripts/build-base.sh`.

| Fichier | Rôle |
|---|---|
| `android.dtb` | DTB Android/Lineage, **obligatoire** dans l'en-tête du `boot.img` (sboot refuse un DTB mainline) |
| `kernel.config` | configuration du noyau utilisée pour l'image publiée |
