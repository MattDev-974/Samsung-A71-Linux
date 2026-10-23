# Audio A715F — état statique M10B0

## Matériel identifié

- codec : WCD9375, confirmé par `mixer_paths_wcd9375.xml` stock ;
- macros Bolero : RX/TX/VA/WSA, SoundWire `swr0/1/2` ;
- aucun amplificateur WSA881x distinct n'est prouvé dans le DT Android ;
- ADSP Android : `qcom,lpass@62400000`, PAS 1, `adsp`.

## Chaîne

```text
ADSP -> APR/Q6 -> machine -> WCD9375/WSA -> snd_soc_card -> ALSA
```

## État mainline

- ADSP : désactivé, firmware `.mbn` demandé alors que le stock est `.mdt`/`.bXX` ;
- codec/SoundWire : aucun nœud A715F ;
- machine driver : `snd-soc-sm8250` n'a pas de compatible A715F ;
- carte ALSA : absente.

## Verdict

```text
audio_codec_identity          pass
audio_android_contract        degraded
audio_adsp_contract           blocked
audio_adsp_firmware_format    blocked
audio_module_compatibility    unknown
audio_machine_driver_fit      blocked
experimental_audio_dtb        blocked
m10b_runtime_authorization    blocked
```

Aucun DTB expérimental valide n'a été compilé ; les patches sont bloqués et
non appliqués. Aucun module, remoteproc, firmware, mixer ou son.
