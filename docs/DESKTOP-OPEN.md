# Profil desktop-open

Server + `a630_sqe.fw` + `a630_gmu.bin` + libdrm + Mesa/Freedreno
(`mesa`, `mesa-dri-gallium`, `mesa-egl`, `mesa-gles`, `mesa-gbm`).

Ne contient **aucun** `a615_zap.*` Samsung, build-base, mesa-dev, en-tête
temporaire ou binaire de test M11B.

```text
redistributable = yes
gpu_hardware_init = incomplete_without_local_zap
gpu_render = not_guaranteed
```

L’initialisation GPU complète de l’A715F exige aussi un ZAP Samsung fourni
localement.
