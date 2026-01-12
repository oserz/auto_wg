#!/bin/bash
# Auto WireGuard VPN Controller (IPv4/IPv6 + Local/Global traffic modes)
# Requires root privileges
#
# Usage: auto_wg.sh [-l] [-s] [-p <node>] [-t <tag>]
#   -l          Local traffic mode (default: global traffic)
#   -s          Server/loopback mode (requires IPv6, starts udp2raw tunnel)
#   -p <node>   Specify node (e.g., p1, p2, default: p1)
#   -t <tag>    Specify interface tag (default: aio)
#
# Examples:
#   auto_wg.sh              # Start/stop p1 node global mode
#   auto_wg.sh -l           # Start/stop p1 node local mode
#   auto_wg.sh -p p2        # Start/stop p2 node global mode
#   auto_wg.sh -s           # Start/stop p1 node server/loopback mode (requires IPv6)
#   auto_wg.sh -s -l -p p2  # Start/stop p2 node server/loopback local mode

set -e

WG_DIR="/etc/wireguard"
WG_BIN="$(command -v wg-quick)"
[ -z "$WG_BIN" ] && { echo "Error: wg-quick command not found"; exit 1; }

# udp2raw configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UDP2RAW_BIN="${SCRIPT_DIR}/udp2raw/udp2raw_amd64_hw_aes"
UDP2RAW_CONF_RUNTIME="/tmp/u2raw_client_runtime.conf"
UDP2RAW_PID_FILE="/tmp/udp2raw.pid"

# udp2raw connection parameters
V6_DOMAIN="your-ipv6-domain.com"
UDP2RAW_LOCAL_ADDR="127.0.0.1"
UDP2RAW_LOCAL_PORT=20828
UDP2RAW_REMOTE_PORT=1667
UDP2RAW_RAW_MODE="faketcp"

# Routing bypass configuration
BYPASS_TABLE="wgbypass"
BYPASS_TABLE_ID=200
BYPASS_RULE_PRIORITY=10
DEFAULT_GW_FILE="/tmp/wg_default_gw.tmp"

# Interface naming variables
IFACE_TAG="aio"
NODE="p1"

# Check root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script requires root privileges."
    exit 1
fi

# Parse command line arguments
LOCAL_MODE=false
SERVER_MODE=false

while getopts "lsp:t:h" opt; do
    case $opt in
        l) LOCAL_MODE=true ;;
        s) SERVER_MODE=true ;;
        p) NODE="$OPTARG" ;;
        t) IFACE_TAG="$OPTARG" ;;
        h)
            echo "Usage: $0 [-l] [-s] [-p <node>] [-t <tag>]"
            echo "  -l          Local traffic mode"
            echo "  -s          Server/loopback mode (requires IPv6)"
            echo "  -p <node>   Specify node (default: p1)"
            echo "  -t <tag>    Specify interface tag (default: aio)"
            exit 0
            ;;
        *)
            echo "Usage: $0 [-l] [-s] [-p <node>] [-t <tag>]"
            exit 1
            ;;
    esac
done

# Validate node parameter format
if ! [[ "$NODE" =~ ^p[0-9]+$ ]]; then
    echo "Error: Invalid node format. Should be p1, p2, p3, etc."
    exit 1
fi

# Build interface name based on mode
# Server mode: {tag}_{node}_{mode} e.g., aio_p1_locals, aio_p1_globals
# Normal mode: {tag}_{node}_{ipmode}{traffic} e.g., aio_p1_v4local, aio_p1_v6global
build_iface_name() {
    local ip_mode="$1"    # v4 or v6 (for normal mode)
    local traffic="$2"    # local or global
    local mode="$3"       # locals or globals (for server mode)
    
    if [ -n "$mode" ]; then
        # Server mode: tag_node_mode
        echo "${IFACE_TAG}_${NODE}_${mode}"
    else
        # Normal mode: tag_node_ipmode+traffic
        echo "${IFACE_TAG}_${NODE}_${ip_mode}${traffic}"
    fi
}

# Check IPv6 availability (using common IPv6 DNS servers)
check_ipv6() {
    local test_targets=("240c::6666" "2400:3200::1" "2402:4e00::")
    for addr in "${test_targets[@]}"; do
        if ping6 -c1 -W1 "$addr" &>/dev/null; then
            return 0  # IPv6 supported
        fi
    done
    return 1  # IPv6 not supported
}

# Resolve domain to get IPv6 address
resolve_ipv6() {
    local domain="$1"
    local ipv6_addr
    ipv6_addr=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1; exit}')
    if [ -z "$ipv6_addr" ]; then
        # Fallback: use dig
        ipv6_addr=$(dig +short AAAA "$domain" 2>/dev/null | head -1)
    fi
    echo "$ipv6_addr"
}

# Generate udp2raw runtime configuration file
generate_udp2raw_conf() {
    local remote_ipv6="$1"
    cat > "$UDP2RAW_CONF_RUNTIME" << EOF
-c
-l ${UDP2RAW_LOCAL_ADDR}:${UDP2RAW_LOCAL_PORT}
-r [${remote_ipv6}]:${UDP2RAW_REMOTE_PORT}
-a
--raw-mode ${UDP2RAW_RAW_MODE}
EOF
    
    echo "Generated udp2raw config: $UDP2RAW_CONF_RUNTIME"
    echo "  Local listen: ${UDP2RAW_LOCAL_ADDR}:${UDP2RAW_LOCAL_PORT}"
    echo "  Remote server: [${remote_ipv6}]:${UDP2RAW_REMOTE_PORT}"
    echo "  Raw mode: ${UDP2RAW_RAW_MODE}"
}

# Start udp2raw process
start_udp2raw() {
    if [ ! -x "$UDP2RAW_BIN" ]; then
        echo "Error: udp2raw binary not found or not executable: $UDP2RAW_BIN"
        return 1
    fi
    
    echo "Starting udp2raw tunnel..."
    nohup "$UDP2RAW_BIN" --conf-file "$UDP2RAW_CONF_RUNTIME" > /tmp/udp2raw.log 2>&1 &
    local pid=$!
    echo $pid > "$UDP2RAW_PID_FILE"
    sleep 1
    
    if kill -0 $pid 2>/dev/null; then
        echo "udp2raw started (PID: $pid)"
        return 0
    else
        echo "Error: udp2raw failed to start. Check /tmp/udp2raw.log"
        return 1
    fi
}

# Stop udp2raw process
stop_udp2raw() {
    if [ -f "$UDP2RAW_PID_FILE" ]; then
        local pid
        pid=$(cat "$UDP2RAW_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Stopping udp2raw (PID: $pid)..."
            kill "$pid" 2>/dev/null || true
            sleep 1
            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
            fi
            echo "udp2raw stopped"
        fi
        rm -f "$UDP2RAW_PID_FILE"
    fi
    # Clean up any remaining processes
    pkill -f "udp2raw_amd64_hw_aes" 2>/dev/null || true
    rm -f "$UDP2RAW_CONF_RUNTIME"
}

# Save current default gateway (call before starting WireGuard)
save_default_gateway() {
    local ipv6_gw ipv6_dev ipv4_gw ipv4_dev
    
    # Get IPv6 default gateway
    ipv6_gw=$(ip -6 route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    ipv6_dev=$(ip -6 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    
    # Get IPv4 default gateway
    ipv4_gw=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    ipv4_dev=$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    
    # Save to temp file
    cat > "$DEFAULT_GW_FILE" << EOF
IPV6_GW=$ipv6_gw
IPV6_DEV=$ipv6_dev
IPV4_GW=$ipv4_gw
IPV4_DEV=$ipv4_dev
EOF
    echo "Saved default gateway info: IPv6=$ipv6_gw ($ipv6_dev), IPv4=$ipv4_gw ($ipv4_dev)"
}

# Load saved default gateway
load_default_gateway() {
    if [ -f "$DEFAULT_GW_FILE" ]; then
        source "$DEFAULT_GW_FILE"
    fi
}

# Ensure routing table exists
ensure_routing_table() {
    local rt_tables_file="/etc/iproute2/rt_tables"
    
    # Ensure directory exists
    if [ ! -d "/etc/iproute2" ]; then
        mkdir -p /etc/iproute2
    fi
    
    # Create rt_tables file with basic content if not exists
    if [ ! -f "$rt_tables_file" ]; then
        cat > "$rt_tables_file" << 'EOF'
#
# reserved values
#
255     local
254     main
253     default
0       unspec
#
# local
#
EOF
        echo "Created $rt_tables_file"
    fi
    
    # Add custom routing table
    if ! grep -q "^${BYPASS_TABLE_ID}[[:space:]]" "$rt_tables_file" 2>/dev/null; then
        echo "${BYPASS_TABLE_ID} ${BYPASS_TABLE}" >> "$rt_tables_file"
        echo "Added routing table: ${BYPASS_TABLE} (ID: ${BYPASS_TABLE_ID})"
    fi
}

# Setup bypass rules: route udp2raw traffic outside WireGuard
# Can be called before or after WireGuard starts
setup_bypass_rules() {
    local target_ipv6="$1"
    
    echo "Setting up udp2raw traffic bypass rules..."
    
    # Ensure routing table exists
    ensure_routing_table
    
    # Load saved default gateway
    load_default_gateway
    
    if [ -z "$IPV6_GW" ] || [ -z "$IPV6_DEV" ]; then
        echo "Error: Cannot get IPv6 default gateway info"
        return 1
    fi
    
    # Clean up old routes and rules
    ip -6 route del "$target_ipv6" via "$IPV6_GW" dev "$IPV6_DEV" table $BYPASS_TABLE_ID 2>/dev/null || true
    # Clean up all possible old rules
    ip -6 rule del to "$target_ipv6" table $BYPASS_TABLE_ID 2>/dev/null || true
    
    # Add route to target server via original gateway in bypass table
    ip -6 route add "$target_ipv6" via "$IPV6_GW" dev "$IPV6_DEV" table $BYPASS_TABLE_ID
    echo "Added bypass route: $target_ipv6 via $IPV6_GW dev $IPV6_DEV (table $BYPASS_TABLE_ID)"
    
    # Save target IP for cleanup
    echo "TARGET_IPV6=$target_ipv6" >> "$DEFAULT_GW_FILE"
    
    echo "Bypass routing setup complete (routing table part)"
}

# Add bypass ip rule (must be called after WireGuard starts)
# This ensures our rule has higher priority than WireGuard rules
add_bypass_rule() {
    local target_ipv6="$1"
    ip -6 rule add to "$target_ipv6" table $BYPASS_TABLE_ID priority $BYPASS_RULE_PRIORITY
    echo "Added bypass rule: to $target_ipv6 -> table $BYPASS_TABLE_ID (priority $BYPASS_RULE_PRIORITY)"
}

# Remove bypass rules
remove_bypass_rules() {
    echo "Removing bypass rules..."
    
    # Load saved gateway info
    load_default_gateway
    
    # Delete destination-based rules (try all possible priorities)
    if [ -n "$TARGET_IPV6" ]; then
        ip -6 rule del to "$TARGET_IPV6" table $BYPASS_TABLE_ID 2>/dev/null || true
    fi
    
    # Delete routes in bypass routing table
    if [ -n "$TARGET_IPV6" ] && [ -n "$IPV6_GW" ] && [ -n "$IPV6_DEV" ]; then
        ip -6 route del "$TARGET_IPV6" via "$IPV6_GW" dev "$IPV6_DEV" table $BYPASS_TABLE_ID 2>/dev/null || true
    fi
    
    # Flush bypass routing table
    ip -6 route flush table $BYPASS_TABLE_ID 2>/dev/null || true
    
    # Delete temp file
    rm -f "$DEFAULT_GW_FILE"
    
    echo "Bypass rules removed"
}

# Check if running in server mode
is_server_mode_active() {
    [ -f "$UDP2RAW_PID_FILE" ] && return 0
    return 1
}

# Get currently active WireGuard interface name
get_active_wg() {
    ip link show type wireguard 2>/dev/null | grep "${IFACE_TAG}" | awk -F: '{print $2}' | tr -d ' '
}

# Start VPN
start_vpn() {
    local iface="$1"
    echo "Starting WireGuard interface: $iface"
    $WG_BIN up "$iface"
}

# Stop VPN
stop_vpn() {
    local iface="$1"
    echo "Stopping WireGuard interface: $iface"
    $WG_BIN down "$iface"
}

# Main logic
main() {
    local active_iface
    active_iface=$(get_active_wg)

    # If there's an active VPN, shut it down
    if [ -n "$active_iface" ]; then
        echo "Detected active WireGuard interface: $active_iface"
        
        # Check if server mode is running, need cleanup
        if is_server_mode_active; then
            stop_udp2raw
            # Stop VPN first, then remove bypass rules (order matters)
            stop_vpn "$active_iface"
            remove_bypass_rules
            exit 0
        fi
        
        stop_vpn "$active_iface"
        exit 0
    fi

    # No active interface, start new VPN based on network status
    local iface
    
    if $SERVER_MODE; then
        # Server/loopback mode, requires IPv6
        if ! check_ipv6; then
            echo "Error: Server/loopback mode (-s) requires IPv6, but current network doesn't support IPv6"
            exit 1
        fi
        
        echo "Preparing server/loopback mode..."
        
        # Resolve domain to get IPv6 address
        echo "Resolving domain: $V6_DOMAIN"
        local ipv6_addr
        ipv6_addr=$(resolve_ipv6 "$V6_DOMAIN")
        if [ -z "$ipv6_addr" ]; then
            echo "Error: Cannot resolve IPv6 address for domain $V6_DOMAIN"
            exit 1
        fi
        echo "Resolved IPv6 address: $ipv6_addr"
        
        # Generate udp2raw config
        if ! generate_udp2raw_conf "$ipv6_addr"; then
            exit 1
        fi
        
        # Build interface name for server mode
        if $LOCAL_MODE; then
            iface=$(build_iface_name "" "" "locals")
        else
            iface=$(build_iface_name "" "" "globals")
        fi
        
        # Save current default gateway (must be before WireGuard starts)
        save_default_gateway
        
        # Setup bypass routing (routing table only, no rule yet)
        if ! setup_bypass_rules "$ipv6_addr"; then
            exit 1
        fi
        
        # Start udp2raw (starts first, will retry connection)
        if ! start_udp2raw; then
            remove_bypass_rules
            exit 1
        fi
        
    else
        # Normal mode: select config based on IPv6 availability
        local ip_mode
        local traffic
        
        if check_ipv6; then
            ip_mode="v6"
        else
            ip_mode="v4"
        fi
        
        if $LOCAL_MODE; then
            traffic="local"
        else
            traffic="global"
        fi
        
        iface=$(build_iface_name "$ip_mode" "$traffic" "")
    fi

    # Check if config file exists
    if [ ! -f "${WG_DIR}/${iface}.conf" ]; then
        echo "Error: Config file not found: ${WG_DIR}/${iface}.conf"
        if $SERVER_MODE; then
            stop_udp2raw
            remove_bypass_rules
        fi
        exit 1
    fi

    start_vpn "$iface"
    
    # If server mode, add bypass rule after WireGuard starts
    # This ensures our rule has higher priority than WireGuard
    if $SERVER_MODE; then
        load_default_gateway
        if [ -n "$TARGET_IPV6" ]; then
            add_bypass_rule "$TARGET_IPV6"
            echo ""
            echo "Checking routing rules:"
            ip -6 rule show | head -10
            echo ""
            echo "Checking route lookup:"
            ip -6 route get "$TARGET_IPV6" 2>/dev/null || true
        fi
    fi
}

main "$@"
