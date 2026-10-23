# Confidentialité

- Aucun blob Samsung dans `repo/rootfs`, `repo/dist`, Git, fixtures ou releases.
- `work/private/samsung/<sha>/` et `work/private/builds/<id>/` : 0700.
- Fichiers privés : 0600.
- `--clean-private-work` refuse les symlinks et préserve les rapports si demandé.
- Les images publiques ne contiennent ni ZAP, ni clé SSH, ni host key.
- Les rapports ne contiennent aucun binaire.
