# Validation runtime

- M7B.11 : ZAP local accepté, GPU initialisé passivement ; SQE/GMU chargés.
- DSI PLL, aux_bridge et 10 fautes SMMU restent présents.
- M11B : renderD128 ouvert, EGL initialisé, `eglChooseConfig` échoué ;
  aucun contexte/FBO/soumission ; aucun IRQ ; affichage et SSH inchangés.
- Aucun benchmark, aucun second test GPU.
- Le GPU est gelé ; la suite est l’installateur I2.
