#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_NAME="vpngate"
readonly MARK="0x64"
readonly ROUTE_TABLE="100"
readonly RULE_PRIORITY="10000"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly LOG_FILE="/var/log/${APP_NAME}-install.log"
readonly BACKUP_ROOT="/var/backups/${APP_NAME}"
readonly BACKUP_DIR="${BACKUP_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)"

WG_IF="wg0"
AWG_IF="awg0"
WG_ADDRESS="10.66.66.1/24"
WG_NETWORK="10.66.66.0/24"
WG_PORT="51820"
WG_DNS="10.66.66.1"
AWG_ADDRESS=""
AWG_PRIVATE_KEY=""
AWG_PEER_PUBLIC_KEY=""
AWG_PRESHARED_KEY=""
AWG_ENDPOINT=""
AWG_JC=""
AWG_JMIN=""
AWG_JMAX=""
AWG_S1=""
AWG_S2=""
AWG_H1=""
AWG_H2=""
AWG_H3=""
AWG_H4=""
AWG_MTU="1420"
WAN_IF=""

log() {
  local level="$1"; shift
  printf '[%s] %-5s %s\n' "$(date -Is)" "$level" "$*" | tee -a "$LOG_FILE" >&2
}

die() { log ERROR "$*"; exit 1; }

on_error() {
  local exit_code=$?
  log ERROR "Installation stopped at line ${BASH_LINENO[0]} (exit ${exit_code})."
  log ERROR "Existing files backed up in ${BACKUP_DIR}. No automatic rollback was attempted."
  exit "$exit_code"
}
trap on_error ERR

require_root() {
  [[ $EUID -eq 0 ]] || die "Run this installer as root: sudo ./install.sh"
}

check_platform() {
  [[ -r /etc/os-release ]] || die "Cannot identify the operating system."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]] || \
    die "This installer supports Ubuntu 24.04 only (found ${PRETTY_NAME:-unknown})."
}

prompt() {
  local variable="$1" label="$2" default="${3:-}" value
  if [[ -n $default ]]; then
    read -r -p "${label} [${default}]: " value
    value=${value:-$default}
  else
    while [[ -z ${value:-} ]]; do read -r -p "${label}: " value; done
  fi
  printf -v "$variable" '%s' "$value"
}

prompt_secret() {
  local variable="$1" label="$2" optional="${3:-false}" value=""
  while [[ -z $value && $optional != true ]]; do
    read -r -s -p "${label}: " value; printf '\n'
  done
  if [[ $optional == true ]]; then
    read -r -s -p "${label} (leave empty if unused): " value; printf '\n'
  fi
  printf -v "$variable" '%s' "$value"
}

valid_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
valid_cidr4() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    ipaddress.IPv4Interface(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PY
}
valid_network4() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    ipaddress.IPv4Network(sys.argv[1], strict=True)
except ValueError:
    raise SystemExit(1)
PY
}
valid_endpoint() {
  local endpoint="$1" port
  [[ $endpoint =~ ^(\[[0-9A-Fa-f:]+\]|[^[:space:]:]+):([0-9]{1,5})$ ]] || return 1
  port=${BASH_REMATCH[2]}
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}
valid_key() { [[ $1 =~ ^[A-Za-z0-9+/]{43}=$ ]]; }

ask_parameters() {
  local detected_wan detected_network
  detected_wan=$(ip -4 route show default | awk 'NR==1 {print $5}')
  prompt WAN_IF "Internet-facing interface" "${detected_wan:-eth0}"
  prompt WG_ADDRESS "wg0 server address (CIDR)" "$WG_ADDRESS"
  valid_cidr4 "$WG_ADDRESS" || die "Invalid wg0 IPv4 CIDR: ${WG_ADDRESS}"
  detected_network=$(python3 - "$WG_ADDRESS" <<'PY'
import ipaddress, sys
print(ipaddress.IPv4Interface(sys.argv[1]).network)
PY
)
  prompt WG_NETWORK "wg0 client network" "$detected_network"
  valid_network4 "$WG_NETWORK" || die "Invalid wg0 network: ${WG_NETWORK}"
  prompt WG_PORT "wg0 UDP listen port" "$WG_PORT"
  valid_uint "$WG_PORT" && (( WG_PORT >= 1 && WG_PORT <= 65535 )) || die "Invalid wg0 port."
  WG_DNS=${WG_ADDRESS%/*}

  printf '\nAmneziaWG client parameters (exported client configuration):\n'
  prompt AWG_ADDRESS "awg0 client address (CIDR)"
  valid_cidr4 "$AWG_ADDRESS" || die "Invalid awg0 address: ${AWG_ADDRESS}"
  prompt_secret AWG_PRIVATE_KEY "awg0 private key"
  valid_key "$AWG_PRIVATE_KEY" || die "awg0 private key has an invalid WireGuard key format."
  prompt_secret AWG_PEER_PUBLIC_KEY "AmneziaWG server public key"
  valid_key "$AWG_PEER_PUBLIC_KEY" || die "Server public key has an invalid WireGuard key format."
  prompt_secret AWG_PRESHARED_KEY "Preshared key" true
  [[ -z $AWG_PRESHARED_KEY ]] || valid_key "$AWG_PRESHARED_KEY" || die "Preshared key has an invalid format."
  prompt AWG_ENDPOINT "Server endpoint (host:port)"
  valid_endpoint "$AWG_ENDPOINT" || die "Endpoint must look like vpn.example.com:443 or [IPv6]:443."
  prompt AWG_JC "Jc" "4"
  prompt AWG_JMIN "Jmin" "8"
  prompt AWG_JMAX "Jmax" "80"
  prompt AWG_S1 "S1" "40"
  prompt AWG_S2 "S2" "60"
  prompt AWG_H1 "H1"
  prompt AWG_H2 "H2"
  prompt AWG_H3 "H3"
  prompt AWG_H4 "H4"
  prompt AWG_MTU "awg0 MTU" "$AWG_MTU"

  for value in "$AWG_JC" "$AWG_JMIN" "$AWG_JMAX" "$AWG_S1" "$AWG_S2" \
               "$AWG_H1" "$AWG_H2" "$AWG_H3" "$AWG_H4" "$AWG_MTU"; do
    valid_uint "$value" || die "AmneziaWG numeric parameters must be non-negative integers."
  done
  (( AWG_JC >= 1 && AWG_JC <= 128 )) || die "Jc must be between 1 and 128."
  (( AWG_JMIN < AWG_JMAX && AWG_JMAX <= 1280 )) || die "Require Jmin < Jmax <= 1280."
  (( AWG_S1 <= 1132 && AWG_S2 <= 1188 && AWG_S1 + 56 != AWG_S2 )) || die "Invalid S1/S2 combination."
  [[ $AWG_H1 != "$AWG_H2" && $AWG_H1 != "$AWG_H3" && $AWG_H1 != "$AWG_H4" && \
     $AWG_H2 != "$AWG_H3" && $AWG_H2 != "$AWG_H4" && $AWG_H3 != "$AWG_H4" ]] || \
    die "H1, H2, H3 and H4 must be unique."
  for value in "$AWG_H1" "$AWG_H2" "$AWG_H3" "$AWG_H4"; do
    (( value >= 1 && value <= 2147483647 )) || die "H1-H4 must be between 1 and 2147483647."
  done

  printf '\nConfiguration summary:\n'
  printf '  WAN: %s\n  wg0: %s, UDP %s, clients %s\n  awg0: %s -> %s\n' \
    "$WAN_IF" "$WG_ADDRESS" "$WG_PORT" "$WG_NETWORK" "$AWG_ADDRESS" "$AWG_ENDPOINT"
  read -r -p "Continue and modify this host? [y/N]: " answer
  [[ $answer =~ ^[Yy]$ ]] || die "Cancelled by user."
}

backup_file() {
  local path="$1" target
  [[ -e $path || -L $path ]] || return 0
  target="${BACKUP_DIR}${path}"
  install -d -m 0700 "$(dirname -- "$target")"
  cp -a -- "$path" "$target"
  printf '%s\n' "$path" >>"${BACKUP_DIR}/MANIFEST"
}

install_packages() {
  log INFO "Installing Ubuntu and AmneziaWG packages."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y software-properties-common python3-launchpadlib gnupg2 \
    "linux-headers-$(uname -r)" wireguard-tools nftables dnsmasq qrencode
  if ! grep -RqsE '^[[:space:]]*deb .*ppa\.launchpadcontent\.net/amnezia/ppa/' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    add-apt-repository -y ppa:amnezia/ppa
  fi
  apt-get update
  apt-get install -y amneziawg
  command -v awg >/dev/null && command -v awg-quick >/dev/null || die "AmneziaWG tools were not installed."
  modprobe amneziawg || die "The AmneziaWG kernel module could not be loaded. Check DKMS and kernel headers."
}

write_configs() {
  local wg_private wg_public existing_peers=""
  log INFO "Creating configuration files."
  install -d -m 0700 /etc/wireguard /etc/amnezia/amneziawg /etc/vpngate/clients
  install -d -m 0755 /etc/nftables.d/vpngate-static /etc/dnsmasq.d /etc/sysctl.d /usr/local/libexec
  install -d -m 0700 "$BACKUP_DIR"
  : >"${BACKUP_DIR}/MANIFEST"

  if [[ -r /etc/wireguard/wg0.conf ]]; then
    wg_private=$(awk -F'[[:space:]]*=[[:space:]]*' '$1 == "PrivateKey" {print $2; exit}' /etc/wireguard/wg0.conf)
    [[ -n $wg_private ]] || die "Existing wg0.conf has no PrivateKey."
    existing_peers=$(awk '/^[[:space:]]*\[Peer\][[:space:]]*$/{copy=1} copy' /etc/wireguard/wg0.conf)
  else
    wg_private=$(wg genkey)
  fi
  wg_public=$(printf '%s' "$wg_private" | wg pubkey)

  backup_file /etc/wireguard/wg0.conf
  umask 077
  cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${WG_ADDRESS}
ListenPort = ${WG_PORT}
PrivateKey = ${wg_private}
SaveConfig = false
EOF
  if [[ -n $existing_peers ]]; then
    printf '\n%s\n' "$existing_peers" >>/etc/wireguard/wg0.conf
    log INFO "Preserved existing wg0 peer sections."
  fi

  backup_file /etc/amnezia/amneziawg/awg0.conf
  cat >/etc/amnezia/amneziawg/awg0.conf <<EOF
[Interface]
Address = ${AWG_ADDRESS}
PrivateKey = ${AWG_PRIVATE_KEY}
Table = off
MTU = ${AWG_MTU}
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}

[Peer]
PublicKey = ${AWG_PEER_PUBLIC_KEY}
EOF
  if [[ -n $AWG_PRESHARED_KEY ]]; then printf 'PresharedKey = %s\n' "$AWG_PRESHARED_KEY" >>/etc/amnezia/amneziawg/awg0.conf; fi
  cat >>/etc/amnezia/amneziawg/awg0.conf <<EOF
AllowedIPs = 0.0.0.0/0
Endpoint = ${AWG_ENDPOINT}
PersistentKeepalive = 25
EOF
  chmod 0600 /etc/wireguard/wg0.conf /etc/amnezia/amneziawg/awg0.conf

  backup_file /etc/nftables.d/vpngate.nft
  cat >/etc/nftables.d/vpngate.nft <<EOF
table inet vpngate {
    set vpn_domains4 {
        type ipv4_addr
        flags timeout
        timeout 1h
    }

    set vpn_static4 {
        type ipv4_addr
        flags interval
    }

    chain mark_selected {
        type filter hook prerouting priority mangle; policy accept;
        iifname "${WG_IF}" ip daddr @vpn_domains4 meta mark set ${MARK}
        iifname "${WG_IF}" ip daddr @vpn_static4 meta mark set ${MARK}
    }

    chain forward_gateway {
        type filter hook forward priority filter; policy accept;
        ct state established,related accept
        iifname "${WG_IF}" oifname { "${WAN_IF}", "${AWG_IF}" } accept
    }

    chain gateway_nat {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr ${WG_NETWORK} oifname { "${WAN_IF}", "${AWG_IF}" } masquerade
    }
}

include "/etc/nftables.d/vpngate-static/*.nft"
EOF
  backup_file /etc/nftables.d/vpngate-static/telegram.nft
  backup_file /etc/nftables.d/vpngate-static/meta.nft
  install -m 0644 "$SCRIPT_DIR/config/static/telegram.nft" /etc/nftables.d/vpngate-static/telegram.nft
  install -m 0644 "$SCRIPT_DIR/config/static/meta.nft" /etc/nftables.d/vpngate-static/meta.nft

  backup_file /etc/nftables.conf
  touch /etc/nftables.conf
  if ! grep -Fqx 'include "/etc/nftables.d/*.nft"' /etc/nftables.conf; then
    printf '\n# Managed include used by vpngate\ninclude "/etc/nftables.d/*.nft"\n' >>/etc/nftables.conf
  fi

  backup_file /etc/dnsmasq.d/vpngate.conf
  cat >/etc/dnsmasq.d/vpngate.conf <<EOF
# Managed by vpngate. Add one nftset line for each routed domain.
interface=${WG_IF}
listen-address=${WG_DNS}
bind-dynamic
domain-needed
bogus-priv
server=1.1.1.1
server=9.9.9.9
nftset=/telegram.org/t.me/telegra.ph/4#inet#vpngate#vpn_domains4
nftset=/facebook.com/fbcdn.net/instagram.com/cdninstagram.com/whatsapp.com/whatsapp.net/4#inet#vpngate#vpn_domains4
EOF

  backup_file /etc/sysctl.d/99-vpngate.conf
  cat >/etc/sysctl.d/99-vpngate.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF

  backup_file /usr/local/libexec/vpngate-policy
  backup_file /usr/local/libexec/vpngate-check
  backup_file /usr/local/sbin/vpngate-add-client
  install -m 0755 "$SCRIPT_DIR/scripts/vpngate-policy" /usr/local/libexec/vpngate-policy
  install -m 0755 "$SCRIPT_DIR/scripts/vpngate-check" /usr/local/libexec/vpngate-check
  install -m 0755 "$SCRIPT_DIR/scripts/vpngate-add-client" /usr/local/sbin/vpngate-add-client

  backup_file /etc/systemd/system/vpngate-policy.service
  install -m 0644 "$SCRIPT_DIR/systemd/vpngate-policy.service" /etc/systemd/system/vpngate-policy.service

  backup_file /etc/vpngate/settings
  cat >/etc/vpngate/settings <<EOF
WG_IF=${WG_IF}
WG_ADDRESS=${WG_ADDRESS}
WG_NETWORK=${WG_NETWORK}
WG_PORT=${WG_PORT}
WG_DNS=${WG_DNS}
WG_PUBLIC_KEY=${wg_public}
AWG_IF=${AWG_IF}
WAN_IF=${WAN_IF}
MARK=${MARK}
ROUTE_TABLE=${ROUTE_TABLE}
RULE_PRIORITY=${RULE_PRIORITY}
EOF
  chmod 0600 /etc/vpngate/settings
}

validate_configs() {
  log INFO "Validating generated configuration before activation."
  awg-quick strip awg0 >/dev/null
  wg-quick strip wg0 >/dev/null
  nft --check --file /etc/nftables.conf
  dnsmasq --test
  systemd-analyze verify /etc/systemd/system/vpngate-policy.service
}

activate() {
  log INFO "Activating forwarding, firewall, tunnels and policy routing."
  sysctl --system >/dev/null
  systemctl daemon-reload
  systemctl enable nftables dnsmasq wg-quick@wg0 awg-quick@awg0 vpngate-policy.service
  systemctl restart nftables
  systemctl restart wg-quick@wg0
  systemctl restart awg-quick@awg0
  systemctl restart vpngate-policy.service
  systemctl restart dnsmasq
  /usr/local/libexec/vpngate-check
}

main() {
  require_root
  install -d -m 0750 "$(dirname -- "$LOG_FILE")"
  touch "$LOG_FILE"; chmod 0600 "$LOG_FILE"
  log INFO "Starting vpngate installer. Secrets are never written to this log."
  check_platform
  command -v ip >/dev/null || die "The ip command is required."
  ask_parameters
  install_packages
  write_configs
  validate_configs
  activate
  trap - ERR
  log INFO "Installation completed. Backup: ${BACKUP_DIR}"
  printf '\nVPN gateway is ready.\n'
  printf 'Add a WireGuard client with: sudo vpngate-add-client\n'
  printf 'Check health with:          sudo /usr/local/libexec/vpngate-check\n'
  printf 'Install log:                %s\n' "$LOG_FILE"
  printf 'Backup:                     %s\n' "$BACKUP_DIR"
}

main "$@"
