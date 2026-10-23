# Internet USB A71 — ECM principal, RNDIS secours

## Topologie M8.2

```text
ECM principal
  téléphone usb1  10.71.0.2/30
  hôte            10.71.0.1/30   (NetworkManager a71-ecm)
  route            default via 10.71.0.1 dev usb1
  SSH              root@10.71.0.2

RNDIS secours
  téléphone usb0  172.16.42.1/24
  hôte            172.16.42.2/24 (NetworkManager a71-usb)
  SSH              root@172.16.42.1
  aucune route par défaut en mode ECM
```

Aucune adresse DHCP (`172.16.42.125/127`) n'est une passerelle persistante.

## Hôte Arch Linux

```bash
sudo repo/scripts/install-a71-host-persistence.sh install
sudo repo/scripts/install-a71-host-ecm-persistence.sh install
sudo repo/scripts/host-usb-internet.sh start
sudo repo/scripts/host-usb-internet.sh verify
sudo repo/scripts/host-usb-internet.sh stop
```

Profils :
- `a71-ecm` : `10.71.0.1/30`, manual, never-default, IPv6 disabled ;
- `a71-usb` : `172.16.42.2/24`, manual, never-default, secours ;
- anciens profils A71 : autoconnect désactivé, état sauvegardé.

NAT : table nftables dédiée `a71_usb`, source strictement `10.71.0.2`,
masquerade vers l'interface Internet réelle. Aucune purge globale.

UFW : une règle de routage minimale source `10.71.0.2` vers l'interface
Internet, sans purge ni règle globale supplémentaire.

## Téléphone

`a71-net` configure :
- usb0 `172.16.42.1/24` et dnsmasq RNDIS ;
- usb1 `10.71.0.2/30` ;
- route ECM prioritaire ;
- fallback RNDIS via `172.16.42.2` si ECM absent ;
- retry ECM borné (12 × 30 s) après fallback ;
- chronyd redémarré lors d'une transition effective ;
- USB local et SSH conservés même sans Internet.

Après reboot humain, vérifier :

```text
usb0=172.16.42.1/24
usb1=10.71.0.2/30
default via 10.71.0.1 dev usb1
SSH ECM root@10.71.0.2
SSH RNDIS root@172.16.42.1
Internet/DNS/HTTPS/chrony
```
