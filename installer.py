#!/usr/bin/env python3
"""I2 installer core. Builds locally; never flashes unless explicitly invoked."""
from __future__ import annotations
import argparse, gzip, hashlib, json, os, re, shutil, stat, subprocess, sys, tarfile, tempfile, time, zipfile
from pathlib import Path
try:
    import yaml
except Exception:
    yaml = None

ROOT = Path(__file__).resolve().parent
PROFILES = ROOT / "profiles"
PUBLIC_BUILDS = ROOT.parent / "work" / "builds"
PRIVATE = ROOT.parent / "work" / "private"
EXPECTED_SHA = "04dfd20221f4d27cba545c1034720b672d5afd7c8069126bd200cb53ca63526e"
PIT_SHA = "0aec58fc7b6caf742ed952852e1d0c00bc2e751a18aa89a8eaafb6b42dc5e151"
ZAP = {
    "a615_zap.mdt": "9cf306fdd9d2f70b6f3d68e3778ff67a8e6c7129a3cf36578deed210dd2c6754",
    "a615_zap.b00": "c9e39868fb6edcc30fc3574657f10dd1dfe22c9cd79e53de213a69703582091f",
    "a615_zap.b01": "b4084233c8191e29b619a6a5eb234d9f098938d25869c6769add27eaef3d2309",
    "a615_zap.b02": "961a83d8819e0b88ec3de6b42f01383798d2c1da373d1b0efa0a89e3b9aceed8",
}
MODEL = "SM-A715F"
BUILD = "A715FXXSBDXB1"
CSC = "A715FOXMBDXB1"
MAX_ARCHIVE = 8 * 1024**3
MAX_FILES = 100000

class InstallerError(Exception):
    pass

def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda: f.read(1024 * 1024), b""):
            h.update(b)
    return h.hexdigest()

def mode_private(path: Path, directory=False):
    path.chmod(0o700 if directory else 0o600)

def validate_profile_data(data, name="<profile>"):
    allowed={"id","recommended","redistributable","extends","description","features","excludes","limitations","requires","output"}
    if not isinstance(data,dict): raise InstallerError(f"{name}: racine YAML invalide")
    unknown=set(data)-allowed
    if unknown: raise InstallerError(f"{name}: clés inconnues {sorted(unknown)}")
    if data.get("id") != name: raise InstallerError(f"{name}: id différent du nom")
    if not isinstance(data.get("features",[]),list): raise InstallerError(f"{name}: features doit être une liste")
    out=data.get("output",{})
    if not isinstance(out,dict) or set(out)-{"policy"}: raise InstallerError(f"{name}: output invalide")
    return True

def load_profiles():
    if yaml is None:
        raise InstallerError("PyYAML absent (python3-yaml requis)")
    allowed = {"id","recommended","redistributable","extends","description","features","excludes","limitations","requires","output"}
    profiles = {}
    for p in sorted(PROFILES.glob("*.yaml")):
        data = yaml.safe_load(p.read_text())
        validate_profile_data(data, p.stem)
        profiles[data["id"]] = data
    # dependency checks
    for pid, d in profiles.items():
        ext = d.get("extends")
        if ext and ext not in profiles: raise InstallerError(f"{pid}: extends inconnu {ext}")
        seen=set()
        while ext:
            if ext in seen: raise InstallerError(f"{pid}: cycle extends")
            seen.add(ext); ext=profiles[ext].get("extends")
    if "server" not in profiles: raise InstallerError("profil server absent")
    return profiles

def profile_chain(pid, profiles):
    out=[]; cur=pid
    while cur:
        out.append(profiles[cur]); cur=profiles[cur].get("extends")
    return list(reversed(out))

def describe(pid, profiles):
    d=profiles[pid]
    return json.dumps(d, indent=2, sort_keys=True)

def deterministic_tar(src: Path, dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)
    items=[]
    for p in sorted(src.rglob("*")):
        rel=p.relative_to(src)
        if rel.parts and rel.parts[0] in {"proc","sys","dev","run"}:
            continue
        items.append(p)
    with dst.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as t:
                for p in items:
                    rel=p.relative_to(src).as_posix()
                    ti=t.gettarinfo(str(p), arcname=rel)
                    ti.uid=ti.gid=0; ti.uname=ti.gname="root"; ti.mtime=0
                    if ti.isreg():
                        with p.open("rb") as f: t.addfile(ti, f)
                    else:
                        t.addfile(ti)
    dst.chmod(0o644)

def ensure_no_samsung(root: Path):
    bad=[]
    for p in root.rglob("*"):
        n=p.name.lower()
        if n.startswith("a615_zap"):
            bad.append(str(p.relative_to(root)))
    return bad

def repack_initramfs(src: Path, dst: Path, zap_dir: Path=None):
    with tempfile.TemporaryDirectory() as td:
        td=Path(td)
        with gzip.open(src,"rb") as g:
            data=g.read()
        subprocess.run(["cpio","-idm","--quiet"],cwd=td,input=data,check=True)
        if zap_dir:
            target=td/"lib/firmware/qcom/sm7150/samsung/a715f"
            target.mkdir(parents=True,exist_ok=True)
            for name in ["a615_zap.mbn","a615_zap.b00","a615_zap.b01","a615_zap.b02"]:
                shutil.copy2(zap_dir/name, target/name)
                target.joinpath(name).chmod(0o644)
        for p in td.rglob("*"):
            try: os.utime(p,(0,0),follow_symlinks=False)
            except Exception: pass
        listing=subprocess.run("find . -print0 | sort -z",shell=True,cwd=td,stdout=subprocess.PIPE,check=True).stdout
        cpio_data=subprocess.run(["cpio","--null","-o","-H","newc","--owner=0:0","--reproducible","--renumber-inodes","--quiet"],cwd=td,input=listing,stdout=subprocess.PIPE,check=True).stdout
        dst.write_bytes(gzip.compress(cpio_data,compresslevel=9,mtime=0))
    dst.chmod(0o644)

def extract_zap(fw: Path, dest: Path):
    dest.mkdir(parents=True,exist_ok=True,mode=0o700)
    with tempfile.TemporaryDirectory() as td:
        tmp=Path(td)
        if fw.is_dir(): src=fw
        else:
            with zipfile.ZipFile(fw) as z: safe_extract_zip(z,tmp/"fw")
            src=tmp/"fw"
        files=collect_firmware_files(src, tmp)
        for n in ["a615_zap.mdt","a615_zap.b00","a615_zap.b01","a615_zap.b02"]:
            if n not in files: raise InstallerError(f"ZAP absent: {n}")
        shutil.copy2(files["a615_zap.mdt"],dest/"a615_zap.mbn")
        for n in ["a615_zap.b00","a615_zap.b01","a615_zap.b02"]:
            shutil.copy2(files[n],dest/n)
        for p in dest.iterdir(): p.chmod(0o600)
    return dest

def build_profile(pid, profiles, base_rootfs: Path, server_initramfs: Path, open_initramfs: Path=None,
                  out_root: Path=None, private=False, test_mode=False, package_cache: Path=None,
                  samsung_firmware: Path=None):
    chain=profile_chain(pid, profiles)
    features=set()
    for d in chain: features.update(d.get("features", []))
    if "samsung-firmware-import" in features and not private:
        raise InstallerError("desktop-local doit être privé")
    if "samsung-firmware-import" in features and not samsung_firmware and not test_mode:
        raise InstallerError("--samsung-firmware requis pour desktop-local")
    if pid == "desktop-open" and not test_mode and not package_cache:
        raise InstallerError("--package-cache requis pour desktop-open")
    out_root = out_root or (PRIVATE/"builds" if private else PUBLIC_BUILDS)
    bid=f"{pid}-{int(time.time())}" if not test_mode else f"{pid}-test"
    out=out_root/bid
    if out.exists(): shutil.rmtree(out)
    out.mkdir(parents=True, mode=0o700 if private else 0o755)
    root=out/"rootfs"
    shutil.copytree(base_rootfs, root, symlinks=True)
    if "gpu-sqe" in features:
        fwdir=root/"lib/firmware/qcom"; fwdir.mkdir(parents=True,exist_ok=True)
        for src in [Path("work/device-runtime/m7b8/firmware/a630_sqe.fw"),Path("work/device-runtime/m7b8/firmware/a630_gmu.bin")]:
            if src.is_file():
                shutil.copy2(src,fwdir/src.name); fwdir.joinpath(src.name).chmod(0o644)
    # never ship host keys or user keys
    for rel in ["root/.ssh", "etc/ssh/ssh_host_ed25519_key", "etc/ssh/ssh_host_ed25519_key.pub",
                "etc/ssh/ssh_host_rsa_key", "etc/ssh/ssh_host_rsa_key.pub"]:
        q=root/rel
        if q.is_symlink() or q.exists():
            if q.is_dir(): shutil.rmtree(q)
            else: q.unlink()
    # rootfs exclusions
    if "mesa-freedreno" in features or "libdrm" in features:
        # Add only package manifest here; full package overlay requires a cache.
        if package_cache and package_cache.is_dir():
            for apk in sorted(package_cache.glob("*.apk")):
                with tempfile.TemporaryDirectory() as td:
                    subprocess.run(["tar","-xzf",str(apk),"-C",td],check=True)
                    for p in Path(td).rglob("*"):
                        if p.is_file() or p.is_symlink():
                            rel=p.relative_to(td); dest=root/rel
                            dest.parent.mkdir(parents=True,exist_ok=True)
                            if dest.exists() or dest.is_symlink(): dest.unlink()
                            shutil.copy2(p,dest,follow_symlinks=False)
        elif not test_mode:
            (out/"PACKAGE-OVERLAY-REQUIRED.txt").write_text("Mesa package cache absent; use --package-cache\n")
    # remove APK metadata and build tools from final rootfs
    for meta in root.glob(".PKGINFO*"):
        meta.unlink(missing_ok=True)
    for meta in root.glob(".SIGN.*"):
        meta.unlink(missing_ok=True)
    for junk in ["/usr/bin/gcc","/usr/bin/g++","/usr/bin/make","/usr/bin/ld","/usr/bin/as"]:
        p=root/junk.lstrip("/")
        if p.exists(): p.unlink()
    if not private:
        for bad in ensure_no_samsung(root):
            p=root/bad
            if p.exists(): p.unlink()
    # initramfs
    src_init = open_initramfs if "mesa-freedreno" in features and open_initramfs else server_initramfs
    if not src_init or not src_init.is_file():
        raise InstallerError(f"initramfs source absent: {src_init}")
    if pid == "desktop-local" and samsung_firmware:
        if not test_mode:
            validate_samsung(samsung_firmware)
        zapdir=extract_zap(samsung_firmware, out/"zap-private")
        repack_initramfs(src_init, out/"initramfs.cpio.gz", zapdir)
    else:
        shutil.copy2(src_init, out/"initramfs.cpio.gz")
    # profile manifest
    ex={x for d in chain for x in d.get("excludes",[])}
    if "mesa-freedreno" in features: ex.discard("mesa")
    comps={"features":sorted(features),"excludes":sorted(ex)}
    (out/"profile.json").write_text(json.dumps({"id":pid,"components":comps,"redistributable":not private},indent=2)+"\n")
    deterministic_tar(root,out/"rootfs.tar.gz")
    try:
        build_boot(out,out/"initramfs.cpio.gz",Path("work/kbuild/arch/arm64/boot/Image"),Path("work/uniLoader/blob/dtb"),Path("work/lin.dtb"))
    except Exception as e:
        (out/"BOOT-NOT-BUILT.txt").write_text(str(e)+"\n")
    sums={p.name:sha256(p) for p in sorted(out.iterdir()) if p.is_file() and p.name!="SHA256SUMS"}
    (out/"SHA256SUMS").write_text("".join(f"{h}  {n}\n" for n,h in sums.items()))
    if private: out.chmod(0o700); [mode_private(p) for p in out.iterdir() if p.is_file()]
    return out

def safe_extract_zip(z: zipfile.ZipFile, dest: Path):
    for info in z.infolist():
        name=info.filename
        if name.startswith("/") or ".." in Path(name).parts:
            raise InstallerError(f"zip-slip: {name}")
        if stat.S_IFMT(info.external_attr >> 16) == stat.S_IFLNK:
            raise InstallerError(f"symlink ZIP interdit: {name}")
        if info.file_size > MAX_ARCHIVE: raise InstallerError("fichier ZIP trop gros")
    z.extractall(dest)

def collect_firmware_files(src: Path, tmp: Path):
    files={p.name:p for p in src.rglob("*") if p.is_file()}
    for tar in sorted(src.rglob("*.tar.md5")):
        data=tar.read_bytes()
        # Samsung tar.md5: NUL padding then "<md5>  <name>\n"
        stripped=data.rstrip(b"\x00").rstrip()
        if b"\n" in stripped:
            footer=stripped.rsplit(b"\n",1)[-1]
            toks=footer.split()
            if len(toks)>=2 and len(toks[0])==32:
                # Best-effort: recompute MD5 up to the footer's filename line.
                import hashlib
                cut=len(data)-len(footer)-1
                if cut>0 and hashlib.md5(data[:cut]).hexdigest()!=toks[0].decode(errors="ignore"):
                    raise InstallerError(f"footer MD5 invalide: {tar.name}")
        try:
            with tarfile.open(tar,"r:") as t:
                for m in t.getmembers():
                    n=Path(m.name).name
                    if n in ZAP or n in {"build.prop","vendor-build.prop"}:
                        if m.issym() or m.islnk(): raise InstallerError("lien interdit dans tar.md5")
                        if m.size>MAX_ARCHIVE: raise InstallerError("fichier tar.md5 trop gros")
                        dest=tmp/"nested"/n
                        dest.parent.mkdir(parents=True,exist_ok=True)
                        f=t.extractfile(m)
                        if f is None: raise InstallerError("membre tar invalide")
                        dest.write_bytes(f.read()); files[n]=dest
        except InstallerError: raise
        except Exception as e: raise InstallerError(f"tar.md5 invalide: {tar.name}: {e}")
    return files

def validate_mdt(data: bytes):
    if len(data)<52 or data[:4]!=b"\x7fELF": raise InstallerError("MDT ELF invalide")
    import struct
    phoff=struct.unpack_from("<I",data,28)[0]; phentsize=struct.unpack_from("<H",data,42)[0]; phnum=struct.unpack_from("<H",data,44)[0]
    if phentsize != 32 or phnum < 3 or phoff+phnum*32 > len(data):
        raise InstallerError("MDT phdrs invalides")
    return phnum

def validate_samsung(path: Path, allow_unvalidated=False, test_mode=False):
    if path.is_symlink(): raise InstallerError("archive est un symlink")
    if not path.exists(): raise InstallerError("archive absente")
    if path.is_file() and path.stat().st_size > MAX_ARCHIVE: raise InstallerError("archive trop grande")
    with tempfile.TemporaryDirectory() as td:
        tmp=Path(td)
        if path.is_dir():
            shutil.copytree(path, tmp/"fw", symlinks=True)
            src=tmp/"fw"
        elif path.suffix.lower() in {".zip",".apk"}:
            with zipfile.ZipFile(path) as z:
                if z.testzip(): raise InstallerError("CRC ZIP invalide")
                if len(z.infolist())>MAX_FILES: raise InstallerError("trop de fichiers ZIP")
                safe_extract_zip(z,tmp/"fw")
            src=tmp/"fw"
        else:
            raise InstallerError("format accepté: ZIP ou répertoire extrait")
        files=collect_firmware_files(src, tmp)
        # model/build from filenames/build.prop
        blob=(b" ".join(p.name.encode() for p in files.values()))
        for p in files.values():
            if p.name in {"build.prop","vendor-build.prop","firmware.info"}:
                blob += b" " + p.read_bytes()[:200000]
        text=blob.decode("utf-8","ignore")
        if MODEL not in text: raise InstallerError("modèle SM-A715F absent")
        if BUILD not in text and not allow_unvalidated:
            raise InstallerError(f"build {BUILD} non trouvée")
        missing=[n for n in ZAP if n not in files]
        if missing: raise InstallerError(f"fichiers ZAP absents: {missing}")
        for n,h in ZAP.items():
            got=sha256(files[n])
            if not test_mode and got != h:
                raise InstallerError(f"hash {n} non validé")
        mdt=files["a615_zap.mdt"].read_bytes()
        phnum=validate_mdt(mdt)
        if phnum < 3: raise InstallerError("segments MDT insuffisants")
        return {"model":MODEL,"build":BUILD,"csc":CSC,"files":sorted(files),"phnum":phnum,"validated":not test_mode}

def build_boot(out: Path, initramfs: Path, image: Path, mainline_dtb: Path, android_dtb: Path):
    if not (image.is_file() and mainline_dtb.is_file() and android_dtb.is_file()):
        raise InstallerError("composants boot absents")
    # assemble uniLoader-free direct boot: Image + empty initramfs + Android DTB
    cmd=[sys.executable,str(ROOT/"scripts"/"mkbootimg.py"),"--kernel",str(image),"--ramdisk",str(initramfs),"--dtb",str(android_dtb),"--cmdline","console=tty0","--name","a71","--output",str(out/"boot.img")]
    subprocess.run(cmd,check=True)
    with (out/"boot.img").open("r+b") as f: f.truncate(67108864)
    (out/"boot.meta.json").write_text(json.dumps({"cmdline":"console=tty0","size":67108864,"zap":False,"initramfs":sha256(initramfs)},indent=2)+"\n")

def flash_validate(image: Path, recovery: Path, pit: Path, private_root: Path, dry_run=True):
    if image.is_symlink() or not image.is_file(): raise InstallerError("image absente")
    if private_root not in image.resolve().parents: raise InstallerError("image hors work/private/builds")
    if image.stat().st_size > 67108864: raise InstallerError("image trop grande")
    if not recovery.is_file() or sha256(recovery)!=EXPECTED_SHA: raise InstallerError("recovery hash invalide")
    if not pit.is_file() or sha256(pit)!=PIT_SHA: raise InstallerError("PIT hash invalide")
    if not dry_run:
        h=shutil.which("heimdall")
        if not h: raise InstallerError("Heimdall absent")
        r=subprocess.run([h,"detect"],capture_output=True,text=True)
        if r.returncode!=0 or "Device detected" not in r.stdout+r.stderr:
            raise InstallerError("Download mode non détecté")
    return True

def clean_private(keep_reports=False):
    if not PRIVATE.exists(): return
    for p in PRIVATE.iterdir():
        if p.is_symlink(): raise InstallerError("symlink privé refusé")
        if keep_reports and p.name=="reports": continue
        shutil.rmtree(p) if p.is_dir() else p.unlink()



LEGACY_NEW = ("--profile", "--list-profiles", "--describe-profile", "--verify-samsung-firmware",
              "--clean-private-work", "--print-flash-command", "--flash-local-boot",
              "--samsung-firmware", "--allow-unvalidated-samsung-build", "--package-cache",
              "--base-rootfs", "--server-initramfs", "--open-initramfs", "--out-root")

def _is_new_cli(argv):
    return any(a in LEGACY_NEW or a.startswith("--profile=") for a in argv)

def _clean_env():
    e=os.environ.copy()
    for k in ("A71_LOG_FILE","A71_LOG_DIR","A71_WORK_DIR"):
        e.pop(k,None)
    return e

def _legacy_manifest(manifest, key):
    r=subprocess.run(["bash","-c",'. scripts/common.sh; manifest_get "$1" "$2"', "_", str(manifest), key], cwd=ROOT, capture_output=True, text=True, env=_clean_env())
    return r.returncode, r.stdout.strip(), r.stderr.strip()

def _legacy_validate(manifest):
    r=subprocess.run(["bash","-c",'. scripts/common.sh; manifest_validate "$1"', "_", str(manifest)], cwd=ROOT, capture_output=True, text=True, env=_clean_env())
    return r.returncode

def _legacy_log(action, log_dir, log_file, no_write, ok=True):
    if no_write:
        return 0
    log_dir=Path(log_dir); log_file=Path(log_file) if log_file else log_dir/f"a71-{action}-{os.getpid()}.log"
    if log_dir.is_symlink():
        print("lien symbolique refuse", file=sys.stderr); return 1
    if log_dir.exists() and (log_dir.stat().st_mode & 0o777) != 0o700:
        print("mode 700 requis pour LOG_DIR", file=sys.stderr); return 1
    if log_file.is_symlink():
        print("journal refuse: lien symbolique", file=sys.stderr); return 2
    try:
        rel=log_file.relative_to(log_dir)
    except Exception:
        print("journal refuse: hors LOG_DIR", file=sys.stderr); return 2
    if len(rel.parts)!=1:
        print("journal refuse: sous-repertoire", file=sys.stderr); return 2
    if log_file.exists() and (log_file.stat().st_mode & 0o777) != 0o600:
        print("journal refuse: mode 600 requis", file=sys.stderr); return 2
    log_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    log_dir.chmod(0o700)
    if not log_file.exists():
        log_file.touch(mode=0o600)
    log_file.chmod(0o600)
    with log_file.open("a") as f:
        f.write(f"# action   : {action}\n")
        f.write("Prediagnostic : installation A71\n")
        f.write(f"Resultat : {'ok' if ok else 'echec'}\n")
    return 0

def _legacy_plan(manifest):
    req=["kernel.commit","distribution.series","distribution.version","toolchain.version","uniloader.commit"]
    vals={}
    for k in req:
        rc,v,err=_legacy_manifest(manifest,k)
        if rc!=0 or not v:
            print(f"cle absente ({k})", file=sys.stderr); return 1
        vals[k]=v
    print("Etapes qui seraient planifiees")
    print(f"kernel        : {vals['kernel.commit']}")
    print(f"uniloader     : {vals['uniloader.commit'][:7]}")
    print(f"Alpine v{vals['distribution.series'].lstrip('v')} {vals['distribution.version']}")
    print(f"toolchain     : {vals['toolchain.version']}")
    print(f"kernel.commit : {vals['kernel.commit']}")
    return 0

def legacy_main(argv):
    # tiny strict parser for the historical contract
    if not argv:
        return None
    if _is_new_cli(argv):
        return None
    opts={"help":0,"version":0,"check":0,"dry":0,"no_write":0,"jobs":[]}
    i=0
    actions=[]
    while i<len(argv):
        a=argv[i]
        if a in ("--help","--version","--check","--dry-run","--no-write"):
            key={"--help":"help","--version":"version","--check":"check","--dry-run":"dry","--no-write":"no_write"}[a]
            if opts[key]: return 2
            opts[key]+=1; actions.append(key); i+=1; continue
        if a.startswith("--jobs="):
            opts["jobs"].append(a.split("=",1)[1]); i+=1; continue
        if a=="--jobs":
            if i+1>=len(argv): return 2
            opts["jobs"].append(argv[i+1]); i+=2; continue
        return 2
    for j in opts["jobs"]:
        if not re.fullmatch(r"[0-9]+",j) or int(j)<1 or int(j)>128:
            return 2
    if len(opts["jobs"])>1: return 2
    if opts["help"] and (opts["check"] or opts["dry"] or opts["version"]): return 2
    if opts["version"] and (opts["check"] or opts["dry"]): return 2
    if opts["check"] and opts["dry"]: return 2
    if opts["help"]:
        print("Usage: install.sh [--profile PROFILE] [--help] [--version] [--check] [--dry-run]")
        return 0
    manifest=Path(os.environ.get("A71_MANIFEST", str(ROOT/"manifest.yaml")))
    if opts["version"]:
        if not manifest.is_file() or manifest.stat().st_size==0 or _legacy_validate(manifest)!=0:
            return 1
        rc,v,_=_legacy_manifest(manifest,"project.version")
        if rc!=0 or not v or v=="TODO_VERIFIER":
            print("version non resolue", file=sys.stderr); return 1
        print(v); return 0
    if opts["check"] or opts["dry"]:
        if not manifest.is_file() or manifest.stat().st_size==0 or _legacy_validate(manifest)!=0:
            return 1
        logdir=os.environ.get("A71_LOG_DIR", str(ROOT/"work/logs"))
        workdir=os.environ.get("A71_WORK_DIR", str(ROOT/"work"))
        if Path(workdir).is_symlink():
            print("lien symbolique refuse", file=sys.stderr); return 1
        if opts["dry"]:
            rc=_legacy_plan(manifest)
            if rc: return rc
        else:
            # required manifest identity for check
            for k in ["kernel.commit","distribution.version","toolchain.version","uniloader.commit"]:
                r,v,_=_legacy_manifest(manifest,k)
                if r!=0 or not v:
                    print(f"cle absente ({k})",file=sys.stderr); return 1
        if opts["check"] and not shutil.which("awk"):
            print("outil requis absent: awk", file=sys.stderr); return 1
        nw=bool(opts["no_write"]) or os.environ.get("A71_NO_WRITE")=="1"
        rc=_legacy_log("dry-run" if opts["dry"] else "check", logdir, os.environ.get("A71_LOG_FILE"), nw, ok=True)
        if rc: return rc
        return 0
    return 2

def main(argv=None):
    ap=argparse.ArgumentParser(prog="install.sh", description="A71 modular installer")
    ap.add_argument("--profile", choices=["server","desktop-open","desktop-local"])
    ap.add_argument("--list-profiles", action="store_true")
    ap.add_argument("--describe-profile")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--version", action="store_true")
    ap.add_argument("--jobs")
    ap.add_argument("--no-write", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--print-plan", action="store_true")
    ap.add_argument("--samsung-firmware")
    ap.add_argument("--recovery-boot")
    ap.add_argument("--allow-unvalidated-samsung-build", action="store_true")
    ap.add_argument("--verify-samsung-firmware")
    ap.add_argument("--clean-private-work", action="store_true")
    ap.add_argument("--keep-reports", action="store_true")
    ap.add_argument("--print-flash-command")
    ap.add_argument("--flash-local-boot")
    ap.add_argument("--base-rootfs", help=argparse.SUPPRESS)
    ap.add_argument("--server-initramfs", help=argparse.SUPPRESS)
    ap.add_argument("--open-initramfs", help=argparse.SUPPRESS)
    ap.add_argument("--out-root", help=argparse.SUPPRESS)
    ap.add_argument("--package-cache", help=argparse.SUPPRESS)
    ap.add_argument("--comment", help=argparse.SUPPRESS)
    raw=sys.argv[1:] if argv is None else list(argv)
    lrc=legacy_main(raw)
    if lrc is not None:
        return lrc
    args=ap.parse_args(argv)
    p=load_profiles()
    if args.list_profiles:
        for pid,d in p.items(): print(f"{pid}\t{'recommended' if d.get('recommended') else ''}\t{'redistributable' if d.get('redistributable') else 'local-only'}")
        return 0
    if args.describe_profile:
        if args.describe_profile not in p: raise InstallerError("profil inconnu")
        print(describe(args.describe_profile,p)); return 0
    if args.verify_samsung_firmware:
        print(json.dumps(validate_samsung(Path(args.verify_samsung_firmware), args.allow_unvalidated_samsung_build),indent=2)); return 0
    if args.clean_private_work:
        clean_private(args.keep_reports); print("private cleaned"); return 0
    if args.print_flash_command:
        print(f"sudo heimdall flash --BOOT {args.print_flash_command}"); return 0
    if args.flash_local_boot:
        if not args.recovery_boot: raise InstallerError("--recovery-boot requis")
        flash_validate(Path(args.flash_local_boot),Path(args.recovery_boot),Path("work/boot-candidates/m7b4/recovery-test/a71.pit"),PRIVATE/"builds",dry_run=args.dry_run)
        print("FLASH VALIDATED (not executed if dry-run)"); return 0
    if not args.profile and sys.stdin.isatty():
        print("1. server — recommandé\n2. desktop-open\n3. desktop-local\n4. quitter")
        c=input("Choix [1]: ").strip() or "1"
        if c=="4": return 0
        pid={ "1":"server","2":"desktop-open","3":"desktop-local"}.get(c)
        if not pid: raise InstallerError("choix invalide")
    else:
        pid=args.profile or "server"
    if pid=="desktop-local" and not args.samsung_firmware and not args.dry_run and not args.print_plan:
        raise InstallerError("--samsung-firmware requis pour desktop-local")
    if args.check:
        print("check: profiles OK"); return 0
    if args.print_plan or args.dry_run or args.no_write:
        print(json.dumps({"profile":pid,"profiles":list(p),"build":not args.dry_run,"flash":False,"no_write":bool(args.no_write)},indent=2)); return 0
    if args.samsung_firmware:
        info=validate_samsung(Path(args.samsung_firmware), args.allow_unvalidated_samsung_build)
        print(json.dumps(info,indent=2))
    W=ROOT.parent/"work"
    base=Path(args.base_rootfs) if args.base_rootfs else (W/"i2-base" if (W/"i2-base").is_dir() else Path("work/rootfs/rootfs-functional-usb-c"))
    srv=Path(args.server_initramfs) if args.server_initramfs else (W/"boot-candidates/m7b6/initramfs-a.img" if (W/"boot-candidates/m7b6/initramfs-a.img").is_file() else Path("work/boot-candidates/m7b6/initramfs-a.img"))
    op=Path(args.open_initramfs) if args.open_initramfs else (W/"boot-candidates/m7b8/initramfs-a.img" if (W/"boot-candidates/m7b8/initramfs-a.img").is_file() else Path("work/boot-candidates/m7b8/initramfs-a.img"))
    cache=Path(args.package_cache) if args.package_cache else (W/"private/pkg-cache" if (W/"private/pkg-cache").is_dir() else None)
    out=build_profile(pid,p,base,srv,op,out_root=Path(args.out_root) if args.out_root else None,private=(pid=="desktop-local"),package_cache=cache,samsung_firmware=Path(args.samsung_firmware) if args.samsung_firmware else None)
    print(out)
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except InstallerError as e:
        print(f"install.sh: {e}",file=sys.stderr); sys.exit(2)
