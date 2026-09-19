#!/bin/bash
# All interfaces with their full address lists for the das6ng.network panel.
# Output: default-route key/value lines, a "---" separator, then per-interface
# `interface` lines followed by `ipv4`/`ipv6` address lines and the interface's
# per-family default gateways (`gw4`/`gw6`). Tab-separated.

internet_probe=1.1.1.1

ping_latency_ms() {
  local host=$1
  LC_ALL=C ping -n -c 1 -W 1 "$host" 2>/dev/null | awk -F'time[=<]' '/time[=<]/ { split($2, parts, " "); print parts[1]; exit }'
}

print_default_route_info() {
  local route_json iface gw src prefix

  route_json=$(ip -j route get "$internet_probe" 2>/dev/null)
  [[ -z $route_json ]] && return

  iface=$(jq -r '.[0].dev // ""' <<<"$route_json" 2>/dev/null)
  gw=$(jq -r '.[0].gateway // ""' <<<"$route_json" 2>/dev/null)
  src=$(jq -r '.[0].prefsrc // ""' <<<"$route_json" 2>/dev/null)

  [[ -z $iface ]] && return

  prefix=$(ip -j addr show "$iface" 2>/dev/null | jq -r '.[0].addr_info[]? | select(.family == "inet") | .prefixlen // ""' 2>/dev/null | head -n 1)

  printf 'iface\t%s\n' "$iface"
  printf 'ip\t%s\n' "$src"
  printf 'prefix\t%s\n' "$prefix"
  printf 'gateway\t%s\n' "$gw"

  # Throughput counters so the panel's transfer stats stay live even when
  # the route's source address differs from the selected interface.
  if [[ -r /sys/class/net/$iface/statistics/rx_bytes ]]; then
    printf 'rx_bytes\t%s\n' "$(cat /sys/class/net/$iface/statistics/rx_bytes)"
  fi
  if [[ -r /sys/class/net/$iface/statistics/tx_bytes ]]; then
    printf 'tx_bytes\t%s\n' "$(cat /sys/class/net/$iface/statistics/tx_bytes)"
  fi

  if [[ -d /sys/class/net/$iface/wireless ]]; then
    printf 'type\twifi\n'
  else
    printf 'type\tethernet\n'
    [[ -r /sys/class/net/$iface/speed ]] && printf 'speed\t%s\n' "$(cat /sys/class/net/$iface/speed)"
    [[ -r /sys/class/net/$iface/duplex ]] && printf 'duplex\t%s\n' "$(cat /sys/class/net/$iface/duplex)"
  fi

  # Ping latency (router + internet) in parallel.
  if command -v ping >/dev/null 2>&1 && [[ -n $gw ]]; then
    local tmpdir router_file
    tmpdir=$(mktemp -d) || return
    router_file="$tmpdir/router"
    ping_latency_ms "$gw" >"$router_file" &
    local router_pid=$!
    printf 'internet_ping_ms\t%s\n' "$(ping_latency_ms "$internet_probe")"
    wait "$router_pid"
    printf 'router_ping_ms\t%s\n' "$(cat "$router_file")"
    rm -rf "$tmpdir"
  fi
}

# DNS servers in use, per link plus "global", from systemd-resolved.
# Emits one dns line per server: dns <link-or-global> <addr> (zone %N stripped).
print_dns_servers() {
  command -v resolvectl >/dev/null 2>&1 || return 0

  local line scope addrs addr
  while IFS= read -r line; do
    case "$line" in
      Global:*)
        scope="global"
        line="${line#Global:}"
        ;;
      Link\ *\(*\):*)
        scope="${line#Link *(}"
        scope="${scope%%)*}"
        line="${line#*):}"
        ;;
      *)
        continue
        ;;
    esac

    for addr in $line; do
      addr="${addr%%%*}"
      [[ "$addr" =~ ^[0-9A-Fa-f:.]+$ ]] || continue
      printf 'dns\t%s\t%s\n' "$scope" "$addr"
    done
  done < <(resolvectl dns 2>/dev/null)
}

print_interface_list() {
  local ifaces iface state mac mtu gw4 gw6
  ifaces=$(ls -1 /sys/class/net/ 2>/dev/null | grep -v '^lo$')

  for iface in $ifaces; do
    state=$(cat /sys/class/net/$iface/operstate 2>/dev/null)
    mac=$(cat /sys/class/net/$iface/address 2>/dev/null)
    mtu=$(cat /sys/class/net/$iface/mtu 2>/dev/null)

    printf 'interface\t%s\t%s\t%s\t%s\n' "$iface" "${state:-unknown}" "${mac:-}" "${mtu:-}"

    while IFS= read -r addr; do
      [[ -n "$addr" ]] && printf 'ipv4\t%s\t%s\n' "$iface" "$addr"
    done < <(ip -j -4 addr show "$iface" 2>/dev/null | jq -r '.[].addr_info[]? | select(.family == "inet") | "\(.local)/\(.prefixlen)"' 2>/dev/null)

    while IFS= read -r addr; do
      [[ -n "$addr" ]] && printf 'ipv6\t%s\t%s\n' "$iface" "$addr"
    done < <(ip -j -6 addr show "$iface" 2>/dev/null | jq -r '.[].addr_info[]? | select(.family == "inet6") | "\(.local)/\(.prefixlen)"' 2>/dev/null)

    # Per-family default gateway on this interface. Absent line = no default
    # route of that family here (e.g. tailscale0).
    gw4=$(ip -j -4 route show default dev "$iface" 2>/dev/null | jq -r '.[0].gateway // ""' 2>/dev/null)
    [[ -n "$gw4" ]] && printf 'gw4\t%s\t%s\n' "$iface" "$gw4"
    gw6=$(ip -j -6 route show default dev "$iface" 2>/dev/null | jq -r '.[0].gateway // ""' 2>/dev/null)
    [[ -n "$gw6" ]] && printf 'gw6\t%s\t%s\n' "$iface" "$gw6"
  done
}

print_default_route_info
printf '%s\n' "---"
print_dns_servers
print_interface_list
