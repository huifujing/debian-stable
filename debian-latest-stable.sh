#!/bin/sh
# shellcheck shell=dash

set -eu

err() {
    printf "\nError: %s.\n" "$1" 1>&2
    exit 1
}

command_exists() {
    command -v "$1" > /dev/null 2>&1
}

download() {
    if command_exists wget; then
        wget -O "$2" "$1"
    elif command_exists curl; then
        curl -fL "$1" -o "$2"
    elif command_exists busybox && busybox wget --help > /dev/null 2>&1; then
        busybox wget -O "$2" "$1"
    else
        err 'Cannot find "wget", "curl" or "busybox wget" to download files'
    fi
}

# 纯 shell 实现 ipcalc -m（CIDR -> 点分十进制掩码）
cidr_to_netmask() {
    cidr="${1#*/}"
    mask=0
    i=0
    while [ "$i" -lt "$cidr" ]; do
        mask=$(( mask | ( 1 << (31 - i) ) ))
        i=$(( i + 1 ))
    done
    printf '%d.%d.%d.%d\n' \
        $(( (mask >> 24) & 255 )) \
        $(( (mask >> 16) & 255 )) \
        $(( (mask >>  8) & 255 )) \
        $(( mask         & 255 ))
}

set_security_archive() {
    case $suite in
        stable|trixie)
            security_archive=''
            ;;
        *)
            err "Unsupported suite: $suite"
    esac
}

set_daily_d_i() {
    # 不再依赖此函数决定下载地址，仅为兼容保留
    case $suite in
        stable|trixie)
            daily_d_i=true
            ;;
        *)
            err "Unsupported suite: $suite"
    esac
}

set_suite() {
    suite=$1
    set_daily_d_i
    set_security_archive
}

# ── 基础配置 ──────────────────────────────
interface=$(ip route | awk '/default/ {print $5; exit}')
ip=$(ip -4 addr show "$interface" | awk '/inet / {print $2; exit}')
gateway=$(ip route | awk '/default/ {print $3; exit}')
dns='1.1.1.1'
ntp=time.cloudflare.com
ssh_port=122
set_suite stable                      # ★ Debian 最新稳定版（stable）
mirror_protocol=http
mirror_host=deb.debian.org
mirror_directory=/debian
mirror_proxy=
password_hash='$5$bvf6qpkFZ7KLOFrr$ztpdLRhznACEkZxaiBZvNY1QbDnOtWRqO5egLeTmnE8'
timezone=UTC

# 健壮的磁盘检测（NVMe / LVM / mdraid）
detect_disk() {
    root_dev=$(awk '$2 == "/" {print $1}' /proc/mounts | tail -n1)

    if echo "$root_dev" | grep -q '^/dev/dm-'; then
        dm_name=$(basename "$root_dev")
        slave=$(ls "/sys/block/$dm_name/slaves/" 2>/dev/null | head -n1)
        [ -n "$slave" ] && root_dev="/dev/$slave"
    fi

    if echo "$root_dev" | grep -q '^/dev/md'; then
        md_name=$(basename "$root_dev")
        slave=$(ls "/sys/block/$md_name/slaves/" 2>/dev/null | head -n1)
        [ -n "$slave" ] && root_dev="/dev/$slave"
    fi

    dev_name=$(basename "$root_dev")

    if echo "$dev_name" | grep -qE 'nvme[0-9]+n[0-9]+p[0-9]+'; then
        disk_name=$(echo "$dev_name" | sed 's/p[0-9]*$//')
    else
        disk_name=$(echo "$dev_name" | sed 's/[0-9]*$//')
    fi

    if [ -b "/dev/$disk_name" ]; then
        echo "/dev/$disk_name"
    else
        lsblk -dpno NAME | grep -vE 'loop|dm-|md' | head -n1
    fi
}

disk=$(detect_disk)

efi=
esp=106
filesystem=ext4
kernel=
install=
upgrade=
kernel_params=
architecture=
force_efi_extra_removable=true
grub_timeout=5
dry_run=false
apt_non_free_firmware=true
apt_non_free=false
apt_contrib=false
apt_src=true

[ -z "$architecture" ] && {
    architecture=$(dpkg --print-architecture 2> /dev/null) || {
        case $(uname -m) in
            x86_64)  architecture=amd64 ;;
            aarch64) architecture=arm64 ;;
            i386)    architecture=i386  ;;
            *)       err 'No "--architecture" specified'
        esac
    }
}

[ -z "$kernel" ] && kernel="linux-image-$architecture"

non_free_firmware_available=false
case $suite in
    stable|trixie)
        non_free_firmware_available=true
        ;;
esac

apt_components=main
[ "$apt_contrib" = true ]              && apt_components="$apt_components contrib"
[ "$apt_non_free" = true ]             && apt_components="$apt_components non-free"
[ "$apt_non_free_firmware" = true ]    && apt_components="$apt_components non-free-firmware"

apt_services=""

installer_directory="/boot/debian-$suite"

save_preseed='cat'
[ "$dry_run" = false ] && {
    [ "$(id -u)" -ne 0 ] && err 'root privilege is required'
    rm -rf "$installer_directory"
    mkdir -p "$installer_directory"
    cd "$installer_directory"
    save_preseed='tee -a preseed.cfg'
}

# ── 生成 preseed.cfg ─────────────────────
$save_preseed << EOF
# Localization

d-i debian-installer/language string en
d-i debian-installer/country string US
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us

# Network configuration

d-i netcfg/choose_interface select $interface
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/get_ipaddress string $(echo "$ip" | cut -d/ -f1)
d-i netcfg/get_netmask string $(cidr_to_netmask "$ip")
d-i netcfg/get_gateway string $gateway
d-i netcfg/get_nameservers string $dns
d-i netcfg/confirm_static boolean true
EOF

hostname=$(cat /proc/sys/kernel/hostname)
domain=$(cat /proc/sys/kernel/domainname)
if [ "$domain" = '(none)' ]; then
    domain=
else
    domain=" $domain"
fi

$save_preseed << EOF
d-i netcfg/get_hostname string $hostname
d-i netcfg/get_domain string$domain

d-i hw-detect/load_firmware boolean true

# Mirror settings

d-i mirror/country string manual
d-i mirror/protocol string $mirror_protocol
d-i mirror/$mirror_protocol/hostname string $mirror_host
d-i mirror/$mirror_protocol/directory string $mirror_directory
d-i mirror/$mirror_protocol/proxy string $mirror_proxy
d-i mirror/suite string $suite
d-i mirror/udeb/suite string stable

# Account setup

EOF

$save_preseed << 'EOF'
d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
EOF

echo "d-i passwd/root-password-crypted password $password_hash" | $save_preseed

$save_preseed << EOF

# Clock and time zone setup

d-i time/zone string $timezone
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean true
d-i clock-setup/ntp-server string $ntp

# Partitioning

d-i partman-auto/method string regular
EOF

if [ -n "$disk" ]; then
    echo "d-i partman-auto/disk string $disk" | $save_preseed
else
    # shellcheck disable=SC2016
    echo 'd-i partman/early_command string debconf-set partman-auto/disk "$(list-devices disk | head -n 1)"' | $save_preseed
fi

$save_preseed << 'EOF'
d-i partman-partitioning/choose_label string gpt
d-i partman-partitioning/default_label string gpt
EOF

echo "d-i partman/default_filesystem string $filesystem" | $save_preseed

[ -z "$efi" ] && {
    efi=false
    [ -d /sys/firmware/efi ] && efi=true
}

$save_preseed << 'EOF'
d-i partman-auto/expert_recipe string \
    naive :: \
EOF

if [ "$efi" = true ]; then
    $save_preseed << EOF
        $esp $esp $esp free \\
EOF
    $save_preseed << 'EOF'
            $iflabel{ gpt } \
            $reusemethod{ } \
            method{ efi } \
            format{ } \
        . \
EOF
else
    $save_preseed << 'EOF'
        1 1 1 free \
            $iflabel{ gpt } \
            $reusemethod{ } \
            method{ biosgrub } \
        . \
EOF
fi

$save_preseed << 'EOF'
        1075 1076 -1 $default_filesystem \
            method{ format } \
            format{ } \
            use_filesystem{ } \
            $default_filesystem{ } \
            mountpoint{ / } \
        .
EOF

if [ "$efi" = true ]; then
    echo 'd-i partman-efi/non_efi_system boolean true' | $save_preseed
fi

$save_preseed << EOF
d-i partman-auto/choose_recipe select naive
d-i partman-basicfilesystems/no_swap boolean false
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman-lvm/device_remove_lvm boolean true

# Base system installation

d-i base-installer/kernel/image string $kernel

# Apt setup

d-i apt-setup/contrib boolean $apt_contrib
d-i apt-setup/non-free boolean $apt_non_free
d-i apt-setup/enable-source-repositories boolean $apt_src
d-i apt-setup/services-select multiselect $apt_services
EOF

[ "$non_free_firmware_available" = true ] && \
    echo "d-i apt-setup/non-free-firmware boolean $apt_non_free_firmware" | $save_preseed

$save_preseed << 'EOF'

# Package selection

tasksel tasksel/first multiselect ssh-server
EOF

install="$install ca-certificates libpam-systemd wget curl screen cron zip unzip tar vnstat nftables dnsutils sudo"

[ -n "$install" ] && echo "d-i pkgsel/include string $install" | $save_preseed
[ -n "$upgrade" ]  && echo "d-i pkgsel/upgrade select $upgrade"  | $save_preseed

$save_preseed << 'EOF'
popularity-contest popularity-contest/participate boolean false

# Boot loader installation

EOF

if [ -n "$disk" ]; then
    echo "d-i grub-installer/bootdev string $disk" | $save_preseed
else
    echo 'd-i grub-installer/bootdev string default' | $save_preseed
fi

[ "$force_efi_extra_removable" = true ] && \
    echo 'd-i grub-installer/force-efi-extra-removable boolean true' | $save_preseed
[ -n "$kernel_params" ] && \
    echo "d-i debian-installer/add-kernel-opts string$kernel_params" | $save_preseed

$save_preseed << 'EOF'

# Finishing up the installation

d-i finish-install/reboot_in_progress note
EOF

late_command="in-target sh -c \"sed -i 's/^#\\?Port .*/Port $ssh_port/' /etc/ssh/sshd_config; sed -i 's/^#\\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config\""
echo "d-i preseed/late_command string $late_command" | $save_preseed

# ── 下载安装程序（固定使用 stable 版） ──
save_grub_cfg='cat'
[ "$dry_run" = false ] && {
    # ★ 核心修复：无论目标是什么版本，始终用 stable 安装程序引导
    base_url="http://deb.debian.org/debian/dists/stable/main/installer-${architecture}/current/images/netboot/debian-installer/${architecture}"

    download "$base_url/linux" linux
    download "$base_url/initrd.gz" initrd.gz

    gzip -d initrd.gz
    echo preseed.cfg | cpio -o -H newc -A -F initrd
    gzip -1 initrd

    mkdir -p /etc/default/grub.d
    tee /etc/default/grub.d/zz-debi.cfg 1>&2 << EOF
GRUB_DEFAULT=debi
GRUB_TIMEOUT=$grub_timeout
GRUB_TIMEOUT_STYLE=menu
EOF

    if command_exists update-grub; then
        grub_cfg=/boot/grub/grub.cfg
        update-grub
    elif command_exists grub2-mkconfig; then
        tmp=$(mktemp)
        grep -vF zz_debi /etc/default/grub > "$tmp"
        cat "$tmp" > /etc/default/grub
        rm "$tmp"
        # shellcheck disable=SC2016
        echo 'zz_debi=/etc/default/grub.d/zz-debi.cfg; if [ -f "$zz_debi" ]; then . "$zz_debi"; fi' >> /etc/default/grub
        grub_cfg=/boot/grub2/grub.cfg
        [ -d /sys/firmware/efi ] && grub_cfg=/boot/efi/EFI/*/grub.cfg
        grub2-mkconfig -o "$grub_cfg"
    elif command_exists grub-mkconfig; then
        tmp=$(mktemp)
        grep -vF zz_debi /etc/default/grub > "$tmp"
        cat "$tmp" > /etc/default/grub
        rm "$tmp"
        # shellcheck disable=SC2016
        echo 'zz_debi=/etc/default/grub.d/zz-debi.cfg; if [ -f "$zz_debi" ]; then . "$zz_debi"; fi' >> /etc/default/grub
        grub_cfg=/boot/grub/grub.cfg
        grub-mkconfig -o "$grub_cfg"
    else
        err 'Could not find "update-grub" or "grub2-mkconfig" or "grub-mkconfig" command'
    fi

    save_grub_cfg="tee -a $grub_cfg"
}

mkrelpath=$installer_directory
[ "$dry_run" = true ] && mkrelpath=/boot
installer_directory=$(grub-mkrelpath "$mkrelpath" 2> /dev/null) ||
installer_directory=$(grub2-mkrelpath "$mkrelpath" 2> /dev/null) || {
    err 'Could not find "grub-mkrelpath" or "grub2-mkrelpath" command'
}
[ "$dry_run" = true ] && installer_directory="$installer_directory/debian-$suite"

kernel_params="$kernel_params lowmem/low=1"
initrd="$installer_directory/initrd.gz"

$save_grub_cfg 1>&2 << EOF
menuentry 'Debian Installer' --id debi {
    insmod part_msdos
    insmod part_gpt
    insmod ext2
    insmod xfs
    insmod btrfs
    linux $installer_directory/linux $kernel_params
    initrd $initrd
}
EOF

reboot