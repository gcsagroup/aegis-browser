#!/usr/bin/env bash
# Only the supervisor executes this inside the UUID-scoped guest after admission.
set -euo pipefail
umask 077
export LC_ALL=C
run_id=${1-}
action=${2-}
[[ $run_id =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] || exit 64
[[ $(id -u) == 0 ]] || exit 65
guest_root=/var/lib/b1-owner/$run_id
case $action in preflight|prepare|quota-test|secrets|inspect|sentinel|verify-sentinel) ;; *) exit 64 ;; esac
for tool in python3 losetup mkfs.ext4 dumpe2fs findmnt blockdev setpriv fallocate sync stat mount; do
  command -v "$tool" >/dev/null || exit 69
done
# No symlink parent, no source/credential host mount, no default guest directory.
for parent in /var/lib /var/lib/b1-owner "$guest_root"; do
  [[ ! -L $parent ]] || exit 65
done
if [[ $action == preflight ]]; then
  python3 - <<'PY'
import json,os,subprocess
m={k:int(v.strip().split()[0])*1024 for k,v in (s.split(':',1) for s in open('/proc/meminfo') if ':' in s)}
mounts=json.loads(subprocess.check_output(['findmnt','--json','--output','TARGET,SOURCE,FSTYPE'],text=True))
def flat(xs):
 for x in xs:
  yield x
  yield from flat(x.get('children',[]))
host=[x for x in flat(mounts['filesystems']) if x['fstype'] in ('virtiofs','9p')]
rv=os.statvfs('/');dv=os.statvfs('/var/lib/docker');
print(json.dumps({'rootFilesystemBytes':rv.f_blocks*rv.f_frsize,'dockerFilesystemBytes':dv.f_blocks*dv.f_frsize,'rootDevice':os.stat('/').st_dev,'dockerDevice':os.stat('/var/lib/docker').st_dev,'cpu':os.cpu_count(),'memoryBytes':m['MemTotal'],'swapBytes':m['SwapTotal'],'hostMounts':host,'toolsVerified':True}))
PY
  exit 0
fi
if [[ $action == prepare ]]; then
  mkdir -p /var/lib/b1-owner
  chmod 700 /var/lib/b1-owner
  if [[ ! -e $guest_root ]]; then
    mkdir -m 700 "$guest_root"
    printf '%s\n' "$run_id" > "$guest_root/owner"
    mkdir -m 700 "$guest_root/data" "$guest_root/secrets"
    fallocate -l 2147483648 "$guest_root/data.ext4"
    loop_device=$(losetup --find --show "$guest_root/data.ext4")
    printf '%s\n' "$loop_device" > "$guest_root/loop"
    mkfs.ext4 -q -b 4096 -m 0 "$loop_device" 524288
  else
    [[ -f $guest_root/owner && $(cat "$guest_root/owner") == "$run_id" ]] || exit 65
    [[ -f $guest_root/data.ext4 && ! -L $guest_root/data.ext4 ]] || exit 65
    loop_device=$(losetup --noheadings --output NAME --associated "$guest_root/data.ext4")
    if [[ -z $loop_device ]]; then
      loop_device=$(losetup --find --show "$guest_root/data.ext4")
      printf '%s\n' "$loop_device" > "$guest_root/loop"
    fi
  fi
  [[ $loop_device =~ ^/dev/loop[0-9]+$ ]] || exit 65
  [[ $(blockdev --getsize64 "$loop_device") == 2147483648 ]] || exit 65
  if ! findmnt --mountpoint "$guest_root/data" >/dev/null; then
    mount -t ext4 -o rw,nodev,nosuid,noexec,data=ordered "$loop_device" "$guest_root/data"
  fi
  printf '{"prepared":true}\n'
  exit 0
fi
[[ -f $guest_root/owner && $(cat "$guest_root/owner") == "$run_id" ]] || exit 65
[[ -d $guest_root/data && ! -L $guest_root/data && -f $guest_root/loop ]] || exit 65
loop_device=$(cat "$guest_root/loop")
[[ $loop_device =~ ^/dev/loop[0-9]+$ ]] || exit 65
[[ $(findmnt --noheadings --mountpoint "$guest_root/data" --output SOURCE) == "$loop_device" ]] || exit 65
if [[ $action == quota-test ]]; then
  pg_uid=${3-}
  pg_gid=${4-}
  [[ $pg_uid =~ ^[1-9][0-9]*$ && $pg_gid =~ ^[1-9][0-9]*$ ]] || exit 64
  [[ ! -e $guest_root/data/pgdata && ! -e $guest_root/quota-proof.json ]] || exit 65
  chown "$pg_uid:$pg_gid" "$guest_root/data"
  chmod 700 "$guest_root/data"
  # Actual pre-initdb write and failed subsequent allocation as eventual PG UID.
  # Capped backing device prevents this test from consuming the guest filesystem.
  # Enter the protected volume while privileged; relative opens after setpriv
  # require only the owned data directory, never traversal through root:0700.
  ( cd -- "$guest_root/data"
  setpriv --reuid "$pg_uid" --regid "$pg_gid" --clear-groups python3 - . <<'PY'
import errno,json,os,sys
root=sys.argv[1];name=root+'/.owner-enospc';fd=os.open(name,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
written=0;block=b'\0'*(1024*1024);full=False
try:
 while written<2147483648+1048576:
  try: written+=os.write(fd,block)
  except OSError as e:
   if e.errno!=errno.ENOSPC: raise
   full=True;break
 if not full: raise RuntimeError('ENOSPC_NOT_PROVEN')
 try: os.posix_fallocate(fd,written,4096)
 except OSError as e:
  if e.errno!=errno.ENOSPC: raise
 else: raise RuntimeError('FURTHER_ALLOCATION_NOT_REFUSED')
 os.fsync(fd)
finally:
 os.close(fd);os.unlink(name)
 d=os.open(root,os.O_DIRECTORY);os.fsync(d);os.close(d)
print(json.dumps({'enospcObserved':True,'furtherAllocationFailed':True,'uid':os.getuid(),'gid':os.getgid(),'writtenBytes':written}))
PY
  )
  sync -f "$guest_root/data"
  sync -f "$guest_root/data.ext4"
  printf '%s:%s\n' "$pg_uid" "$pg_gid" > "$guest_root/quota-proof.json"
  exit 0
fi
if [[ $action == secrets ]]; then
  for role in bootstrap migrator app; do
    IFS= read -r password
    [[ $password =~ ^[0-9a-f]{64}$ && ! -e $guest_root/secrets/$role ]] || exit 65
    printf '%s\n' "$password" > "$guest_root/secrets/$role"
    chmod 600 "$guest_root/secrets/$role"
    unset password
  done
  # Container starts as root and reads password-file before dropping to PG UID.
  sync -f "$guest_root/secrets"
  exit 0
fi
if [[ $action == sentinel || $action == verify-sentinel ]]; then
  python3 - "$guest_root/data" "$run_id" "$action" <<'PY'
import os,sys,hashlib,json
root,u,action=sys.argv[1:];p=root+'/.owner-durable';body=('B1-OWNED-DURABLE:'+u+'\n').encode()
if action=='sentinel':
 fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 try: os.write(fd,body);os.fsync(fd)
 finally: os.close(fd)
 d=os.open(root,os.O_DIRECTORY);os.fsync(d);os.close(d)
if open(p,'rb').read()!=body: raise RuntimeError('SENTINEL_CHANGED')
print(json.dumps({'sha256':hashlib.sha256(body).hexdigest(),'verified':True}))
PY
  sync -f "$guest_root/data.ext4"
  exit 0
fi
python3 - "$guest_root" "$loop_device" <<'PY'
import os,sys,subprocess,json,re,stat
root,loop=sys.argv[1:];backing=root+'/data.ext4';s=os.lstat(backing)
if not stat.S_ISREG(s.st_mode) or s.st_size!=2147483648 or s.st_blocks*512<2147483648: raise RuntimeError('BACKING_ALLOCATION')
info=json.loads(subprocess.check_output(['losetup','--json','--output','NAME,BACK-FILE,BACK-INO,SIZELIMIT',loop],text=True))['loopdevices']
if len(info)!=1 or info[0]['back-file']!=backing or int(info[0]['back-ino'])!=s.st_ino: raise RuntimeError('LOOP_IDENTITY')
size=int(subprocess.check_output(['blockdev','--getsize64',loop],text=True))
mount=json.loads(subprocess.check_output(['findmnt','--json','--mountpoint',root+'/data','--output','SOURCE,TARGET,FSTYPE,OPTIONS'],text=True))['filesystems'][0]
if mount['source']!=loop or mount['fstype']!='ext4' or not {'rw','nodev','nosuid','noexec','data=ordered'}.issubset(set(mount['options'].split(','))): raise RuntimeError('MOUNT_IDENTITY')
dump=subprocess.check_output(['dumpe2fs','-h',loop],text=True,stderr=subprocess.DEVNULL)
def field(name):
 m=re.search(r'^'+re.escape(name)+r':\s+(\S+)',dump,re.M)
 if not m: raise RuntimeError('EXT4_FIELD')
 return m.group(1)
secret_modes=all(stat.S_IMODE(os.lstat(root+'/secrets/'+role).st_mode)==0o600 and stat.S_ISREG(os.lstat(root+'/secrets/'+role).st_mode) for role in ('bootstrap','migrator','app'))
# WAL/tablespaces cannot escape the capped filesystem, including symlink tricks.
pg=root+'/data/pgdata';dev=os.stat(root+'/data').st_dev
if os.path.exists(pg):
 for name in ('pg_wal','pg_tblspc'):
  p=pg+'/'+name
  if not os.path.realpath(p).startswith(root+'/data/') or os.stat(p).st_dev!=dev: raise RuntimeError('PGDATA_ESCAPE')
 for name in os.listdir(pg+'/pg_tblspc'):
  if os.path.islink(pg+'/pg_tblspc/'+name): raise RuntimeError('TABLESPACE_ESCAPE')
m={k:int(v.strip().split()[0])*1024 for k,v in (s.split(':',1) for s in open('/proc/meminfo') if ':' in s)}
v=os.statvfs(root)
print(json.dumps({'quotaBytes':size,'blockSize':int(field('Block size')),'blockCount':int(field('Block count')),'filesystemUuid':field('Filesystem UUID'),'mountType':mount['fstype'],'mountOptions':mount['options'],'loopDevice':loop,'backingFile':backing,'backingInode':s.st_ino,'backingAllocatedBytes':s.st_blocks*512,'mountDevice':dev,'capacityParentFreeBytes':v.f_bavail*v.f_frsize,'swapBytes':m['SwapTotal'],'secretModes':secret_modes,'enospcProofExists':os.path.isfile(root+'/quota-proof.json')}))
PY
