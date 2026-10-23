#!/usr/bin/env python3
"""validate-rootfs.py - validation statique stricte du rootfs A71 (E1).

Lecture seule : le seul fichier ecrit est le rapport demande. Aucun montage,
chroot, QEMU, sudo, loop device ni acces appareil.

Codes : 0 conforme, 1 non-conformite, 2 usage, 3 entree invalide,
        4 rapport impossible.
"""

import argparse
import hashlib
import os
import posixpath
import re
import stat
import sys
import tempfile

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_USAGE = 2
EXIT_INPUT = 3
EXIT_REPORT = 4

PEM_MARKERS = (
    b"BEGIN OPENSSH PRIVATE KEY",
    b"BEGIN RSA PRIVATE KEY",
    b"BEGIN EC PRIVATE KEY",
    b"BEGIN PRIVATE KEY",
)
KEY_NAMES = re.compile(r"^(ssh_host_.*_key|id_rsa|id_ed25519|id_ecdsa)$")


class Report:
    def __init__(self):
        self.lines = []
        self.failures = []

    def ok(self, ident, detail=""):
        self.lines.append("OK   %s%s" % (ident, " " + detail if detail else ""))

    def fail(self, ident, detail=""):
        self.failures.append((ident, detail))
        self.lines.append("FAIL %s%s" % (ident, " " + detail if detail else ""))

    def check(self, condition, ident, detail=""):
        if condition:
            self.ok(ident, detail)
        else:
            self.fail(ident, detail)
        return condition

    def text(self, rootfs_name):
        out = ["# validate-rootfs - rapport deterministe",
               "rootfs=%s" % rootfs_name,
               "checks=%d" % (len(self.lines)),
               "nonconformites=%d" % len(self.failures),
               ""]
        out.extend(self.lines)
        out.append("")
        out.append("RESULTAT=%s" % ("OK" if not self.failures else "NON_CONFORME"))
        return "\n".join(out) + "\n"


def read_text(path, limit=4 * 1024 * 1024):
    with open(path, "rb") as fh:
        data = fh.read(limit)
    return data.decode("utf-8", "replace")


def parse_manifest(path):
    """Parseur YAML minimal du manifeste (sections + cles a 2 espaces)."""
    sections = {}
    current = None
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            stripped = line.rstrip("\n")
            indent = len(stripped) - len(stripped.lstrip(" "))
            match = re.match(r"^([A-Za-z0-9_]+):\s*(.*)$", stripped.strip())
            if not match:
                continue
            key, value = match.groups()
            if indent == 0:
                current = key
                sections.setdefault(current, {})
            elif indent == 2 and current is not None:
                sections[current][key] = value.strip().strip('"')
    return sections


def parse_policy(path):
    policy = {}
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.rstrip("\n").split(None, 5)
            if len(parts) != 6:
                raise ValueError("politique ligne %d invalide" % lineno)
            kind, mode, uid, gid, rel, justification = parts
            if kind not in ("d", "f", "l"):
                raise ValueError("politique ligne %d : type" % lineno)
            if not rel.startswith("/") or ".." in rel.split("/"):
                raise ValueError("politique ligne %d : chemin" % lineno)
            if rel != "/":
                rel = rel.rstrip("/")
            policy[rel] = (kind, int(mode, 8), int(uid), int(gid), justification)
    return policy


def lstat(root, rel):
    path = root if rel == "/" else os.path.join(root, rel.lstrip("/"))
    try:
        return os.lstat(path), path
    except OSError:
        return None, path


def actual_kind(st):
    if stat.S_ISDIR(st.st_mode):
        return "d"
    if stat.S_ISLNK(st.st_mode):
        return "l"
    if stat.S_ISREG(st.st_mode):
        return "f"
    return "o"


def mode_text(mode):
    return format(mode & 0o7777, "04o")


def parse_ownership(path, report):
    entries = {}
    order = []
    errors = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split(":", 4)
            if len(fields) != 5:
                errors.append("ligne %d : 5 champs attendus" % lineno)
                continue
            uid_s, gid_s, mode_s, kind, rel = fields
            try:
                uid = int(uid_s, 10)
                gid = int(gid_s, 10)
                mode = int(mode_s, 8)
            except ValueError:
                errors.append("ligne %d : uid/gid/mode non numerique" % lineno)
                continue
            if kind not in ("d", "f", "l"):
                errors.append("ligne %d : type invalide" % lineno)
                continue
            if not rel.startswith("/"):
                errors.append("ligne %d : chemin non absolu" % lineno)
                continue
            if ".." in rel.split("/"):
                errors.append("ligne %d : traversee '..'" % lineno)
                continue
            if "//" in rel or (rel != "/" and rel.endswith("/")):
                errors.append("ligne %d : chemin non normalise" % lineno)
                continue
            if mode < 0 or mode > 0o7777:
                errors.append("ligne %d : mode hors plage" % lineno)
                continue
            if rel in entries:
                errors.append("ligne %d : doublon %s" % (lineno, rel))
                continue
            norm = "/" if rel == "/" else posixpath.normpath(rel)
            if norm != rel:
                errors.append("ligne %d : chemin non canonique %s" % (lineno, rel))
                continue
            if rel.startswith(("/home/", "/tmp/", "/Users/", "/private/", "/var/folders/")):
                errors.append("ligne %d : chemin prive interdit %s" % (lineno, rel))
                continue
            entries[rel] = (uid, gid, mode, kind)
            order.append(rel)
    for error in errors[:30]:
        report.fail("ownership", error)
    report.check(not errors, "ownership_format", "%d entree(s)" % len(entries))
    return entries


def check_basic_files(root, sections, report):
    def read(rel):
        path = os.path.join(root, rel.lstrip("/"))
        try:
            return read_text(path).strip()
        except OSError:
            return None

    version = sections.get("distribution", {}).get("version", "")
    release = sections.get("kernel", {}).get("expected_release", "")
    report.check(read("/etc/alpine-release") == version, "alpine_version", "attendu %s" % version)
    report.check(read("/etc/apk/arch") == "aarch64", "architecture", "aarch64")
    report.check(read("/etc/hostname") == "a71", "hostname", "a71")

    hosts = read("/etc/hosts") or ""
    report.check("127.0.0.1" in hosts and "a71" in hosts, "etc_hosts")

    fstab = read("/etc/fstab") or ""
    report.check(re.search(r"^LABEL=A71ROOT\s+/\s+ext4\b", fstab, re.M) is not None,
                 "fstab_label_ext4")

    inittab = read("/etc/inittab") or ""
    active_inittab = [ln.strip() for ln in inittab.splitlines()
                      if ln.strip() and not ln.lstrip().startswith("#")]
    report.check(any(re.match(r"^tty0::respawn:/sbin/getty\b", ln)
                     for ln in active_inittab), "tty0_console")
    report.check(not any(re.match(r"^ttyMSM0::respawn:", ln)
                         for ln in active_inittab), "no_active_ttyMSM0")
    bad_tty = []
    for sub in ("etc/init.d", "etc/conf.d", "etc/local.d"):
        base = os.path.join(root, sub)
        if not os.path.isdir(base):
            continue
        for dirpath, _, filenames in os.walk(base):
            for name in filenames:
                fp = os.path.join(dirpath, name)
                try:
                    data = read_text(fp, 512 * 1024)
                except OSError:
                    continue
                for ln in data.splitlines():
                    if "ttyMSM0" in ln and not ln.lstrip().startswith("#"):
                        bad_tty.append(os.path.relpath(fp, root))
                        break
    report.check(not bad_tty, "no_service_ttyMSM0",
                 ", ".join(sorted(set(bad_tty))[:5]))

    interfaces = read("/etc/network/interfaces") or ""
    report.check(re.search(r"^iface\s+usb0\s+inet\s+dhcp\b", interfaces, re.M) is None,
                 "no_usb0_dhcp_client")

    report.check(read("/etc/timezone") == "UTC", "timezone_utc")
    localtime = os.path.join(root, "etc/localtime")
    report.check(os.path.islink(localtime) and "UTC" in os.readlink(localtime),
                 "localtime_utc")

    return release


def resolve_inside(root, rel):
    """Resout un lien dans le rootfs sans sortir de l'arbre.

    Rend (path, st) ou (None, message). Detecte les boucles et les sorties.
    """
    current = rel
    seen = set()
    for _ in range(40):
        key = current
        if key in seen:
            return None, "boucle de liens"
        seen.add(key)
        path = root if current == "/" else os.path.join(root, current.lstrip("/"))
        try:
            st = os.lstat(path)
        except OSError:
            return None, "cible absente"
        if not stat.S_ISLNK(st.st_mode):
            return path, st
        target = os.readlink(path)
        if target.startswith("/"):
            candidate = os.path.normpath(os.path.join(root, target.lstrip("/")))
        else:
            candidate = os.path.normpath(os.path.join(os.path.dirname(path), target))
        try:
            if os.path.commonpath([root, candidate]) != root:
                return None, "cible sortante du rootfs"
        except ValueError:
            return None, "cible sortante du rootfs"
        current = "/" + os.path.relpath(candidate, root)
        if current == "/.":
            current = "/"
    return None, "boucle de liens (profondeur)"


def check_init_contract(root, report):
    init = os.path.join(root, "init")
    try:
        st = os.lstat(init)
    except OSError:
        report.fail("init_present", "absent")
        return
    if not stat.S_ISLNK(st.st_mode):
        report.fail("init_is_symlink", "type non lien")
        return
    report.ok("init_is_symlink")
    target = os.readlink(init)
    report.check(target == "/sbin/init", "init_target_exact",
                 "cible textuelle %s" % target)
    path, info = resolve_inside(root, "/init")
    if path is None:
        report.fail("init_resolution", info)
        return
    report.ok("init_resolution", "confinée")
    report.check(stat.S_ISREG(os.lstat(path).st_mode), "init_resolved_regular")
    report.check((os.lstat(path).st_mode & 0o111) == 0o111,
                 "init_resolved_executable")

    spath = os.path.join(root, "sbin/init")
    try:
        sst = os.lstat(spath)
    except OSError:
        report.fail("sbin_init_present", "absent")
        return
    report.ok("sbin_init_present")
    if stat.S_ISLNK(sst.st_mode):
        spath2, sinfo = resolve_inside(root, "/sbin/init")
        if spath2 is None:
            report.fail("sbin_init_resolution", sinfo)
            return
        report.check(stat.S_ISREG(os.lstat(spath2).st_mode), "sbin_init_regular")
        report.check((os.lstat(spath2).st_mode & 0o111) == 0o111,
                     "sbin_init_executable")
    else:
        report.check((sst.st_mode & 0o111) == 0o111, "sbin_init_executable")

    inittab = os.path.join(root, "etc/inittab")
    try:
        text = read_text(inittab)
    except OSError:
        report.fail("inittab_present", "absent")
        return
    report.ok("inittab_present")
    required = (
        "::sysinit:/sbin/openrc sysinit",
        "::sysinit:/sbin/openrc boot",
        "::wait:/sbin/openrc default",
    )
    for line in required:
        report.check(line in text, "inittab_%s" % line.split(":")[-1].replace(" ", "_"))
    report.check(os.path.isfile(os.path.join(root, "sbin/openrc")) and
                 os.access(os.path.join(root, "sbin/openrc"), os.X_OK),
                 "openrc_for_inittab")


def check_packages(root, report):
    path = os.path.join(root, "reports/packages.txt")
    try:
        lines = [line.strip() for line in open(path, encoding="utf-8", errors="replace")
                 if line.strip() and not line.startswith("#")]
    except OSError:
        report.fail("packages", "reports/packages.txt absent")
        return
    report.check(len(lines) == 100, "package_count", "%d attendus" % 100)
    report.check(lines == sorted(lines), "package_inventory_sorted")
    report.check(len(set(lines)) == len(lines), "package_inventory_unique")

    repos_path = os.path.join(root, "etc/apk/repositories")
    try:
        repos = [line.strip() for line in open(repos_path, encoding="utf-8", errors="replace")
                 if line.strip()]
    except OSError:
        repos = []
    expected = {
        "https://dl-cdn.alpinelinux.org/alpine/v3.22/main",
        "https://dl-cdn.alpinelinux.org/alpine/v3.22/community",
    }
    report.check(set(repos) == expected, "apk_repositories_v322")


def check_modules(root, release, report):
    modules_root = os.path.join(root, "lib/modules")
    try:
        entries = [e for e in os.listdir(modules_root)
                   if os.path.isdir(os.path.join(modules_root, e))]
    except OSError:
        report.fail("kernel_release", "lib/modules absent")
        return
    report.check(entries == [release], "kernel_release", release)
    release_dir = os.path.join(modules_root, release)
    kos = []
    compressed = 0
    if os.path.isdir(release_dir):
        for base, _dirs, files in os.walk(release_dir):
            for name in files:
                if name.endswith(".ko"):
                    kos.append(os.path.join(base, name))
                elif name.endswith((".ko.gz", ".ko.xz", ".ko.zst")):
                    compressed += 1
    report.check(len(kos) == 607, "module_count", "%d attendus" % 607)
    report.check(compressed == 0, "module_compression", "aucun module compresse")
    for name in ("modules.dep", "modules.dep.bin", "modules.alias", "modules.alias.bin",
                 "modules.softdep", "modules.symbols", "modules.symbols.bin"):
        p = os.path.join(release_dir, name)
        report.check(os.path.isfile(p) and os.path.getsize(p) > 0, "module_metadata_%s" % name.replace(".", "_"))
    dep = os.path.join(release_dir, "modules.dep")
    try:
        dep_lines = [line for line in open(dep, encoding="utf-8", errors="replace") if line.strip()]
    except OSError:
        dep_lines = []
    report.check(len(dep_lines) == 607, "modules_dep_count", "%d lignes" % len(dep_lines))

    legacy = []
    for base, _dirs, files in os.walk(root):
        if base == modules_root or base.startswith(release_dir + os.sep):
            continue
        for name in files:
            if name.endswith(".ko"):
                legacy.append(os.path.relpath(os.path.join(base, name), root))
    report.check(not legacy, "no_legacy_modules", "%d hors release" % len(legacy))


def check_openrc(root, report):
    openrc = os.path.join(root, "sbin/openrc")
    report.check(os.path.exists(openrc) and os.access(openrc, os.X_OK), "openrc_binary")
    expected = {
        "sysinit": ("devfs", "procfs", "sysfs", "mdev"),
        "default": ("local", "sshd", "chronyd"),
    }
    for level, services in expected.items():
        for service in services:
            link = os.path.join(root, "etc/runlevels", level, service)
            good = False
            if os.path.islink(link):
                target = os.readlink(link)
                if target.startswith("/") and ".." not in target.split("/"):
                    good = os.path.exists(os.path.join(root, target.lstrip("/")))
            report.check(good, "runlevel_%s_%s" % (level, service))


def parse_sshd(path):
    values = {}
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 1)
            if len(parts) == 2:
                values[parts[0].lower()] = parts[1].strip().lower()
    except OSError:
        pass
    return values


def check_ssh_and_accounts(root, report):
    sshd = parse_sshd(os.path.join(root, "etc/ssh/sshd_config"))
    report.check(sshd.get("permitrootlogin") == "prohibit-password",
                 "sshd_permit_root_login_prohibit_password")
    report.check(sshd.get("passwordauthentication") == "no", "sshd_password_auth_no")

    shadow_path = os.path.join(root, "etc/shadow")
    shadow = {}
    empty = []
    try:
        for line in open(shadow_path, encoding="utf-8", errors="replace"):
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split(":")
            if len(fields) < 2:
                continue
            shadow[fields[0]] = fields[1]
            if fields[1] == "":
                empty.append(fields[0])
    except OSError:
        shadow = {}
    root_hash = shadow.get("root", "")
    locked = root_hash in ("*", "!") or root_hash.startswith("!")
    report.check(locked, "root_locked", "root shadow non vide et verrouille")
    report.check(not empty, "no_empty_password", "%d compte(s)" % len(empty))

    passwd_path = os.path.join(root, "etc/passwd")
    bad_passwd = []
    try:
        for line in open(passwd_path, encoding="utf-8", errors="replace"):
            fields = line.rstrip("\n").split(":")
            if len(fields) >= 2 and fields[1] == "":
                bad_passwd.append(fields[0])
    except OSError:
        pass
    report.check(not bad_passwd, "passwd_no_empty_field")


def is_elf(path):
    try:
        with open(path, "rb") as fh:
            head = fh.read(4)
        return head == b"\x7fELF"
    except OSError:
        return False


def elf_machine(path):
    try:
        with open(path, "rb") as fh:
            head = fh.read(20)
    except OSError:
        return None
    if len(head) < 20 or head[:4] != b"\x7fELF":
        return None
    endian = "little" if head[5] == 1 else "big"
    return int.from_bytes(head[18:20], endian), head[4]


def check_private_keys(root, report):
    pem_hits = []
    name_hits = []
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(base, d))]
        for name in files:
            path = os.path.join(base, name)
            rel = os.path.relpath(path, root)
            if KEY_NAMES.match(name):
                name_hits.append(rel)
            try:
                st = os.lstat(path)
            except OSError:
                continue
            if not stat.S_ISREG(st.st_mode):
                continue
            if is_elf(path):
                continue
            try:
                with open(path, "rb") as fh:
                    data = fh.read(1024 * 1024)
            except OSError:
                continue
            if b"\x00" in data[:8192]:
                continue
            for marker in PEM_MARKERS:
                if marker in data:
                    pem_hits.append(rel)
                    break
    report.check(not pem_hits, "no_private_key_pem", "%d fichier(s) texte" % len(pem_hits))
    report.check(not name_hits, "no_private_key_name", "%d nom(s) classique(s)" % len(name_hits))


def check_m1(root, report):
    def read(rel):
        path = os.path.join(root, rel.lstrip("/"))
        try:
            return read_text(path)
        except OSError:
            return ""

    def is_exec(rel):
        path = os.path.join(root, rel.lstrip("/"))
        return os.path.isfile(path) and os.access(path, os.X_OK)

    for rel in ("/usr/local/sbin/a71-usb-gadget", "/etc/init.d/a71-usb",
                "/etc/init.d/a71-net", "/etc/init.d/a71-ssh-keys",
                "/etc/init.d/a71-bootlog"):
        report.check(is_exec(rel), "m1_exec_%s" % rel.strip("/").replace("/", "_"))

    usb = read("/etc/init.d/a71-usb")
    net = read("/etc/init.d/a71-net")
    gadget = read("/usr/local/sbin/a71-usb-gadget")
    bootlog = read("/etc/init.d/a71-bootlog")
    report.check("need localmount" in usb and "before a71-net" in usb,
                 "a71_usb_dependencies")
    report.check(re.search(r"^\s*provide\s+net\b", usb, re.M) is None,
                 "a71_usb_no_provide_net")
    report.check("need a71-usb" in net and "provide net" in net and "before sshd" in net,
                 "a71_net_dependencies")
    report.check("A71_ECM_GW=10.71.0.1" in net and "A71_RNDIS_GW=172.16.42.2" in net and
                 "172.16.42.127" not in net and "via $A71_ECM_GW dev usb1" in net,
                 "a71_net_static_gateway")
    def has_ip(text, ip):
        return re.search(r"(?<![0-9.])%s(?![0-9.])" % re.escape(ip), text) is not None
    report.check(all(has_ip(net, ip) for ip in (
        "172.16.42.1", "10.71.0.2", "10.71.0.1",
        "172.16.42.100", "172.16.42.150")), "a71_net_ipv4")
    report.check("port=0" in net and "dnsmasq" in net, "a71_net_dhcp_local_only")
    report.check("set -eu" in gadget and "start)" in gadget and "stop)" in gadget and
                 "status)" in gadget, "a71_gadget_start_stop_status")
    report.check("0x1d6b" in gadget and "0x0104" in gadget, "a71_gadget_vid_pid")
    report.check("rndis" in gadget and "ecm" in gadget, "a71_gadget_rndis_ecm")
    report.check("/sys/class/udc" in gadget and "a600000.usb" in gadget,
                 "a71_gadget_udc_policy")
    report.check("blacklist ipv6" in read("/etc/modprobe.d/a71-historical-kernel.conf") and
                 "install ipv6 /bin/false" in read("/etc/modprobe.d/a71-historical-kernel.conf"),
                 "ipv6_module_blacklist")
    explicit = []
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in ("reports", "lib", "usr/lib", "bin", "sbin", "var")]
        for name in files:
            path = os.path.join(base, name)
            if not os.path.isfile(path) or os.path.islink(path):
                continue
            try:
                data = open(path, "rb").read(1024 * 1024)
            except OSError:
                continue
            if b"\x00" in data[:4096]:
                continue
            text = data.decode("utf-8", "replace")
            if re.search(r"(modprobe|insmod|kmod)\s+ipv6\b", text):
                explicit.append(os.path.relpath(path, root))
    report.check(not explicit, "no_explicit_ipv6_load", "%d fichier(s)" % len(explicit))
    report.check("early" in bootlog and "late-60" in bootlog and "late-90" in bootlog and
                 "/sys/class/udc" in bootlog and "/sys/class/net" in bootlog and
                 "usb_gadget/a71" in bootlog and "rc-status" in bootlog and
                 "dmesg" in bootlog and "authorized_keys" in bootlog,
                 "a71_bootlog_diagnostics")
    report.check(os.path.isdir(os.path.join(root, "root/.ssh")) and
                 stat.S_IMODE(os.lstat(os.path.join(root, "root/.ssh")).st_mode) == 0o700,
                 "root_ssh_dir_0700")
    auth = os.path.join(root, "root/.ssh/authorized_keys")
    if not os.path.exists(auth):
        report.ok("authorized_key_absent")
    else:
        try:
            ast = os.lstat(auth)
        except OSError:
            ast = None
        report.check(ast is not None and stat.S_ISREG(ast.st_mode) and not os.path.islink(auth),
                     "authorized_key_regular")
        if ast is not None:
            report.check(stat.S_IMODE(ast.st_mode) == 0o600, "authorized_key_mode_0600")
            data = open(auth, "rb").read(16384)
            report.check(b"PRIVATE KEY" not in data, "authorized_key_not_private")
            lines = [ln for ln in data.decode("utf-8", "replace").splitlines() if ln.strip()]
            report.check(len(lines) == 1, "authorized_key_one_line")
            if len(lines) == 1:
                key_type = lines[0].split()[0]
                report.check(key_type in ("ssh-ed25519", "sk-ssh-ed25519@openssh.com",
                                          "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512"),
                             "authorized_key_type")
            report.check(hashlib.sha256(data).hexdigest() !=
                         "8712c6e2a4818fed38acbb6ea2f0b47e06f1347ba3e51f7f0962be77f6b15bae",
                         "authorized_key_not_historical")
    report.check(os.path.isfile(os.path.join(root, "etc/resolv.conf")),
                 "resolv_conf_present")
    # Liens de runlevels
    for level, svc in (("default", "a71-usb"), ("default", "a71-net"),
                       ("default", "a71-ssh-keys"), ("default", "a71-bootlog"),
                       ("default", "sshd"), ("boot", "syslog")):
        link = os.path.join(root, "etc/runlevels", level, svc)
        good = os.path.islink(link) and os.readlink(link) == "/etc/init.d/" + svc
        report.check(good, "runlevel_%s_%s" % (level, svc))


def check_firstboot(root, report):
    path = os.path.join(root, "etc/local.d/firstboot.start")
    try:
        st = os.lstat(path)
    except OSError:
        report.fail("firstboot_present", "absent")
        return
    report.check(stat.S_ISREG(st.st_mode) and (stat.S_IMODE(st.st_mode) & 0o111) == 0o111,
                 "firstboot_executable")
    try:
        text = read_text(path)
    except OSError:
        text = ""
    report.check("ssh-keygen" in text and "ed25519" in text and "rsa" in text,
                 "firstboot_generates_host_keys")


def check_manifest_entries(root, entries, policy, report):
    missing = 0
    type_bad = 0
    mode_bad = 0
    id_bad = 0
    for rel, (uid, gid, mode, kind) in entries.items():
        st, _path = lstat(root, rel)
        if st is None:
            missing += 1
            continue
        if actual_kind(st) != kind:
            type_bad += 1
            continue
        if kind != "l" and stat.S_IMODE(st.st_mode) != mode:
            mode_bad += 1
        if uid != 0 or gid not in (0, 5, 10, 42):
            id_bad += 1
    report.check(missing == 0, "manifest_paths_exist", "%d absent(s)" % missing)
    report.check(type_bad == 0, "manifest_types", "%d type(s) incorrect(s)" % type_bad)
    report.check(mode_bad == 0, "manifest_modes_actual", "%d mode(s) incorrect(s)" % mode_bad)
    report.check(id_bad == 0, "manifest_logical_ids", "%d uid/gid hors politique" % id_bad)

    # La politique est la source de verite pour les chemins qu'elle cite et qui
    # existent dans l'image ; les chemins absents (paquet non installe) sont
    # ignores, mais les chemins sensibles obligatoires sont verifies plus bas.
    policy_bad = 0
    for rel, (kind, mode, uid, gid, _just) in policy.items():
        if rel not in entries:
            continue
        got = entries[rel]
        if got != (uid, gid, mode, kind):
            policy_bad += 1
    report.check(policy_bad == 0, "manifest_policy", "%d divergence(s)" % policy_bad)


def check_sensitive(root, entries, report):
    for rel, kind, mode in (
        ("/bin/busybox", "f", 0o755),
        ("/bin/bbsuid", "f", 0o4111),
        ("/etc/passwd", "f", 0o644),
        ("/etc/group", "f", 0o644),
        ("/etc/shadow", "f", 0o640),
        ("/root", "d", 0o700),
        ("/tmp", "d", 0o1777),
        ("/var/tmp", "d", 0o1777),
    ):
        got = entries.get(rel)
        report.check(got is not None, "manifest_sensitive_%s" % rel.strip("/").replace("/", "_"))
        if got is None:
            continue
        report.check(got[2] == mode and got[3] == kind, "sensitive_%s" % rel.strip("/").replace("/", "_"),
                     "%s" % mode_text(mode))

    for rel in ("/etc/gshadow",):
        st, _path = lstat(root, rel)
        if st is not None and stat.S_ISREG(st.st_mode):
            report.check(stat.S_IMODE(st.st_mode) & 0o007 == 0, "gshadow_restricted")

    busybox = entries.get("/bin/busybox")
    if busybox:
        report.check(busybox[2] & 0o111 == 0o111, "busybox_executable_all")
        machine = elf_machine(os.path.join(root, "bin/busybox"))
        report.check(machine is not None and machine[0] == 183 and machine[1] == 2,
                     "busybox_elf_aarch64")


def check_special_bits(root, policy, report):
    allowed_setid = {rel for rel, (_k, mode, _u, _g, _j) in policy.items() if mode & 0o6000}
    allowed_world = {rel for rel, (_k, mode, _u, _g, _j) in policy.items() if mode & 0o002}
    bad_setid = []
    bad_world = []
    special = []
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(base, d))]
        for name in list(dirs) + files:
            path = os.path.join(base, name)
            rel = "/" + os.path.relpath(path, root)
            try:
                st = os.lstat(path)
            except OSError:
                continue
            kind = actual_kind(st)
            if kind == "o":
                special.append(rel)
                continue
            if kind == "l":
                continue
            mode = stat.S_IMODE(st.st_mode)
            if mode & 0o6000 and rel not in allowed_setid:
                bad_setid.append(rel)
            if mode & 0o002 and rel not in allowed_world:
                bad_world.append(rel)
    report.check(not bad_setid, "no_unexpected_setid", "%d chemin(s)" % len(bad_setid))
    report.check(not bad_world, "no_unexpected_world_writable", "%d chemin(s)" % len(bad_world))
    report.check(not special, "no_special_files", "%d entree(s)" % len(special))


def check_no_boot_image(root, report):
    hits = []
    for base, _dirs, files in os.walk(root):
        for name in files:
            if re.match(r"^boot.*\.img$", name):
                hits.append(os.path.relpath(os.path.join(base, name), root))
    report.check(not hits, "no_boot_image", "%d fichier(s)" % len(hits))


def write_report(report, path, rootfs_name):
    if os.path.islink(path):
        print("validate-rootfs: rapport est un lien symbolique", file=sys.stderr)
        return EXIT_REPORT
    parent = os.path.dirname(os.path.abspath(path)) or "."
    if not os.path.isdir(parent):
        print("validate-rootfs: parent du rapport absent", file=sys.stderr)
        return EXIT_REPORT
    if os.path.isdir(path):
        print("validate-rootfs: rapport est un repertoire", file=sys.stderr)
        return EXIT_REPORT
    try:
        fd, tmp = tempfile.mkstemp(prefix=".validate-rootfs.", dir=parent)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(report.text(rootfs_name))
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError as exc:
        print("validate-rootfs: ecriture du rapport impossible (%s)" % exc, file=sys.stderr)
        return EXIT_REPORT
    return EXIT_OK


def main(argv):
    parser = argparse.ArgumentParser(prog="validate-rootfs.sh")
    parser.add_argument("--rootfs", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--ownership-manifest", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--policy", default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "configs", "rootfs-mode-policy.txt"))
    args = parser.parse_args(argv)

    if not os.path.isdir(args.rootfs) or os.path.islink(args.rootfs):
        print("validate-rootfs: rootfs invalide", file=sys.stderr)
        return EXIT_INPUT
    if not os.path.isfile(args.manifest):
        print("validate-rootfs: manifeste absent", file=sys.stderr)
        return EXIT_INPUT
    if not os.path.isfile(args.ownership_manifest):
        print("validate-rootfs: manifeste de proprietaires absent", file=sys.stderr)
        return EXIT_INPUT
    if not os.path.isfile(args.policy):
        print("validate-rootfs: politique de modes absente", file=sys.stderr)
        return EXIT_INPUT

    try:
        sections = parse_manifest(args.manifest)
        policy = parse_policy(args.policy)
    except (OSError, ValueError) as exc:
        print("validate-rootfs: entree invalide (%s)" % exc, file=sys.stderr)
        return EXIT_INPUT

    release = sections.get("kernel", {}).get("expected_release", "")
    if not release or not sections.get("distribution", {}).get("version"):
        print("validate-rootfs: manifeste incomplet", file=sys.stderr)
        return EXIT_INPUT

    root = os.path.abspath(args.rootfs)
    report = Report()
    check_basic_files(root, sections, report)
    check_init_contract(root, report)
    check_packages(root, report)
    check_modules(root, release, report)
    check_openrc(root, report)
    check_ssh_and_accounts(root, report)
    check_private_keys(root, report)
    check_firstboot(root, report)
    check_m1(root, report)
    entries = parse_ownership(args.ownership_manifest, report)
    check_manifest_entries(root, entries, policy, report)
    check_sensitive(root, entries, report)
    check_special_bits(root, policy, report)
    check_no_boot_image(root, report)

    result = write_report(report, args.report, os.path.basename(os.path.normpath(root)))
    if result != EXIT_OK:
        return result
    return EXIT_OK if not report.failures else EXIT_FAIL


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
