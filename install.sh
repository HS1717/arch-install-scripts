#!/bin/bash

# Arch Linux BTRFS RAID 10 자동 설치 스크립트
# 사용자: nev, 호스트: nev
# GPU: RTX 3070, CPU: i5-12400F
# 독일 지역설정, 영어 시스템

set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 로그 함수
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# 루트 권한 확인
if [[ $EUID -ne 0 ]]; then
   error "이 스크립트는 루트 권한으로 실행해야 합니다."
fi

# 설정 변수
USERNAME="nev"
HOSTNAME="nev"
TIMEZONE="Europe/Berlin"
KEYMAP="us"
LOCALE="en_US.UTF-8"
REGION_LOCALE="de_DE.UTF-8"

log "Arch Linux BTRFS RAID 10 설치 시작"
log "사용자: $USERNAME, 호스트: $HOSTNAME"

# 1. 시스템 시계 동기화
log "시스템 시계 동기화 중..."
timedatectl set-ntp true

# 2. 네트워크 연결 확인
log "네트워크 연결 확인 중..."
if ! ping -c 1 archlinux.org &> /dev/null; then
    warn "DNS 해석 실패, IP 직접 접속 시도 중..."
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        error "인터넷 연결을 확인해주세요."
    fi
    log "네트워크 연결됨 (DNS 문제 있음, 설치는 계속 진행)"
fi

# 3. NVMe 디스크 식별
log "NVMe 디스크 식별 중..."
echo "사용 가능한 NVMe 디스크:"
lsblk | grep nvme

# PCIe 버스 주소 기준으로 정렬된 NVMe 디스크 식별
NVME_PATHS=($(find /dev/disk/by-path/ -name "*nvme*" | grep -E 'pci-[0-9a-f]+:[0-9a-f]+:[0-9a-f]+\.[0-9a-f]+-nvme' | sort -V))
if [ ${#NVME_PATHS[@]} -lt 4 ]; then
    error "RAID 10을 위해서는 최소 4개의 NVMe가 필요합니다. 현재: ${#NVME_PATHS[@]}개"
fi

log "감지된 NVMe 디스크 (PCIe 버스 주소 순서):"
RAID_DISKS=()
for i in "${!NVME_PATHS[@]}"; do
    real_device=$(readlink -f "${NVME_PATHS[$i]}")
    pcie_addr=$(echo "${NVME_PATHS[$i]}" | grep -o 'pci-[0-9a-f:\.]*')
    echo "$((i+1)). $pcie_addr -> $real_device"
    RAID_DISKS+=("$real_device")
done

# 가장 낮은 PCIe 주소의 NVMe를 PRIMARY로 선택
PRIMARY_NVME="${RAID_DISKS[0]}"
log "주 디스크로 선택됨: $PRIMARY_NVME"

# RAID 10용 4개 디스크 설정
if [ ${#RAID_DISKS[@]} -gt 4 ]; then
    # 4개만 사용 (처음 4개)
    RAID_DISKS=("${RAID_DISKS[@]:0:4}")
    warn "4개 초과 디스크 감지, 처음 4개만 사용: ${RAID_DISKS[*]}"
fi

log "RAID 10 구성 디스크: ${RAID_DISKS[*]}"

# 사용자 확인
echo -e "${YELLOW}계속하려면 'YES'를 입력하세요 (모든 데이터가 삭제됩니다):${NC}"
read -r confirmation
if [ "$confirmation" != "YES" ]; then
    error "설치가 취소되었습니다."
fi

# 4. 디스크 파티셔닝
log "디스크 파티셔닝 시작..."

for i in "${!RAID_DISKS[@]}"; do
    disk="${RAID_DISKS[$i]}"
    log "$disk 파티셔닝 중..."
    
    # 파티션 테이블 초기화
    wipefs -af "$disk"
    sgdisk --zap-all "$disk"
    
    if [ $i -eq 0 ]; then
        # 첫 번째 디스크만: EFI + SWAP + ROOT
        sgdisk --clear \
               --new=1:0:+1G --typecode=1:ef00 --change-name=1:'EFI System' \
               --new=2:0:+52G --typecode=2:8200 --change-name=2:'Linux swap' \
               --new=3:0:0 --typecode=3:8300 --change-name=3:'Linux filesystem' \
               "$disk"
    else
        # 나머지 디스크들: ROOT만
        sgdisk --clear \
               --new=1:0:0 --typecode=1:8300 --change-name=1:'Linux filesystem' \
               "$disk"
    fi
    
    partprobe "$disk"
    sleep 2
done

# 5. BTRFS RAID 10 구성
log "BTRFS RAID 10 파일시스템 생성 중..."

# 루트 파티션들 배열 생성
ROOT_PARTITIONS=()
for i in "${!RAID_DISKS[@]}"; do
    disk="${RAID_DISKS[$i]}"
    if [ $i -eq 0 ]; then
        ROOT_PARTITIONS+=("${disk}p3")  # 첫 번째: p3
    else
        ROOT_PARTITIONS+=("${disk}p1")  # 나머지: p1
    fi
done

# BTRFS RAID 10 생성
mkfs.btrfs -f -m raid10 -d raid10 "${ROOT_PARTITIONS[@]}"

# SWAP 파티션 설정 (첫 번째 디스크만)
mkswap "${PRIMARY_NVME}p2"

# EFI 파티션 설정 (첫 번째 디스크만)
mkfs.fat -F32 "${PRIMARY_NVME}p1"

# 6. BTRFS 서브볼륨 생성
log "BTRFS 서브볼륨 생성 중..."

# 루트 파티션 마운트
mount "${PRIMARY_NVME}p3" /mnt

# 서브볼륨 생성
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@snapshots

# 언마운트
umount /mnt

# 7. 서브볼륨 마운트
log "서브볼륨 마운트 중..."

# 마운트 옵션
BTRFS_OPTS="defaults,noatime,compress=zstd,space_cache=v2"

# 루트 서브볼륨 마운트 (첫 번째 디스크의 ROOT 파티션 사용)
mount -o $BTRFS_OPTS,subvol=@ "${PRIMARY_NVME}p3" /mnt

# 디렉토리 생성 및 서브볼륨 마운트
mkdir -p /mnt/{home,var,tmp,.snapshots,boot}
mount -o $BTRFS_OPTS,subvol=@home "${PRIMARY_NVME}p3" /mnt/home
mount -o $BTRFS_OPTS,subvol=@var "${PRIMARY_NVME}p3" /mnt/var
mount -o $BTRFS_OPTS,subvol=@tmp "${PRIMARY_NVME}p3" /mnt/tmp
mount -o $BTRFS_OPTS,subvol=@snapshots "${PRIMARY_NVME}p3" /mnt/.snapshots

# EFI 파티션 마운트
mount "${PRIMARY_NVME}p1" /mnt/boot

# SWAP 활성화 (첫 번째 디스크만)
swapon "${PRIMARY_NVME}p2"

# 8. 미러 설정 및 키링 업데이트
log "패키지 미러 설정 중..."
reflector --country Germany,France --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
pacman -Sy --noconfirm archlinux-keyring

# 9. 기본 시스템 설치
log "기본 시스템 설치 중..."
pacstrap /mnt base base-devel linux linux-firmware btrfs-progs intel-ucode

# 10. fstab 생성
log "fstab 생성 중..."
genfstab -U /mnt >> /mnt/etc/fstab

# 추가 SWAP 설정은 제거 (단일 SWAP만 사용)

# 11. chroot 환경에서 실행할 스크립트 생성
cat > /mnt/setup-chroot.sh << CHROOT_EOF
#!/bin/bash

# chroot 환경 설정 스크립트
# PRIMARY_NVME: $PRIMARY_NVME

# 색상 정의
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "\${GREEN}[CHROOT] \$1\${NC}"
}

PRIMARY_NVME="$PRIMARY_NVME"

# 시간대 설정
log "시간대 설정 중..."
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc

# 로케일 설정
log "로케일 설정 중..."
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "de_DE.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen

echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "LC_TIME=de_DE.UTF-8" >> /etc/locale.conf
echo "LC_MONETARY=de_DE.UTF-8" >> /etc/locale.conf
echo "LC_PAPER=de_DE.UTF-8" >> /etc/locale.conf
echo "LC_MEASUREMENT=de_DE.UTF-8" >> /etc/locale.conf

# 키보드 설정
echo "KEYMAP=us" > /etc/vconsole.conf

# 호스트명 설정
log "호스트명 설정 중..."
echo "nev" > /etc/hostname

# hosts 파일 설정
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   nev.localdomain nev
EOF

# 필수 패키지 설치
log "필수 패키지 설치 중..."
pacman -S --noconfirm \
    networkmanager \
    networkmanager-openvpn \
    wireless_tools \
    wpa_supplicant \
    dialog \
    os-prober \
    mtools \
    dosfstools \
    git \
    reflector \
    snapper \
    grub \
    grub-btrfs \
    efibootmgr \
    nodejs \
    npm \
    ripgrep \
    github-cli \
    nvidia-dkms \
    nvidia-utils \
    nvidia-settings \
    mesa \
    vulkan-icd-loader \
    lib32-nvidia-utils \
    lib32-mesa

# GRUB 설치 및 설정
log "GRUB 부트로더 설치 중..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

# GRUB 설정
cat > /etc/default/grub << EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX=""
GRUB_PRELOAD_MODULES="part_gpt part_msdos"
GRUB_TIMEOUT_STYLE=menu
GRUB_TERMINAL_INPUT=console
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
GRUB_DISABLE_RECOVERY=false
# BTRFS 스냅샷 부팅을 위한 설정
GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION=true
EOF

# GRUB 설정 생성
grub-mkconfig -o /boot/grub/grub.cfg

# mkinitcpio 설정 (BTRFS 지원)
log "initramfs 설정 중..."
sed -i 's/^MODULES=()/MODULES=(btrfs nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf

# initramfs 재생성
mkinitcpio -P

# 서비스 활성화
log "시스템 서비스 활성화 중..."
systemctl enable NetworkManager
systemctl enable systemd-timesyncd

# 사용자 생성
log "사용자 생성 중..."
useradd -m -G wheel,audio,video,optical,storage -s /bin/bash nev

# sudoers 설정
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

log "루트 암호 설정:"
passwd

log "사용자 'nev' 암호 설정:"
passwd nev

# Snapper 설정 및 grub-btrfs 연동
log "Snapper 설정 중..."
umount /.snapshots
rm -r /.snapshots
snapper -c root create-config /
btrfs subvolume delete /.snapshots
mkdir /.snapshots
mount -a
chmod 750 /.snapshots

# grub-btrfs 자동 업데이트 활성화
systemctl enable grub-btrfs.path

# Snapper 자동 정리 설정
cat > /etc/snapper/configs/root << EOF
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS=""
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="10"
NUMBER_LIMIT_IMPORTANT="5"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_YEARLY="0"
EOF

# 자동 스냅샷 서비스 활성화
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer

# grub-btrfs 설정 (부팅 시 스냅샷 메뉴)
systemctl enable grub-btrfs.path
# 스냅샷 생성될 때마다 GRUB 메뉴 자동 업데이트

# paru 설치 (chroot 환경에 맞게 수정)
log "paru AUR 헬퍼 설치 중..."
cd /tmp
git clone https://aur.archlinux.org/paru.git
chown -R nev:nev /tmp/paru
cd paru
runuser -l nev -c "cd /tmp/paru && makepkg -si --noconfirm"

log "chroot 설정 완료!"
CHROOT_EOF

# chroot 스크립트 실행 권한 부여
chmod +x /mnt/setup-chroot.sh

log "chroot 환경으로 전환하여 시스템 설정을 완료합니다..."
arch-chroot /mnt ./setup-chroot.sh

# chroot 스크립트 정리
rm /mnt/setup-chroot.sh

# 13. niri 설치 준비 스크립트 생성 (사용자가 부팅 후 실행)
cat > /mnt/home/nev/install-niri.sh << 'NIRI_EOF'
#!/bin/bash

# niri 및 dotfiles 설치 스크립트 (부팅 후 사용자가 실행)

log() {
    echo -e "\033[0;32m[NIRI] $1\033[0m"
}

log "niri 컴포지터 및 관련 패키지 설치 중..."

# niri 및 필수 패키지 설치
paru -S --noconfirm \
    niri \
    waybar \
    wofi \
    mako \
    grim \
    slurp \
    wl-clipboard \
    swayidle \
    swaylock \
    xdg-desktop-portal-wlr \
    qt5-wayland \
    qt6-wayland \
    firefox \
    alacritty \
    thunar \
    pipewire \
    pipewire-pulse \
    pipewire-alsa \
    wireplumber

# dotfiles 클론 및 적용
log "niri-dots 클론 중..."
cd ~
git clone https://github.com/shreyas-sha3/niri-dots.git
cd niri-dots

log "dotfiles 적용을 위해 스크립트를 확인하세요:"
ls -la

echo "==================================================="
echo "자동 설치 완료!"
echo "==================================================="
echo "다음 단계를 수동으로 진행하세요:"
echo "1. 시스템 재부팅"
echo "2. nev 사용자로 로그인"
echo "3. ~/install-niri.sh 실행"
echo "4. niri-dots 설정 적용"
echo "5. fcitx5 한국어 입력기 설정 (선택사항)"
echo "==================================================="
NIRI_EOF

chmod +x /mnt/home/nev/install-niri.sh
chown 1000:1000 /mnt/home/nev/install-niri.sh

# fcitx5 설치 스크립트 생성 (선택사항)
cat > /mnt/home/nev/install-fcitx5.sh << 'FCITX_EOF'
#!/bin/bash

# fcitx5 한국어 입력기 설치 (선택사항)
# 2024 최신 Wayland 환경에 최적화됨

echo "fcitx5 한국어 입력기 설치 중..."
paru -S --noconfirm \
    fcitx5-im \
    fcitx5-hangul \
    fcitx5-configtool

# systemd user 환경 변수 설정 (최신 방식)
mkdir -p ~/.config/environment.d
cat > ~/.config/environment.d/fcitx5.conf << EOF
# Fcitx5 환경 변수 (Wayland 최적화)
# XWayland 앱용으로만 설정 (순수 Wayland 앱은 text-input 프로토콜 사용)
XMODIFIERS=@im=fcitx

# Qt/GTK IM 모듈은 Wayland에서는 설정하지 않음
# (text-input 프로토콜을 우선 사용하도록)
EOF

# 자동 시작 설정
mkdir -p ~/.config/autostart
cp /usr/share/applications/org.fcitx.Fcitx5.desktop ~/.config/autostart/

echo "=============================="
echo "fcitx5 설치 완료!"
echo "=============================="
echo "다음 단계:"
echo "1. 재부팅 또는 재로그인"
echo "2. niri에서 Virtual Keyboard를 fcitx5로 설정"
echo "3. fcitx5-configtool로 한국어 입력 추가"
echo ""
echo "참고: Wayland 환경에서는 text-input 프로토콜을 우선 사용합니다."
echo "문제 발생 시 fcitx5-diagnose 명령으로 진단하세요."
FCITX_EOF

chmod +x /mnt/home/nev/install-fcitx5.sh
chown 1000:1000 /mnt/home/nev/install-fcitx5.sh

log "설치 완료!"
echo "=============================="
echo "설치가 완료되었습니다!"
echo "=============================="
echo "다음 단계:"
echo "1. 'umount -R /mnt' 실행"
echo "2. 'reboot' 실행"
echo "3. 부팅 후 nev 계정으로 로그인"
echo "4. '~/install-niri.sh' 실행"
echo "5. niri-dots 적용"
echo "=============================="
