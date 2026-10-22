# Installer des paquets (Alpine / apk)

Le système est une base **Alpine Linux 3.22 (musl, aarch64)** : les paquets
s'installent avec `apk`.

## Utilisation

Depuis le PC :

```bash
./scripts/a71-install.sh pkgs nano htop curl
```

Ou directement sur le téléphone (SSH) :

```bash
apk update
apk add nano
```

## Ce qui a été nécessaire pour que ça marche

1. **Le binaire `apk`** n'était pas dans le rootfs : `apk.static` (paquet
   `apk-tools-static`) est copié dans `/sbin/apk`.
2. **Les clés de signature** : les `*.rsa.pub` du paquet `alpine-keys` vont
   dans `/etc/apk/keys/`.
3. **Les dépôts** : `/etc/apk/repositories` doit contenir

   ```
   https://dl-cdn.alpinelinux.org/alpine/v3.22/main
   https://dl-cdn.alpinelinux.org/alpine/v3.22/community
   ```

4. **Les certificats** : le paquet `ca-certificates` était présent mais
   **`/etc/ssl/cert.pem` manquait** (CAfile par défaut d'OpenSSL). Sans lui :

   ```
   tls_post_process_server_certificate:certificate verify failed
   ```

   Correctif : `ln -s certs/ca-certificates.crt /etc/ssl/cert.pem`

5. **L'horloge** : au démarrage elle est à 1970, donc les certificats sont
   « pas encore valides ». L'init synchronise maintenant l'heure dès que le
   réseau répond (`ntpd -q`, sinon la date d'une réponse HTTP).

## Vérifications

```
$ apk update
v3.22.7 main / community — 26168 distinct packages available
$ apk add nano
(1/1) Installing nano (8.4-r0)
GNU nano, version 8.4
$ df -h /
/dev/mmcblk2  28.5G  40.5M used  27.0G free
```
