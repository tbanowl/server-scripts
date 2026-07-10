#!/usr/bin/env bash

# Personal Linux server bootstrapper.
# Supported package-manager families: apt, dnf/yum, pacman, zypper, apk.

set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
readonly SSH_DROPIN_FILE="${SSH_DROPIN_DIR}/00-init-settings.conf"

PKG_MANAGER=""
OS_ID=""
TARGET_USER=""
TARGET_HOME=""
CREATED_USER=""
PRIVATE_KEY_PATH=""
SSH_PORT=""
SSH_BACKUP_PATH=""
IS_MAINLAND_CHINA="false"
APT_UPDATED="false"
UPGRADE_ONLY="false"
FORCE_UPGRADE="false"

info() { printf '\033[1;34m[信息]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[完成]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[警告]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
用法：sudo bash ${SCRIPT_NAME} [选项]

选项：
  --upgrade    仅更新 Yazi 和 Neovim；不处理用户、SSH、配置仓库、Docker 或 Nginx
  -h, --help   显示此帮助信息
EOF
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --upgrade)
                UPGRADE_ONLY="true"
                FORCE_UPGRADE="true"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "未知选项：$1"
                ;;
        esac
        shift
    done
}

on_error() {
    local exit_code=$?
    warn "${SCRIPT_NAME} 在第 ${BASH_LINENO[0]} 行发生错误（退出码 ${exit_code}）。"
    exit "$exit_code"
}
trap on_error ERR

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行：sudo bash ${SCRIPT_NAME}"
    [[ "$(uname -s)" == "Linux" ]] || die "此脚本仅支持 Linux。"
}

to_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

confirm_default_yes() {
    local prompt=$1 answer
    read -r -p "${prompt} [Y/n]: " answer || true
    answer="$(to_lower "${answer:-}")"
    case "$answer" in
        ""|y|yes) return 0 ;;
        n|no) return 1 ;;
        *) warn "无法识别输入，按默认选项“是”处理。"; return 0 ;;
    esac
}

detect_system() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-}"
    fi

    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
    else
        die "未识别到受支持的包管理器。"
    fi
    info "系统：${OS_ID:-unknown}，包管理器：${PKG_MANAGER}"
}

pkg_update() {
    case "$PKG_MANAGER" in
        apt)
            [[ "$APT_UPDATED" == "true" ]] && return 0
            DEBIAN_FRONTEND=noninteractive apt-get update
            APT_UPDATED="true"
            ;;
        pacman) pacman -Syu --noconfirm ;;
        apk) apk update ;;
        *) return 0 ;;
    esac
}

pkg_install() {
    (($# > 0)) || return 0
    case "$PKG_MANAGER" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
        pacman) pacman -S --needed --noconfirm "$@" ;;
        zypper) zypper --non-interactive install "$@" ;;
        apk) apk add --no-cache "$@" ;;
    esac
}

install_base_dependencies() {
    info "安装基础依赖……"
    pkg_update
    case "$PKG_MANAGER" in
        apt) pkg_install ca-certificates curl git unzip openssh-client openssh-server sudo file ;;
        dnf|yum) pkg_install ca-certificates curl git unzip openssh-clients openssh-server sudo file ;;
        pacman) pkg_install ca-certificates curl git unzip openssh sudo file ;;
        zypper) pkg_install ca-certificates curl git unzip openssh sudo file ;;
        apk) pkg_install ca-certificates curl git unzip openssh-client openssh-server sudo shadow file ;;
    esac
}

install_upgrade_dependencies() {
    local missing="false" command_name
    for command_name in curl unzip tar; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            missing="true"
        fi
    done
    [[ "$missing" == "true" ]] || return 0

    info "安装更新 Yazi/Neovim 所需的最小依赖……"
    case "$PKG_MANAGER" in
        apt)
            pkg_update
            pkg_install ca-certificates curl unzip tar
            ;;
        dnf|yum|pacman|zypper|apk)
            pkg_install ca-certificates curl unzip tar
            ;;
    esac
}

valid_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [[ "$1" != "root" ]]
}

create_login_user() {
    local username answer primary_group key_dir authorized_keys sudoers_file

    while true; do
        read -r -p "请输入要创建的普通用户名（输入 n/no 跳过）: " username
        answer="$(to_lower "$username")"
        if [[ "$answer" == "n" || "$answer" == "no" ]]; then
            info "已跳过创建用户。"
            return 0
        fi
        if ! valid_username "$username"; then
            warn "用户名无效：仅允许小写字母、数字、_、-，且必须以字母或 _ 开头。"
            continue
        fi
        if id "$username" >/dev/null 2>&1; then
            warn "用户 ${username} 已存在，请输入其他用户名。"
            continue
        fi

        read -r -p "确认创建用户 '${username}'？[Y/n]: " answer || true
        answer="$(to_lower "${answer:-}")"
        if [[ "$answer" == "n" || "$answer" == "no" ]]; then
            info "已跳过创建用户。"
            return 0
        fi
        [[ -z "$answer" || "$answer" == "y" || "$answer" == "yes" ]] || {
            warn "无法识别输入，请重新输入用户名。"
            continue
        }
        break
    done

    useradd --create-home --shell /bin/bash "$username"
    passwd --lock "$username" >/dev/null 2>&1 || true
    if getent group sudo >/dev/null 2>&1; then
        usermod -aG sudo "$username"
    elif getent group wheel >/dev/null 2>&1; then
        usermod -aG wheel "$username"
    else
        warn "未发现 sudo/wheel 管理组，将仅通过 sudoers 文件授予管理权限。"
    fi
    if command -v visudo >/dev/null 2>&1; then
        install -d -m 755 /etc/sudoers.d
        sudoers_file="/etc/sudoers.d/90-${username}-init-settings"
        printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$username" > "$sudoers_file"
        chmod 440 "$sudoers_file"
        if ! visudo -cf "$sudoers_file" >/dev/null; then
            rm -f "$sudoers_file"
            warn "sudoers 配置校验失败，未授予 ${username} 免密码 sudo 权限。"
        fi
    else
        warn "未找到 visudo；${username} 已锁定密码，可能无法使用 sudo。"
    fi

    key_dir="/root/.ssh/init-settings"
    install -d -m 700 "$key_dir"
    PRIVATE_KEY_PATH="${key_dir}/${username}_ed25519"
    if [[ -e "$PRIVATE_KEY_PATH" || -e "${PRIVATE_KEY_PATH}.pub" ]]; then
        PRIVATE_KEY_PATH="${PRIVATE_KEY_PATH}_$(date +%Y%m%d%H%M%S)"
    fi
    ssh-keygen -q -t ed25519 -a 100 -N "" -C "${username}@$(hostname)-$(date +%F)" -f "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"
    chmod 644 "${PRIVATE_KEY_PATH}.pub"

    primary_group="$(id -gn "$username")"
    authorized_keys="$(getent passwd "$username" | cut -d: -f6)/.ssh/authorized_keys"
    install -d -m 700 -o "$username" -g "$primary_group" "${authorized_keys%/*}"
    install -m 600 -o "$username" -g "$primary_group" "${PRIVATE_KEY_PATH}.pub" "$authorized_keys"

    CREATED_USER="$username"
    TARGET_USER="$username"
    TARGET_HOME="$(getent passwd "$username" | cut -d: -f6)"
    ok "已创建 ${username} 并安装 ed25519 公钥。"
    warn "私钥保存在 ${PRIVATE_KEY_PATH}。请安全下载并验证新端口登录后，从服务器删除该私钥。"
}

select_target_user() {
    local candidate
    [[ -n "$TARGET_USER" ]] && return 0
    candidate="${SUDO_USER:-root}"
    if [[ "$candidate" == "root" ]] || ! id "$candidate" >/dev/null 2>&1; then
        candidate="root"
    fi
    TARGET_USER="$candidate"
    TARGET_HOME="$(getent passwd "$candidate" | cut -d: -f6)"
    info "个人配置将写入用户 ${TARGET_USER} 的主目录。"
}

run_as_target() {
    if [[ "$TARGET_USER" == "root" ]]; then
        HOME="$TARGET_HOME" "$@"
    elif command -v runuser >/dev/null 2>&1; then
        runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"
    else
        sudo -H -u "$TARGET_USER" "$@"
    fi
}

install_yazi_binary() {
    local machine target url temp_dir extracted
    machine="$(uname -m)"
    case "$machine" in
        # Upstream's static musl builds also work on glibc distributions and avoid
        # failures when a release was built against a newer glibc than the server.
        x86_64|amd64) target="x86_64-unknown-linux-musl" ;;
        aarch64|arm64) target="aarch64-unknown-linux-musl" ;;
        *) return 1 ;;
    esac

    url="https://github.com/sxyazi/yazi/releases/latest/download/yazi-${target}.zip"
    temp_dir="$(mktemp -d)"
    if ! curl --fail --location --retry 2 --connect-timeout 10 --output "${temp_dir}/yazi.zip" "$url"; then
        rm -rf "$temp_dir"
        return 1
    fi
    if ! unzip -q "${temp_dir}/yazi.zip" -d "$temp_dir"; then
        rm -rf "$temp_dir"
        return 1
    fi
    extracted="${temp_dir}/yazi-${target}"
    [[ -x "${extracted}/yazi" && -x "${extracted}/ya" ]] || {
        rm -rf "$temp_dir"
        return 1
    }
    "${extracted}/yazi" --version >/dev/null 2>&1 || {
        rm -rf "$temp_dir"
        return 1
    }
    install -m 755 "${extracted}/yazi" "${extracted}/ya" /usr/local/bin/
    rm -rf "$temp_dir"
}

yazi_is_usable() {
    command -v yazi >/dev/null 2>&1 && command -v ya >/dev/null 2>&1 && yazi --version >/dev/null 2>&1
}

install_yazi() {
    info "安装 Yazi……"
    if [[ "$FORCE_UPGRADE" == "true" ]]; then
        if install_yazi_binary && yazi_is_usable; then
            ok "Yazi 已更新：$(yazi --version | head -n1)"
            return 0
        fi
        warn "Yazi 更新失败。"
        return 1
    fi
    if yazi_is_usable; then
        ok "Yazi 已安装：$(command -v yazi)"
        return 0
    fi

    case "$PKG_MANAGER" in
        pacman|zypper|apk) pkg_install yazi || true ;;
        apt|dnf|yum) : ;;
    esac
    if ! yazi_is_usable && ! install_yazi_binary; then
        warn "Yazi 官方二进制下载失败，尝试系统软件源。"
        pkg_install yazi || true
    fi

    if yazi_is_usable; then
        ok "Yazi 安装完成。"
    else
        warn "Yazi 安装失败；其余初始化流程将继续。"
        return 1
    fi
}

configure_yazi_wrapper() {
    local rc_file marker
    marker="# init-settings: Yazi shell wrapper"
    for rc_file in "${TARGET_HOME}/.bashrc" "${TARGET_HOME}/.zshrc"; do
        touch "$rc_file"
        if ! grep -Fq "$marker" "$rc_file"; then
            cat >>"$rc_file" <<'EOF'

# init-settings: Yazi shell wrapper
function y() {
    local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
    command yazi "$@" --cwd-file="$tmp"
    IFS= read -r -d '' cwd < "$tmp"
    [ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd"
    command rm -f -- "$tmp"
}
EOF
        fi
        chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$rc_file"
    done
    ok "已为 ${TARGET_USER} 配置 Yazi Shell wrapper：y"
}

install_neovim() {
    info "安装 Neovim……"
    if ! install_neovim_binary; then
        if [[ "$FORCE_UPGRADE" == "true" ]]; then
            warn "Neovim 更新失败。"
            return 1
        fi
        warn "Neovim 官方最新二进制安装失败，尝试系统软件源。"
        case "$PKG_MANAGER" in
            apt|dnf|yum|pacman|zypper|apk) pkg_install neovim || true ;;
        esac
    fi
    if command -v nvim >/dev/null 2>&1; then
        ok "Neovim 安装完成：$(nvim --version | head -n1)"
        return 0
    fi
    warn "Neovim 安装失败；仍会尝试下载配置。"
    return 1
}

install_neovim_binary() {
    local machine archive_arch url temp_dir extracted version destination
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) archive_arch="x86_64" ;;
        aarch64|arm64) archive_arch="arm64" ;;
        *) return 1 ;;
    esac

    url="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${archive_arch}.tar.gz"
    temp_dir="$(mktemp -d)"
    if ! curl --fail --location --retry 2 --connect-timeout 10 --output "${temp_dir}/nvim.tar.gz" "$url"; then
        rm -rf "$temp_dir"
        return 1
    fi
    if ! tar -C "$temp_dir" -xzf "${temp_dir}/nvim.tar.gz"; then
        rm -rf "$temp_dir"
        return 1
    fi
    extracted="${temp_dir}/nvim-linux-${archive_arch}"
    [[ -x "${extracted}/bin/nvim" ]] || {
        rm -rf "$temp_dir"
        return 1
    }
    version="$("${extracted}/bin/nvim" --version | awk 'NR == 1 { sub(/^v/, "", $2); print $2 }')"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        rm -rf "$temp_dir"
        return 1
    }
    destination="/opt/neovim-${version}-${archive_arch}"
    if [[ ! -d "$destination" ]]; then
        mv "$extracted" "$destination"
    fi
    [[ -x "${destination}/bin/nvim" ]] || {
        rm -rf "$temp_dir"
        return 1
    }
    ln -sfn "${destination}/bin/nvim" /usr/local/bin/nvim
    rm -rf "$temp_dir"
    nvim --version >/dev/null 2>&1
}

detect_mainland_china() {
    local country="" trace=""
    country="$(curl --silent --show-error --fail --max-time 5 https://ipapi.co/country/ 2>/dev/null || true)"
    country="$(printf '%s' "$country" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
    if [[ ! "$country" =~ ^[A-Z]{2}$ ]]; then
        trace="$(curl --silent --show-error --fail --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
        country="$(printf '%s\n' "$trace" | sed -n 's/^loc=//p' | head -n1 | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
    fi
    if [[ "$country" == "CN" ]]; then
        IS_MAINLAND_CHINA="true"
        info "公网位置检测结果：中国大陆。"
    elif [[ "$country" =~ ^[A-Z]{2}$ ]]; then
        IS_MAINLAND_CHINA="false"
        info "公网位置检测结果：${country}（非中国大陆）。"
    else
        IS_MAINLAND_CHINA="false"
        warn "无法判断服务器位置，默认使用 GitHub 仓库。"
    fi
}

clone_neovim_config() {
    local default_repo repo config_dir backup_dir=""
    detect_mainland_china
    if [[ "$IS_MAINLAND_CHINA" == "true" ]]; then
        default_repo="https://gitee.com/dbsfly/nvim-config.git"
    else
        default_repo="https://github.com/tbanowl/nvim-config.git"
    fi

    read -r -p "Neovim 配置仓库地址（直接回车使用 ${default_repo}）: " repo || true
    repo="${repo:-$default_repo}"
    config_dir="${TARGET_HOME}/.config/nvim"
    if [[ -e "$config_dir" ]]; then
        backup_dir="${config_dir}.backup.$(date +%Y%m%d%H%M%S)"
        mv "$config_dir" "$backup_dir"
        chown -R "$TARGET_USER:$(id -gn "$TARGET_USER")" "$backup_dir"
        info "原 Neovim 配置已备份至 ${backup_dir}"
    fi
    install -d -m 755 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" "${TARGET_HOME}/.config"

    if run_as_target git clone --depth 1 "$repo" "$config_dir"; then
        ok "Neovim 配置已从 ${repo} 下载。"
    else
        warn "Neovim 配置拉取失败，已按要求继续执行后续流程。"
        if [[ -n "$backup_dir" && -e "$backup_dir" ]]; then
            mv "$backup_dir" "$config_dir"
            info "已恢复原 Neovim 配置。"
        fi
        return 0
    fi
}

install_docker_apt() {
    local docker_os codename arch
    docker_os="$OS_ID"
    case "$docker_os" in
        ubuntu|debian) ;;
        linuxmint|pop) docker_os="ubuntu" ;;
        *) docker_os="debian" ;;
    esac
    pkg_install ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl --fail --location "https://download.docker.com/linux/${docker_os}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    arch="$(dpkg --print-architecture)"
    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "$codename" ]] || return 1
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
        "$arch" "$docker_os" "$codename" > /etc/apt/sources.list.d/docker.list
    APT_UPDATED="false"
    pkg_update
    pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_rpm() {
    local repo_os="centos"
    [[ "$OS_ID" == "fedora" ]] && repo_os="fedora"
    [[ "$OS_ID" == "rhel" ]] && repo_os="rhel"
    pkg_install dnf-plugins-core || pkg_install yum-utils
    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        if [[ "$repo_os" == "fedora" ]]; then
            dnf config-manager addrepo --from-repofile "https://download.docker.com/linux/${repo_os}/docker-ce.repo" || \
                dnf config-manager --add-repo "https://download.docker.com/linux/${repo_os}/docker-ce.repo"
        else
            dnf config-manager --add-repo "https://download.docker.com/linux/${repo_os}/docker-ce.repo" || \
                dnf config-manager addrepo --from-repofile "https://download.docker.com/linux/${repo_os}/docker-ce.repo"
        fi
    else
        yum-config-manager --add-repo "https://download.docker.com/linux/${repo_os}/docker-ce.repo"
    fi
    pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

enable_service() {
    local service=$1
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl enable --now "$service"
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update add "$service" default || true
        rc-service "$service" start
    elif command -v service >/dev/null 2>&1; then
        service "$service" start
    else
        warn "无法识别服务管理器，请手动启动 ${service}。"
        return 1
    fi
}

install_docker() {
    info "安装 Docker……"
    if command -v docker >/dev/null 2>&1; then
        ok "Docker 已安装。"
    else
        case "$PKG_MANAGER" in
            apt) install_docker_apt || { warn "Docker 官方源安装失败，尝试发行版软件包 docker.io。"; pkg_install docker.io; } ;;
            dnf|yum) install_docker_rpm ;;
            pacman) pkg_install docker docker-compose docker-buildx ;;
            zypper) pkg_install docker docker-compose ;;
            apk) pkg_install docker docker-cli-compose docker-cli-buildx ;;
        esac
    fi
    command -v docker >/dev/null 2>&1 || { warn "Docker 安装失败。"; return 1; }
    enable_service docker || true
    if [[ -n "$CREATED_USER" ]] && getent group docker >/dev/null 2>&1; then
        usermod -aG docker "$CREATED_USER"
        warn "已将 ${CREATED_USER} 加入 docker 组；该组等同于 root 权限。"
    fi
    ok "Docker 安装完成。"
}

install_nginx() {
    info "安装 Nginx……"
    if ! command -v nginx >/dev/null 2>&1; then
        pkg_install nginx
    fi
    command -v nginx >/dev/null 2>&1 || { warn "Nginx 安装失败。"; return 1; }
    enable_service nginx || true
    ok "Nginx 安装完成。"
}

port_is_in_use() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -H -lnt | awk '{print $4}' | grep -Eq "(^|:|\])${port}$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt | awk 'NR>2 {print $4}' | grep -Eq "(^|:|\])${port}$"
    else
        return 1
    fi
}

random_ssh_port() {
    local port i
    for ((i = 0; i < 100; i++)); do
        if command -v shuf >/dev/null 2>&1; then
            port="$(shuf -i 10001-65535 -n 1)"
        else
            port="$((10001 + ((RANDOM << 1 ^ RANDOM) % 55535)))"
        fi
        if ! port_is_in_use "$port"; then
            printf '%s' "$port"
            return 0
        fi
    done
    return 1
}

select_ssh_port() {
    local input numeric
    while true; do
        read -r -p "请输入 SSH 端口（10001-65535，直接回车随机生成）: " input || true
        if [[ -z "$input" ]]; then
            SSH_PORT="$(random_ssh_port)" || die "无法找到可用的随机 SSH 端口。"
            info "随机 SSH 端口：${SSH_PORT}"
            return 0
        fi
        if [[ "$input" =~ ^[0-9]+$ && ${#input} -le 5 ]]; then
            numeric=$((10#$input))
        else
            numeric=0
        fi
        if ((numeric >= 10001 && numeric <= 65535)); then
            if port_is_in_use "$numeric"; then
                warn "端口 ${numeric} 已被占用，请选择其他端口。"
            else
                SSH_PORT="$numeric"
                return 0
            fi
        else
            warn "端口必须是 10001 到 65535 之间的整数。"
        fi
    done
}

has_authorized_key() {
    local auth_file="${TARGET_HOME}/.ssh/authorized_keys"
    [[ -s "$auth_file" ]] && grep -Eq '(^|[[:space:]])(ssh-(ed25519|rsa|dss)|ecdsa-|sk-ssh-|sk-ecdsa-)' "$auth_file"
}

ensure_key_login_available() {
    local public_key primary_group auth_file
    has_authorized_key && return 0
    warn "用户 ${TARGET_USER} 尚无可识别的 SSH authorized_keys。"
    read -r -p "请粘贴一行 SSH 公钥（留空将跳过 SSH 加固）: " public_key || true
    [[ -n "$public_key" ]] || return 1
    [[ "$public_key" =~ ^(ssh-(ed25519|rsa|dss)|ecdsa-|sk-ssh-|sk-ecdsa-) ]] || {
        warn "公钥格式无法识别，将跳过 SSH 加固。"
        return 1
    }
    primary_group="$(id -gn "$TARGET_USER")"
    auth_file="${TARGET_HOME}/.ssh/authorized_keys"
    install -d -m 700 -o "$TARGET_USER" -g "$primary_group" "${auth_file%/*}"
    touch "$auth_file"
    grep -Fqx "$public_key" "$auth_file" || printf '%s\n' "$public_key" >> "$auth_file"
    chown "$TARGET_USER:$primary_group" "$auth_file"
    chmod 600 "$auth_file"
}

open_firewall_port() {
    local port=$1
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "${port}/tcp"
        ok "UFW 已放行 TCP ${port}。"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/tcp"
        firewall-cmd --reload
        ok "firewalld 已放行 TCP ${port}。"
    else
        warn "未检测到启用的 UFW/firewalld。若使用云安全组或其他防火墙，请手动放行 TCP ${port}。"
    fi
}

configure_selinux_ssh_port() {
    local port=$1
    command -v getenforce >/dev/null 2>&1 || return 0
    [[ "$(getenforce)" != "Disabled" ]] || return 0
    if ! command -v semanage >/dev/null 2>&1; then
        case "$PKG_MANAGER" in
            dnf) pkg_install policycoreutils-python-utils || true ;;
            yum) pkg_install policycoreutils-python || true ;;
        esac
    fi
    command -v semanage >/dev/null 2>&1 || {
        warn "SELinux 已启用但缺少 semanage，无法注册新 SSH 端口。"
        return 1
    }
    if semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null; then
        return 0
    fi
    semanage port -m -t ssh_port_t -p tcp "$port"
}

sshd_binary() {
    if command -v sshd >/dev/null 2>&1; then
        command -v sshd
    elif [[ -x /usr/sbin/sshd ]]; then
        printf '%s' /usr/sbin/sshd
    else
        return 1
    fi
}

reload_sshd() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        if systemctl is-active --quiet ssh.socket 2>/dev/null; then
            systemctl daemon-reload
            systemctl restart ssh.socket
        elif systemctl cat ssh.service >/dev/null 2>&1; then
            systemctl reload ssh
        else
            systemctl reload sshd
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service sshd restart
    elif command -v service >/dev/null 2>&1; then
        service ssh reload 2>/dev/null || service sshd reload
    else
        return 1
    fi
}

ensure_single_dropin_include() {
    local config_file=$1 temp_file
    temp_file="$(mktemp)"
    awk -v target="${SSH_DROPIN_DIR}/*.conf" '
        BEGIN { in_match = 0 }
        /^[[:space:]]*[Mm][Aa][Tt][Cc][Hh][[:space:]]/ { in_match = 1 }
        !in_match && tolower($1) == "include" {
            found = 0
            remaining = $1
            for (i = 2; i <= NF; i++) {
                if ($i == target) {
                    found = 1
                } else {
                    remaining = remaining " " $i
                }
            }
            if (found) {
                print "# init-settings disabled duplicate: " $0
                if (remaining != $1) print remaining
                next
            }
        }
        { print }
    ' "$config_file" > "$temp_file"
    {
        printf 'Include %s/*.conf\n' "$SSH_DROPIN_DIR"
        cat "$temp_file"
    } > "$config_file"
    rm -f "$temp_file"
}

disable_existing_port_directives() {
    local config_file=$1 port=$2 temp_file
    temp_file="$(mktemp)"
    awk -v new_port="$port" '
        BEGIN { in_match = 0 }
        /^[[:space:]]*[Mm][Aa][Tt][Cc][Hh][[:space:]]/ { in_match = 1 }
        !in_match && /^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]+/ {
            print "# init-settings disabled: " $0
            next
        }
        !in_match && /^[[:space:]]*[Ll][Ii][Ss][Tt][Ee][Nn][Aa][Dd][Dd][Rr][Ee][Ss][Ss][[:space:]]+/ {
            if ($2 ~ /^\[[^]]+\]:[0-9]+$/ || $2 ~ /^[^:]+:[0-9]+$/) {
                sub(/:[0-9]+$/, ":" new_port, $2)
            }
            print
            next
        }
        { print }
    ' "$config_file" > "$temp_file"
    cat "$temp_file" > "$config_file"
    rm -f "$temp_file"
}

restore_ssh_config() {
    local backup_dir=$1 had_dropin=$2
    cp -a "${backup_dir}/sshd_config" /etc/ssh/sshd_config
    if [[ -d "${backup_dir}/dropins" ]]; then
        cp -a "${backup_dir}/dropins/." "$SSH_DROPIN_DIR/"
    fi
    if [[ "$had_dropin" != "true" ]]; then
        rm -f "$SSH_DROPIN_FILE"
    fi
}

validate_effective_sshd_config() {
    local sshd=$1 main_config=$2 port=$3 output address ports addresses
    output="$("$sshd" -T -f "$main_config" -C "user=${TARGET_USER},host=$(hostname),addr=127.0.0.1")" || return 1
    ports="$(printf '%s\n' "$output" | awk '$1 == "port" { printf "%s ", $2 }' | sed 's/[[:space:]]*$//')"
    [[ "$ports" == "$port" ]] || return 1

    addresses="$(printf '%s\n' "$output" | awk '$1 == "listenaddress" { print $2 }')"
    if [[ -n "$addresses" ]]; then
        while IFS= read -r address; do
            [[ "$address" == *":${port}" ]] || return 1
        done <<< "$addresses"
    fi
    [[ "$(printf '%s\n' "$output" | awk '$1 == "passwordauthentication" { print $2; exit }')" == "no" ]] || return 1
    [[ "$(printf '%s\n' "$output" | awk '$1 == "kbdinteractiveauthentication" { print $2; exit }')" == "no" ]] || return 1
    [[ "$(printf '%s\n' "$output" | awk '$1 == "pubkeyauthentication" { print $2; exit }')" == "yes" ]] || return 1
    [[ "$(printf '%s\n' "$output" | awk '$1 == "authenticationmethods" { print $2; exit }')" == "publickey" ]] || return 1
    printf '%s\n' "$output" | awk '$1 == "authorizedkeysfile" { print $2 }' | grep -Fqx '.ssh/authorized_keys' || return 1
}

configure_ssh() {
    local sshd main_config backup_dir main_mode permit_root config_file had_dropin="false"
    sshd="$(sshd_binary)" || { warn "未找到 sshd，跳过 SSH 配置。"; return 0; }
    main_config="/etc/ssh/sshd_config"
    [[ -f "$main_config" ]] || { warn "未找到 ${main_config}，跳过 SSH 配置。"; return 0; }

    if ! ensure_key_login_available; then
        warn "为避免服务器失联，SSH 端口和认证设置均未修改。"
        return 0
    fi
    select_ssh_port
    open_firewall_port "$SSH_PORT"
    configure_selinux_ssh_port "$SSH_PORT" || {
        warn "SELinux 端口配置失败，SSH 设置未修改。"
        return 0
    }

    backup_dir="$(mktemp -d)"
    cp -a "$main_config" "${backup_dir}/sshd_config"
    main_mode="$(stat -c '%a' "$main_config")"
    install -d -m 700 "${backup_dir}/dropins"
    if [[ -d "$SSH_DROPIN_DIR" ]]; then
        cp -a "${SSH_DROPIN_DIR}/." "${backup_dir}/dropins/"
    fi
    if [[ -e "$SSH_DROPIN_FILE" ]]; then
        had_dropin="true"
    fi
    install -d -m 755 "$SSH_DROPIN_DIR"

    # Keep one Include at the top: repeated Includes would read repeatable Port values twice.
    ensure_single_dropin_include "$main_config"
    chmod "$main_mode" "$main_config"
    disable_existing_port_directives "$main_config" "$SSH_PORT"
    for config_file in "${SSH_DROPIN_DIR}"/*.conf; do
        [[ -f "$config_file" && ! -L "$config_file" && "$config_file" != "$SSH_DROPIN_FILE" ]] || continue
        disable_existing_port_directives "$config_file" "$SSH_PORT"
    done

    permit_root="prohibit-password"
    [[ "$TARGET_USER" != "root" ]] && permit_root="no"
    cat > "$SSH_DROPIN_FILE" <<EOF
# Managed by ${SCRIPT_NAME}
Port ${SSH_PORT}
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
PermitEmptyPasswords no
PermitRootLogin ${permit_root}
EOF
    chmod 600 "$SSH_DROPIN_FILE"

    if ! "$sshd" -t -f "$main_config"; then
        warn "sshd 配置校验失败，正在回滚。"
        restore_ssh_config "$backup_dir" "$had_dropin"
        rm -rf "$backup_dir"
        return 0
    fi
    if ! validate_effective_sshd_config "$sshd" "$main_config" "$SSH_PORT"; then
        warn "sshd 生效配置不满足“仅监听新端口并使用密钥认证”，正在回滚。"
        restore_ssh_config "$backup_dir" "$had_dropin"
        rm -rf "$backup_dir"
        return 0
    fi

    if ! reload_sshd; then
        warn "sshd 重载失败，正在回滚并恢复服务。"
        restore_ssh_config "$backup_dir" "$had_dropin"
        reload_sshd || true
        rm -rf "$backup_dir"
        return 0
    fi
    if command -v ss >/dev/null 2>&1; then
        sleep 1
        if ! port_is_in_use "$SSH_PORT"; then
            warn "sshd 重载后未监听端口 ${SSH_PORT}，正在回滚。"
            restore_ssh_config "$backup_dir" "$had_dropin"
            reload_sshd || true
            rm -rf "$backup_dir"
            return 0
        fi
    fi
    SSH_BACKUP_PATH="/root/.local/share/init-settings/backups/ssh-$(date +%Y%m%d%H%M%S)"
    install -d -m 700 "${SSH_BACKUP_PATH%/*}"
    cp -a "$backup_dir" "$SSH_BACKUP_PATH"
    chmod -R go-rwx "$SSH_BACKUP_PATH"
    rm -rf "$backup_dir"
    ok "SSH 已改为端口 ${SSH_PORT}，并关闭密码及键盘交互认证。"
    info "原 SSH 配置备份：${SSH_BACKUP_PATH}"
    warn "不要立即关闭当前会话；请先在另一终端验证：ssh -p ${SSH_PORT} ${TARGET_USER}@服务器地址"
}

print_summary() {
    printf '\n========== 初始化结果 ==========\n'
    printf '配置用户: %s\n' "$TARGET_USER"
    [[ -n "$CREATED_USER" ]] && printf '新建用户: %s\n' "$CREATED_USER"
    [[ -n "$PRIVATE_KEY_PATH" ]] && printf '新用户私钥: %s\n' "$PRIVATE_KEY_PATH"
    [[ -n "$SSH_PORT" ]] && printf 'SSH 端口: %s\n' "$SSH_PORT"
    [[ -n "$SSH_BACKUP_PATH" ]] && printf 'SSH 配置备份: %s\n' "$SSH_BACKUP_PATH"
    yazi_is_usable && printf 'Yazi: 已安装（使用命令 y）\n' || printf 'Yazi: 未安装成功\n'
    command -v nvim >/dev/null 2>&1 && printf 'Neovim: 已安装\n' || printf 'Neovim: 未安装成功\n'
    command -v docker >/dev/null 2>&1 && printf 'Docker: 已安装\n' || printf 'Docker: 未安装/已跳过\n'
    command -v nginx >/dev/null 2>&1 && printf 'Nginx: 已安装\n' || printf 'Nginx: 未安装/已跳过\n'
    printf '================================\n'
}

print_upgrade_summary() {
    printf '\n========== 更新结果 ==========\n'
    if yazi_is_usable; then
        printf 'Yazi: %s\n' "$(yazi --version | head -n1)"
    else
        printf 'Yazi: 更新失败\n'
    fi
    if command -v nvim >/dev/null 2>&1; then
        printf 'Neovim: %s\n' "$(nvim --version | head -n1)"
    else
        printf 'Neovim: 更新失败\n'
    fi
    printf '用户/SSH/Docker/Nginx/个人配置: 未处理\n'
    printf '==============================\n'
}

main() {
    local upgrade_failed=0
    parse_args "$@"
    require_root
    detect_system

    if [[ "$UPGRADE_ONLY" == "true" ]]; then
        info "已启用 --upgrade：仅更新 Yazi 和 Neovim。"
        install_upgrade_dependencies
        if ! install_yazi; then
            upgrade_failed=1
        fi
        if ! install_neovim; then
            upgrade_failed=1
        fi
        print_upgrade_summary
        ((upgrade_failed == 0)) || die "一个或多个更新步骤失败。"
        return 0
    fi

    install_base_dependencies
    create_login_user
    select_target_user

    install_yazi || true
    configure_yazi_wrapper
    install_neovim || true
    clone_neovim_config

    if confirm_default_yes "是否安装 Docker？"; then
        install_docker || warn "Docker 安装步骤未成功完成，继续执行。"
    else
        info "已跳过 Docker。"
    fi

    if confirm_default_yes "是否安装 Nginx？"; then
        install_nginx || warn "Nginx 安装步骤未成功完成，继续执行。"
    else
        info "已跳过 Nginx。"
    fi

    configure_ssh
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
