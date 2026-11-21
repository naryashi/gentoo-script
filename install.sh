#!/usr/bin/env bash
# gentoo-install - menu-driven Gentoo installer (archinstall style)
#
#   * YOU partition the disks and choose every mount point
#   * stage3 (desktop profile) + official binhost + generic CFLAGS => mostly binary packages
#   * systemd or OpenRC, UEFI or BIOS (GRUB), GNOME / KDE / XFCE / MATE / Cinnamon / none
#   * audio (PipeWire), bluetooth, wifi, printing, flatpak as checkboxes
#   * your own extras: drop *.sh files in hooks/ (run inside the new system at the end)
#
# Boot the Gentoo minimal ISO (or LiveGUI), get internet, then:   bash install.sh
# NOT handled: LUKS / LVM / RAID initramfs configuration, btrfs subvolumes.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MNT=/mnt/gentoo
LOG=/tmp/gentoo-install.log
DIST=https://distfiles.gentoo.org/releases/amd64/autobuilds

# ---------- settings (edited through the menu) ----------
INIT=systemd;  HOST_NAME=gentoo;  TZ_NAME=UTC;  LOCALE=en_US.UTF-8;  KEYMAP=us
USERNAME="";   USERPW="";         ROOTPW=""
DE=gnome;      GPU=all;           KERNEL=bin;   BINHOST=x86-64
FEATS="audio bluetooth wifi flatpak"
ROOT_DEV="";   EFI_MP="";         BOOT_DISK=""
declare -A PMP=() PFS=() PFMT=()     # device -> mountpoint | filesystem | format (yes/no)
if [[ -d /sys/firmware/efi ]]; then BOOT_MODE=uefi; else BOOT_MODE=bios; fi

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- tiny UI layer (whiptail or dialog) ----------
TUI=$(command -v whiptail || command -v dialog || true)
ui()  { "$TUI" --backtitle "Gentoo installer | boot mode: $BOOT_MODE" "$@" 3>&1 1>&2 2>&3; }
msg() { ui --title "${2:-Notice}" --msgbox "$1" 16 70; }

pick() {  # pick VAR "Title" "Prompt" tag desc [tag desc ...]
  local var=$1 title=$2 prompt=$3 c; shift 3
  local n=$(( $# / 2 ))
  c=$(ui --title "$title" --default-item "${!var}" --menu "$prompt" $((n + 8)) 72 "$n" "$@") || return 0
  printf -v "$var" '%s' "$c"
}

input() { # input VAR "Title" "Prompt" validator-function
  local var=$1 v
  while true; do
    v=$(ui --title "$2" --inputbox "$3" 11 72 "${!var}") || return 0
    if "$4" "$v"; then printf -v "$var" '%s' "$v"; return 0; fi
    msg "Invalid value: $v" "Error"
  done
}

newpass() { # newpass VAR "Title"
  local a b
  while true; do
    a=$(ui --title "$2" --passwordbox "Enter password:" 9 60) || return 0
    b=$(ui --title "$2" --passwordbox "Repeat password:" 9 60) || return 0
    if [[ -n $a && $a == "$b" ]]; then printf -v "$1" '%s' "$a"; return 0; fi
    msg "Passwords are empty or do not match." "Error"
  done
}

v_host()   { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]]; }
v_tz()     { [[ -f /usr/share/zoneinfo/$1 ]]; }
v_locale() { [[ $1 =~ ^[a-z]{2,3}_[A-Z]{2}\.UTF-8$ ]]; }
v_keymap() { [[ $1 =~ ^[A-Za-z0-9._-]+$ ]]; }
v_user()   { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

onoff() { if [[ " $FEATS " == *" $1 "* ]]; then echo on; else echo off; fi; }

set_feats() {
  local out
  out=$(ui --title "Features" --separate-output --checklist "SPACE = toggle, ENTER = confirm" 18 76 6 \
    audio     "PipeWire audio (+ WirePlumber)"            "$(onoff audio)" \
    bluetooth "Bluetooth (BlueZ)"                         "$(onoff bluetooth)" \
    wifi      "Wi-Fi (NetworkManager + wpa_supplicant)"   "$(onoff wifi)" \
    printing  "Printing (CUPS)"                           "$(onoff printing)" \
    flatpak   "Flatpak + Flathub remote"                  "$(onoff flatpak)" \
    osprober  "GRUB os-prober (detect Windows/other OS)"  "$(onoff osprober)") || return 0
  FEATS=$(tr '\n' ' ' <<<"$out"); FEATS=${FEATS% }
}

# ---------- disks and partitions ----------
list_parts() {  # prints: device<TAB>size<TAB>fstype
  local line NAME SIZE FSTYPE TYPE MOUNTPOINT
  while IFS= read -r line; do
    eval "$line"
    [[ $TYPE == part || $TYPE == lvm || $TYPE == crypt ]] || continue
    [[ $FSTYPE == iso9660 || $FSTYPE == squashfs || $FSTYPE == LVM2_member || $FSTYPE == crypto_LUKS ]] && continue
    printf '%s\t%s\t%s\n' "$NAME" "$SIZE" "$FSTYPE"
  done < <(lsblk -pPno NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT)
}

disk_items() { lsblk -dpno NAME,SIZE,MODEL -e 7,11 | awk '{n=$1; s=$2; $1=$2=""; sub(/^ +/,""); print n; print s " " $0}'; }

pick_disk() {  # pick_disk VAR "Title"
  local -a items; local c
  mapfile -t items < <(disk_items)
  ((${#items[@]})) || { msg "No disks found."; return 1; }
  c=$(ui --title "$2" --menu "Select a disk:" 18 70 8 "${items[@]}") || return 1
  printf -v "$1" '%s' "$c"
}

assign_part() {
  local dev=$1 role fs fmt d
  role=$(ui --title "$dev" --menu "Use this partition as:" 21 72 9 \
    /          "Root filesystem" \
    /efi       "EFI System Partition at /efi (Gentoo default)" \
    /boot/efi  "EFI System Partition at /boot/efi" \
    /boot      "Separate /boot" \
    /home      "/home" \
    swap       "Swap" \
    custom     "Other mount point..." \
    none       "Unassign this partition") || return 0
  if [[ $role == none ]]; then
    unset "PMP[$dev]" "PFS[$dev]" "PFMT[$dev]"; return 0
  fi
  if [[ $role == custom ]]; then
    role=$(ui --title "Mount point" --inputbox "Absolute path (e.g. /data):" 9 60 "/") || return 0
    [[ $role =~ ^/[A-Za-z0-9._/-]+$ ]] || { msg "Invalid mount point."; return 0; }
  fi
  if [[ $role != swap ]]; then      # one device per mount point
    for d in "${!PMP[@]}"; do
      if [[ ${PMP[$d]} == "$role" && $d != "$dev" ]]; then unset "PMP[$d]" "PFS[$d]" "PFMT[$d]"; fi
    done
  fi
  case $role in
    swap)
      fs=swap; fmt=yes ;;
    /efi|/boot/efi)
      fs=vfat
      fmt=$(ui --title "EFI partition" --menu "Format the EFI partition?" 12 70 2 \
        yes "Format (new ESP, erases it)" no "Keep as is (shared with another OS)") || return 0 ;;
    *)
      fs=$(ui --title "Filesystem for $role" --menu "Filesystem:" 14 70 4 \
        ext4 "ext4 (format)" btrfs "btrfs (format)" xfs "xfs (format)" keep "Keep existing data/filesystem") || return 0
      if [[ $fs == keep ]]; then
        fs=$(blkid -s TYPE -o value "$dev" || true); fmt=no
        [[ -n $fs ]] || { msg "$dev has no filesystem, pick one to format."; return 0; }
      else
        fmt=yes
      fi ;;
  esac
  PMP[$dev]=$role; PFS[$dev]=$fs; PFMT[$dev]=$fmt
}

resolve_parts() {   # silently fills ROOT_DEV and EFI_MP from the assignments
  local d; ROOT_DEV=""; EFI_MP=""
  for d in "${!PMP[@]}"; do
    case ${PMP[$d]} in
      /)                ROOT_DEV=$d ;;
      /efi|/boot/efi)   EFI_MP=${PMP[$d]} ;;
      /boot)            if [[ ${PFS[$d]} == vfat && -z $EFI_MP ]]; then EFI_MP=/boot; fi ;;
    esac
  done
}

parts_problem() {   # prints a problem description, nothing if all good
  resolve_parts
  if [[ -z $ROOT_DEV ]]; then echo "No root (/) partition assigned."; return; fi
  if [[ $BOOT_MODE == uefi && -z $EFI_MP ]]; then
    echo "UEFI boot needs an EFI partition mounted at /efi or /boot/efi."; return
  fi
  if [[ $BOOT_MODE == bios && -z $BOOT_DISK ]]; then echo "BIOS boot: GRUB target disk not chosen."; fi
}

partition_menu() {
  local c d size fs role p
  while true; do
    local -a items=("@cfdisk" "Edit a partition table (cfdisk)")
    while IFS=$'\t' read -r d size fs; do
      role="-"
      if [[ -n ${PMP[$d]:-} ]]; then role="${PMP[$d]}  [${PFS[$d]}, format=${PFMT[$d]}]"; fi
      items+=("$d" "$size ${fs:-no-fs}  =>  $role")
    done < <(list_parts)
    items+=("@done" ">>> Done, back to main menu")
    c=$(ui --title "Partitions" \
      --menu "Create partitions with cfdisk if needed, then pick each one to give it a role." \
      22 78 14 "${items[@]}") || return 0
    case $c in
      @cfdisk) if pick_disk d "Partition which disk?"; then cfdisk "$d"; partprobe "$d" 2>/dev/null || true; udevadm settle || true; fi ;;
      @done)
        if [[ $BOOT_MODE == bios && -z $BOOT_DISK ]]; then pick_disk BOOT_DISK "GRUB (BIOS) target disk" || true; fi
        p=$(parts_problem)
        if [[ -n $p ]]; then msg "$p"; else return 0; fi ;;
      *) assign_part "$c" ;;
    esac
  done
}

parts_summary() {
  if ((${#PMP[@]} == 0)); then echo "<not set>"; else echo "${#PMP[@]} assigned"; fi
}

# ---------- install steps ----------
format_and_mount() {
  local d mp
  umount -R "$MNT" 2>/dev/null || true
  for d in "${!PMP[@]}"; do
    [[ ${PFMT[$d]} == yes ]] || continue
    log "Formatting $d as ${PFS[$d]}"
    case ${PFS[$d]} in
      ext4)  mkfs.ext4 -F "$d" ;;
      btrfs) mkfs.btrfs -f "$d" ;;
      xfs)   mkfs.xfs -f "$d" ;;
      vfat)  mkfs.fat -F 32 "$d" ;;
      swap)  mkswap "$d" ;;
    esac
  done
  udevadm settle || true
  mkdir -p "$MNT"
  mount "$ROOT_DEV" "$MNT"
  while read -r mp d; do               # sorted: parents before children
    if [[ $mp == swap ]]; then swapon "$d"; continue; fi
    mkdir -p "$MNT$mp"
    mount "$d" "$MNT$mp"
  done < <(for d in "${!PMP[@]}"; do [[ ${PMP[$d]} == / ]] || echo "${PMP[$d]} $d"; done | LC_ALL=C sort)
}

stage3_path() { awk '/\.tar\.xz/ {print $1; exit}'; }   # reads latest-stage3-*.txt on stdin

verify_stage3() {
  local f=$1
  if ! command -v gpg >/dev/null; then
    echo "WARNING: gpg not found, stage3 signature NOT verified."; return 0
  fi
  GNUPGHOME=$(mktemp -d); export GNUPGHOME
  if [[ -f /usr/share/openpgp-keys/gentoo-release.asc ]]; then
    gpg --quiet --import /usr/share/openpgp-keys/gentoo-release.asc
  else
    gpg --quiet --auto-key-locate=clear,nodefault,wkd --locate-key releng@gentoo.org
  fi
  gpg --verify "$f.asc" "$f" || die "stage3 signature check FAILED, aborting."
}

fetch_stage3() {
  local txt path file
  txt=$(curl -fsSL "$DIST/latest-stage3-amd64-desktop-$INIT.txt") || die "Could not fetch the stage3 index."
  path=$(stage3_path <<<"$txt")
  [[ -n $path ]] || die "Could not parse the stage3 index."
  file=$(basename "$path")
  log "Downloading $file"
  curl -fsSL -o "$MNT/$file" "$DIST/$path"
  curl -fsSL -o "$MNT/$file.asc" "$DIST/$path.asc"
  verify_stage3 "$MNT/$file"
  log "Extracting stage3"
  tar xpf "$MNT/$file" --xattrs-include='*.*' --numeric-owner -C "$MNT"
  rm -f "$MNT/$file" "$MNT/$file.asc"
}

write_fstab() {
  local mp d u fs opts pass
  {
    echo "# /etc/fstab - generated by gentoo-install"
    while read -r mp d; do
      u=$(blkid -s UUID -o value "$d"); fs=${PFS[$d]}
      if [[ $mp == swap ]]; then printf 'UUID=%s\tnone\tswap\tsw\t0 0\n' "$u"; continue; fi
      opts="defaults,noatime"; pass=2
      [[ $mp == / ]] && pass=1
      [[ $fs == btrfs || $fs == xfs ]] && pass=0
      [[ $fs == vfat ]] && opts="defaults,umask=0077"
      printf 'UUID=%s\t%s\t%s\t%s\t0 %s\n' "$u" "$mp" "$fs" "$opts" "$pass"
    done < <(for d in "${!PMP[@]}"; do echo "${PMP[$d]} $d"; done | LC_ALL=C sort)
  } > "$MNT/etc/fstab"
}

prepare_chroot() {
  local cores ram JOBS FS_PKGS="sys-fs/dosfstools" d v conf=$MNT/root/install.conf
  cores=$(nproc); ram=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
  JOBS=$(( ram / 2 < cores ? ram / 2 : cores )); ((JOBS < 1)) && JOBS=1
  for d in "${!PFS[@]}"; do
    case ${PFS[$d]} in
      btrfs) FS_PKGS+=" sys-fs/btrfs-progs" ;;
      xfs)   FS_PKGS+=" sys-fs/xfsprogs" ;;
    esac
  done

  : > "$conf"; chmod 600 "$conf"
  for v in INIT HOST_NAME TZ_NAME LOCALE KEYMAP USERNAME DE GPU KERNEL BINHOST FEATS BOOT_MODE EFI_MP BOOT_DISK FS_PKGS JOBS; do
    printf '%s=%q\n' "$v" "${!v}" >> "$conf"
  done
  cp "$DIR/chroot.sh" "$MNT/root/chroot.sh"
  if [[ -d $DIR/hooks ]]; then cp -r "$DIR/hooks" "$MNT/root/hooks"; fi

  cp --dereference /etc/resolv.conf "$MNT/etc/"
  mountpoint -q "$MNT/proc" || mount --types proc /proc "$MNT/proc"
  mountpoint -q "$MNT/sys"  || { mount --rbind /sys "$MNT/sys"; mount --make-rslave "$MNT/sys"; }
  mountpoint -q "$MNT/dev"  || { mount --rbind /dev "$MNT/dev"; mount --make-rslave "$MNT/dev"; }
  mountpoint -q "$MNT/run"  || { mount --bind /run "$MNT/run"; mount --make-slave "$MNT/run"; }
}

do_install() {
  log "Checking internet"
  curl -fsI --max-time 15 https://distfiles.gentoo.org >/dev/null || die "No internet. Run net-setup (or nmtui) and try again."
  chronyd -q 'pool pool.ntp.org iburst' >/dev/null 2>&1 || true

  log "Formatting and mounting"
  format_and_mount
  fetch_stage3
  write_fstab
  log "Preparing chroot"
  prepare_chroot

  log "Chroot stage (long part: binhost + whatever has to compile)"
  chroot "$MNT" /usr/bin/env -i HOME=/root TERM="${TERM:-linux}" /bin/bash -l /root/chroot.sh

  log "Setting passwords"
  printf 'root:%s\n%s:%s\n' "$ROOTPW" "$USERNAME" "$USERPW" | chroot "$MNT" chpasswd
  rm -rf "$MNT/root/install.conf" "$MNT/root/chroot.sh" "$MNT/root/hooks"

  log "Unmounting"
  local d
  for d in "${!PFS[@]}"; do if [[ ${PFS[$d]} == swap ]]; then swapoff "$d" || true; fi; done
  umount -R "$MNT" || true
}

# ---------- main menu ----------
confirm_install() {
  local s d
  s="Boot: $BOOT_MODE   Init: $INIT   Desktop: $DE   Binhost: $BINHOST\n\nPartitions:\n"
  for d in $(printf '%s\n' "${!PMP[@]}" | LC_ALL=C sort); do
    s+="  $d  ->  ${PMP[$d]}  (${PFS[$d]})"
    if [[ ${PFMT[$d]} == yes ]]; then s+="   ** WILL BE FORMATTED **"; fi
    s+="\n"
  done
  if [[ $BOOT_MODE == bios ]]; then s+="\nGRUB goes to: $BOOT_DISK\n"; fi
  s+="\nContinue? Data on the partitions marked above will be destroyed."
  ui --title "Confirm" --defaultno --yesno "$s" 24 78
}

check_ready() {
  local p="" pp
  pp=$(parts_problem); [[ -n $pp ]] && p+="  - $pp\n"
  [[ -n $USERNAME && -n $USERPW ]] || p+="  - user name / password\n"
  [[ -n $ROOTPW ]] || p+="  - root password\n"
  if [[ -n $p ]]; then msg "Not ready yet:\n\n$p"; return 1; fi
  return 0
}

run_install() {
  : > "$LOG"
  ( set -e; do_install ) 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  if ((rc == 0)); then
    if ui --title "Done" --yesno "Gentoo is installed. Reboot now?" 9 50; then reboot; fi
    exit 0
  fi
  msg "Install FAILED (log: $LOG).\n\nThe target is still mounted at $MNT. To look around:\n  chroot $MNT /bin/bash -l\n\nFix the problem and run the installer again." "Failed"
}

main_menu() {
  local c last=init
  while true; do
    c=$(ui --title "Gentoo installer" --default-item "$last" \
      --menu "Set everything up, then choose INSTALL." 24 78 15 \
      init    "Init system        : $INIT" \
      parts   "Partitions         : $(parts_summary)" \
      host    "Hostname           : $HOST_NAME" \
      tz      "Timezone           : $TZ_NAME" \
      locale  "Locale             : $LOCALE" \
      keymap  "Console keymap     : $KEYMAP" \
      user    "User               : ${USERNAME:-<not set>}" \
      rootpw  "Root password      : $([[ -n $ROOTPW ]] && echo set || echo '<not set>')" \
      de      "Desktop            : $DE" \
      gpu     "Graphics drivers   : $GPU" \
      kernel  "Kernel             : $KERNEL" \
      binhost "Binhost level      : $BINHOST" \
      feats   "Features           : ${FEATS:-none}" \
      install ">>> INSTALL <<<" \
      quit    "Quit") || exit 0
    last=$c
    case $c in
      init)    pick INIT "Init system" "Choose the init system:" systemd "systemd" openrc "OpenRC (+ elogind)" ;;
      parts)   partition_menu ;;
      host)    input HOST_NAME "Hostname" "Hostname:" v_host ;;
      tz)      input TZ_NAME "Timezone" "Region/City, e.g. America/Sao_Paulo or UTC:" v_tz ;;
      locale)  input LOCALE "Locale" "Locale, e.g. en_US.UTF-8 or pt_BR.UTF-8:" v_locale ;;
      keymap)  input KEYMAP "Keymap" "Console keymap, e.g. us, br-abnt2, de-latin1:" v_keymap
               loadkeys "$KEYMAP" 2>/dev/null || true ;;
      user)    input USERNAME "User" "Login name for your user (gets sudo via wheel):" v_user; newpass USERPW "Password for $USERNAME" ;;
      rootpw)  newpass ROOTPW "Root password" ;;
      de)      pick DE "Desktop" "Desktop environment:" gnome "GNOME" kde "KDE Plasma" xfce "XFCE" mate "MATE" cinnamon "Cinnamon" none "None (TTY only)" ;;
      gpu)     pick GPU "Graphics" "VIDEO_CARDS (see notes about binhost):" all "Intel + AMD + nouveau" intel "Intel" amd "AMD" nouveau "NVIDIA (open nouveau)" vm "Virtual machine (virgl/vmware)" none "Don't set" ;;
      kernel)  pick KERNEL "Kernel" "Which kernel package:" bin "gentoo-kernel-bin (prebuilt, fastest)" src "gentoo-kernel (compiled locally)" ;;
      binhost) pick BINHOST "Binhost" "Which official binary package level:" x86-64 "x86-64 (any 64-bit CPU)" x86-64-v3 "x86-64-v3 (Haswell/Zen 2013+ only)" ;;
      feats)   set_feats ;;
      install) if check_ready && confirm_install; then run_install; fi ;;
      quit)    exit 0 ;;
    esac
  done
}

main() {
  [[ $EUID -eq 0 ]] || die "Run as root."
  [[ -n $TUI ]] || die "Neither whiptail nor dialog found (the Gentoo LiveGUI ISO has them)."
  [[ -f $DIR/chroot.sh ]] || die "chroot.sh must be next to install.sh."
  main_menu
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
