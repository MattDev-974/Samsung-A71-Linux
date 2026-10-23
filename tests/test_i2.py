import gzip, io, os, shutil, struct, subprocess, sys, tarfile, tempfile, unittest, zipfile
from pathlib import Path
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import installer as I

class Fixture:
    def __init__(self, root: Path):
        self.root=root
        self.rootfs=root/"rootfs"; self.rootfs.mkdir()
        (self.rootfs/"bin").mkdir(); (self.rootfs/"bin/busybox").write_bytes(b"busybox")
        (self.rootfs/"etc").mkdir(); (self.rootfs/"etc/hostname").write_text("a71\n")
        self.initrd=root/"initramfs.img"
        tree=root/"itree"; (tree/"bin").mkdir(parents=True); (tree/"bin/busybox").write_bytes(b"busybox")
        (tree/"init").write_text("#!/bin/sh\n")
        cpio=root/"initramfs.cpio"
        listing=subprocess.run(["find",".","-print0"],cwd=tree,stdout=subprocess.PIPE,check=True).stdout
        with cpio.open("wb") as out:
            subprocess.run(["cpio","--null","-o","-H","newc","--owner=0:0","--reproducible","--quiet"],cwd=tree,input=listing,stdout=out,check=True)
        with self.initrd.open("wb") as raw:
            subprocess.run(["gzip","-n","-9","-c",str(cpio)],stdout=raw,check=True)
        self.fw=root/"fw"; self.fw.mkdir()
        (self.fw/"build.prop").write_text("ro.product.model=SM-A715F\nro.build.id=A715FXXSBDXB1\n")
        elf=bytearray(52+3*32); elf[:4]=b"\x7fELF"; struct.pack_into("<H",elf,42,32); struct.pack_into("<H",elf,44,3); struct.pack_into("<I",elf,28,52)
        (self.fw/"a615_zap.mdt").write_bytes(elf)
        for n,data in [("a615_zap.b00",b"b00"),("a615_zap.b01",b"b01"),("a615_zap.b02",b"b02")]: (self.fw/n).write_bytes(data)

class TestProfiles(unittest.TestCase):
    def test_profiles_and_default(self):
        p=I.load_profiles()
        self.assertIn("server",p); self.assertTrue(p["server"]["recommended"])
        self.assertEqual(p["desktop-open"]["extends"],"server")
        self.assertEqual(p["desktop-local"]["extends"],"desktop-open")
        for d in p.values():
            self.assertFalse(set(d.get("features",[])) & {"wifi","audio","bluetooth"})
    def test_unknown_key_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            d=Path(td)/"server.yaml"; d.write_text("id: server\nrecommended: true\nredistributable: true\nfeatures: [base-rootfs]\nbogus: 1\n")
            with mock.patch.object(I,"PROFILES",Path(td)):
                with self.assertRaises(I.InstallerError): I.load_profiles()
    def test_validator_desc(self):
        p=I.load_profiles(); out=I.describe("server",p); self.assertIn("server",out)

class TestSamsung(unittest.TestCase):
    def test_synthetic_valid_test_mode(self):
        with tempfile.TemporaryDirectory() as td:
            f=Fixture(Path(td)); r=I.validate_samsung(f.fw,test_mode=True); self.assertEqual(r["model"],I.MODEL); self.assertEqual(r["phnum"],3)
    def test_model_wrong(self):
        with tempfile.TemporaryDirectory() as td:
            f=Fixture(Path(td)); (f.fw/"build.prop").write_text("ro.product.model=SM-A716B\n")
            with self.assertRaises(I.InstallerError): I.validate_samsung(f.fw,test_mode=True)
    def test_missing_segment(self):
        with tempfile.TemporaryDirectory() as td:
            f=Fixture(Path(td)); (f.fw/"a615_zap.b01").unlink()
            with self.assertRaises(I.InstallerError): I.validate_samsung(f.fw,test_mode=True)
    def test_invalid_mdt(self):
        with tempfile.TemporaryDirectory() as td:
            f=Fixture(Path(td)); (f.fw/"a615_zap.mdt").write_bytes(b"notelf")
            with self.assertRaises(I.InstallerError): I.validate_samsung(f.fw,test_mode=True)
    def test_zip_slip(self):
        with tempfile.TemporaryDirectory() as td:
            z=Path(td)/"evil.zip"
            with zipfile.ZipFile(z,"w") as zf: zf.writestr("../escape",b"x")
            with self.assertRaises(I.InstallerError): I.validate_samsung(z,test_mode=True)
    def test_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/"link.zip"; p.symlink_to(Path(td)/"none")
            with self.assertRaises(I.InstallerError): I.validate_samsung(p,test_mode=True)
    def test_zip_crc_or_valid(self):
        with tempfile.TemporaryDirectory() as td:
            f=Fixture(Path(td)); z=Path(td)/"fw.zip"
            with zipfile.ZipFile(z,"w") as zf:
                for p in f.fw.iterdir(): zf.write(p,p.name)
            r=I.validate_samsung(z,test_mode=True); self.assertEqual(r["phnum"],3)

class TestBuild(unittest.TestCase):
    def test_server_reproducible_and_no_samsung(self):
        with tempfile.TemporaryDirectory() as td:
            f=Fixture(Path(td)); p=I.load_profiles()
            a=I.build_profile("server",p,f.rootfs,f.initrd,out_root=Path(td)/"a",test_mode=True)
            b=I.build_profile("server",p,f.rootfs,f.initrd,out_root=Path(td)/"b",test_mode=True)
            self.assertEqual(I.sha256(a/"rootfs.tar.gz"),I.sha256(b/"rootfs.tar.gz"))
            self.assertEqual(I.sha256(a/"initramfs.cpio.gz"),I.sha256(b/"initramfs.cpio.gz"))
            self.assertFalse(list(a.rglob("*a615_zap*")))
    def test_desktop_open_local(self):
        with tempfile.TemporaryDirectory() as td:
            f=Fixture(Path(td)); p=I.load_profiles()
            o=I.build_profile("desktop-open",p,f.rootfs,f.initrd,f.initrd,out_root=Path(td)/"o",test_mode=True)
            self.assertTrue((o/"profile.json").exists())
            l=I.build_profile("desktop-local",p,f.rootfs,f.initrd,f.initrd,out_root=Path(td)/"priv",private=True,test_mode=True,samsung_firmware=f.fw)
            self.assertEqual((l/"initramfs.cpio.gz").exists(),True)
            self.assertTrue((l/"zap-private").is_dir())
            self.assertFalse(list((Path(td)/"o").rglob("*a615_zap*")))

class TestFlash(unittest.TestCase):
    def test_flash_validation_and_refusals(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)/"private"/"builds"; root.mkdir(parents=True)
            img=root/"boot.img"; img.write_bytes(b"x"*100)
            recovery=Path(__file__).resolve().parents[2]/"work/boot-candidates/m7b4/boot-ipv6-HISTORICAL.img"
            pit=Path(__file__).resolve().parents[2]/"work/boot-candidates/m7b4/recovery-test/a71.pit"
            self.assertTrue(I.flash_validate(img,recovery,pit,root.parent,dry_run=True))
            outside=Path(td)/"out.img"; outside.write_bytes(b"x")
            with self.assertRaises(I.InstallerError): I.flash_validate(outside,recovery,pit,root.parent,dry_run=True)
            bad=Path(td)/"bad"; bad.write_bytes(b"x")
            with self.assertRaises(I.InstallerError): I.flash_validate(img,bad,pit,root.parent,dry_run=True)

class TestPrivacy(unittest.TestCase):
    def test_no_samsung_detection(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); (root/"a615_zap.mdt").write_bytes(b"x")
            self.assertEqual(I.ensure_no_samsung(root),["a615_zap.mdt"])
    def test_clean_private_symlink_refused(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)/"private"; root.mkdir(); (root/"link").symlink_to("/")
            with mock.patch.object(I,"PRIVATE",root):
                with self.assertRaises(I.InstallerError): I.clean_private()

if __name__=="__main__":
    unittest.main(verbosity=2)
