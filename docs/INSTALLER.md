# Installateur A71 I2

```sh
./install.sh                         # menu si terminal, sinon server
./install.sh --profile server
./install.sh --profile desktop-open
./install.sh --profile desktop-local --samsung-firmware ZIP --recovery-boot IMG
./install.sh --list-profiles
./install.sh --describe-profile PROFILE
./install.sh --check
./install.sh --dry-run --profile PROFILE
./install.sh --print-plan --profile PROFILE
./install.sh --verify-samsung-firmware PATH
./install.sh --clean-private-work [--keep-reports]
./install.sh --print-flash-command IMAGE
./install.sh --flash-local-boot IMAGE
```

La construction ne flashe jamais. Le flash est une commande distincte et
n'est pas exécutée en I2. Aucun blob Samsung n'est publié.

Sorties publiques : `work/builds/`.
Sorties privées : `work/private/` (0700, fichiers 0600).
