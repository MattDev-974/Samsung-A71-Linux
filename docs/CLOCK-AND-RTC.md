# Horloge et RTC — état A71

## constat

- heure système au boot : `1970-01-01` + uptime ;
- `/dev/rtc0` absent ;
- `/sys/class/rtc/` vide ;
- `/proc/driver/rtc` absent ;
- aucune route par défaut, aucun DNS externe ;
- `chronyd` 4.6.1 installé mais arrêté.

## cause chronyd

```text
Fatal error : Could not get user/group ID of chrony
```

L'utilisateur et le groupe `chrony` ne sont pas créés. La résolution de
`pool.ntp.org` échoue aussi faute de route/DNS. `rtcsync` ne peut pas
fonctionner sans périphérique RTC.

## options (non appliquées en M6)

A. heure ponctuelle depuis le PC via SSH ;
B. NTP après route/NAT et création de l'utilisateur/groupe ;
C. RTC après ajout driver/DT et `/dev/rtc0` ;
D. timestamp de dernier arrêt propre.

Aucune modification, aucun démarrage de chronyd, aucune requête NTP.
`clock_runtime=fail` avant M7A. Après M7A/M8 :

```text
clock_local_sync=pass
clock_boot_persistence=ready_for_reboot_test
chrony_runtime=pass
```


## Mise à jour M7A/M8

- heure initiale poussée depuis le PC : **2026-10-23T13:50:40Z** ;
- `/usr/local/sbin/a71-clock` et `/etc/init.d/a71-clock` installés ;
- état `/var/lib/a71-clock/last-good-epoch` (0644 root:root), moniteur 300 s ;
- restauration au boot sans recul, pas de RTC, pas de réseau dans le service ;
- chrony : utilisateur/groupe créés, `rtcsync` et `initstepslew` retirés ;
- source NTP directe `162.159.200.1` (time.cloudflare.com), commande locale
  limitée à `127.0.0.1:323` ;
- `chronyc tracking` : Leap status Normal, offset sub-ms ;
- persistance après reboot : `ready_for_reboot_test`, non observée.
