#!/usr/bin/env python3
"""Fixtures minimales pour scripts/validate-rootfs.sh (E1).

Construit un rootfs factice mais conforme aux contrôles statiques : 100 paquets,
607 modules, OpenRC, comptes verrouilles, modes sensibles corrects, services
M1. Les tests mutent ensuite une copie pour vérifier chaque refus.
"""

import argparse
import os
import shutil
import stat
import sys

ELF_AARCH64 = (
    b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8) +
    (2).to_bytes(2, "little") + (183).to_bytes(2, "little") +
    (1).to_bytes(4, "little") + (0).to_bytes(8, "little") +
    (0).to_bytes(8, "little") + (0).to_bytes(8, "little") +
    (64).to_bytes(4, "little") + (0).to_bytes(2, "little") +
    (0).to_bytes(2, "little") + (0).to_bytes(2, "little") +
    (0).to_bytes(2, "little") + (0).to_bytes(2, "little") +
    bytes(16)
)

SERVICES = ("devfs", "procfs", "sysfs", "mdev", "networking",
            "local", "dhcpcd", "sshd", "chronyd")

MODULES = 607
PACKAGES = 100


def write(path, data=b"x\n", mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)
    os.chmod(path, mode)


def symlink(target, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.lexists(path):
        os.unlink(path)
    os.symlink(target, path)


def build(root, release):
    for name in ("bin", "sbin", "etc", "etc/apk", "etc/init.d", "etc/local.d",
                 "etc/network", "etc/runlevels", "etc/ssh", "home", "lib",
                 "lib/modules", "proc", "root", "run", "sys", "tmp", "usr",
                 "usr/bin", "usr/share", "usr/share/zoneinfo", "var", "var/log",
                 "var/tmp", "dev", "reports"):
        os.makedirs(os.path.join(root, name), exist_ok=True)

    write(os.path.join(root, "etc/alpine-release"), b"3.22.7\n")
    write(os.path.join(root, "etc/apk/arch"), b"aarch64\n")
    write(os.path.join(root, "etc/apk/repositories"),
          b"https://dl-cdn.alpinelinux.org/alpine/v3.22/main\n"
          b"https://dl-cdn.alpinelinux.org/alpine/v3.22/community\n")
    write(os.path.join(root, "etc/hostname"), b"a71\n")
    write(os.path.join(root, "etc/hosts"),
          b"127.0.0.1 localhost localhost.localdomain\n"
          b"::1 localhost ip6-localhost\n"
          b"172.16.42.1 a71.localdomain a71\n")
    write(os.path.join(root, "etc/fstab"),
          b"LABEL=A71ROOT\t/\text4\trw,relatime\t0 1\n")
    write(os.path.join(root, "etc/timezone"), b"UTC\n")
    write(os.path.join(root, "usr/share/zoneinfo/UTC"), b"UTC\n")
    symlink("/usr/share/zoneinfo/UTC", os.path.join(root, "etc/localtime"))
    write(os.path.join(root, "etc/inittab"),
          b"::sysinit:/sbin/openrc sysinit\n"
          b"::sysinit:/sbin/openrc boot\n"
          b"::wait:/sbin/openrc default\n"
          b"tty0::respawn:/sbin/getty 38400 tty0\n"
          b"#ttyMSM0::respawn:/sbin/getty -L 115200 ttyMSM0 vt100\n")
    write(os.path.join(root, "etc/network/interfaces"),
          b"auto lo\niface lo inet loopback\n")
    write(os.path.join(root, "etc/resolv.conf"),
          b"# local USB management, no external DNS\n")
    write(os.path.join(root, "etc/passwd"),
          b"root:x:0:0:root:/root:/bin/sh\n"
          b"sshd:x:22:22:sshd:/dev/null:/sbin/nologin\n")
    write(os.path.join(root, "etc/group"),
          b"root:x:0:root\nshadow:x:42:\ntty:x:5:\nchrony:x:10:\n")
    write(os.path.join(root, "etc/shadow"),
          b"root:*::0:::::\nsshd:!::0:::::\n", 0o640)
    write(os.path.join(root, "etc/ssh/sshd_config"),
          b"PermitRootLogin prohibit-password\nPasswordAuthentication no\nPermitEmptyPasswords no\n"
          b"PubkeyAuthentication yes\nHostKey /etc/ssh/ssh_host_ed25519_key\n")
    write(os.path.join(root, "etc/local.d/firstboot.start"),
          b"#!/bin/sh\nssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key\n"
          b"ssh-keygen -q -t rsa -N '' -f /etc/ssh/ssh_host_rsa_key\n", 0o755)
    write(os.path.join(root, "sbin/openrc"), b"#!/bin/sh\nexit 0\n", 0o755)

    for service in SERVICES:
        write(os.path.join(root, "etc/init.d", service), b"#!/bin/sh\nexit 0\n", 0o755)
    for service in ("devfs", "procfs", "sysfs", "mdev", "networking"):
        symlink("/etc/init.d/" + service, os.path.join(root, "etc/runlevels/sysinit", service))
    for service in ("local", "dhcpcd", "sshd", "chronyd"):
        symlink("/etc/init.d/" + service, os.path.join(root, "etc/runlevels/default", service))

    write(os.path.join(root, "bin/busybox"), ELF_AARCH64, 0o755)
    write(os.path.join(root, "bin/bbsuid"), ELF_AARCH64, 0o4111)
    write(os.path.join(root, "bin/mount"), ELF_AARCH64, 0o4755)
    write(os.path.join(root, "bin/umount"), ELF_AARCH64, 0o4755)
    symlink("/bin/busybox", os.path.join(root, "bin/sh"))
    symlink("/bin/busybox", os.path.join(root, "sbin/init"))
    symlink("/sbin/init", os.path.join(root, "init"))
    os.chmod(os.path.join(root, "root"), 0o700)
    os.chmod(os.path.join(root, "tmp"), 0o1777)
    os.chmod(os.path.join(root, "var/tmp"), 0o1777)

    release_dir = os.path.join(root, "lib/modules", release)
    os.makedirs(os.path.join(release_dir, "kernel"), exist_ok=True)
    for index in range(MODULES):
        write(os.path.join(release_dir, "kernel", "module%04d.ko" % index), b"", 0o644)
    with open(os.path.join(release_dir, "modules.dep"), "w", encoding="utf-8") as fh:
        for index in range(MODULES):
            fh.write("kernel/module%04d.ko:\n" % index)
    for name in ("modules.dep.bin", "modules.alias", "modules.alias.bin",
                 "modules.softdep", "modules.symbols", "modules.symbols.bin"):
        write(os.path.join(release_dir, name), b"data\n", 0o644)

    os.makedirs(os.path.join(root, "root/.ssh"), exist_ok=True)
    os.chmod(os.path.join(root, "root/.ssh"), 0o700)
    write(os.path.join(root, "etc/modprobe.d/a71-historical-kernel.conf"),
          b"blacklist ipv6\ninstall ipv6 /bin/false\n")
    write(os.path.join(root, "usr/local/sbin/a71-usb-gadget"),
          b"#!/bin/sh\nset -eu\n# /sys/class/udc a600000.usb 0x1d6b 0x0104 rndis ecm\n"
          b"start) : ;;\nstop) : ;;\nstatus) : ;;\n", 0o755)
    write(os.path.join(root, "etc/init.d/a71-usb"),
          b"#!/sbin/openrc-run\ndepend() { need localmount; before a71-net; }\n", 0o755)
    write(os.path.join(root, "etc/init.d/a71-net"),
          b"#!/sbin/openrc-run\ndepend() { need a71-usb; provide net; before sshd; }\n"
          b"A71_ECM_ADDR=10.71.0.2\n"
          b"A71_ECM_GW=10.71.0.1\n"
          b"A71_RNDIS_GW=172.16.42.2\n"
          b"ip route replace default via $A71_ECM_GW dev usb1\n"
          b"# 172.16.42.1 172.16.43.1 172.16.42.100 172.16.42.150 "
          b"172.16.43.100 172.16.43.150 port=0 dnsmasq\n", 0o755)
    write(os.path.join(root, "etc/init.d/a71-ssh-keys"),
          b"#!/sbin/openrc-run\n", 0o755)
    write(os.path.join(root, "etc/init.d/a71-bootlog"),
          b"#!/sbin/openrc-run\n# early late-60 late-90 /sys/class/udc /sys/class/net "
          b"usb_gadget/a71 rc-status dmesg authorized_keys\n", 0o755)
    for svc in ("a71-usb", "a71-net", "a71-ssh-keys", "a71-bootlog", "sshd"):
        symlink("/etc/init.d/" + svc, os.path.join(root, "etc/runlevels/default", svc))
    symlink("/etc/init.d/syslog", os.path.join(root, "etc/runlevels/boot/syslog"))

    with open(os.path.join(root, "reports/packages.txt"), "w", encoding="utf-8") as fh:
        for index in range(PACKAGES):
            fh.write("pkg%03d-1.0-r0\n" % index)

    entries = []
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(base, d))]
        for name in list(dirs) + files:
            path = os.path.join(base, name)
            rel = "/" + os.path.relpath(path, root)
            if rel == "/reports" or rel.startswith("/reports/"):
                continue
            st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode):
                kind = "l"
            elif stat.S_ISDIR(st.st_mode):
                kind = "d"
            else:
                kind = "f"
            entries.append((rel, kind, stat.S_IMODE(st.st_mode)))
    entries.append(("/", "d", 0o755))
    entries.sort()
    with open(os.path.join(root, "reports/ownership-manifest.txt"), "w",
              encoding="utf-8") as fh:
        for rel, kind, mode in entries:
            fh.write("0:0:%04o:%s:%s\n" % (mode, kind, rel))
    os.chmod(os.path.join(root, "reports/ownership-manifest.txt"), 0o600)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--release", default="6.18.0-rc1-a71+")
    args = parser.parse_args()
    if os.path.lexists(args.out):
        shutil.rmtree(args.out)
    os.makedirs(args.out)
    build(args.out, args.release)
    print(args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
