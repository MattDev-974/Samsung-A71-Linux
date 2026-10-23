#!/bin/bash
# Reproduction hors appareil d'un boot Android v2 RESEARCH_ONLY, NOT_FLASHABLE.
set -Eeuo pipefail
usage(){ echo "usage: $0 --reference FILE --kernel FILE --ramdisk FILE --dtb FILE --output FILE --expected SHA256 [--allow-kernel-size-change]"; }
REF= KERNEL= RAMDISK= DTB= OUT= EXPECTED= ALLOW_KERNEL_SIZE=0
while [ $# -gt 0 ]; do
 case "$1" in
  --reference) REF=$2; shift;; --kernel) KERNEL=$2; shift;;
  --ramdisk) RAMDISK=$2; shift;; --dtb) DTB=$2; shift;;
  --output) OUT=$2; shift;; --expected) EXPECTED=$2; shift;;
  --allow-kernel-size-change) ALLOW_KERNEL_SIZE=1;;
  -h|--help) usage; exit 0;; *) usage; exit 2;;
 esac; shift
done
[ -n "$REF" ] && [ -n "$KERNEL" ] && [ -n "$RAMDISK" ] && [ -n "$DTB" ] && [ -n "$OUT" ] && [ -n "$EXPECTED" ] || { usage; exit 2; }
for f in "$REF" "$KERNEL" "$RAMDISK" "$DTB"; do
 [ -f "$f" ] || { echo "entrée absente: $f" >&2; exit 3; }
 [ -L "$f" ] && { echo "symlink refusé: $f" >&2; exit 3; }
done
python3 - "$REF" "$KERNEL" "$RAMDISK" "$DTB" "$OUT" "$EXPECTED" "$ALLOW_KERNEL_SIZE" <<'PY'
import hashlib,os,struct,sys
ref,kernel,ramdisk,dtb,out,expected,allow_kernel_size=sys.argv[1:8]
allow_kernel_size=int(allow_kernel_size)
def h(p):
    return hashlib.sha256(open(p,'rb').read()).hexdigest()
r=open(ref,'rb').read()
if len(r)<4096 or r[:8]!=b'ANDROID!': raise SystemExit('référence non Android boot')
ks,ka,rs,ra,ss,sa,ta,page,hv,osv=struct.unpack_from('<10I',r,8)
if hv!=2: raise SystemExit('header_version != 2')
if page!=4096: raise SystemExit('page_size != 4096')
name=r[48:64]; cmd=r[64:576]; ident=r[576:608]; extra=r[608:1632]
dtb_size=struct.unpack_from('<I',r,1648)[0]; dtb_addr=struct.unpack_from('<Q',r,1652)[0]
K=open(kernel,'rb').read(); R=open(ramdisk,'rb').read(); D=open(dtb,'rb').read()
if len(K)!=ks:
    if not allow_kernel_size: raise SystemExit('kernel size mismatch')
    ks=len(K)
if len(R)!=rs: raise SystemExit('ramdisk size mismatch')
if len(D)!=dtb_size: raise SystemExit('dtb size mismatch')
hdr=struct.pack('<8s10I',b'ANDROID!',ks,ka,rs,ra,ss,sa,ta,page,hv,osv)+name+cmd+ident+extra
hdr+=struct.pack('<I',0)+struct.pack('<Q',0)+struct.pack('<I',1660)+struct.pack('<I',dtb_size)+struct.pack('<Q',dtb_addr)
assert len(hdr)==1660, len(hdr)
body=hdr+b'\0'*(page-len(hdr))
for blob in (K,R,D):
    body+=blob
    body+=b'\0'*((-len(blob))%page)
# taille de référence, sans jamais écrire d'autre octet non nul
body+=b'\0'*(len(r)-len(body))
if len(body)!=len(r): raise SystemExit('taille finale incohérente')
open(out,'wb').write(body)
print('sha256',h(out)); print('size',len(body))
PY
[ "$(sha256sum "$OUT" | awk '{print $1}')" = "$EXPECTED" ] || { echo "SHA inattendu" >&2; exit 4; }
chmod 0644 "$OUT"
echo 'RESEARCH_ONLY NOT_FLASHABLE UNTESTED'
