#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_VERSION="0.1.0"
readonly EASYTIER_REPOSITORY="EasyTier/EasyTier"
readonly EASYTIER_RELEASE_API="https://api.github.com/repos/${EASYTIER_REPOSITORY}/releases/latest"
readonly SERVICE_NAME="easytier-node"
readonly INSTALL_DIR="${EASYTIER_INSTALL_DIR:-/opt/easytier}"
readonly CONFIG_DIR="${EASYTIER_CONFIG_DIR:-/etc/easytier}"
readonly CONFIG_FILE="${EASYTIER_CONFIG_DIR:-/etc/easytier}/easytier.conf"
readonly CONFIG_BACKUP_DIR="${EASYTIER_CONFIG_DIR:-/etc/easytier}/backup"
readonly SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
readonly OPENRC_SCRIPT="/etc/init.d/${SERVICE_NAME}"

RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[1;34m'
RESET=$'\033[0m'

NON_INTERACTIVE=0
SKIP_DEPENDENCIES=0
FORCE_UPDATE=0
ALLOW_EMPTY_SECRET=0
NO_PEER=0
AUTO_FIREWALL="${EASYTIER_AUTO_FIREWALL:-1}"
GITHUB_PROXY="${EASYTIER_GITHUB_PROXY:-}"

NETWORK_NAME="${EASYTIER_NETWORK_NAME:-}"
NETWORK_SECRET="${EASYTIER_NETWORK_SECRET:-}"
PEER_HOST="${EASYTIER_PEER_HOST:-}"
PEER_PORT="${EASYTIER_PEER_PORT:-11010}"
PEER_PROTOCOL="${EASYTIER_PEER_PROTOCOL:-tcp}"
NODE_ROLE="${EASYTIER_ROLE:-client}"
LISTEN_PORT="${EASYTIER_LISTEN_PORT:-11010}"
NODE_HOSTNAME="${EASYTIER_HOSTNAME:-}"
ROLE_EXPLICIT=0
[ -n "${EASYTIER_ROLE:-}" ] && ROLE_EXPLICIT=1

OS_ID="unknown"
OS_VERSION=""
INIT_SYSTEM=""
ARCH=""
RAW_ARCH=""
TUN_AVAILABLE=0
NO_TUN=0
RPC_PORT=15888
RELEASE_VERSION=""
RELEASE_JSON=""
ASSET_NAME=""
EXPECTED_DIGEST=""
CORE_VERSION=""
PEER_URI=""

usage() {
  cat <<'EOF'
EasyTier Linux 一键安装器

用法:
  sudo bash install-easytier.sh [选项]

默认行为:
  1. 检查 Linux、CPU 架构、root、包管理器、TUN、systemd/OpenRC 和网络环境
  2. 下载 EasyTier 最新 Linux CLI，校验 GitHub Release 提供的 SHA-256
  3. 交互式填写网络名称、网络密码、初始节点地址和端口
  4. 生成配置文件，安装 easytier-node 服务并设置开机启动

选项:
  --non-interactive       使用环境变量运行，不进行交互式提问
  --force-update          即使已有 EasyTier 二进制也下载最新版本
  --skip-deps             不自动安装 curl/unzip/iproute2 等依赖
  --allow-empty-secret    允许空网络密码（不推荐）
  --no-peer               不设置初始节点，单独启动本地网络
  --proxy URL             GitHub 下载前缀，例如 https://ghfast.top/
  --network-name NAME     网络名称；交互模式建议直接输入
  --network-secret PASS   网络密码；命令行参数可能出现在 shell 历史中
  --peer-host HOST        初始节点地址
  --peer-port PORT        初始节点端口，默认 11010
  --peer-protocol PROTO   初始节点协议，默认 tcp
  --role client|relay     普通节点或共享/公网节点，默认 client
  --listen-port PORT      relay 模式监听端口，默认 11010
  --hostname NAME         EasyTier 虚拟网络中的主机名
  -h, --help              显示帮助

非交互模式示例:
  sudo env \
    EASYTIER_NETWORK_NAME='my-network' \
    EASYTIER_NETWORK_SECRET='change-me' \
    EASYTIER_PEER_HOST='relay.example.com' \
    EASYTIER_PEER_PORT='11010' \
    bash install-easytier.sh --non-interactive
EOF
}

log() {
  printf '%b[%s]%b %s\n' "$BLUE" "EasyTier" "$RESET" "$*"
}

success() {
  printf '%b[完成]%b %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
  printf '%b[警告]%b %s\n' "$YELLOW" "$RESET" "$*" >&2
}

die() {
  printf '%b[错误]%b %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

on_error() {
  local rc=$?
  printf '%b[错误]%b 安装器在第 %s 行失败，退出码 %s。\n' "$RED" "$RESET" "${BASH_LINENO[0]:-?}" "$rc" >&2
  exit "$rc"
}

trap on_error ERR

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 运行，或者执行：sudo bash $0"
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --non-interactive)
        NON_INTERACTIVE=1
        ;;
      --force-update)
        FORCE_UPDATE=1
        ;;
      --skip-deps)
        SKIP_DEPENDENCIES=1
        ;;
      --allow-empty-secret)
        ALLOW_EMPTY_SECRET=1
        ;;
      --no-peer)
        NO_PEER=1
        ;;
      --proxy)
        [ "$#" -ge 2 ] || die "--proxy 需要一个 URL"
        GITHUB_PROXY="$2"
        shift
        ;;
      --network-name)
        [ "$#" -ge 2 ] || die "--network-name 需要一个值"
        NETWORK_NAME="$2"
        shift
        ;;
      --network-secret)
        [ "$#" -ge 2 ] || die "--network-secret 需要一个值"
        NETWORK_SECRET="$2"
        shift
        ;;
      --peer-host)
        [ "$#" -ge 2 ] || die "--peer-host 需要一个值"
        PEER_HOST="$2"
        shift
        ;;
      --peer-port)
        [ "$#" -ge 2 ] || die "--peer-port 需要一个值"
        PEER_PORT="$2"
        shift
        ;;
      --peer-protocol)
        [ "$#" -ge 2 ] || die "--peer-protocol 需要一个值"
        PEER_PROTOCOL="$2"
        shift
        ;;
      --role)
        [ "$#" -ge 2 ] || die "--role 需要 client 或 relay"
        NODE_ROLE="$2"
        ROLE_EXPLICIT=1
        shift
        ;;
      --listen-port)
        [ "$#" -ge 2 ] || die "--listen-port 需要一个端口"
        LISTEN_PORT="$2"
        shift
        ;;
      --hostname)
        [ "$#" -ge 2 ] || die "--hostname 需要一个值"
        NODE_HOSTNAME="$2"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知选项：$1。使用 --help 查看帮助。"
        ;;
    esac
    shift
  done
}

ask_value() {
  local prompt="$1"
  local default_value="${2:-}"
  local answer=""

  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    printf '%s' "$default_value"
    return 0
  fi

  if [ -n "$default_value" ]; then
    printf '%s [%s]：' "$prompt" "$default_value" >&2
  else
    printf '%s：' "$prompt" >&2
  fi

  if [ -r /dev/tty ]; then
    IFS= read -r answer < /dev/tty
  else
    IFS= read -r answer
  fi

  if [ -z "$answer" ]; then
    answer="$default_value"
  fi
  printf '%s' "$answer"
}

ask_secret() {
  local prompt="$1"
  local answer=""
  local tty_path="/dev/tty"

  [ "$NON_INTERACTIVE" -eq 0 ] || return 0
  [ -r "$tty_path" ] || die "当前没有可用终端，无法安全读取网络密码。请设置 EASYTIER_NETWORK_SECRET。"

  printf '%s：' "$prompt" >&2
  stty -echo < "$tty_path"
  IFS= read -r answer < "$tty_path" || true
  stty echo < "$tty_path"
  printf '\n' >&2
  printf '%s' "$answer"
}

ask_yes_no() {
  local prompt="$1"
  local default_answer="${2:-n}"
  local answer=""

  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    [ "$default_answer" = "y" ]
    return
  fi

  if [ "$default_answer" = "y" ]; then
    printf '%s [Y/n]：' "$prompt" >&2
  else
    printf '%s [y/N]：' "$prompt" >&2
  fi
  if [ -r /dev/tty ]; then
    IFS= read -r answer < /dev/tty
  else
    IFS= read -r answer
  fi
  answer="${answer:-$default_answer}"
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

detect_os() {
  [ -r /etc/os-release ] || die "无法识别 Linux 发行版：缺少 /etc/os-release。"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
  log "操作系统：${PRETTY_NAME:-$OS_ID $OS_VERSION}"
}

detect_arch() {
  RAW_ARCH="$(uname -m)"
  case "$RAW_ARCH" in
    x86_64|amd64)
      ARCH="x86_64"
      ;;
    aarch64|arm64)
      ARCH="aarch64"
      ;;
    armv7*|armv7l)
      if grep -qiE '(^|[[:space:]])(vfp|vfpv3|vfpv4|neon|half)([[:space:]]|$)' /proc/cpuinfo 2>/dev/null; then
        ARCH="armv7hf"
      else
        ARCH="armv7"
      fi
      ;;
    armv6*|arm)
      ARCH="arm"
      ;;
    mips64el|mipsel)
      ARCH="mipsel"
      ;;
    mips64|mips)
      ARCH="mips"
      ;;
    riscv64)
      ARCH="riscv64"
      ;;
    loongarch64)
      ARCH="loongarch64"
      ;;
    *)
      die "暂不支持当前 CPU 架构：$RAW_ARCH。请查看 EasyTier Release 是否有对应资产。"
      ;;
  esac
  log "CPU 架构：${RAW_ARCH} → EasyTier 资产架构 ${ARCH}"
}

detect_init_system() {
  local pid1=""
  pid1="$(cat /proc/1/comm 2>/dev/null || true)"

  if [ "$pid1" = "systemd" ] && command -v systemctl >/dev/null 2>&1; then
    INIT_SYSTEM="systemd"
  elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
    INIT_SYSTEM="openrc"
  else
    die "未检测到可用的 systemd 或 OpenRC。当前 PID 1 为 '${pid1:-未知}'，无法可靠配置开机启动。"
  fi
  log "服务管理器：$INIT_SYSTEM"
}

package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf '%s' apt
  elif command -v dnf >/dev/null 2>&1; then
    printf '%s' dnf
  elif command -v yum >/dev/null 2>&1; then
    printf '%s' yum
  elif command -v apk >/dev/null 2>&1; then
    printf '%s' apk
  elif command -v pacman >/dev/null 2>&1; then
    printf '%s' pacman
  elif command -v zypper >/dev/null 2>&1; then
    printf '%s' zypper
  else
    printf '%s' none
  fi
}

install_dependencies() {
  local missing=()
  local command_name=""
  local pm=""

  for command_name in curl unzip; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing+=("$command_name")
    fi
  done

  if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
    missing+=("iproute2")
  fi

  if [ "${#missing[@]}" -eq 0 ]; then
    log "基础依赖已存在：curl、unzip，以及端口检测工具。"
    return 0
  fi

  if [ "$SKIP_DEPENDENCIES" -eq 1 ]; then
    die "缺少依赖：${missing[*]}。已指定 --skip-deps，无法继续。"
  fi

  pm="$(package_manager)"
  [ "$pm" != "none" ] || die "缺少依赖 ${missing[*]}，且没有识别到可用包管理器。"

  log "将通过 $pm 安装缺少的依赖：${missing[*]}"
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y ca-certificates curl unzip iproute2 coreutils
      ;;
    dnf)
      dnf install -y ca-certificates curl unzip iproute coreutils
      ;;
    yum)
      yum install -y ca-certificates curl unzip iproute coreutils
      ;;
    apk)
      apk add --no-cache ca-certificates curl unzip iproute2 coreutils
      ;;
    pacman)
      pacman -Sy --noconfirm ca-certificates curl unzip iproute2 coreutils
      ;;
    zypper)
      zypper --non-interactive install ca-certificates curl unzip iproute2 coreutils
      ;;
  esac

  command -v curl >/dev/null 2>&1 || die "curl 安装失败。"
  command -v unzip >/dev/null 2>&1 || die "unzip 安装失败。"
}

check_tun() {
  if [ -c /dev/net/tun ]; then
    TUN_AVAILABLE=1
    log "TUN 设备：/dev/net/tun 可用。"
    return 0
  fi

  if command -v modprobe >/dev/null 2>&1; then
    modprobe tun >/dev/null 2>&1 || true
  fi

  if [ -c /dev/net/tun ]; then
    TUN_AVAILABLE=1
    log "TUN 内核模块已加载，/dev/net/tun 可用。"
    return 0
  fi

  warn "未发现 /dev/net/tun。普通组网节点需要 TUN 才能创建虚拟网卡。"
  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    if [ "${EASYTIER_NO_TUN:-0}" = "1" ]; then
      NO_TUN=1
      warn "已按 EASYTIER_NO_TUN=1 使用无 TUN 模式。"
    else
      die "当前环境没有 TUN。若只需要无 TUN/子网代理模式，请设置 EASYTIER_NO_TUN=1 后重试。"
    fi
  elif ask_yes_no "仍以无 TUN 模式继续" "n"; then
    NO_TUN=1
    warn "将使用无 TUN 模式；本机不会创建 EasyTier 虚拟网卡。"
  else
    die "已停止。请在宿主机开启 TUN 后重试。"
  fi
}

normalise_proxy() {
  if [ -n "$GITHUB_PROXY" ] && [[ "$GITHUB_PROXY" != */ ]]; then
    GITHUB_PROXY="${GITHUB_PROXY}/"
  fi
}

fetch_url() {
  local url="$1"
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 -A "easytier-one-click/${SCRIPT_VERSION}" "${GITHUB_PROXY}${url}"
}

extract_release_tag() {
  printf '%s' "$1" \
    | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
    | head -n1
}

extract_asset_digest() {
  local wanted="$1"
  local names=""
  local digests=""
  local name=""
  local digest=""
  local index=1

  names="$(printf '%s' "$RELEASE_JSON" | grep -oE '"name"[[:space:]]*:[[:space:]]*"easytier-linux-[^"]+\.zip"' | sed -nE 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' || true)"
  digests="$(printf '%s' "$RELEASE_JSON" | grep -oE '"digest"[[:space:]]*:[[:space:]]*"sha256:[^"]+"' | sed -nE 's/.*"digest"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' || true)"

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    digest="$(printf '%s\n' "$digests" | sed -n "${index}p")"
    if [ "$name" = "$wanted" ]; then
      printf '%s' "$digest"
      return 0
    fi
    index=$((index + 1))
  done <<< "$names"

  return 0
}

load_release_metadata() {
  local metadata=""

  log "读取 EasyTier 最新 Release 信息。"
  if ! metadata="$(fetch_url "$EASYTIER_RELEASE_API")"; then
    if [ -n "$GITHUB_PROXY" ]; then
      die "无法通过指定的 GitHub 代理读取 Release 信息：$GITHUB_PROXY"
    fi
    warn "直连 GitHub 失败。"
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
      die "请设置 EASYTIER_GITHUB_PROXY 或使用 --proxy URL 后重试。"
    fi
    if ask_yes_no "尝试使用 ghfast.top 作为 GitHub 加速前缀" "y"; then
      GITHUB_PROXY="https://ghfast.top/"
      metadata="$(fetch_url "$EASYTIER_RELEASE_API")" || die "GitHub 直连和加速访问都失败。"
    else
      die "没有可用的 GitHub 下载通道。"
    fi
  fi

  RELEASE_JSON="$metadata"
  RELEASE_VERSION="$(extract_release_tag "$RELEASE_JSON")"
  [ -n "$RELEASE_VERSION" ] || die "GitHub Release 返回内容异常，未找到版本号。"

  ASSET_NAME="easytier-linux-${ARCH}-${RELEASE_VERSION}.zip"
  EXPECTED_DIGEST="$(extract_asset_digest "$ASSET_NAME")"
  log "目标版本：${RELEASE_VERSION}；下载资产：${ASSET_NAME}"
  if [ -n "$EXPECTED_DIGEST" ]; then
    log "Release SHA-256：${EXPECTED_DIGEST#sha256:}"
  else
    warn "当前 Release API 未返回资产摘要，将跳过 SHA-256 校验。"
  fi
}

binary_version() {
  local binary="$1"
  "$binary" --version 2>/dev/null | head -n1 || true
}

download_and_install_binary() {
  local temp_dir=""
  local zip_file=""
  local download_url=""
  local extracted_core=""
  local extracted_cli=""
  local actual_digest=""

  temp_dir="$(mktemp -d /tmp/easytier-installer.XXXXXX)"
  zip_file="${temp_dir}/${ASSET_NAME}"
  download_url="https://github.com/${EASYTIER_REPOSITORY}/releases/download/${RELEASE_VERSION}/${ASSET_NAME}"

  log "下载 EasyTier：${GITHUB_PROXY}${download_url}"
  curl -fL --retry 3 --connect-timeout 10 --max-time 300 -A "easytier-one-click/${SCRIPT_VERSION}" \
    "${GITHUB_PROXY}${download_url}" -o "$zip_file"

  if [ -n "$EXPECTED_DIGEST" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      actual_digest="$(sha256sum "$zip_file" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      actual_digest="$(shasum -a 256 "$zip_file" | awk '{print $1}')"
    else
      die "无法找到 sha256sum 或 shasum，不能校验下载文件。"
    fi
    [ "$actual_digest" = "${EXPECTED_DIGEST#sha256:}" ] \
      || die "下载文件 SHA-256 校验失败。期望 ${EXPECTED_DIGEST#sha256:}，实际 ${actual_digest}。"
    success "下载文件 SHA-256 校验通过。"
  fi

  mkdir -p "${temp_dir}/extract"
  unzip -q "$zip_file" -d "${temp_dir}/extract"
  extracted_core="$(find "${temp_dir}/extract" -type f -name easytier-core -print -quit)"
  extracted_cli="$(find "${temp_dir}/extract" -type f -name easytier-cli -print -quit)"
  [ -n "$extracted_core" ] || die "压缩包中没有 easytier-core，下载资产可能不匹配。"
  [ -n "$extracted_cli" ] || warn "压缩包中没有 easytier-cli，核心服务仍可安装。"

  install -d -m 0755 "$INSTALL_DIR"
  install -m 0755 "$extracted_core" "${INSTALL_DIR}/easytier-core"
  if [ -n "$extracted_cli" ]; then
    install -m 0755 "$extracted_cli" "${INSTALL_DIR}/easytier-cli"
  fi
  rm -rf "$temp_dir"

  CORE_VERSION="$(binary_version "${INSTALL_DIR}/easytier-core")"
  [ -n "$CORE_VERSION" ] || die "EasyTier 核心程序安装后无法执行 --version。"
  success "EasyTier 已安装：${CORE_VERSION}"
}

select_or_install_binary() {
  local existing_version=""
  local update_existing=1

  if [ -x "${INSTALL_DIR}/easytier-core" ] && [ "$FORCE_UPDATE" -eq 0 ]; then
    existing_version="$(binary_version "${INSTALL_DIR}/easytier-core")"
    if [ -n "$existing_version" ]; then
      if [ "$NON_INTERACTIVE" -eq 1 ]; then
        update_existing=0
      elif ! ask_yes_no "检测到已有 EasyTier（${existing_version}），是否更新到最新版本" "y"; then
        update_existing=0
      fi
    fi
  fi

  if [ "$update_existing" -eq 0 ]; then
    CORE_VERSION="$existing_version"
    log "保留已有 EasyTier：${CORE_VERSION}"
  else
    load_release_metadata
    download_and_install_binary
  fi

  install -d -m 0755 /usr/local/bin
  ln -sfn "${INSTALL_DIR}/easytier-core" /usr/local/bin/easytier-core
  if [ -x "${INSTALL_DIR}/easytier-cli" ]; then
    ln -sfn "${INSTALL_DIR}/easytier-cli" /usr/local/bin/easytier-cli
  fi
}

validate_text() {
  local value="$1"
  local label="$2"
  [ -n "$value" ] || die "${label}不能为空。"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]] \
    || die "${label}不能包含换行、回车或制表符。"
}

validate_port() {
  local value="$1"
  local label="$2"
  local numeric=0
  [[ "$value" =~ ^[0-9]+$ ]] || die "${label}必须是 1-65535 的数字。"
  numeric=$((10#$value))
  (( numeric >= 1 && numeric <= 65535 )) || die "${label}必须是 1-65535 的数字。"
}

toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

collect_network_config() {
  local secret_confirm=""
  local role_choice=""
  local peer_host_input=""

  if [ -z "$NETWORK_NAME" ]; then
    NETWORK_NAME="$(ask_value "网络名称" "")"
  fi
  validate_text "$NETWORK_NAME" "网络名称"

  if [ -z "$NETWORK_SECRET" ]; then
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
      [ "$ALLOW_EMPTY_SECRET" -eq 1 ] || die "非交互模式必须设置 EASYTIER_NETWORK_SECRET；如确实需要空密码，请同时加 --allow-empty-secret。"
    else
      NETWORK_SECRET="$(ask_secret "网络密码（输入时不显示）")"
      if [ -z "$NETWORK_SECRET" ] && [ "$ALLOW_EMPTY_SECRET" -eq 0 ]; then
        die "网络密码不能为空；如确实需要开放网络，请加 --allow-empty-secret 后重试。"
      fi
      if [ -n "$NETWORK_SECRET" ]; then
        secret_confirm="$(ask_secret "再次输入网络密码")"
        [ "$NETWORK_SECRET" = "$secret_confirm" ] || die "两次输入的网络密码不一致。"
      fi
    fi
  fi
  if [ -z "$NETWORK_SECRET" ] && [ "$ALLOW_EMPTY_SECRET" -eq 0 ]; then
    die "网络密码不能为空。"
  fi
  if [ -n "$NETWORK_SECRET" ]; then
    validate_text "$NETWORK_SECRET" "网络密码"
  fi

  if [ "$ROLE_EXPLICIT" -eq 0 ] && [ "$NON_INTERACTIVE" -eq 0 ]; then
    printf '\n节点模式：\n' >&2
    printf '  1) 普通加入节点（默认不监听本地端口，适合连接共享节点）\n' >&2
    printf '  2) 共享/公网节点（监听 TCP+UDP，需放行云防火墙端口）\n' >&2
    role_choice="$(ask_value "请选择 1 或 2" "1")"
    case "$role_choice" in
      1) NODE_ROLE="client" ;;
      2) NODE_ROLE="relay" ;;
      *) die "节点模式选择无效。" ;;
    esac
  elif [ "$NODE_ROLE" != "client" ] && [ "$NODE_ROLE" != "relay" ]; then
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
      die "--role 只能是 client 或 relay。"
    fi
    die "节点模式只能是 client 或 relay。"
  fi

  if [ "$NODE_ROLE" = "relay" ]; then
    if [ -z "${EASYTIER_LISTEN_PORT:-}" ] && [ "$NON_INTERACTIVE" -eq 0 ]; then
      LISTEN_PORT="$(ask_value "共享节点监听端口" "$LISTEN_PORT")"
    fi
    validate_port "$LISTEN_PORT" "共享节点监听端口"
  fi

  if [ "$NO_PEER" -eq 0 ] && [ -z "$PEER_HOST" ]; then
    peer_host_input="$(ask_value "初始节点地址（可留空表示稍后手动配置）" "")"
    PEER_HOST="$peer_host_input"
  fi

  if [ -n "$PEER_HOST" ]; then
    if [[ "$PEER_HOST" == *://* ]]; then
      PEER_URI="$PEER_HOST"
    else
      if [ "$NON_INTERACTIVE" -eq 0 ] && [ "${EASYTIER_PEER_PROTOCOL:-}" = "" ]; then
        PEER_PROTOCOL="$(ask_value "初始节点协议" "$PEER_PROTOCOL")"
      fi
      case "$PEER_PROTOCOL" in
        tcp|udp|quic|ws|wss|faketcp) ;;
        *) die "不支持的初始节点协议：$PEER_PROTOCOL。" ;;
      esac
      if [ "$NON_INTERACTIVE" -eq 0 ] && [ -z "${EASYTIER_PEER_PORT:-}" ]; then
        PEER_PORT="$(ask_value "初始节点端口" "$PEER_PORT")"
      fi
      validate_port "$PEER_PORT" "初始节点端口"
      if [[ "$PEER_HOST" == *:* && "$PEER_HOST" != \[*\] ]]; then
        PEER_HOST="[${PEER_HOST}]"
      fi
      PEER_URI="${PEER_PROTOCOL}://${PEER_HOST}:${PEER_PORT}"
    fi
    [[ "$PEER_URI" != *[[:space:]]* ]] || die "初始节点地址不能包含空格。"
  fi

  if [ -z "$NODE_HOSTNAME" ]; then
    NODE_HOSTNAME="$(hostname -s 2>/dev/null || hostname)"
  fi
  validate_text "$NODE_HOSTNAME" "主机名"

  if port_is_in_use "$RPC_PORT"; then
    RPC_PORT=0
    warn "本机 127.0.0.1:15888 已被占用，EasyTier RPC 将使用随机本地端口。"
  fi
}

port_is_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -H -lntu 2>/dev/null | awk -v port=":${port}" '$5 ~ port "$" {found=1} END {exit !found}'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lntu 2>/dev/null | awk -v port=":${port}" '$4 ~ port "$" {found=1} END {exit !found}'
  else
    return 1
  fi
}

check_relay_port() {
  [ "$NODE_ROLE" = "relay" ] || return 0
  if port_is_in_use "$LISTEN_PORT"; then
    die "共享节点监听端口 ${LISTEN_PORT} 已被占用。请换一个端口，或先停止占用该端口的服务。"
  fi
}

stop_managed_service() {
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
      log "停止已有 ${SERVICE_NAME}.service，以便更新配置。"
      systemctl stop "${SERVICE_NAME}.service"
    fi
  elif rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
    log "停止已有 ${SERVICE_NAME}，以便更新配置。"
    rc-service "$SERVICE_NAME" stop
  fi
}

find_other_easytier_services() {
  local active_units=""
  local active_unit=""
  local process_list=""

  if [ "$INIT_SYSTEM" = "systemd" ]; then
    active_units="$(systemctl list-units --type=service --state=running --no-legend 'easytier*.service' 2>/dev/null \
      | awk '{print $1}' \
      | grep -v -Fx "${SERVICE_NAME}.service" || true)"
    if [ -n "$active_units" ]; then
      warn "检测到其他正在运行的 EasyTier systemd 服务：${active_units//$'\n'/, }"
      if [ "$NON_INTERACTIVE" -eq 1 ] || ! ask_yes_no "停止这些旧服务，避免 TUN/端口冲突" "n"; then
        die "请先停止旧 EasyTier 服务，或在确认后重新运行安装器。"
      fi
      while IFS= read -r active_unit; do
        [ -n "$active_unit" ] && systemctl stop "$active_unit"
      done <<< "$active_units"
    fi
  fi

  process_list="$(pgrep -af '[e]asytier-core' 2>/dev/null || true)"
  if [ -n "$process_list" ]; then
    warn "检测到未由 ${SERVICE_NAME} 管理的 EasyTier 进程：\n${process_list}"
    die "为避免误杀其他实例，安装器不会自动终止该进程；请先手动停止后重试。"
  fi
}

write_config() {
  local tmp_config=""
  local escaped_network=""
  local escaped_secret=""
  local escaped_hostname=""

  install -d -m 0700 "$CONFIG_DIR" "$CONFIG_BACKUP_DIR"
  if [ -f "$CONFIG_FILE" ]; then
    cp -p "$CONFIG_FILE" "${CONFIG_BACKUP_DIR}/easytier.conf.$(date +%Y%m%d%H%M%S)"
    log "旧配置已备份到 ${CONFIG_BACKUP_DIR}。"
  fi

  escaped_network="$(toml_escape "$NETWORK_NAME")"
  escaped_secret="$(toml_escape "$NETWORK_SECRET")"
  escaped_hostname="$(toml_escape "$NODE_HOSTNAME")"
  tmp_config="$(mktemp "${CONFIG_DIR}/.easytier.conf.XXXXXX")"

  {
    printf '# Generated by easytier-one-click %s\n' "$SCRIPT_VERSION"
    printf '# Do not commit this file: it contains the network secret.\n\n'
    printf 'instance_name = "easytier-node"\n'
    printf 'hostname = "%s"\n' "$escaped_hostname"
    if [ "$NO_TUN" -eq 0 ]; then
      printf 'dhcp = true\n'
    else
      printf 'dhcp = false\n'
    fi
    if [ "$NODE_ROLE" = "relay" ]; then
      printf 'listeners = ["tcp://0.0.0.0:%s", "udp://0.0.0.0:%s"]\n' "$LISTEN_PORT" "$LISTEN_PORT"
    else
      printf 'listeners = []\n'
    fi
    printf 'mapped_listeners = []\n'
    printf 'exit_nodes = []\n'
    printf 'rpc_portal = "127.0.0.1:%s"\n\n' "$RPC_PORT"
    printf '[network_identity]\n'
    printf 'network_name = "%s"\n' "$escaped_network"
    printf 'network_secret = "%s"\n\n' "$escaped_secret"
    if [ -n "$PEER_URI" ]; then
      printf '[[peer]]\n'
      printf 'uri = "%s"\n\n' "$(toml_escape "$PEER_URI")"
    fi
    printf '[flags]\n'
    printf 'default_protocol = "udp"\n'
    printf 'dev_name = ""\n'
    printf 'enable_encryption = true\n'
    printf 'enable_ipv6 = true\n'
    printf 'mtu = 1380\n'
    printf 'latency_first = false\n'
    printf 'enable_exit_node = false\n'
    printf 'no_tun = %s\n' "$([ "$NO_TUN" -eq 1 ] && printf true || printf false)"
    printf 'use_smoltcp = false\n'
    printf 'foreign_network_whitelist = "*"\n'
    printf 'disable_p2p = false\n'
    printf 'relay_all_peer_rpc = false\n'
    printf 'disable_udp_hole_punching = false\n'
    printf 'disable_tcp_hole_punching = false\n'
  } > "$tmp_config"

  chmod 0600 "$tmp_config"
  mv -f "$tmp_config" "$CONFIG_FILE"
  success "配置文件已生成：${CONFIG_FILE}（权限 600）"
}

write_systemd_unit() {
  local listener_flag=""
  [ "$NODE_ROLE" = "client" ] && listener_flag=" --no-listener"

  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=EasyTier network node
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/easytier-core --config-file ${CONFIG_FILE}${listener_flag}
Restart=always
RestartSec=5s
TimeoutStopSec=30s
LimitNOFILE=1048576
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service" >/dev/null
}

write_openrc_script() {
  local listener_flag=""
  [ "$NODE_ROLE" = "client" ] && listener_flag=" --no-listener"

  cat > "$OPENRC_SCRIPT" <<EOF
#!/sbin/openrc-run

name="EasyTier network node"
description="EasyTier network node"
command="${INSTALL_DIR}/easytier-core"
command_args="--config-file ${CONFIG_FILE}${listener_flag}"
command_background="yes"
pidfile="/run/${SERVICE_NAME}.pid"
output_log="/var/log/${SERVICE_NAME}.log"
error_log="/var/log/${SERVICE_NAME}.err"

depend() {
    need net
    after firewall
}
EOF
  chmod 0755 "$OPENRC_SCRIPT"
  rc-update add "$SERVICE_NAME" default >/dev/null
}

configure_firewall() {
  [ "$NODE_ROLE" = "relay" ] || return 0
  [ "$AUTO_FIREWALL" = "1" ] || {
    warn "已跳过系统防火墙配置；共享节点需要放行 TCP/UDP ${LISTEN_PORT}。"
    return 0
  }

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${LISTEN_PORT}/tcp" >/dev/null
    ufw allow "${LISTEN_PORT}/udp" >/dev/null
    success "已通过 ufw 放行 TCP/UDP ${LISTEN_PORT}。"
  elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${LISTEN_PORT}/tcp" >/dev/null
    firewall-cmd --permanent --add-port="${LISTEN_PORT}/udp" >/dev/null
    firewall-cmd --reload >/dev/null
    success "已通过 firewalld 放行 TCP/UDP ${LISTEN_PORT}。"
  else
    warn "未识别到 ufw/firewalld。请同时在 VPS 云防火墙和系统防火墙放行 TCP/UDP ${LISTEN_PORT}。"
  fi
}

start_service() {
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    write_systemd_unit
    systemctl restart "${SERVICE_NAME}.service"
    sleep 2
    if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
      systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
      if command -v journalctl >/dev/null 2>&1; then
        journalctl -u "${SERVICE_NAME}.service" -n 80 --no-pager || true
      fi
      die "EasyTier 服务启动失败。"
    fi
  else
    write_openrc_script
    rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || rc-service "$SERVICE_NAME" start
    sleep 2
    rc-service "$SERVICE_NAME" status || die "EasyTier OpenRC 服务启动失败。"
  fi
  success "EasyTier 已启动，并已配置为开机启动。"
}

show_summary() {
  printf '\n%b================ EasyTier 安装完成 ================%b\n' "$GREEN" "$RESET"
  printf '版本：%s\n' "$CORE_VERSION"
  printf '模式：%s\n' "$([ "$NODE_ROLE" = "relay" ] && printf '共享/公网节点' || printf '普通加入节点')"
  printf '网络名称：%s\n' "$NETWORK_NAME"
  if [ -n "$PEER_URI" ]; then
    printf '初始节点：%s\n' "$PEER_URI"
  else
    printf '初始节点：未设置\n'
  fi
  if [ "$NODE_ROLE" = "relay" ]; then
    printf '本地监听：TCP/UDP %s\n' "$LISTEN_PORT"
  else
    printf '本地监听：关闭（不会抢占共享节点的 11010）\n'
  fi
  printf '配置文件：%s\n' "$CONFIG_FILE"
  printf '安装目录：%s\n' "$INSTALL_DIR"
  printf '\n管理命令：\n'
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    printf '  systemctl status %s\n' "$SERVICE_NAME"
    printf '  systemctl restart %s\n' "$SERVICE_NAME"
    printf '  journalctl -u %s -f\n' "$SERVICE_NAME"
  else
    printf '  rc-service %s status\n' "$SERVICE_NAME"
    printf '  rc-service %s restart\n' "$SERVICE_NAME"
    printf '  tail -f /var/log/%s.log\n' "$SERVICE_NAME"
  fi
  if [ -x /usr/local/bin/easytier-cli ] && [ "$RPC_PORT" -ne 0 ]; then
    printf '\n虚拟网络状态：\n'
    /usr/local/bin/easytier-cli node 2>/dev/null || warn "easytier-cli 暂时无法读取节点状态，请稍后执行 easytier-cli node。"
    printf '\n对等节点：\n'
    /usr/local/bin/easytier-cli peer 2>/dev/null || true
  fi
  if [ "$NO_TUN" -eq 1 ]; then
    warn "当前使用无 TUN 模式，不会出现 EasyTier 虚拟网卡。"
  fi
  printf '%b====================================================%b\n' "$GREEN" "$RESET"
}

main() {
  parse_args "$@"
  normalise_proxy
  require_root
  detect_os
  detect_arch
  detect_init_system
  install_dependencies
  check_tun
  stop_managed_service
  find_other_easytier_services
  select_or_install_binary
  collect_network_config
  check_relay_port
  write_config
  configure_firewall
  start_service
  show_summary
}

main "$@"
