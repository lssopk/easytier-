#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SERVICE_NAME="easytier-node"
readonly CONFIG_DIR="${EASYTIER_MENU_CONFIG_DIR:-/etc/easytier}"
readonly FIREWALL_CONFIG="${CONFIG_DIR}/firewall.conf"
readonly FIREWALL_SYSTEMD_UNIT="/etc/systemd/system/easytier-firewall.service"
readonly FIREWALL_OPENRC_SCRIPT="/etc/init.d/easytier-firewall"
readonly NFT_TABLE="easytier_forward"
readonly IPTABLES_CHAIN="EASYTIER_FORWARD"

RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[1;34m'
RESET=$'\033[0m'

FIREWALL_ENABLED=0
EASYTIER_IFACE="easytier0"
LAN_IFACES=""
WAN_IFACES=""
ET_TO_LAN=0
ET_TO_WAN=0
LAN_TO_ET=0
WAN_TO_ET=0
FIREWALL_BACKEND=""

log() {
  printf '%b[EasyTier]%b %s\n' "$BLUE" "$RESET" "$*"
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

require_root() {
  [ "$(id -u)" -eq 0 ] || die "快捷菜单需要 root 权限，请使用 sudo easytier-menu。"
}

init_system() {
  local pid1=""
  pid1="$(cat /proc/1/comm 2>/dev/null || true)"
  if [ "$pid1" = "systemd" ] && command -v systemctl >/dev/null 2>&1; then
    printf '%s' systemd
  elif command -v rc-service >/dev/null 2>&1; then
    printf '%s' openrc
  else
    printf '%s' none
  fi
}

read_tty() {
  local answer=""
  if [ -r /dev/tty ]; then
    IFS= read -r answer < /dev/tty || true
  else
    IFS= read -r answer || true
  fi
  printf '%s' "$answer"
}

ask_value() {
  local prompt="$1"
  local default_value="${2:-}"
  local answer=""

  if [ -n "$default_value" ]; then
    printf '%s [%s]：' "$prompt" "$default_value" >&2
  else
    printf '%s：' "$prompt" >&2
  fi
  answer="$(read_tty)"
  printf '%s' "${answer:-$default_value}"
}

ask_toggle() {
  local prompt="$1"
  local current="$2"
  local answer=""

  if [ "$current" = "1" ]; then
    printf '%s [Y/n]：' "$prompt" >&2
  else
    printf '%s [y/N]：' "$prompt" >&2
  fi
  answer="$(read_tty)"
  case "$answer" in
    "")
      printf '%s' "$current"
      ;;
    [Yy]|[Yy][Ee][Ss])
      printf '1'
      ;;
    [Nn]|[Nn][Oo])
      printf '0'
      ;;
    1)
      printf '1'
      ;;
    0)
      printf '0'
      ;;
    *)
      warn "输入无效，保持原值。"
      printf '%s' "$current"
      ;;
  esac
}

load_firewall_config() {
  FIREWALL_ENABLED=0
  EASYTIER_IFACE="easytier0"
  LAN_IFACES=""
  WAN_IFACES=""
  ET_TO_LAN=0
  ET_TO_WAN=0
  LAN_TO_ET=0
  WAN_TO_ET=0

  if [ -f "$FIREWALL_CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$FIREWALL_CONFIG"
  fi

  FIREWALL_ENABLED="${FIREWALL_ENABLED:-0}"
  EASYTIER_IFACE="${EASYTIER_IFACE:-easytier0}"
  LAN_IFACES="${LAN_IFACES:-}"
  WAN_IFACES="${WAN_IFACES:-}"
  ET_TO_LAN="${ET_TO_LAN:-0}"
  ET_TO_WAN="${ET_TO_WAN:-0}"
  LAN_TO_ET="${LAN_TO_ET:-0}"
  WAN_TO_ET="${WAN_TO_ET:-0}"
}

validate_iface_name() {
  local iface="$1"
  [ -n "$iface" ] || return 1
  [ "${#iface}" -le 15 ] || return 1
  [[ "$iface" =~ ^[a-zA-Z0-9_.:-]+$ ]]
}

validate_iface_list() {
  local list="$1"
  local iface=""
  local -a interfaces=()
  local old_ifs="$IFS"

  IFS=' ' read -r -a interfaces <<< "$list"
  IFS="$old_ifs"
  for iface in "${interfaces[@]}"; do
    [ -n "$iface" ] || continue
    validate_iface_name "$iface" || die "网卡名称无效：$iface"
  done
}

validate_config() {
  case "$FIREWALL_ENABLED" in 0|1) ;; *) die "FIREWALL_ENABLED 必须是 0 或 1。" ;; esac
  for value in "$ET_TO_LAN" "$ET_TO_WAN" "$LAN_TO_ET" "$WAN_TO_ET"; do
    case "$value" in 0|1) ;; *) die "转发开关必须是 0 或 1。" ;; esac
  done
  validate_iface_name "$EASYTIER_IFACE" || die "EasyTier 虚拟网卡名称无效：$EASYTIER_IFACE"
  validate_iface_list "$LAN_IFACES"
  validate_iface_list "$WAN_IFACES"
}

interface_exists() {
  ip link show dev "$1" >/dev/null 2>&1
}

default_route_iface() {
  local iface=""
  iface="$(ip -4 route show default 2>/dev/null \
    | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }' \
    || true)"
  if [ -z "$iface" ]; then
    iface="$(ip -6 route show default 2>/dev/null \
      | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }' \
      || true)"
  fi
  printf '%s' "$iface"
}

detect_defaults() {
  local candidate=""

  if ! interface_exists "$EASYTIER_IFACE"; then
    candidate="$(ip -o link show 2>/dev/null \
      | awk -F': ' '{print $2}' \
      | cut -d@ -f1 \
      | grep -E '^(easytier|et_)' \
      | head -n1 \
      || true)"
    [ -n "$candidate" ] && EASYTIER_IFACE="$candidate"
  fi

  if [ -z "$WAN_IFACES" ]; then
    WAN_IFACES="$(default_route_iface)"
  fi

  if [ -z "$LAN_IFACES" ] && interface_exists br-lan; then
    LAN_IFACES="br-lan"
  fi
}

available_interfaces() {
  ip -o link show 2>/dev/null \
    | awk -F': ' '{print $2}' \
    | cut -d@ -f1 \
    | sort -u \
    | tr '\n' ' '
}

save_firewall_config() {
  local temp_config=""
  temp_config="$(mktemp "${FIREWALL_CONFIG}.XXXXXX")"
  {
    printf '# Managed by easytier-menu.\n'
    printf 'FIREWALL_ENABLED=%q\n' "$FIREWALL_ENABLED"
    printf 'EASYTIER_IFACE=%q\n' "$EASYTIER_IFACE"
    printf 'LAN_IFACES=%q\n' "$LAN_IFACES"
    printf 'WAN_IFACES=%q\n' "$WAN_IFACES"
    printf 'ET_TO_LAN=%q\n' "$ET_TO_LAN"
    printf 'ET_TO_WAN=%q\n' "$ET_TO_WAN"
    printf 'LAN_TO_ET=%q\n' "$LAN_TO_ET"
    printf 'WAN_TO_ET=%q\n' "$WAN_TO_ET"
  } > "$temp_config"
  chmod 0600 "$temp_config"
  mv -f "$temp_config" "$FIREWALL_CONFIG"
}

firewall_backend() {
  if command -v nft >/dev/null 2>&1; then
    printf '%s' nft
  elif command -v iptables >/dev/null 2>&1; then
    printf '%s' iptables
  else
    printf '%s' none
  fi
}

nft_ifset() {
  local list="$1"
  local iface=""
  local result=""
  local -a interfaces=()
  local old_ifs="$IFS"

  IFS=' ' read -r -a interfaces <<< "$list"
  IFS="$old_ifs"
  for iface in "${interfaces[@]}"; do
    [ -n "$iface" ] || continue
    result="${result:+$result, }\"${iface}\""
  done
  [ -n "$result" ] && printf '{ %s }' "$result"
}

write_nft_rule() {
  local source_iface="$1"
  local destination_list="$2"
  local allow="$3"
  local destination_set=""

  [ -n "$destination_list" ] || return 0
  destination_set="$(nft_ifset "$destination_list")"
  [ -n "$destination_set" ] || return 0
  if [ "$allow" = "1" ]; then
    printf '    iifname "%s" oifname %s accept\n' "$source_iface" "$destination_set"
  else
    printf '    iifname "%s" oifname %s drop\n' "$source_iface" "$destination_set"
  fi
}

write_nft_reverse_rule() {
  local source_list="$1"
  local destination_iface="$2"
  local allow="$3"
  local source_set=""

  [ -n "$source_list" ] || return 0
  source_set="$(nft_ifset "$source_list")"
  [ -n "$source_set" ] || return 0
  if [ "$allow" = "1" ]; then
    printf '    iifname %s oifname "%s" accept\n' "$source_set" "$destination_iface"
  else
    printf '    iifname %s oifname "%s" drop\n' "$source_set" "$destination_iface"
  fi
}

remove_iptables_rules() {
  local ipt="${1:-iptables}"
  local count=0

  command -v "$ipt" >/dev/null 2>&1 || return 0
  while "$ipt" -C FORWARD -j "$IPTABLES_CHAIN" >/dev/null 2>&1; do
    "$ipt" -D FORWARD -j "$IPTABLES_CHAIN" >/dev/null 2>&1 || break
    count=$((count + 1))
    [ "$count" -lt 100 ] || break
  done
  "$ipt" -F "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
  "$ipt" -X "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
}

write_iptables_rule() {
  local ipt="$1"
  local source_iface="$2"
  local destination_list="$3"
  local allow="$4"
  local action="DROP"
  local iface=""
  local -a interfaces=()
  local old_ifs="$IFS"

  [ -n "$destination_list" ] || return 0
  [ "$allow" = "1" ] && action="ACCEPT"
  IFS=' ' read -r -a interfaces <<< "$destination_list"
  IFS="$old_ifs"
  for iface in "${interfaces[@]}"; do
    [ -n "$iface" ] || continue
    "$ipt" -A "$IPTABLES_CHAIN" -i "$source_iface" -o "$iface" -j "$action"
  done
}

write_iptables_reverse_rule() {
  local ipt="$1"
  local source_list="$2"
  local destination_iface="$3"
  local allow="$4"
  local action="DROP"
  local iface=""
  local -a interfaces=()
  local old_ifs="$IFS"

  [ -n "$source_list" ] || return 0
  [ "$allow" = "1" ] && action="ACCEPT"
  IFS=' ' read -r -a interfaces <<< "$source_list"
  IFS="$old_ifs"
  for iface in "${interfaces[@]}"; do
    [ -n "$iface" ] || continue
    "$ipt" -A "$IPTABLES_CHAIN" -i "$iface" -o "$destination_iface" -j "$action"
  done
}

apply_nft_rules() {
  local temp_rules=""
  temp_rules="$(mktemp /tmp/easytier-nft.XXXXXX)"

  remove_iptables_rules iptables
  nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
  {
    printf 'table inet %s {\n' "$NFT_TABLE"
    printf '  chain forward {\n'
    printf '    type filter hook forward priority -10; policy accept;\n'
    printf '    ct state established,related accept\n'
    write_nft_rule "$EASYTIER_IFACE" "$LAN_IFACES" "$ET_TO_LAN"
    write_nft_rule "$EASYTIER_IFACE" "$WAN_IFACES" "$ET_TO_WAN"
    write_nft_reverse_rule "$LAN_IFACES" "$EASYTIER_IFACE" "$LAN_TO_ET"
    write_nft_reverse_rule "$WAN_IFACES" "$EASYTIER_IFACE" "$WAN_TO_ET"
    printf '  }\n'
    printf '}\n'
  } > "$temp_rules"

  if ! nft -f "$temp_rules"; then
    rm -f "$temp_rules"
    die "nftables 转发规则应用失败。"
  fi
  rm -f "$temp_rules"
}

apply_iptables_rules() {
  local ipt="iptables"

  nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
  remove_iptables_rules "$ipt"
  "$ipt" -N "$IPTABLES_CHAIN"
  "$ipt" -A "$IPTABLES_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  write_iptables_rule "$ipt" "$EASYTIER_IFACE" "$LAN_IFACES" "$ET_TO_LAN"
  write_iptables_rule "$ipt" "$EASYTIER_IFACE" "$WAN_IFACES" "$ET_TO_WAN"
  write_iptables_reverse_rule "$ipt" "$LAN_IFACES" "$EASYTIER_IFACE" "$LAN_TO_ET"
  write_iptables_reverse_rule "$ipt" "$WAN_IFACES" "$EASYTIER_IFACE" "$WAN_TO_ET"
  "$ipt" -I FORWARD 1 -j "$IPTABLES_CHAIN"
}

apply_forward_sysctl() {
  local has_allowed=0
  if [ "$ET_TO_LAN" = "1" ] || [ "$ET_TO_WAN" = "1" ] \
    || [ "$LAN_TO_ET" = "1" ] || [ "$WAN_TO_ET" = "1" ]; then
    has_allowed=1
  fi

  if [ "$has_allowed" = "1" ]; then
    install -d -m 0755 /etc/sysctl.d
    cat > /etc/sysctl.d/99-easytier-forward.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
    if command -v sysctl >/dev/null 2>&1; then
      sysctl -w net.ipv4.ip_forward=1 >/dev/null || warn "无法开启 IPv4 转发。"
      sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
    fi
  else
    rm -f /etc/sysctl.d/99-easytier-forward.conf
  fi
}

apply_firewall() {
  local backend=""
  load_firewall_config
  validate_config

  if [ "$FIREWALL_ENABLED" != "1" ]; then
    nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
    remove_iptables_rules iptables
    rm -f /etc/sysctl.d/99-easytier-forward.conf
    log "菜单管理的 LAN/WAN 转发规则未启用。"
    return 0
  fi

  backend="$(firewall_backend)"
  [ "$backend" != "none" ] || die "未找到 nft 或 iptables，无法应用转发规则。"
  FIREWALL_BACKEND="$backend"

  if [ "$backend" = "nft" ]; then
    apply_nft_rules
  else
    apply_iptables_rules
    warn "当前使用 iptables 后端，规则主要覆盖 IPv4。"
  fi
  apply_forward_sysctl
  success "已应用四向转发规则（后端：$backend）。"
}

show_forwarding_config() {
  load_firewall_config
  printf '\n转发配置：\n'
  printf '  菜单规则：%s\n' "$([ "$FIREWALL_ENABLED" = "1" ] && printf '启用' || printf '未启用')"
  printf '  EasyTier 网卡：%s\n' "$EASYTIER_IFACE"
  printf '  LAN 网卡：%s\n' "${LAN_IFACES:-未设置}"
  printf '  WAN 网卡：%s\n' "${WAN_IFACES:-未设置}"
  printf '  EasyTier → LAN：%s\n' "$([ "$ET_TO_LAN" = "1" ] && printf '允许' || printf '禁止')"
  printf '  EasyTier → WAN：%s\n' "$([ "$ET_TO_WAN" = "1" ] && printf '允许' || printf '禁止')"
  printf '  LAN → EasyTier：%s\n' "$([ "$LAN_TO_ET" = "1" ] && printf '允许' || printf '禁止')"
  printf '  WAN → EasyTier：%s\n' "$([ "$WAN_TO_ET" = "1" ] && printf '允许' || printf '禁止')"
}

configure_forwarding() {
  load_firewall_config
  detect_defaults

  printf '\n配置 LAN/WAN 与 EasyTier 虚拟网络的转发。\n' >&2
  printf '可用网卡：%s\n' "$(available_interfaces)" >&2
  printf '网卡名称使用空格分隔；LAN 没有网卡时可以直接回车。\n' >&2
  printf '四个开关控制新建连接方向，已建立连接的返回包会自动放行。\n\n' >&2

  EASYTIER_IFACE="$(ask_value "EasyTier 虚拟网卡" "$EASYTIER_IFACE")"
  LAN_IFACES="$(ask_value "LAN 网卡列表" "$LAN_IFACES")"
  WAN_IFACES="$(ask_value "WAN 网卡列表" "$WAN_IFACES")"
  ET_TO_LAN="$(ask_toggle "允许 EasyTier → LAN" "$ET_TO_LAN")"
  ET_TO_WAN="$(ask_toggle "允许 EasyTier → WAN" "$ET_TO_WAN")"
  LAN_TO_ET="$(ask_toggle "允许 LAN → EasyTier" "$LAN_TO_ET")"
  WAN_TO_ET="$(ask_toggle "允许 WAN → EasyTier" "$WAN_TO_ET")"

  FIREWALL_ENABLED=1
  validate_config
  save_firewall_config
  apply_firewall
}

disable_managed_forwarding() {
  load_firewall_config
  FIREWALL_ENABLED=0
  save_firewall_config
  apply_firewall
  success "已关闭菜单管理的转发规则；其他系统防火墙规则不受影响。"
}

service_action() {
  local action="$1"
  case "$(init_system)" in
    systemd)
      systemctl "$action" "${SERVICE_NAME}.service"
      ;;
    openrc)
      rc-service "$SERVICE_NAME" "$action"
      ;;
    *)
      die "未检测到 systemd 或 OpenRC。"
      ;;
  esac
}

show_status() {
  case "$(init_system)" in
    systemd)
      systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
      ;;
    openrc)
      rc-service "$SERVICE_NAME" status || true
      ;;
    *)
      die "未检测到 systemd 或 OpenRC。"
      ;;
  esac
}

show_logs() {
  case "$(init_system)" in
    systemd)
      command -v journalctl >/dev/null 2>&1 || die "当前系统没有 journalctl。"
      journalctl -u "${SERVICE_NAME}.service" -n 100 --no-pager
      printf '\n按 Ctrl+C 退出实时日志。\n' >&2
      journalctl -u "${SERVICE_NAME}.service" -f
      ;;
    openrc)
      [ -f "/var/log/${SERVICE_NAME}.log" ] || die "日志文件不存在：/var/log/${SERVICE_NAME}.log"
      tail -f "/var/log/${SERVICE_NAME}.log"
      ;;
    *)
      die "未检测到 systemd 或 OpenRC。"
      ;;
  esac
}

show_cli() {
  local command_name="$1"
  command -v easytier-cli >/dev/null 2>&1 || die "未找到 easytier-cli。"
  easytier-cli "$command_name" || true
}

print_menu() {
  printf '\n%b========== EasyTier 快捷启动菜单 ==========%b\n' "$GREEN" "$RESET"
  printf '  1) 启动 EasyTier\n'
  printf '  2) 停止 EasyTier\n'
  printf '  3) 重启 EasyTier\n'
  printf '  4) 查看运行状态\n'
  printf '  5) 查看实时日志\n'
  printf '  6) 查看本机节点信息\n'
  printf '  7) 查看对等节点和路由\n'
  printf '  8) 配置 LAN/WAN 转发开关\n'
  printf '  9) 应用当前转发规则\n'
  printf ' 10) 关闭菜单管理的转发规则\n'
  printf '  0) 退出\n'
  show_forwarding_config
  printf '%b============================================%b\n' "$GREEN" "$RESET"
}

main() {
  local choice=""

  require_root
  case "${1:-}" in
    --apply-firewall)
      apply_firewall
      return 0
      ;;
    --help|-h)
      printf '用法：easytier-menu [--apply-firewall]\n'
      return 0
      ;;
    "")
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac

  while true; do
    print_menu
    choice="$(ask_value "请选择操作" "0")"
    case "$choice" in
      1) service_action start ;;
      2) service_action stop ;;
      3) service_action restart ;;
      4) show_status ;;
      5) show_logs ;;
      6) show_cli node ;;
      7) show_cli peer; printf '\n'; show_cli route ;;
      8) configure_forwarding ;;
      9) apply_firewall ;;
      10) disable_managed_forwarding ;;
      0) exit 0 ;;
      *) warn "无效选项：$choice" ;;
    esac
    printf '\n按回车返回菜单。' >&2
    read_tty >/dev/null
  done
}

main "$@"
