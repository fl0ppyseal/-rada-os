#!/usr/bin/env bash
# =============================================================================
#  build-rada-os.sh — Rada OS (Верховна Рада Edition) live-build автоматизація
#  Debian 12 "bookworm" • amd64 • KDE Plasma (або XFCE) • uk_UA.UTF-8 • hybrid ISO
#
#  Використання:
#     ./build-rada-os.sh [--clean] [--with-installer] [--qemu] [--files-only] [--no-backports] [--xfce]
#     (типово: KDE Plasma + новіше ядро з bookworm-backports; --xfce — легший варіант)
#
#  Змінні середовища (необов'язкові):
#     RADA_WORKDIR      каталог збірки         (типово ./rada-os-build)
#     RADA_OUTDIR       куди покласти ISO      (типово поточний каталог)
#     RADA_MIRROR       дзеркало Debian        (типово http://deb.debian.org/debian/)
#     RADA_COMPRESSION  xz | zstd | gzip       (типово xz)
#     RADA_VERSION      рядок версії           (типово YYYY.MM.DD)
# =============================================================================
set -Eeuo pipefail
trap 'echo -e "\n\e[1;31m[ПОМИЛКА]\e[0m збій на рядку $LINENO (код $?)" >&2' ERR

VERSION="${RADA_VERSION:-$(date +%Y.%m.%d)}"
WORK="${RADA_WORKDIR:-$PWD/rada-os-build}"
OUT="${RADA_OUTDIR:-$PWD}"
MIRROR="${RADA_MIRROR:-http://deb.debian.org/debian/}"
COMPRESSION="${RADA_COMPRESSION:-xz}"
WITH_INSTALLER=0; CLEAN=0; RUN_QEMU=0; FILES_ONLY=0; BACKPORTS=1; DESKTOP=plasma

info() { echo -e "\e[1;34m[РАДА]\e[0m $*"; }
warn() { echo -e "\e[1;33m[УВАГА]\e[0m $*" >&2; }
die()  { echo -e "\e[1;31m[СТОП]\e[0m $*" >&2; exit 1; }

# safe_clean — спочатку відмонтовує все під $WORK (залишки chroot-монтувань), потім видаляє
safe_clean() {
  if [[ -d "$WORK" ]]; then
    local m
    while read -r m; do
      [[ -n "$m" ]] && { umount -l "$m" 2>/dev/null || true; }
    done < <(findmnt -rn -o TARGET 2>/dev/null | grep -F "$WORK/" | sort -r || true)
    if findmnt -rn -o TARGET 2>/dev/null | grep -qF "$WORK/"; then
      die "Під $WORK досі є змонтовані каталоги — перезавантажтесь і повторіть."
    fi
    rm -rf "$WORK"
  fi
}

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    --clean)           CLEAN=1 ;;
    --with-installer)  WITH_INSTALLER=1 ;;
    --qemu)            RUN_QEMU=1 ;;
    --files-only)      FILES_ONLY=1 ;;
    --no-backports)    BACKPORTS=0 ;;
    --xfce)            DESKTOP=xfce ;;
    -h|--help)         usage ;;
    *) die "Невідомий параметр: $arg (див. --help)" ;;
  esac
done

INC="$WORK/config/includes.chroot"
PKG="$WORK/config/package-lists"
HOOKS="$WORK/config/hooks/live"

# install_file <шлях> <права> — читає вміст зі stdin
install_file() {
  local dest="$1" mode="$2"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest"
  chmod "$mode" "$dest"
}

# desktop_entry <файл> <назва> <опис> <команда-в-терміналі> <іконка>
desktop_entry() {
  local file="$1" name="$2" comment="$3" cmd="$4" icon="$5"
  mkdir -p "$(dirname "$file")"
  {
    echo "[Desktop Entry]"
    echo "Version=1.0"
    echo "Type=Application"
    echo "Name=$name"
    echo "Comment=$comment"
    if [[ $DESKTOP == plasma ]]; then
      echo "Exec=konsole --hold -e bash -c \"$cmd\""
    else
      echo "Exec=xfce4-terminal --hold -T \"$name\" -x bash -c \"$cmd\""
    fi
    echo "Icon=$icon"
    echo "Terminal=false"
    echo "StartupNotify=false"
    echo "Categories=Utility;"
  } > "$file"
  chmod 755 "$file"
}

# -----------------------------------------------------------------------------
# 0. Права та залежності хоста
# -----------------------------------------------------------------------------
require_root() {
  if [[ $EUID -ne 0 ]]; then
    info "Потрібні права root — перезапускаю через sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

check_deps() {
  info "Перевіряю залежності хоста..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      live-build debootstrap xorriso squashfs-tools debian-archive-keyring \
      syslinux syslinux-common isolinux grub-pc-bin grub-efi-amd64-bin \
      mtools dosfstools cpio rsync ca-certificates
  else
    die "Потрібен хост на базі Debian/Ubuntu/Kali (apt-get не знайдено)."
  fi

  command -v lb >/dev/null 2>&1 || die "Команда 'lb' (live-build) не знайдена."
  info "live-build: $(lb --version 2>/dev/null || echo '?')"

  # Старі Ubuntu не знають про bookworm у debootstrap
  if [[ ! -e /usr/share/debootstrap/scripts/bookworm ]]; then
    warn "debootstrap не має сценарію для bookworm — створюю симлінк на sid."
    ln -s sid /usr/share/debootstrap/scripts/bookworm
  fi

  # Каталог збірки не повинен бути на noexec/nodev файловій системі
  mkdir -p "$WORK"
  local opts
  opts="$(findmnt -no OPTIONS -T "$WORK" 2>/dev/null || true)"
  if [[ "$opts" == *noexec* || "$opts" == *nodev* ]]; then
    die "Каталог $WORK змонтований з noexec/nodev. Вкажіть інший RADA_WORKDIR."
  fi
}

# -----------------------------------------------------------------------------
# 1. lb config
# -----------------------------------------------------------------------------
run_lb_config() {
  info "Налаштовую live-build (bookworm / amd64 / XFCE / uk_UA)..."
  cd "$WORK"
  lb config \
    --distribution bookworm \
    --architectures amd64 \
    --linux-flavours amd64 \
    --archive-areas "main contrib non-free non-free-firmware" \
    --mirror-bootstrap "$MIRROR" \
    --mirror-chroot "$MIRROR" \
    --mirror-binary "$MIRROR" \
    --security true \
    --updates true \
    --apt-recommends true \
    --chroot-squashfs-compression-type "$COMPRESSION" \
    --memtest none \
    --image-name "rada-os" \
    --iso-application "Rada OS" \
    --iso-publisher "Rada OS Project; meme edition" \
    --iso-volume "RADA_OS_${VERSION//./}" \
    --bootappend-live "boot=live components locales=uk_UA.UTF-8 keyboard-layouts=ua,us keyboard-options=grp:alt_shift_toggle"
}

# -----------------------------------------------------------------------------
# 2. Списки пакунків
# -----------------------------------------------------------------------------
write_package_lists() {
  info "Пишу списки пакунків (стільниця: $DESKTOP)..."
  install_file "$PKG/rada-common.list.chroot" 644 <<'EOF'
# --- Локалізація, шрифти, клавіатура, консоль ---
# (console-data прибрано з Debian 12 — його роль виконують kbd + console-setup)
task-ukrainian
task-ukrainian-desktop
locales
console-setup
console-setup-linux
keyboard-configuration
kbd
xdg-user-dirs
fonts-dejavu
fonts-dejavu-extra
fonts-noto-core
fonts-noto-ui-core
fonts-noto-color-emoji
fonts-firacode
xfonts-terminus

# --- Інструменти та оболонки ---
sudo
zsh
zsh-autosuggestions
zsh-syntax-highlighting
bash-completion
htop
nano
vim
git
curl
wget
figlet
lolcat
neofetch
libglib2.0-bin

# --- Зручності в стилі Ubuntu: магазин, драйвери, захист, бекапи, кодеки ---
flatpak
synaptic
gparted
timeshift
vlc
vlc-l10n
ffmpeg
libavcodec-extra
ufw
nvidia-detect
cups
bluez
network-manager

# --- Мікропрограми та гостьові доповнення ---
firmware-linux
firmware-iwlwifi
firmware-realtek
firmware-atheros
qemu-guest-agent
spice-vdagent
open-vm-tools-desktop
EOF

  if [[ $DESKTOP == plasma ]]; then
    install_file "$PKG/rada-plasma.list.chroot" 644 <<'EOF'
# --- KDE Plasma ---
task-kde-desktop
sddm
konsole
plasma-discover
plasma-discover-backend-flatpak
kde-config-flatpak
plasma-firewall
partitionmanager
print-manager
bluedevil
breeze-gtk-theme
kde-config-gtk-style
librsvg2-bin
EOF
  else
    install_file "$PKG/rada-xfce.list.chroot" 644 <<'EOF'
# --- XFCE ---
task-xfce-desktop
lightdm
lightdm-gtk-greeter
xfce4-goodies
xfce4-terminal
mousepad
network-manager-gnome
arc-theme
papirus-icon-theme
librsvg2-bin
EOF
  fi

  if [[ $WITH_INSTALLER -eq 1 ]]; then
    install_file "$PKG/rada-installer.list.chroot" 644 <<'EOF'
calamares
calamares-settings-debian
EOF
  fi
}

# Новіше ядро та мікропрограми з bookworm-backports (потрібне для свіжих ноутбуків)
write_backports() {
  info "Підключаю bookworm-backports (ядро 6.x+ та firmware)..."
  install_file "$WORK/config/archives/bookworm-backports.list.chroot" 644 <<EOF
deb ${MIRROR} bookworm-backports main contrib non-free non-free-firmware
EOF
  install_file "$WORK/config/archives/bookworm-backports.pref.chroot" 644 <<'EOF'
Package: linux-image-* linux-base firmware-*
Pin: release n=bookworm-backports
Pin-Priority: 600
EOF
}

# -----------------------------------------------------------------------------
# 3. includes.chroot — конфіги, утиліти, шпалери, ярлики
# -----------------------------------------------------------------------------
write_includes() {
  info "Пишу includes.chroot (локалізація, утиліти, оформлення)..."

  # ---- 3.1 Локалізація -------------------------------------------------------
  install_file "$INC/etc/default/locale" 644 <<'EOF'
LANG=uk_UA.UTF-8
LC_ALL=uk_UA.UTF-8
EOF

  install_file "$INC/etc/locale.gen" 644 <<'EOF'
en_US.UTF-8 UTF-8
uk_UA.UTF-8 UTF-8
EOF

  install_file "$INC/etc/default/keyboard" 644 <<'EOF'
# KEYBOARD CONFIGURATION FILE — Rada OS
XKBMODEL="pc105"
XKBLAYOUT="ua,us"
XKBVARIANT=","
XKBOPTIONS="grp:alt_shift_toggle"
BACKSPACE="guess"
EOF

  install_file "$INC/etc/default/console-setup" 644 <<'EOF'
# CONFIGURATION FILE FOR SETUPCON — Rada OS
ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="CyrKoi"
FONTFACE="Terminus"
FONTSIZE="16"
VIDEOMODE=
EOF

  # Параметри live-config (користувач, ім'я хоста, часовий пояс)
  install_file "$INC/etc/live/config.conf.d/rada.conf" 644 <<'EOF'
LIVE_USERNAME="deputat"
LIVE_USER_FULLNAME="Народний депутат"
LIVE_HOSTNAME="verkhovna-rada"
LIVE_TIMEZONE="Europe/Kyiv"
LIVE_LOCALES="uk_UA.UTF-8"
LIVE_KEYBOARD_LAYOUTS="ua,us"
LIVE_KEYBOARD_OPTIONS="grp:alt_shift_toggle"
EOF

  printf '%s\n' "$VERSION" | install_file "$INC/etc/rada-version" 644
  printf '%s\n' "$DESKTOP" | install_file "$INC/etc/rada-desktop" 644

  # ---- 3.2 Спільний файл оболонки: аліаси + промпт + MOTD --------------------
  install_file "$INC/etc/rada/rada-shell.sh" 644 <<'EOF'
# Rada OS — спільні налаштування для bash та zsh (підключається з bash.bashrc / zshrc)
case $- in *i*) ;; *) return 0 2>/dev/null ;; esac

# ---- Аліаси -----------------------------------------------------------------
# Привілеї
#   potuzhnist — окремий скрипт-обгортка над sudo (/usr/local/bin/potuzhnist)
# Пакунки
alias pryiniaty='potuzhnist apt install'
alias skasuvaty='potuzhnist apt purge'
alias pererahuvaty='potuzhnist apt update'
alias modernizatsiia='potuzhnist apt upgrade'
# Процеси та система
alias pozbavyty-mandatu='kill -9'
alias deputaty='htop'
alias novyi-sklykannya='potuzhnist systemctl reboot'
alias zakryty-zasidannya='potuzhnist systemctl poweroff'
alias pererva='systemctl suspend'
# Редактори та файли
alias zakonoproekt='nano'
alias konstytutsiya='vim'
alias rada-log='git'
alias tribuna='cd ~'
alias zvit='ls -lah'
alias spysok='cat'
alias chystyty-spysok='clear'
# Дрібниці
alias grep='grep --color=auto'
alias ls='ls --color=auto'
# Корисні скорочення
alias prybyraty='potuzhnist apt autoremove'
alias poshuk='apt search'
alias vidomosti='apt show'
alias merezha='ip -br -c a'
alias pamiat='free -h'
alias dysk='df -h'
alias zviazok='ping -c 4'
alias chas='date "+%A, %d.%m.%Y %H:%M"'

# ---- Промпт -----------------------------------------------------------------
_rada_role="ДЕПУТАТ"
[ "$(id -u)" -eq 0 ] && _rada_role="СПІКЕР"

if [ -n "${ZSH_VERSION:-}" ]; then
  PROMPT="%F{33}╔═[%F{220}${_rada_role}:%n%F{33}]─[%F{220}%~%F{33}]"$'\n'"╚═╡%F{220}ВР-УКРАЇНИ%F{33}╞═▶ %f"
elif [ -n "${BASH_VERSION:-}" ]; then
  _b='\[\e[1;34m\]'; _y='\[\e[1;33m\]'; _r='\[\e[0m\]'
  PS1="${_b}╔═[${_y}${_rada_role}:\u${_b}]─[${_y}\w${_b}]\n╚═╡${_y}ВР-УКРАЇНИ${_b}╞═▶ ${_r}"
  unset _b _y _r
  HISTCONTROL=ignoredups:erasedups
  HISTSIZE=5000
  shopt -s histappend checkwinsize 2>/dev/null
  if ! shopt -oq posix && [ -r /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  fi
fi
unset _rada_role

# ---- Банер (лише у не-логін оболонках: у логін-оболонках працює /etc/motd) ---
_rada_login=0
if [ -n "${BASH_VERSION:-}" ]; then
  shopt -q login_shell && _rada_login=1
elif [ -n "${ZSH_VERSION:-}" ]; then
  [[ -o login ]] && _rada_login=1
fi
if [ "$_rada_login" -eq 0 ] && [ -z "${RADA_MOTD_SHOWN:-}" ] && [ -x /usr/local/bin/rada-motd ]; then
  export RADA_MOTD_SHOWN=1
  /usr/local/bin/rada-motd
fi
unset _rada_login
EOF

  # .zshrc, щоб zsh не запускав майстер першого налаштування
  install_file "$INC/etc/skel/.zshrc" 644 <<'EOF'
# Rada OS — базовий ~/.zshrc
HISTFILE=~/.zsh_history
HISTSIZE=5000
SAVEHIST=5000
setopt SHARE_HISTORY HIST_IGNORE_DUPS
autoload -Uz compinit && compinit -u
[ -r /etc/rada/rada-shell.sh ] && . /etc/rada/rada-shell.sh
for _p in /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
          /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh; do
  [ -r "$_p" ] && . "$_p"
done
unset _p
EOF

  # ---- 3.3 Утиліти в /usr/local/bin ------------------------------------------
  install_file "$INC/usr/local/bin/potuzhnist" 755 <<'EOF'
#!/usr/bin/env bash
# potuzhnist — потужна обгортка над sudo
if [[ $# -eq 0 ]]; then
  echo "Використання: potuzhnist <команда> [аргументи]   (обгортка над sudo)"
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo -e "\e[1;33m⚡ ПОТУЖНІСТЬ активовано. Підвищуємо повноваження...\e[0m" >&2
  exec /usr/bin/sudo "$@"
else
  exec "$@"
fi
EOF

  install_file "$INC/usr/local/bin/holosuvaty" 755 <<'EOF'
#!/usr/bin/env bash
# holosuvaty — симулятор голосування у Верховній Раді
# Використання: holosuvaty "Про заборону понеділків"   (RADA_FAST=1 — без пауз)
B=$'\e[1;34m'; Y=$'\e[1;33m'; G=$'\e[1;32m'; R=$'\e[1;31m'; W=$'\e[1;37m'; D=$'\e[0m'
nap() { [[ -n "${RADA_FAST:-}" ]] || sleep "$1"; }
bar() { # bar <значення> <максимум> <колір>
  local v=$1 m=$2 c=$3 n i s=""
  n=$(( v * 40 / m ))
  for ((i=0; i<40; i++)); do (( i < n )) && s+="█" || s+="░"; done
  printf '%s%s%s' "$c" "$s" "$D"
}

if [[ $# -lt 1 ]]; then
  echo "${Y}Використання:${D} holosuvaty \"питання для голосування\""
  echo "Приклад:     holosuvaty \"Про безкоштовну каву для всіх\""
  exit 1
fi
issue="$*"

echo
echo "${B}════════════════════════════════════════════════════${D}"
echo "${Y}   ЗАСІДАННЯ ВЕРХОВНОЇ РАДИ — РЕЖИМ ГОЛОСУВАННЯ${D}"
echo "${B}════════════════════════════════════════════════════${D}"
echo "${W}Питання на голосування:${D} ${issue}"
echo "Для ухвалення необхідно ${Y}226${D} голосів з 450."
echo
echo "Депутати вставляють картки (по одній... або по кілька)..."
nap 1
for i in 5 4 3 2 1; do
  printf '\r%sГолосуємо через %s...%s  ' "$Y" "$i" "$D"
  nap 1
done
printf '\r%sГОЛОСУЄМО!%s                    \n\n' "$G" "$D"

za=312; proty=0; utr=12; nehol=$(( 450 - za - proty - utr ))
printf '%sЗА:%s          %3d  ' "$G" "$D" "$za";     bar "$za" 450 "$G";  echo; nap 0.6
printf '%sПРОТИ:%s       %3d  ' "$R" "$D" "$proty";  bar "$proty" 450 "$R"; echo; nap 0.6
printf '%sУТРИМАЛИСЬ:%s  %3d  ' "$Y" "$D" "$utr";    bar "$utr" 450 "$Y";  echo; nap 0.6
printf '%sНЕ ГОЛОСУВАЛИ:%s %d  (пішли на каву)\n' "$W" "$D" "$nehol"
echo
echo "${W}ЗА: ${za}${D} | ${W}ПРОТИ: ${proty}${D} | ${W}УТРИМАЛИСЬ: ${utr}${D}"
nap 1
echo
printf '\a'
echo -e "\e[1;30;43m  РІШЕННЯ ПРИЙНЯТО! Потужно.  \e[0m"
echo
EOF

  install_file "$INC/usr/local/bin/tribuna-fight" 755 <<'EOF'
#!/usr/bin/env bash
# tribuna-fight — генератор парламентського хаосу (усі події вигадані)
Y=$'\e[1;33m'; B=$'\e[1;34m'; R=$'\e[1;31m'; D=$'\e[0m'
nap() { [[ -n "${RADA_FAST:-}" ]] || sleep "${1:-0.8}"; }

events=(
  "Президію заблоковано: спікер намагається пробитися крізь живий ланцюг"
  "У залі спрацювала димова шашка. Вентиляція відмовляється співпрацювати"
  "Мікрофон на трибуні зламано. Тепер усі кричать без підсилення"
  "Депутат зайняв трибуну і заявив, що піде звідти не раніше ранку"
  "Розбіжності щодо порядку денного вирішують... фізкультурою"
  "Хтось відніс Регламент у буфет. Повернути обіцяють після обіду"
  "Кнопка «ПРОТИ» застрягла і голосує самостійно"
  "Дзвоник спікера дзвенить уже п'ять хвилин — ніхто не помічає"
  "Табличка «Тиша в залі» втратила юридичну силу"
  "Двоє депутатів обговорюють поправку. Іншим двом доводиться їх розтягувати"
  "Оголошено перерву на п'ять хвилин. Перерва триває до наступного скликання"
  "У залі вимкнули світло. Дискусія продовжується, стало лише потужніше"
  "Хтось приніс на трибуну банку огірків «для аргументації»"
  "Три сектори одночасно кричать «Ганьба!» — система розпізнавання не витримала"
  "Комітет з регламенту: «Це не бійка, це дискусія з елементами контакту»"
  "Виявлено, що один депутат тримає в руках аж три картки для голосування"
)

echo
echo "${B}━━━━━━━━━━  ПРЯМЕ ВКЛЮЧЕННЯ З СЕСІЙНОЇ ЗАЛИ  ━━━━━━━━━━${D}"
echo
n=7
while IFS= read -r ev; do
  ts=$(printf '%02d:%02d:%02d' $((RANDOM % 24)) $((RANDOM % 60)) $((RANDOM % 60)))
  echo "${Y}[${ts}]${D} ${R}⚠${D} ${ev}"
  nap 0.9
done < <(printf '%s\n' "${events[@]}" | shuf -n "$n")
echo
echo "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
echo "${Y}Засідання перенесено. Рівень потужності: ПІДВИЩЕНО.${D}"
echo "Порада: виконайте ${Y}kava${D}, щоб заспокоїти нерви."
echo
EOF

  install_file "$INC/usr/local/bin/kava" 755 <<'EOF'
#!/usr/bin/env bash
# kava — симулятор парламентського буфету (ціни мемні й умовні)
Y=$'\e[1;33m'; B=$'\e[1;34m'; G=$'\e[1;32m'; W=$'\e[1;37m'; D=$'\e[0m'
nap() { [[ -n "${RADA_FAST:-}" ]] || sleep "$1"; }

echo
padr() { local s="$1" w=$2; printf '%s' "$s"; (( w > ${#s} )) && printf '%*s' $(( w - ${#s} )) ''; return 0; }
line() { printf ' '; padr "$1" 26; printf ' %6s грн\n' "$2"; }
echo "${B}╔══════════════════════════════════════════════╗${D}"
echo "${B}║${Y}        ПАРЛАМЕНТСЬКИЙ БУФЕТ — МЕНЮ           ${B}║${D}"
echo "${B}╚══════════════════════════════════════════════╝${D}"
echo " 1. Бутерброд з лососем ........... 12.00 грн"
echo " 2. Чай (чорний, з лимоном) ........ 3.00 грн"
echo " 3. Борщ з пампушкою ............... 9.00 грн"
echo " 4. Кава «Потужна» ................. 5.00 грн"
echo " ${W}(ціни умовні — це мем, у реальності буфет давно інший)${D}"
echo

extras=("Чай чорний з лимоном|3.00" "Борщ з пампушкою|9.00" "Кава «Потужна»|5.00" "Компот із сухофруктів|2.50")
pick="${extras[RANDOM % ${#extras[@]}]}"
extra_name="${pick%%|*}"; extra_price="${pick##*|}"

echo "Замовляємо: ${Y}бутерброд з лососем${D} та ${Y}${extra_name}${D}."
frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
steps=40; [[ -n "${RADA_FAST:-}" ]] && steps=3
for ((i=0; i<steps; i++)); do
  printf '\r%s %s Буфетниця нарізає лосося...%s ' "$Y" "${frames[i % 10]}" "$D"
  [[ -n "${RADA_FAST:-}" ]] || sleep 0.1
done
printf '\r%-50s\n' "${G}✔ Готово!${D}"
echo
total=$(awk -v a=12.00 -v b="$extra_price" 'BEGIN{printf "%.2f", a+b}')
echo "${W}───────────── ЧЕК ─────────────${D}"
line "Бутерброд з лососем" "12.00"
line "$extra_name" "$extra_price"
line "РАЗОМ" "$total"
echo "${W}────────────────────────────────${D}"
echo "Решти немає, зате є ${Y}потужність${D}. Смачного!"
echo
EOF

  install_file "$INC/usr/local/bin/radar-scan" 755 <<'EOF'
#!/usr/bin/env bash
# radar-scan — мем-діагностика «рівня потужності» та залізних показників
B=$'\e[1;34m'; Y=$'\e[1;33m'; G=$'\e[1;32m'; R=$'\e[1;31m'; W=$'\e[1;37m'; D=$'\e[0m'

cpu_model=$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo)
cores=$(nproc)
mem_total_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
mem_avail_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
load=$(cut -d' ' -f1-3 /proc/loadavg)
up_s=$(cut -d. -f1 /proc/uptime)
disk=$(df -h / | awk 'NR==2{print $3" / "$2" ("$5")"}')
temp="н/д"
for z in /sys/class/thermal/thermal_zone*/temp; do
  [[ -r "$z" ]] && { temp="$(( $(<"$z") / 1000 )) °C"; break; }
done

power=$(( cores * 250 + mem_total_kb / 16384 + RANDOM % 100 ))
if   (( power >= 4000 )); then verdict="${G}ПОТУЖНІСТЬ ЗАШКАЛЮЄ! Це вже не комп'ютер, це фракція.${D}"
elif (( power >= 1500 )); then verdict="${G}ПОТУЖНО! Можна ухвалювати закони в першому читанні.${D}"
elif (( power >= 600  )); then verdict="${Y}Нормально, працюємо. Потужність — в межах регламенту.${D}"
else                           verdict="${R}Слабенько. Потрібна реформа... і, мабуть, більше RAM.${D}"
fi
filled=$(( power / 100 )); (( filled > 30 )) && filled=30
meter=""; for ((i=0; i<30; i++)); do (( i < filled )) && meter+="█" || meter+="░"; done

echo
echo "${B}╔═══════════════════ RADAR-SCAN ═══════════════════╗${D}"
printf '%s ⚡ Рівень потужності:%s %d  %s%s%s\n' "$Y" "$D" "$power" "$Y" "$meter" "$D"
echo "   Висновок: $verdict"
echo "${B}╠═══════════════════════════════════════════════════╣${D}"
printf ' %sПроцесор :%s %s\n' "$W" "$D" "${cpu_model:-невідомо}"
printf ' %sМандатів (ядер) :%s %s\n' "$W" "$D" "$cores"
printf ' %sПам'"'"'ять  :%s %d МБ вільно з %d МБ\n' "$W" "$D" $((mem_avail_kb/1024)) $((mem_total_kb/1024))
printf ' %sНавантаження :%s %s\n' "$W" "$D" "$load"
printf ' %sДиск (/) :%s %s\n' "$W" "$D" "$disk"
printf ' %sТемпература :%s %s\n' "$W" "$D" "$temp"
printf ' %sУ роботі :%s %d год %d хв\n' "$W" "$D" $((up_s/3600)) $((up_s%3600/60))
echo "${B}╚═══════════════════════════════════════════════════╝${D}"
echo
EOF

  install_file "$INC/usr/local/bin/zakon-generator" 755 <<'EOF'
#!/usr/bin/env bash
# zakon-generator — вигадує законопроєкти (усе вигадано, збіги випадкові)
# Використання: zakon-generator [кількість]
Y=$'\e[1;33m'; B=$'\e[1;34m'; D=$'\e[0m'
pre=("Про внесення змін до закону про" "Про всебічне забезпечення" "Про державну підтримку" "Про тимчасову заборону" "Про сталий розвиток" "Про запровадження" "Про скасування")
sub=("потужності" "буфетних бутербродів" "понеділків" "трибун та мікрофонів" "кнопок для голосування" "кави в сесійній залі" "перемоги" "перерв на каву" "регламенту, який ніхто не читав")
suf=("(у першому читанні, надовго)" "(з поправками від усіх фракцій)" "(термінове, але не дуже)" "(в цілому та потужно)" "(повторне друге читання)" "(із застереженням «на всякий випадок»)")
count="${1:-3}"
echo
for ((i=0; i<count; i++)); do
  num=$(( 1000 + RANDOM % 9000 ))
  echo "${B}Законопроєкт №${num}${D}"
  echo "  ${Y}«${pre[RANDOM % ${#pre[@]}]} ${sub[RANDOM % ${#sub[@]}]}»${D}"
  echo "  ${suf[RANDOM % ${#suf[@]}]}"
  echo
done
EOF

  install_file "$INC/usr/local/bin/mandat" 755 <<'EOF'
#!/usr/bin/env bash
# mandat — депутатське посвідчення (дані про вашу систему)
B=$'\e[1;34m'; Y=$'\e[1;33m'; W=$'\e[1;37m'; D=$'\e[0m'
user="${USER:-$(id -un)}"
role="ДЕПУТАТ"; [[ $EUID -eq 0 ]] && role="СПІКЕР"
fractions=("Партія Потужності" "Блок Буфетних Реформ" "Фракція Вільної Кави" "Група «Перерва»" "Об'єднання Кнопкодавів" "Союз Регламентників")
sum=$(printf '%s' "$user" | cksum | cut -d' ' -f1)
fr="${fractions[sum % ${#fractions[@]}]}"
num=$(printf '%08d' $(( sum % 100000000 )))
up_s=$(cut -d. -f1 /proc/uptime)
rep() { local s="" i; for ((i=0; i<$1; i++)); do s+="$2"; done; printf '%s' "$s"; }
padr() { local s="$1" w=$2; printf '%s' "$s"; (( w > ${#s} )) && printf '%*s' $(( w - ${#s} )) ''; return 0; }
row() { printf '%s║%s ' "$B" "$D"; padr "$1" 16; printf ' %s' "$Y"; padr "$2" 32; printf '%s%s║%s\n' "$D" "$B" "$D"; }
echo
printf '%s╔%s%s ПОСВІДЧЕННЯ ДЕПУТАТА %s%s╗%s\n' "$B" "$(rep 15 ═)" "$Y" "$B" "$(rep 13 ═)" "$D"
row "Ім'я"       "$user"
row "Посада"      "$role"
row "Фракція"     "$fr"
row "Картка №"    "$num"
row "Округ"       "$(hostname)"
row "Ядро"        "$(uname -r)"
row "Оболонка"    "$(basename "${SHELL:-bash}")"
row "Стаж"        "$(printf '%d год %d хв' $((up_s/3600)) $((up_s%3600/60)))"
printf '%s╚%s╝%s\n' "$B" "$(rep 50 ═)" "$D"
echo "${W}Дійсне до наступного перезавантаження. Потужно.${D}"
echo
EOF

  install_file "$INC/usr/local/bin/kvorum" 755 <<'EOF'
#!/usr/bin/env bash
# kvorum — перевірка кворуму у залі
B=$'\e[1;34m'; Y=$'\e[1;33m'; G=$'\e[1;32m'; R=$'\e[1;31m'; D=$'\e[0m'
nap() { [[ -n "${RADA_FAST:-}" ]] || sleep "$1"; }
total=450; need=226
present=$(( 150 + RANDOM % 290 ))
step=7; [[ -n "${RADA_FAST:-}" ]] && step=60
echo
echo "${B}══════════ ПЕРЕВІРКА КВОРУМУ ══════════${D}"
echo "Депутати вставляють картки..."
for ((n=0; n<present; n+=step)); do
  printf '\r%sЗареєстровано:%s %3d / %d' "$Y" "$D" "$n" "$total"
  nap 0.04
done
printf '\r%sЗареєстровано:%s %3d / %d    \n' "$Y" "$D" "$present" "$total"
filled=$(( present * 40 / total )); bar=""
for ((i=0; i<40; i++)); do (( i < filled )) && bar+="█" || bar+="░"; done
echo "$bar"
echo "Потрібно для кворуму: $need"
echo
if (( present >= need )); then
  echo "${G}КВОРУМ Є.${D} Можна голосувати — спробуйте: holosuvaty \"Про потужність\""
else
  echo "${R}КВОРУМУ НЕМАЄ.${D} Не вистачає $(( need - present )) депутатів. Оголошується перерва."
  echo "Рекомендовано: kava"
fi
echo
EOF

  install_file "$INC/usr/local/bin/vybory" 755 <<'EOF'
#!/usr/bin/env bash
# vybory — вибори між варіантами: vybory піца суші борщ
B=$'\e[1;34m'; Y=$'\e[1;33m'; G=$'\e[1;32m'; W=$'\e[1;37m'; D=$'\e[0m'
nap() { [[ -n "${RADA_FAST:-}" ]] || sleep "$1"; }
if [[ $# -lt 2 ]]; then
  echo "${Y}Використання:${D} vybory варіант1 варіант2 [варіант3 ...]"
  echo "Приклад:      vybory піца суші борщ"
  exit 1
fi
padr() { local s="$1" w=$2; printf '%s' "$s"; (( w > ${#s} )) && printf '%*s' $(( w - ${#s} )) ''; return 0; }
names=("$@"); n=${#names[@]}
w=(); sum=0
for ((i=0; i<n; i++)); do w[i]=$(( 5 + RANDOM % 95 )); sum=$(( sum + w[i] )); done
pct=(); acc=0
for ((i=0; i<n; i++)); do pct[i]=$(( w[i] * 100 / sum )); acc=$(( acc + pct[i] )); done
pct[0]=$(( pct[0] + 100 - acc ))
slogans=("Разом — потужніше!" "Голосуй серцем і буфетом!" "Кожен голос — як бутерброд: важливий" "Вперед, до другого читання!" "За стабільність і лосося!")
echo
echo "${B}════════════ ВИБОРИ ════════════${D}"
echo "Кандидатів: $n   Явка: $(( 55 + RANDOM % 40 ))%"
echo "Гасло дня: ${slogans[RANDOM % ${#slogans[@]}]}"
echo
for i in 1 2 3; do printf '\r%sПідрахунок голосів%s%s' "$Y" "$(printf '.%.0s' $(seq 1 $i))" "$D   "; nap 0.7; done
printf '\r%-40s\n\n' ""
first=1
while IFS='|' read -r p nm; do
  filled=$(( p * 30 / 100 )); bar=""
  for ((i=0; i<30; i++)); do (( i < filled )) && bar+="█" || bar+="░"; done
  if (( first )); then col="$G"; first=0; winner="$nm"; wp="$p"; else col="$W"; fi
  printf '%s' "$col"; padr "$nm" 18; printf '%s %3d%%  %s%s%s\n' "$D" "$p" "$col" "$bar" "$D"
  nap 0.4
done < <(for ((i=0; i<n; i++)); do printf '%d|%s\n' "${pct[i]}" "${names[i]}"; done | sort -t'|' -k1,1nr)
echo
echo -e "\e[1;30;43m  ПЕРЕМОГУ ОДЕРЖУЄ: ${winner} (${wp}%)  \e[0m"
echo
EOF

  install_file "$INC/usr/local/bin/promova" 755 <<'EOF'
#!/usr/bin/env bash
# promova — генератор депутатської промови. Використання: promova [кількість речень]
Y=$'\e[1;33m'; D=$'\e[0m'
gen=("потужності" "системного підходу" "консолідації" "виваженого регламенту" "додаткової перерви" "бутербродів з лососем" "перемоги" "кнопки для голосування")
tpl=(
  "Це питання вимагає %s."
  "Без %s ми не зможемо рухатися далі."
  "Наша фракція виступає проти відсутності %s."
  "Ми вже втретє повертаємося до питання %s."
  "Пропоную створити комітет з питань %s."
  "Не можна говорити про реформи, забуваючи про значення %s."
)
open=("Шановні колеги!" "Шановна президіє!" "Дозвольте два слова." "Колеги, я буду стислим.")
close=("Дякую за увагу." "Прошу поставити на голосування." "Регламент, на жаль, мене вже вимикає.")
count="${1:-5}"
echo
echo "${Y}${open[RANDOM % ${#open[@]}]}${D}"
for ((i=0; i<count; i++)); do
  printf "${tpl[RANDOM % ${#tpl[@]}]} " "${gen[RANDOM % ${#gen[@]}]}"
done
echo
echo "${Y}${close[RANDOM % ${#close[@]}]}${D}"
echo
EOF

  install_file "$INC/usr/local/bin/reglament" 755 <<'EOF'
#!/usr/bin/env bash
# reglament — випадкова (вигадана) стаття регламенту
Y=$'\e[1;33m'; B=$'\e[1;34m'; D=$'\e[0m'
rules=(
  "Кожен депутат має право на одну перерву на каву щогодини, а на кожну другу — за окремим голосуванням."
  "Мікрофон вимикається, коли промова перевищує обсяг, прийнятний для здорового глузду."
  "Якщо кворуму немає, його вважають таким, що вийшов на перерву."
  "Бутерброд з лососем не може бути предметом поправки."
  "Голосування чужою карткою вважається проявом колективного духу."
  "Дзвоник спікера дзвонить до першого мовчання в залі."
  "Законопроєкт, який ніхто не читав, вважається прочитаним у першому читанні."
  "Будь-яка суперечка завершується перервою; перерва завершується буфетом."
  "Трибуна належить тому, хто на ній стоїть, але лише до кінця засідання."
  "Фраза «потужно» додається до кожного рішення автоматично."
)
n=$(( 1 + RANDOM % 99 ))
echo
echo "${B}Регламент, стаття ${n}${D}"
echo "${Y}${rules[RANDOM % ${#rules[@]}]}${D}"
echo
EOF

  install_file "$INC/usr/local/bin/zasidannya" 755 <<'EOF'
#!/usr/bin/env bash
# zasidannya — таймер засідання (помодоро). Використання: zasidannya [хвилини]
Y=$'\e[1;33m'; B=$'\e[1;34m'; G=$'\e[1;32m'; D=$'\e[0m'
mins="${1:-25}"
if ! [[ "$mins" =~ ^[0-9]+$ ]] || (( mins < 1 )); then
  echo "Використання: zasidannya [хвилини]   (типово 25)"; exit 1
fi
secs=$(( mins * 60 )); [[ -n "${RADA_FAST:-}" ]] && secs=5
trap 'echo; echo "${Y}Засідання перервано. Регламент це дозволяє.${D}"; exit 130' INT
echo "${B}Засідання розпочато на ${mins} хв. Ctrl+C — перервати.${D}"
total=$secs
while (( secs > 0 )); do
  done_=$(( (total - secs) * 30 / total )); bar=""
  for ((i=0; i<30; i++)); do (( i < done_ )) && bar+="█" || bar+="░"; done
  printf '\r%s%02d:%02d%s  %s%s%s ' "$Y" $((secs/60)) $((secs%60)) "$D" "$B" "$bar" "$D"
  [[ -n "${RADA_FAST:-}" ]] || sleep 1
  (( secs-- ))
done
printf '\r%-60s\n' ""
printf '\a'; sleep 0.2; printf '\a'
echo "${G}Засідання закрито.${D} Час на каву: kava"
EOF

  install_file "$INC/usr/local/bin/rada-drivers" 755 <<'EOF'
#!/usr/bin/env bash
# rada-drivers — драйвери відеокарти (аналог «Додаткових драйверів» в Ubuntu)
Y=$'\e[1;33m'; B=$'\e[1;34m'; G=$'\e[1;32m'; D=$'\e[0m'
echo
echo "${B}══════════ ДРАЙВЕРИ ВІДЕОКАРТИ ══════════${D}"
lspci -nn | grep -Ei 'vga|3d|display' || echo "Відеоадаптерів не знайдено."
echo
if lspci | grep -qi nvidia; then
  if command -v nvidia-detect >/dev/null 2>&1; then nvidia-detect; fi
  echo
  echo "${Y}Знайдено NVIDIA.${D} Рекомендований пакунок: nvidia-driver"
  echo "У live-режимі зміни зникнуть після перезавантаження (потрібне встановлення на диск)."
  read -r -p "Встановити зараз? [т/Н] " a
  case "$a" in
    т|Т|y|Y|так) potuzhnist apt install -y nvidia-driver firmware-misc-nonfree
                 echo "${G}Готово.${D} Перезавантажтесь: novyi-sklykannya" ;;
    *)           echo "Пропущено." ;;
  esac
else
  echo "${G}NVIDIA не знайдено${D} — відкриті драйвери (mesa) вже встановлені."
fi
echo
EOF

  install_file "$INC/usr/local/bin/zakhyst" 755 <<'EOF'
#!/usr/bin/env bash
# zakhyst — простий фаєрвол (ufw). Використання: zakhyst [status|on|off]
case "${1:-status}" in
  status) potuzhnist ufw status verbose ;;
  on)     potuzhnist ufw enable ;;
  off)    potuzhnist ufw disable ;;
  *)      echo "Використання: zakhyst [status|on|off]"; exit 1 ;;
esac
EOF

  install_file "$INC/usr/local/bin/rada-help" 755 <<'EOF'
#!/usr/bin/env bash
# rada-help — довідка по всіх командах Rada OS
Y=$'\e[1;33m'; B=$'\e[1;34m'; D=$'\e[0m'
padr() { local s="$1" w=$2; printf '%s' "$s"; (( w > ${#s} )) && printf '%*s' $(( w - ${#s} )) ''; return 0; }
row() { printf '  %s' "$Y"; padr "$1" 24; printf '%s %s\n' "$D" "$2"; }
echo
echo "${B}═══════════ RADA OS — ДОВІДНИК ДЕПУТАТА ═══════════${D}"
echo "${B}Привілеї та пакунки${D}"
row potuzhnist "обгортка над sudo"
row pryiniaty "apt install"
row skasuvaty "apt purge"
row pererahuvaty "apt update"
row modernizatsiia "apt upgrade"
echo "${B}Система та процеси${D}"
row deputaty "htop"
row pozbavyty-mandatu "kill -9"
row novyi-sklykannya "перезавантаження"
row zakryty-zasidannya "вимкнення"
row pererva "режим сну"
echo "${B}Файли та редактори${D}"
row zakonoproekt "nano"
row konstytutsiya "vim"
row rada-log "git"
row tribuna "cd ~"
row zvit "ls -lah"
row spysok "cat"
row chystyty-spysok "clear"
echo "${B}Розваги${D}"
row "holosuvaty \"питання\"" "симулятор голосування"
row tribuna-fight "парламентський хаос"
row kava "буфет із бутербродами з лососем"
row radar-scan "рівень потужності та залізо"
row "zakon-generator [N]" "вигадані законопроєкти"
row rada-motd "банер з прапором"
row mandat "депутатське посвідчення"
row kvorum "перевірка кворуму"
row "vybory а б в" "вибори між варіантами"
row promova "генератор промов"
row reglament "випадкова стаття регламенту"
row "zasidannya [хв]" "таймер засідання (помодоро)"
row rada-drivers "драйвери відеокарти"
row "zakhyst [on|off]" "фаєрвол (ufw)"
echo "${B}Корисні скорочення${D}"
row prybyraty "apt autoremove"
row poshuk "apt search"
row vidomosti "apt show"
row merezha "мережеві інтерфейси"
row pamiat "використання пам'яті"
row dysk "місце на дисках"
row zviazok "ping -c 4"
row chas "дата й час"
echo
EOF

  install_file "$INC/usr/local/bin/rada-motd" 755 <<'EOF'
#!/usr/bin/env bash
# rada-motd — банер «ВЕРХОВНА РАДА LINUX» у кольорах прапора України
BLU=$'\e[38;5;27m'; YEL=$'\e[38;5;220m'; BG_B=$'\e[48;5;27m'; BG_Y=$'\e[48;5;220m'
BOLD=$'\e[1m'; RST=$'\e[0m'
cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"

declare -A G=(
  [В]="████ |█   █|████ |█   █|████ "
  [Е]="█████|█    |████ |█    |█████"
  [Р]="████ |█   █|████ |█    |█    "
  [Х]="█   █| █ █ |  █  | █ █ |█   █"
  [О]=" ███ |█   █|█   █|█   █| ███ "
  [Н]="█   █|█   █|█████|█   █|█   █"
  [А]=" ███ |█   █|█████|█   █|█   █"
  [Д]="  ███| █  █| █  █|█████|█   █"
  [L]="█    |█    |█    |█    |█████"
  [I]="█████|  █  |  █  |  █  |█████"
  [N]="█   █|██  █|█ █ █|█  ██|█   █"
  [U]="█   █|█   █|█   █|█   █| ███ "
  [X]="█   █| █ █ |  █  | █ █ |█   █"
  [_]="   |   |   |   |   "
)

# render <колір> <літери...>
render() {
  local colour=$1; shift
  local width=-2 ch r line pad
  local -a rows
  # ширина: літера = 5, пробіл = 3, між ними по 2
  for ch in "$@"; do
    if [[ $ch == _ ]]; then width=$(( width + 5 )); else width=$(( width + 7 )); fi
  done
  pad=$(( (cols - width) / 2 )); (( pad < 0 )) && pad=0
  for ((r=0; r<5; r++)); do
    line=""
    for ch in "$@"; do
      IFS='|' read -r -a rows <<< "${G[$ch]}"
      line+="${rows[r]}  "
    done
    printf '%*s%s%s%s%s\n' "$pad" '' "$BOLD" "$colour" "$line" "$RST"
  done
}

flag() { # два рядки синього та два жовтого
  local w=$(( cols > 60 ? 60 : cols - 2 )); (( w < 10 )) && w=10
  local pad=$(( (cols - w) / 2 )) s
  (( pad < 0 )) && pad=0
  printf -v s '%*s' "$w" ''
  printf '%*s%s%s%s\n' "$pad" '' "$BG_B" "$s" "$RST"
  printf '%*s%s%s%s\n' "$pad" '' "$BG_B" "$s" "$RST"
  printf '%*s%s%s%s\n' "$pad" '' "$BG_Y" "$s" "$RST"
  printf '%*s%s%s%s\n' "$pad" '' "$BG_Y" "$s" "$RST"
}

ver="$(cat /etc/rada-version 2>/dev/null || echo dev)"
echo
if (( cols >= 72 )); then
  flag
  echo
  render "$BLU" В Е Р Х О В Н А
  echo
  render "$YEL" Р А Д А _ L I N U X
  echo
  flag
else
  echo "${BG_B}  ${BG_Y}  ${RST} ${BOLD}${BLU}ВЕРХОВНА РАДА${RST} ${BOLD}${YEL}LINUX${RST}"
fi
echo
printf '  %s%s%s\n' "$BLU$BOLD" "Rada OS — Верховна Рада Edition • версія $ver" "$RST"
printf '  %s%s%s\n' "$YEL$BOLD" "Слава Україні! Потужно. Законно. Перемога." "$RST"
if [[ "${1:-}" != "--no-tip" ]]; then
  tips=("rada-help — список усіх команд" "mandat — ваше депутатське посвідчення" "kvorum — чи є кворум?" "vybory піца суші борщ — вибори на вечерю" "promova — готова промова" "reglament — випадкова стаття регламенту" "zasidannya 25 — таймер засідання" "Alt+Shift — перемкнути розкладку")
  printf '  %s▶ Порада:%s %s\n' "$YEL$BOLD" "$RST" "${tips[RANDOM % ${#tips[@]}]}"
fi
echo
EOF

  # ---- 3.4 Автозапуск сесії (шпалери + ярлики) -------------------------------
  install_file "$INC/usr/local/bin/rada-session-init" 755 <<'EOF'
#!/usr/bin/env bash
# rada-session-init — виконується при вході: ярлики на стільниці, шпалери, кольорова схема
KIND="$(cat /etc/rada-desktop 2>/dev/null || echo xfce)"
DESK="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
mkdir -p "$DESK"
for f in /usr/share/applications/rada-*.desktop; do
  [[ -e "$f" ]] || continue
  cp -n "$f" "$DESK/" 2>/dev/null || true
  chmod +x "$DESK/$(basename "$f")" 2>/dev/null || true
done

case "$KIND" in
  plasma)
    MARK="$HOME/.config/rada-session-done"
    if [[ ! -e "$MARK" ]]; then
      for _ in $(seq 1 40); do pgrep -x plasmashell >/dev/null 2>&1 && break; sleep 1; done
      sleep 4
      command -v plasma-apply-colorscheme >/dev/null 2>&1 && plasma-apply-colorscheme RadaDark >/dev/null 2>&1
      command -v plasma-apply-wallpaperimage >/dev/null 2>&1 && \
        plasma-apply-wallpaperimage /usr/share/backgrounds/rada/rada-os.png >/dev/null 2>&1
      mkdir -p "$(dirname "$MARK")"; touch "$MARK"
    fi
    ;;
  *)
    WALL=/usr/share/backgrounds/rada/rada-os.svg
    sleep 3
    while read -r p; do
      xfconf-query -c xfce4-desktop -p "$p" -s "$WALL" 2>/dev/null || true
    done < <(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep 'last-image$' || true)
    for f in "$DESK"/rada-*.desktop; do
      [[ -e "$f" ]] || continue
      gio set "$f" metadata::xfce-exe-checksum "$(sha256sum "$f" | cut -d' ' -f1)" 2>/dev/null || true
    done
    ;;
esac
exit 0
EOF

  install_file "$INC/etc/xdg/autostart/rada-session-init.desktop" 644 <<'EOF'
[Desktop Entry]
Type=Application
Name=Rada OS: ініціалізація сесії
Exec=/usr/local/bin/rada-session-init
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

  # ---- 3.5 Ярлики (меню програм + стільниця) ---------------------------------
  local A="$INC/usr/share/applications"
  desktop_entry "$A/rada-holosuvaty.desktop"     "Голосування"        "Симулятор голосування Верховної Ради" "holosuvaty 'Про потужність'" "emblem-default"
  desktop_entry "$A/rada-tribuna-fight.desktop"  "Трибуна: сутичка"   "Генератор парламентського хаосу"      "tribuna-fight"               "face-angry"
  desktop_entry "$A/rada-kava.desktop"           "Буфет (кава)"       "Бутерброди з лососем"                 "kava"                        "face-smile"
  desktop_entry "$A/rada-radar-scan.desktop"     "Радар потужності"   "Рівень потужності та стан заліза"     "radar-scan"                  "utilities-system-monitor"
  desktop_entry "$A/rada-zakon.desktop"          "Законопроєкти"      "Генератор вигаданих законопроєктів"   "zakon-generator 5"           "text-x-generic"
  desktop_entry "$A/rada-mandat.desktop"         "Моє посвідчення"    "Депутатське посвідчення"              "mandat"                      "x-office-address-book"
  desktop_entry "$A/rada-kvorum.desktop"         "Кворум"             "Перевірка кворуму"                    "kvorum"                      "system-users"
  desktop_entry "$A/rada-drivers.desktop"        "Драйвери"           "Драйвери відеокарти (як в Ubuntu)"    "rada-drivers"                "preferences-system"
  desktop_entry "$A/rada-help.desktop"           "Довідник депутата"  "Список усіх команд Rada OS"           "rada-help"                   "help-browser"

  # ---- 3.6 Шпалери -----------------------------------------------------------
  install_file "$INC/usr/share/backgrounds/rada/rada-os.svg" 644 <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#050a18"/>
      <stop offset="0.6" stop-color="#0a1a3f"/>
      <stop offset="1" stop-color="#07102a"/>
    </linearGradient>
    <radialGradient id="blue" cx="0.15" cy="0.1" r="0.7">
      <stop offset="0" stop-color="#0057B7" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#0057B7" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="gold" cx="0.85" cy="0.95" r="0.6">
      <stop offset="0" stop-color="#FFD700" stop-opacity="0.32"/>
      <stop offset="1" stop-color="#FFD700" stop-opacity="0"/>
    </radialGradient>
    <pattern id="grid" width="64" height="64" patternUnits="userSpaceOnUse">
      <path d="M64 0H0V64" fill="none" stroke="#ffffff" stroke-opacity="0.035" stroke-width="1"/>
    </pattern>
    <linearGradient id="goldline" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#FFD700" stop-opacity="0"/>
      <stop offset="0.5" stop-color="#FFD700"/>
      <stop offset="1" stop-color="#FFD700" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#bg)"/>
  <rect width="1920" height="1080" fill="url(#grid)"/>
  <rect width="1920" height="1080" fill="url(#blue)"/>
  <rect width="1920" height="1080" fill="url(#gold)"/>

  <text x="960" y="250" text-anchor="middle" font-family="Noto Sans, DejaVu Sans, sans-serif" font-weight="700" font-size="118" letter-spacing="8" fill="#FFFFFF">ВЕРХОВНА РАДА</text>
  <text x="960" y="355" text-anchor="middle" font-family="Noto Sans, DejaVu Sans, sans-serif" font-weight="700" font-size="64" letter-spacing="30" fill="#FFD700">LINUX</text>
  <rect x="560" y="385" width="800" height="3" fill="url(#goldline)"/>
  <text x="960" y="440" text-anchor="middle" font-family="Noto Sans, DejaVu Sans, sans-serif" font-size="28" letter-spacing="3" fill="#9DB6E6">Rada OS · Верховна Рада Edition</text>

  <g fill="#0d2250" stroke="#FFD700" stroke-opacity="0.38" stroke-width="2">
    <rect x="958" y="470" width="4" height="30" fill="#FFD700" stroke="none"/>
    <path d="M860 600 A100 100 0 0 1 1060 600 Z"/>
    <rect x="870" y="600" width="180" height="32"/>
    <polygon points="680,730 960,640 1240,730"/>
    <rect x="680" y="730" width="560" height="22"/>
    <rect x="700"  y="752" width="26" height="68"/>
    <rect x="770"  y="752" width="26" height="68"/>
    <rect x="840"  y="752" width="26" height="68"/>
    <rect x="910"  y="752" width="26" height="68"/>
    <rect x="984"  y="752" width="26" height="68"/>
    <rect x="1054" y="752" width="26" height="68"/>
    <rect x="1124" y="752" width="26" height="68"/>
    <rect x="1194" y="752" width="26" height="68"/>
    <rect x="640" y="820" width="640" height="16"/>
    <rect x="620" y="836" width="680" height="16"/>
  </g>

  <path d="M0 800 C 320 720 640 900 960 820 S 1600 740 1920 830 L1920 1080 L0 1080 Z" fill="#0057B7" fill-opacity="0.38"/>
  <path d="M0 880 C 360 820 700 960 1040 890 S 1640 830 1920 900 L1920 1080 L0 1080 Z" fill="#FFD700" fill-opacity="0.30"/>
  <path d="M0 960 C 400 920 760 1010 1100 960 S 1700 930 1920 975 L1920 1080 L0 1080 Z" fill="#050a18" fill-opacity="0.65"/>

  <text x="1860" y="1036" text-anchor="end" font-family="Noto Sans, DejaVu Sans, sans-serif" font-size="26" fill="#CFD8EE" fill-opacity="0.75">Потужно. Законно. Перемога.</text>
</svg>
EOF

  # ---- 3.7 Профілі терміналів (темні, у кольорах прапора) ---------------------
  if [[ $DESKTOP == plasma ]]; then
    install_file "$INC/etc/skel/.local/share/konsole/Rada.colorscheme" 644 <<'EOF'
[Background]
Color=13,17,23

[BackgroundIntense]
Color=22,27,34

[Foreground]
Color=230,237,243

[ForegroundIntense]
Color=255,255,255

[Color0]
Color=27,34,48

[Color0Intense]
Color=72,79,88

[Color1]
Color=255,107,107

[Color1Intense]
Color=255,139,139

[Color2]
Color=90,247,142

[Color2Intense]
Color=130,255,170

[Color3]
Color=255,215,0

[Color3Intense]
Color=255,230,90

[Color4]
Color=74,158,255

[Color4Intense]
Color=120,185,255

[Color5]
Color=199,146,234

[Color5Intense]
Color=220,175,245

[Color6]
Color=87,199,255

[Color6Intense]
Color=140,220,255

[Color7]
Color=223,230,238

[Color7Intense]
Color=255,255,255

[General]
Description=Rada
Opacity=1
EOF
    install_file "$INC/etc/skel/.local/share/konsole/Rada.profile" 644 <<'EOF'
[Appearance]
ColorScheme=Rada
Font=Fira Code,11,-1,5,50,0,0,0,0,0

[General]
Name=Rada
Parent=FALLBACK/

[Scrolling]
ScrollBarPosition=2
EOF
    install_file "$INC/etc/skel/.config/konsolerc" 644 <<'EOF'
[Desktop Entry]
DefaultProfile=Rada.profile
EOF
  else
    install_file "$INC/etc/skel/.config/xfce4/terminal/terminalrc" 644 <<'EOF'
[Configuration]
FontName=Fira Code 11
MiscAlwaysShowTabs=FALSE
MiscBell=FALSE
MiscMenubarDefault=FALSE
MiscDefaultGeometry=110x30
ScrollingBar=TERMINAL_SCROLLBAR_NONE
ColorForeground=#e6edf3
ColorBackground=#0d1117
ColorCursor=#ffd700
ColorPalette=#1b2230;#ff6b6b;#5af78e;#ffd700;#4a9eff;#c792ea;#57c7ff;#dfe6ee;#484f58;#ff8b8b;#82ffaa;#ffe65a;#78b9ff;#dcaff5;#8cdcff;#ffffff
EOF
  fi
}

# -----------------------------------------------------------------------------
# 4. Хуки (виконуються всередині chroot після встановлення пакунків)
# -----------------------------------------------------------------------------
write_hooks() {
  info "Пишу chroot-хуки..."

  install_file "$HOOKS/0100-rada-localisation.hook.chroot" 755 <<'EOF'
#!/bin/bash
# Локалізація: uk_UA.UTF-8, клавіатура ua,us, часовий пояс Київ
set -e
export DEBIAN_FRONTEND=noninteractive

cat <<'SEL' | debconf-set-selections
locales locales/default_environment_locale select uk_UA.UTF-8
locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8, uk_UA.UTF-8 UTF-8
keyboard-configuration keyboard-configuration/layoutcode string ua,us
keyboard-configuration keyboard-configuration/optionscode string grp:alt_shift_toggle
tzdata tzdata/Areas select Europe
tzdata tzdata/Zones/Europe select Kyiv
SEL

locale-gen
update-locale LANG=uk_UA.UTF-8 LC_ALL=uk_UA.UTF-8

ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
echo "Europe/Kyiv" > /etc/timezone
EOF

  install_file "$HOOKS/0200-rada-branding.hook.chroot" 755 <<'EOF'
#!/bin/bash
# Брендинг, інтеграція оболонок, права, шпалери XFCE, MOTD
set -e

# --- Підключення спільного файлу до bash та zsh -------------------------------
LINE='[ -r /etc/rada/rada-shell.sh ] && . /etc/rada/rada-shell.sh'
for f in /etc/bash.bashrc /etc/skel/.bashrc /root/.bashrc; do
  [ -f "$f" ] || touch "$f"
  grep -qF '/etc/rada/rada-shell.sh' "$f" || printf '\n# --- Rada OS ---\n%s\n' "$LINE" >> "$f"
done

mkdir -p /etc/zsh
[ -f /etc/zsh/zshrc ] || touch /etc/zsh/zshrc
grep -qF '/etc/rada/rada-shell.sh' /etc/zsh/zshrc || printf '\n# --- Rada OS ---\n%s\n' "$LINE" >> /etc/zsh/zshrc

# --- Права ---------------------------------------------------------------------
find /usr/local/bin -maxdepth 1 -type f -exec chmod 755 {} +
chmod 755 /usr/share/applications/rada-*.desktop

# --- Ідентифікація системи -----------------------------------------------------
sed -i --follow-symlinks 's/^PRETTY_NAME=.*/PRETTY_NAME="Rada OS (Верховна Рада Edition) на базі Debian 12"/' /etc/os-release

cat > /etc/issue <<'ISSUE'
Rada OS — Верховна Рада Edition (\n) (\l)

ISSUE
cp /etc/issue /etc/issue.net

# --- MOTD (з ANSI-кольорами) ---------------------------------------------------
COLUMNS=80 /usr/local/bin/rada-motd --no-tip > /etc/motd


# --- Оболонка за замовчуванням для live-користувача: zsh (як у Kali) ------------
if [ -f /etc/adduser.conf ]; then sed -i 's|^DSHELL=.*|DSHELL=/bin/zsh|' /etc/adduser.conf; fi
useradd -D -s /bin/zsh 2>/dev/null || true
EOF

  if [[ $DESKTOP == plasma ]]; then
  install_file "$HOOKS/0220-rada-plasma.hook.chroot" 755 <<'EOF'
#!/bin/bash
# KDE Plasma: темна тема в кольорах України, екран входу, Flathub, фаєрвол
set -e
R="${RADA_TEST_ROOT:-}"

# 1. Кольорова схема «Rada Dark» на основі Breeze Dark (синій акцент, жовтий hover)
SRC="$R/usr/share/color-schemes/BreezeDark.colors"
DST="$R/usr/share/color-schemes/RadaDark.colors"
if [ -f "$SRC" ]; then
  sed -e '/^Name\[/d' -e 's/^Name=.*/Name=Rada Dark/' \
      -e 's/61,174,233/0,110,214/g' \
      -e 's/^DecorationHover=.*/DecorationHover=255,215,0/' "$SRC" > "$DST"
fi

# 2. Типові налаштування вигляду (для всіх користувачів)
mkdir -p "$R/etc/xdg"
cat > "$R/etc/xdg/kdeglobals" <<'CONF'
[General]
ColorScheme=RadaDark

[Icons]
Theme=breeze-dark

[KDE]
LookAndFeelPackage=org.kde.breezedark.desktop
CONF

# 3. Шпалери у PNG (Plasma та екран входу)
mkdir -p "$R/usr/share/backgrounds/rada"
if command -v rsvg-convert >/dev/null 2>&1 && [ -f "$R/usr/share/backgrounds/rada/rada-os.svg" ]; then
  rsvg-convert -w 2560 -h 1440 "$R/usr/share/backgrounds/rada/rada-os.svg" \
    -o "$R/usr/share/backgrounds/rada/rada-os.png" || true
fi

# 4. Екран входу SDDM
mkdir -p "$R/etc/sddm.conf.d" "$R/usr/share/sddm/themes/breeze"
cat > "$R/etc/sddm.conf.d/10-rada.conf" <<'CONF'
[Theme]
Current=breeze
CursorTheme=breeze_cursors
CONF
cat > "$R/usr/share/sddm/themes/breeze/theme.conf.user" <<'CONF'
[General]
background=/usr/share/backgrounds/rada/rada-os.png
type=image
CONF

# 5. Flathub (магазин Discover → Flatpak)
if command -v flatpak >/dev/null 2>&1; then
  flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
fi

# 6. Фаєрвол ufw вмикається при завантаженні (вхідні — заборонені, вихідні — дозволені)
if [ -f "$R/etc/ufw/ufw.conf" ]; then
  sed -i 's/^ENABLED=.*/ENABLED=yes/' "$R/etc/ufw/ufw.conf"
  systemctl enable ufw >/dev/null 2>&1 || true
fi

fc-cache -f >/dev/null 2>&1 || true
EOF
  else
  install_file "$HOOKS/0210-rada-xfce.hook.chroot" 755 <<'EOF'
#!/bin/bash
# XFCE: тема Arc-Dark + Papirus, шпалери, екран входу
set -e
R="${RADA_TEST_ROOT:-}"
X="$R/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "$X" "$R/etc/gtk-3.0" "$R/etc/lightdm"

# --- Шпалери для різних назв моніторів ---
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<channel name="xfce4-desktop" version="1.0">'
  echo '  <property name="backdrop" type="empty">'
  echo '    <property name="screen0" type="empty">'
  for m in 0 Virtual-1 Virtual1 VGA-1 HDMI-1 HDMI-A-1 DP-1 eDP-1 LVDS-1; do
    echo "      <property name=\"monitor$m\" type=\"empty\">"
    for w in 0 1 2 3; do
      echo "        <property name=\"workspace$w\" type=\"empty\">"
      echo '          <property name="color-style" type="int" value="0"/>'
      echo '          <property name="image-style" type="int" value="5"/>'
      echo '          <property name="last-image" type="string" value="/usr/share/backgrounds/rada/rada-os.svg"/>'
      echo '        </property>'
    done
    echo '      </property>'
  done
  echo '    </property>'
  echo '  </property>'
  echo '</channel>'
} > "$X/xfce4-desktop.xml"

cat > "$X/xsettings.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Arc-Dark"/>
    <property name="IconThemeName" type="string" value="Papirus-Dark"/>
    <property name="EnableEventSounds" type="bool" value="false"/>
    <property name="EnableInputFeedbackSounds" type="bool" value="false"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="Noto Sans 10"/>
    <property name="MonospaceFontName" type="string" value="Fira Code 10"/>
  </property>
  <property name="Xft" type="empty">
    <property name="Antialias" type="int" value="1"/>
    <property name="Hinting" type="int" value="1"/>
    <property name="HintStyle" type="string" value="hintslight"/>
    <property name="RGBA" type="string" value="rgb"/>
  </property>
</channel>
XML

cat > "$X/xfwm4.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Arc-Dark"/>
    <property name="title_font" type="string" value="Noto Sans Bold 10"/>
    <property name="button_layout" type="string" value="O|HMC"/>
    <property name="use_compositing" type="bool" value="true"/>
  </property>
</channel>
XML

cat > "$R/etc/gtk-3.0/settings.ini" <<'INI'
[Settings]
gtk-theme-name=Arc-Dark
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=Noto Sans 10
gtk-application-prefer-dark-theme=1
INI

cat > "$R/etc/lightdm/lightdm-gtk-greeter.conf" <<'INI'
[greeter]
background=/usr/share/backgrounds/rada/rada-os.svg
theme-name=Arc-Dark
icon-theme-name=Papirus-Dark
font-name=Noto Sans 11
clock-format=%H:%M — %d.%m.%Y
position=50%,center
INI

fc-cache -f >/dev/null 2>&1 || true
EOF
  fi

  # Обов'язково виконувані (lb ігнорує невиконувані хуки)
  chmod 755 "$HOOKS"/*.hook.chroot
}

# -----------------------------------------------------------------------------
# 5. Збірка та результат
# -----------------------------------------------------------------------------
run_build() {
  info "Запускаю lb build (це займе 20–60 хв залежно від інтернету та CPU)..."
  cd "$WORK"
  lb build 2>&1 | tee build.log
}

collect_iso() {
  local iso final
  iso="$(find "$WORK" -maxdepth 1 -name '*.iso' | head -n1)"
  [[ -n "$iso" ]] || die "ISO не знайдено — перегляньте $WORK/build.log"
  mkdir -p "$OUT"
  final="$OUT/rada-os-${VERSION}-amd64.iso"
  cp -f "$iso" "$final"
  ( cd "$OUT" && sha256sum "$(basename "$final")" > "$(basename "$final").sha256" )
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$final" "$final.sha256" || true
  fi
  ISO_PATH="$final"
  info "Готово! ISO: $final ($(du -h "$final" | cut -f1))"
}

run_qemu() {
  command -v qemu-system-x86_64 >/dev/null 2>&1 || { warn "qemu-system-x86_64 не встановлено."; return; }
  local kvm=()
  [[ -e /dev/kvm ]] && kvm=(-enable-kvm -cpu host)
  qemu-system-x86_64 "${kvm[@]}" -m 4096 -smp 2 -cdrom "$ISO_PATH" -boot d -vga virtio -display gtk
}

print_epilogue() {
  cat <<EOF

────────────────────────────────────────────────────────────
 Rada OS ${VERSION} зібрано.  Що далі:

 Перевірка в QEMU (BIOS):
   qemu-system-x86_64 -enable-kvm -m 4096 -smp 2 \\
     -cdrom "${ISO_PATH}" -boot d -vga virtio

 Перевірка в QEMU (UEFI, потрібен пакунок ovmf):
   qemu-system-x86_64 -enable-kvm -m 4096 -smp 2 \\
     -bios /usr/share/ovmf/OVMF.fd -cdrom "${ISO_PATH}" -vga virtio

 Запис на флешку (УВАГА: перезапише весь /dev/sdX!):
   lsblk
   sudo dd if="${ISO_PATH}" of=/dev/sdX bs=4M status=progress conv=fsync

 Ventoy: просто скопіюйте файл ISO на розділ Ventoy.
────────────────────────────────────────────────────────────
EOF
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
ISO_PATH=""

if [[ $FILES_ONLY -eq 1 ]]; then
  [[ $CLEAN -eq 1 ]] && safe_clean
  mkdir -p "$WORK"
  write_package_lists; write_includes; write_hooks
  if [[ $BACKPORTS -eq 1 ]]; then write_backports; fi
  info "Режим --files-only: конфігурацію згенеровано в $WORK/config (lb не запускався)."
  exit 0
fi

require_root "$@"
check_deps
if [[ $CLEAN -eq 1 ]]; then info "Очищаю $WORK"; safe_clean; fi
mkdir -p "$WORK"
run_lb_config
write_package_lists
write_includes
write_hooks
if [[ $BACKPORTS -eq 1 ]]; then write_backports; fi
run_build
collect_iso
print_epilogue
[[ $RUN_QEMU -eq 1 ]] && run_qemu
exit 0
