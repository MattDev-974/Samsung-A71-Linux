# Migration installateur phase 1 → I2

## État historique

`install.sh` phase 1 n’est pas récupérable par Git :

```text
git show HEAD:install.sh        -> absent
git show origin/main:install.sh -> absent
git log --all -- install.sh     -> vide
git rev-list --objects --all    -> aucun objet install.sh
index                           -> blob vide e69de29b…
```

Il ne s’agit donc pas d’une suppression versionnée prouvée : le contrat
phase 1 a été testé mais jamais versionné. I2 ne prétend pas restaurer un
fichier bit à bit.

## Compatibilité conservée

```text
--help, --version, --check, --dry-run, --jobs N, --no-write
manifeste A71_MANIFEST (absent/vide/invalide refusé)
journaux sous work/ avec permissions 0700/0600
plan déterministe et validation des clés
```

## Nouveau contrat

```text
--profile server|desktop-open|desktop-local
--list-profiles, --describe-profile
--samsung-firmware, --recovery-boot
--print-flash-command, --flash-local-boot
--clean-private-work
```

Le build est explicite : `--profile server` par défaut documenté ; aucune
écriture cible sans action. Les options de flash restent séparées et ne sont
jamais exécutées par le build.

## Tests

- `tests/phase1/run-tests.sh` : 1133 réussites, 0 échec ;
- `tests/installer/run-tests.sh` : tests CLI I2 ;
- `tests/test_i2.py` : profils, validation Samsung synthétique, privacy,
  rollback, refus de flash.

Wi-Fi/audio/Bluetooth restent expérimentaux et absents des profils/menu.
