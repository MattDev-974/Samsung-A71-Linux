# GPU — état final

```text
gpu_sqe_firmware_load       pass
gpu_gmu_firmware_load       pass
gpu_zap_manifest_load       pass (local)
gpu_zap_segments_load       pass (local)
gpu_zap_scm_authentication  accepted (test local antérieur)
gpu_hardware_init           pass (M7B.11)
```

Validation Mesa M11B corrigée :

```text
gpu_render_node_open   pass
gpu_userspace_driver   detected_not_validated
gpu_egl_initialize     pass
gpu_egl_config         fail
gpu_egl_context        not_tested
gpu_gles_context       not_tested
gpu_fbo                not_tested
gpu_submission         not_tested
gpu_irq_activity       not_tested
gpu_devfreq_activity   not_tested
gpu_runtime            initialized_passive
display_unchanged      pass
ssh_stability          pass
rollback_required      no
```

`eglChooseConfig` a échoué avant tout contexte ; aucun travail GPU n’a été
soumis. Le développement GPU est **gelé**. Aucun second test ne sera lancé.
