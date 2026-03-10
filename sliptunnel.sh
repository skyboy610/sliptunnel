#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════╗
# ║  SlipTunnel v4.0 - DNS Covert Channel Deployer (Fixed Edition)   ║
# ║  Foreign Server Setup + Iran Package Builder                     ║
# ║  Fixes: Port fallback, systemd-resolved, stealth, auto-recovery ║
# ╚═══════════════════════════════════════════════════════════════════╝

# ─── Colors ───
RST='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
RED='\033[38;5;196m'; GREEN='\033[38;5;46m'; YELLOW='\033[38;5;226m'
BLUE='\033[38;5;39m'; CYAN='\033[38;5;51m'; WHITE='\033[38;5;255m'
ORANGE='\033[38;5;208m'; MAGENTA='\033[38;5;201m'
LIME='\033[38;5;118m'; PURPLE='\033[38;5;141m'; GRAY='\033[38;5;245m'
PINK='\033[38;5;213m'
BG_WHITE='\033[48;5;255m'; BG_DARK='\033[48;5;233m'
FG_BLACK='\033[38;5;232m'; FG_RED='\033[38;5;196m'
MC1='\033[38;5;80m'; MC2='\033[38;5;142m'; MC3='\033[38;5;166m'; MC4='\033[38;5;183m'

# ─── Defaults ───
SS_PASSWORD=""; SS_METHOD=""; SS_PORT=""; SOCKS_PORT=""
TUNNEL_DOMAIN=""; NS_HOSTNAME=""; SERVER_IP=""; DNS_PORT="53"
TARGET_PORT=""; TARGET_ADDR=""; TUNNEL_MODE=""

# ─── Fallback port list (if primary is blocked/occupied) ───
FALLBACK_DNS_PORTS=(53 5353 8053 2053 443 853)
FALLBACK_SS_PORTS=(8388 8488 8588 9388 18388)

# ─── Config Paths ───
INSTALL_DIR="/opt/slipstream-tunnel"
CONFIG_DIR="/etc/slipstream"
LOG_DIR="/var/log/slipstream"
PACKAGE_DIR="/tmp/slipstream-iran-package"

# ─── Helpers ───
info()    { echo -e "  ${CYAN}ℹ${RST}  ${WHITE}$1${RST}"; }
success() { echo -e "  ${GREEN}✔${RST}  ${GREEN}$1${RST}"; }
warn()    { echo -e "  ${YELLOW}⚠${RST}  ${YELLOW}$1${RST}"; }
error()   { echo -e "  ${RED}✘${RST}  ${RED}$1${RST}"; }
step()    { echo -e "\n  ${MAGENTA}▶${RST} ${BOLD}${WHITE}$1${RST}"; }
substep() { echo -e "    ${BLUE}→${RST} ${DIM}${WHITE}$1${RST}"; }
divider() { echo -e "  ${DIM}${GRAY}─────────────────────────────────────────────────────${RST}"; }

ask_input() {
    local prompt="$1" default="${2:-}" var_name="$3"
    if [[ -n "$default" ]]; then
        echo -ne "  ${ORANGE}?${RST}  ${WHITE}${prompt}${RST} ${DIM}[${default}]${RST}: "
    else
        echo -ne "  ${ORANGE}?${RST}  ${WHITE}${prompt}${RST}: "
    fi
    read -r input
    input="${input:-$default}"
    printf -v "$var_name" '%s' "$input"
}

confirm() {
    echo -ne "  ${YELLOW}?${RST}  ${WHITE}$1${RST} ${DIM}(y/n)${RST}: "
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

spinner() {
    local pid=$1 msg="${2:-Processing...}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}${spin:i++%${#spin}:1}${RST}  ${DIM}${WHITE}%s${RST}" "$msg"
        sleep 0.1
    done
    printf "\r\033[2K"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Run as root: sudo bash $0"
        exit 1
    fi
}

# ═══ Auto-cleanup any existing tunnel installation ═══
cleanup_existing() {
    step "Checking for existing tunnel installations..."
    local found=false

    # Stop and remove slipstream services
    for svc in slipstream-server slipstream-client slipstream-watchdog.timer ss-backend; do
        if systemctl list-unit-files 2>/dev/null | grep -q "$svc"; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc}.service" "/etc/systemd/system/${svc}.timer"
            found=true
        fi
    done

    # Remove old binaries and configs
    [[ -d "$INSTALL_DIR" ]] && { rm -rf "$INSTALL_DIR"; found=true; }
    [[ -d "$CONFIG_DIR" ]] && { rm -rf "$CONFIG_DIR"; found=true; }
    [[ -d "$LOG_DIR" ]] && { rm -rf "$LOG_DIR"; found=true; }
    [[ -d "$PACKAGE_DIR" ]] && { rm -rf "$PACKAGE_DIR"; found=true; }

    # Check for other DNS tunnel tools
    for old_svc in dnstt-server dnstt-client dns2tcp iodined; do
        if systemctl is-active --quiet "$old_svc" 2>/dev/null; then
            warn "Found running: ${old_svc} — stopping..."
            systemctl stop "$old_svc" 2>/dev/null || true
            systemctl disable "$old_svc" 2>/dev/null || true
            found=true
        fi
        if command -v "$old_svc" &>/dev/null; then
            warn "Found binary: ${old_svc}"
            found=true
        fi
    done

    # Kill any process on our target ports
    for port in 53 5353 8053; do
        local pid_on_port
        pid_on_port=$(fuser "${port}/udp" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$pid_on_port" ]]; then
            local pname
            pname=$(ps -p "$pid_on_port" -o comm= 2>/dev/null || echo "unknown")
            if [[ "$pname" != "systemd-resolve" ]]; then
                warn "Port ${port}/udp occupied by ${pname} (pid ${pid_on_port})"
            fi
        fi
    done

    if [[ "$found" == "true" ]]; then
        systemctl daemon-reload
        success "Previous installation cleaned up"
    else
        success "No previous installation found"
    fi
}

# ═══ Install shortcut command ═══
install_shortcut() {
    local script_path
    script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")

    # Copy script to permanent location
    local perm_path="/usr/local/bin/sliptunnel.sh"
    if [[ "$script_path" != "$perm_path" ]]; then
        cp "$script_path" "$perm_path" 2>/dev/null || true
        chmod +x "$perm_path" 2>/dev/null || true
    fi

    # Create short alias: 'st'
    cat > /usr/local/bin/st <<'SHORTCUT'
#!/usr/bin/env bash
exec bash /usr/local/bin/sliptunnel.sh "$@"
SHORTCUT
    chmod +x /usr/local/bin/st 2>/dev/null || true

    # Also create 'slt' alias
    ln -sf /usr/local/bin/st /usr/local/bin/slt 2>/dev/null || true

    # Add to PATH if needed
    if ! echo "$PATH" | grep -q "/usr/local/bin"; then
        export PATH="/usr/local/bin:$PATH"
        echo 'export PATH="/usr/local/bin:$PATH"' >> /root/.bashrc 2>/dev/null || true
    fi

    success "Shortcut installed: type ${BOLD}${CYAN}st${RST}${GREEN} or ${BOLD}${CYAN}slt${RST}${GREEN} to run"
}

print_banner() {
    clear
    echo ""
    echo -e "${BG_WHITE}${FG_BLACK}${BOLD}                                                                    ${RST}"
    echo -e "${BG_WHITE}${FG_BLACK}${BOLD}    ███████╗██╗     ██╗██████╗ ████████╗██╗   ██╗███╗   ██╗         ${RST}"
    echo -e "${BG_WHITE}${FG_BLACK}${BOLD}    ██╔════╝██║     ██║██╔══██╗╚══██╔══╝██║   ██║████╗  ██║         ${RST}"
    echo -e "${BG_WHITE}${FG_BLACK}${BOLD}    ███████╗██║     ██║██████╔╝   ██║   ██║   ██║██╔██╗ ██║         ${RST}"
    echo -e "${BG_WHITE}${FG_BLACK}${BOLD}    ╚════██║██║     ██║██╔═══╝    ██║   ██║   ██║██║╚██╗██║         ${RST}"
    echo -e "${BG_WHITE}${FG_BLACK}${BOLD}    ███████║███████╗██║██║        ██║   ╚██████╔╝██║ ╚████║         ${RST}"
    echo -e "${BG_WHITE}${FG_BLACK}${BOLD}    ╚══════╝╚══════╝╚═╝╚═╝        ╚═╝    ╚═════╝ ╚═╝  ╚═══╝         ${RST}"
    echo -e "${BG_WHITE}${FG_BLACK}${BOLD}                                                                    ${RST}"
    echo -e "${BG_WHITE}${FG_BLACK}${BOLD}     🌐 SlipTunnel v4  |  DNS Covert Channel  |  Auto-Fallback      ${RST}"
    echo -e "${BG_WHITE}${FG_BLACK}${BOLD}     📡 Multi-Path QUIC over DNS  |  Stealth Mode                   ${RST}"
    echo -e "${BG_WHITE}${FG_BLACK}${BOLD}                                                                    ${RST}"
    echo ""
}

get_public_ip() {
    local ip=""

    # First try without touching firewall
    for svc in ifconfig.me ipinfo.io/ip icanhazip.com api.ipify.org; do
        ip=$(curl -s --connect-timeout 5 --max-time 8 "$svc" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done

    # Failed — try disabling firewall temporarily
    local fw_method=""
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi "active"; then
        ufw disable >/dev/null 2>&1; fw_method="ufw"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        systemctl stop firewalld 2>/dev/null; fw_method="firewalld"
    elif command -v iptables &>/dev/null; then
        iptables-save > /tmp/.iptables-backup-$$ 2>/dev/null
        iptables -P INPUT ACCEPT 2>/dev/null
        iptables -P OUTPUT ACCEPT 2>/dev/null
        iptables -F 2>/dev/null
        fw_method="iptables"
    fi

    if [[ -n "$fw_method" ]]; then
        sleep 1
        for svc in ifconfig.me ipinfo.io/ip icanhazip.com api.ipify.org; do
            ip=$(curl -s --connect-timeout 5 --max-time 8 "$svc" 2>/dev/null | tr -d '[:space:]')
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                break
            fi
            ip=""
        done

        # Re-enable the SAME firewall we disabled
        case "$fw_method" in
            ufw) ufw --force enable >/dev/null 2>&1 ;;
            firewalld) systemctl start firewalld 2>/dev/null ;;
            iptables)
                if [[ -f /tmp/.iptables-backup-$$ ]]; then
                    iptables-restore < /tmp/.iptables-backup-$$ 2>/dev/null
                    rm -f /tmp/.iptables-backup-$$
                fi ;;
        esac

        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    fi

    # Last fallback: hostname
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
        return 0
    fi
    echo ""
    return 1
}

# ═══════════════════════════════════════════════════════════════
#  BUG FIX #1: Check and resolve port conflicts
# ═══════════════════════════════════════════════════════════════

find_available_port() {
    # Usage: find_available_port "udp" 53 5353 8053 2053 443 853
    local proto="$1"; shift
    local ports=("$@")

    for port in "${ports[@]}"; do
        if [[ "$proto" == "udp" ]]; then
            if ! ss -ulnp 2>/dev/null | grep -q ":${port} "; then
                echo "$port"
                return 0
            fi
        else
            if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
                echo "$port"
                return 0
            fi
        fi
    done
    echo ""
    return 1
}

# ═══════════════════════════════════════════════════════════════
#  BUG FIX #2: Disable systemd-resolved if conflicting
# ═══════════════════════════════════════════════════════════════

fix_port53_conflict() {
    step "Checking port 53 availability..."

    # Check if systemd-resolved is using port 53
    if ss -ulnp 2>/dev/null | grep -q ":53 " && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        warn "systemd-resolved is occupying port 53!"
        substep "Disabling stub listener..."

        # Method 1: Disable stub listener only (safest)
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/no-stub.conf <<'RESOLVEDEOF'
[Resolve]
DNSStubListener=no
RESOLVEDEOF

        # Update /etc/resolv.conf to not point to 127.0.0.53
        if [[ -L /etc/resolv.conf ]]; then
            rm -f /etc/resolv.conf
            echo "nameserver 8.8.8.8" > /etc/resolv.conf
            echo "nameserver 1.1.1.1" >> /etc/resolv.conf
        fi

        systemctl restart systemd-resolved 2>/dev/null || true
        sleep 1

        # Verify
        if ss -ulnp 2>/dev/null | grep -q ":53 "; then
            warn "Port 53 still occupied. Trying full disable..."
            systemctl stop systemd-resolved 2>/dev/null || true
            systemctl disable systemd-resolved 2>/dev/null || true
            sleep 1
        fi

        if ! ss -ulnp 2>/dev/null | grep -q ":53 "; then
            success "Port 53 freed successfully"
        else
            warn "Port 53 still blocked - will try fallback ports"
            return 1
        fi
    elif ss -ulnp 2>/dev/null | grep -q ":53 "; then
        # Something else is on port 53
        local occupier
        occupier=$(ss -ulnp 2>/dev/null | grep ":53 " | awk '{print $NF}' | head -1)
        warn "Port 53 occupied by: ${occupier}"
        warn "Will try fallback ports"
        return 1
    else
        success "Port 53 is available"
    fi
    return 0
}

auto_select_dns_port() {
    # Try port 53 first, then fallback
    if fix_port53_conflict; then
        DNS_PORT="53"
    else
        local new_port
        new_port=$(find_available_port "udp" "${FALLBACK_DNS_PORTS[@]}")
        if [[ -n "$new_port" ]]; then
            DNS_PORT="$new_port"
            warn "Auto-selected fallback DNS port: ${DNS_PORT}"
        else
            error "No available ports! All fallback ports occupied."
            ask_input "Manual DNS port" "8053" DNS_PORT
        fi
    fi
    success "DNS Port: ${DNS_PORT}"
}

# ═══════════════════════════════════════════════════════════════
#  INSTALLATION
# ═══════════════════════════════════════════════════════════════

detect_system() {
    step "Detecting system..."
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME="$ID"; OS_VERSION="${VERSION_ID:-unknown}"
    else
        error "Unsupported OS"; exit 1
    fi
    ARCH=$(uname -m)
    success "OS: ${OS_NAME} ${OS_VERSION} | Arch: ${ARCH}"
}

install_dependencies() {
    step "Installing dependencies..."
    case "$OS_NAME" in
        ubuntu|debian)
            apt-get update -qq >/dev/null 2>&1 &
            spinner $! "Updating package lists..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                build-essential cmake git curl pkg-config \
                libssl-dev libclang-dev clang openssl \
                net-tools jq tar gzip bc iproute2 \
                >/dev/null 2>&1 &
            spinner $! "Installing packages..."
            ;;
        centos|rhel|fedora|rocky|alma)
            local pm="dnf"; command -v dnf &>/dev/null || pm="yum"
            $pm install -y -q gcc gcc-c++ cmake git curl openssl-devel \
                clang clang-devel pkgconfig jq tar gzip net-tools bc iproute \
                >/dev/null 2>&1 &
            spinner $! "Installing packages..."
            ;;
        *) error "Unsupported OS: $OS_NAME"; exit 1 ;;
    esac
    success "Dependencies installed"
}

install_rust() {
    step "Setting up Rust..."
    if command -v rustc &>/dev/null; then
        success "Rust already installed: $(rustc --version | awk '{print $2}')"
        return
    fi
    curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable >/dev/null 2>&1 &
    spinner $! "Installing Rust..."
    source "$HOME/.cargo/env" 2>/dev/null || true
    export PATH="$HOME/.cargo/bin:$PATH"
    success "Rust installed: $(rustc --version | awk '{print $2}')"
}

build_slipstream() {
    step "Building slipstream-rust..."
    local src="/tmp/slipstream-rust-build"
    rm -rf "$src"

    substep "Cloning repository..."
    git clone --recursive --depth 1 https://github.com/Mygod/slipstream-rust.git "$src" >/dev/null 2>&1 &
    spinner $! "Cloning..."
    success "Cloned"

    cd "$src"
    source "$HOME/.cargo/env" 2>/dev/null || true
    export CARGO_BUILD_JOBS=$(nproc)

    # ═══ BUG FIX #5: Detect actual binary names from Cargo.toml ═══
    substep "Detecting binary names from Cargo.toml..."
    local server_pkg="" client_pkg=""

    # Try to detect package/binary names
    if [[ -f Cargo.toml ]]; then
        # Check workspace members
        local members
        members=$(grep -A 50 '\[workspace\]' Cargo.toml 2>/dev/null | sed -n 's/.*"\([^"]*\)".*/\1/p' || true)
        substep "Workspace members: ${members:-single package}"
    fi

    # Try known package names
    for try_server in slipstream-server server dnstt-server; do
        if grep -rq "name.*=.*\"${try_server}\"" . 2>/dev/null; then
            server_pkg="$try_server"
            break
        fi
    done
    for try_client in slipstream-client client dnstt-client; do
        if grep -rq "name.*=.*\"${try_client}\"" . 2>/dev/null; then
            client_pkg="$try_client"
            break
        fi
    done

    substep "Building (using $(nproc) cores)... This may take 5-15 minutes"
    echo ""

    # Build with detected names or fallback to full build
    if [[ -n "$server_pkg" && -n "$client_pkg" ]]; then
        substep "Building packages: ${server_pkg}, ${client_pkg}"
        if ! cargo build --release -p "$server_pkg" -p "$client_pkg" 2>&1; then
            warn "Targeted build failed, trying full build..."
            cargo build --release 2>&1 || { error "Build failed!"; exit 1; }
        fi
    else
        substep "Building all packages..."
        cargo build --release 2>&1 || { error "Build failed!"; exit 1; }
    fi

    # ═══ BUG FIX #6: Smart binary detection after build ═══
    mkdir -p "$INSTALL_DIR/bin"
    local found_server=false found_client=false

    # Search for server binary
    for bin_name in slipstream-server server dnstt-server; do
        if [[ -f "target/release/${bin_name}" ]]; then
            cp "target/release/${bin_name}" "$INSTALL_DIR/bin/slipstream-server"
            found_server=true
            substep "Server binary: ${bin_name}"
            break
        fi
    done

    # Search for client binary
    for bin_name in slipstream-client client dnstt-client; do
        if [[ -f "target/release/${bin_name}" ]]; then
            cp "target/release/${bin_name}" "$INSTALL_DIR/bin/slipstream-client"
            found_client=true
            substep "Client binary: ${bin_name}"
            break
        fi
    done

    # Last resort: find any executable in release dir
    if [[ "$found_server" == "false" || "$found_client" == "false" ]]; then
        warn "Standard binary names not found, scanning release directory..."
        local binaries
        binaries=$(find target/release -maxdepth 1 -type f -executable ! -name '*.d' ! -name '*.so' 2>/dev/null | sort)
        info "Found binaries:"
        echo "$binaries" | while read -r b; do echo "    $(basename "$b")"; done

        if [[ "$found_server" == "false" ]]; then
            local srv_bin
            srv_bin=$(echo "$binaries" | grep -i "serv" | head -1)
            if [[ -n "$srv_bin" ]]; then
                cp "$srv_bin" "$INSTALL_DIR/bin/slipstream-server"
                found_server=true
            fi
        fi
        if [[ "$found_client" == "false" ]]; then
            local cli_bin
            cli_bin=$(echo "$binaries" | grep -i "clie" | head -1)
            if [[ -n "$cli_bin" ]]; then
                cp "$cli_bin" "$INSTALL_DIR/bin/slipstream-client"
                found_client=true
            fi
        fi
    fi

    chmod +x "$INSTALL_DIR/bin/"* 2>/dev/null

    if [[ "$found_server" == "false" ]]; then
        error "Server binary not found after build!"; exit 1
    fi
    if [[ "$found_client" == "false" ]]; then
        error "Client binary not found after build!"; exit 1
    fi

    success "Binaries installed: $INSTALL_DIR/bin/"
    cd /; rm -rf "$src"
}

# ═══ BUG FIX #7: Generate stealth certificates ═══
generate_certs() {
    step "Generating TLS certificates (stealth mode)..."
    mkdir -p "$CONFIG_DIR"

    # Use a realistic-looking CN instead of "slipstream" which is easily fingerprinted by DPI
    local stealth_domains=("cloudflare-dns.com" "dns.google" "one.one.one.one" "doh.opendns.com" "resolver1.opendns.com")
    local random_cn="${stealth_domains[$RANDOM % ${#stealth_domains[@]}]}"

    # Generate with realistic certificate fields
    if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$CONFIG_DIR/key.pem" -out "$CONFIG_DIR/cert.pem" \
        -days 365 -subj "/C=US/ST=California/L=San Francisco/O=Cloudflare Inc/CN=${random_cn}" \
        -addext "subjectAltName=DNS:${random_cn},DNS:*.${random_cn}" \
        >/dev/null 2>&1; then

        # EC key or -addext not supported (old openssl), fallback to RSA
        warn "EC key not supported, using RSA..."
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$CONFIG_DIR/key.pem" -out "$CONFIG_DIR/cert.pem" \
            -days 365 -subj "/C=US/ST=California/L=San Francisco/O=Cloudflare Inc/CN=${random_cn}" \
            >/dev/null 2>&1
    fi

    openssl rand -hex 32 > "$CONFIG_DIR/reset-seed"
    chmod 600 "$CONFIG_DIR/key.pem" "$CONFIG_DIR/reset-seed"
    success "Certificates generated (CN: ${random_cn} - stealth)"
}

# ═══════════════════════════════════════════════════════════════
#  CONFIGURATION
# ═══════════════════════════════════════════════════════════════

collect_config() {
    step "Configuration"
    echo ""

    SERVER_IP=$(get_public_ip)
    if [[ -z "$SERVER_IP" || ! "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "Could not auto-detect IP"
        SERVER_IP=""
        ask_input "Server public IP (required)" "" SERVER_IP
        while [[ ! "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; do
            error "Invalid IP format!"
            ask_input "Server public IP" "" SERVER_IP
        done
    else
        info "Detected server IP: ${BOLD}${LIME}${SERVER_IP}${RST}"
    fi
    echo ""
    divider
    echo -e "  ${BOLD}${CYAN}Domain Setup${RST}"
    divider
    echo ""
    echo -e "  ${WHITE}  You need 2 DNS records:${RST}"
    echo -e "  ${WHITE}  ${BOLD}A record${RST}${WHITE}  → points ns.yourdomain to this server${RST}"
    echo -e "  ${WHITE}  ${BOLD}NS record${RST}${WHITE} → delegates tunnel subdomain to ns${RST}"
    echo ""

    ask_input "Kharej Domain - NS Record (e.g. t.example.com)" "" TUNNEL_DOMAIN
    if [[ -z "$TUNNEL_DOMAIN" ]]; then error "Required!"; exit 1; fi

    local base_domain="${TUNNEL_DOMAIN#*.}"
    ask_input "Kharej Domain - A Record (e.g. ns.example.com)" "ns.${base_domain}" NS_HOSTNAME

    # ═══ BUG FIX #1: Auto-select DNS port with fallback ═══
    echo ""
    divider
    echo -e "  ${BOLD}${CYAN}DNS Port (Auto-Fallback Enabled)${RST}"
    divider
    echo ""
    auto_select_dns_port

    echo ""
    divider
    echo -e "  ${BOLD}${CYAN}Tunnel Mode${RST}"
    divider
    echo ""
    echo -e "  ${MC1}${BOLD}1)${RST} ${MC1}Shadowsocks${RST} ${DIM}(Recommended)${RST}"
    echo -e "  ${MC2}${BOLD}2)${RST} ${MC2}SOCKS5 Proxy${RST}"
    echo -e "  ${MC3}${BOLD}3)${RST} ${MC3}SSH Tunnel${RST}"
    echo -e "  ${MC4}${BOLD}4)${RST} ${MC4}Direct Port Forward${RST}"
    echo ""
    local mode_choice
    ask_input "Select" "1" mode_choice

    case "$mode_choice" in
        1) TUNNEL_MODE="shadowsocks" ;;
        2) TUNNEL_MODE="socks" ;;
        3) TUNNEL_MODE="ssh" ;;
        4) TUNNEL_MODE="forward" ;;
        *) TUNNEL_MODE="shadowsocks" ;;
    esac

    case "$TUNNEL_MODE" in
        shadowsocks)
            SS_PASSWORD=$(openssl rand -base64 24)
            SS_METHOD="chacha20-ietf-poly1305"
            # Auto-find available SS port
            SS_PORT=$(find_available_port "tcp" "${FALLBACK_SS_PORTS[@]}")
            if [[ -z "$SS_PORT" ]]; then SS_PORT="8388"; fi
            TARGET_PORT="$SS_PORT"
            TARGET_ADDR="127.0.0.1:${SS_PORT}"
            ;;
        socks)
            SOCKS_PORT=$(find_available_port "tcp" 1080 1180 1280 9050)
            [[ -z "$SOCKS_PORT" ]] && SOCKS_PORT="1080"
            TARGET_PORT="$SOCKS_PORT"
            TARGET_ADDR="127.0.0.1:${SOCKS_PORT}"
            ;;
        ssh)
            TARGET_PORT="22"
            TARGET_ADDR="127.0.0.1:22"
            ;;
        forward)
            ask_input "Target address (IP:Port)" "127.0.0.1:8080" FORWARD_TARGET
            TARGET_PORT="${FORWARD_TARGET##*:}"
            TARGET_ADDR="$FORWARD_TARGET"
            ;;
    esac

    success "Mode: ${TUNNEL_MODE} | Target: ${TARGET_ADDR}"
}

setup_backend() {
    case "$TUNNEL_MODE" in
        shadowsocks)
            step "Setting up Shadowsocks backend..."

            if ! command -v ss-server &>/dev/null; then
                substep "Installing shadowsocks-libev..."
                apt-get install -y -qq shadowsocks-libev >/dev/null 2>&1 || \
                    yum install -y -q shadowsocks-libev >/dev/null 2>&1 || true
            fi

            # Verify installation
            if ! command -v ss-server &>/dev/null; then
                warn "shadowsocks-libev not in repos, trying snap..."
                snap install shadowsocks-libev 2>/dev/null || true
            fi

            mkdir -p /etc/shadowsocks-libev
            cat > /etc/shadowsocks-libev/config.json <<EOF
{
    "server": "127.0.0.1",
    "server_port": ${SS_PORT},
    "password": "${SS_PASSWORD}",
    "timeout": 300,
    "method": "${SS_METHOD}",
    "mode": "tcp_only",
    "fast_open": true,
    "no_delay": true
}
EOF
            # Try multiple service name variants
            local ss_started=false
            for svc_name in shadowsocks-libev "shadowsocks-libev-server@config" shadowsocks-server; do
                if systemctl list-unit-files 2>/dev/null | grep -q "$svc_name"; then
                    systemctl enable "$svc_name" >/dev/null 2>&1 || true
                    systemctl restart "$svc_name" >/dev/null 2>&1 && ss_started=true && break
                fi
            done

            # If systemd service didn't work, run directly
            if [[ "$ss_started" == "false" ]]; then
                warn "No systemd service found, creating custom service..."
                local ss_bin
                ss_bin=$(command -v ss-server 2>/dev/null || echo "/usr/bin/ss-server")
                cat > /etc/systemd/system/ss-backend.service <<SSEOF
[Unit]
Description=Shadowsocks Backend
After=network.target
[Service]
Type=simple
ExecStart=${ss_bin} -c /etc/shadowsocks-libev/config.json
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
SSEOF
                systemctl daemon-reload
                systemctl enable ss-backend >/dev/null 2>&1
                systemctl restart ss-backend >/dev/null 2>&1 && ss_started=true
            fi

            sleep 1
            if ss -tlnp 2>/dev/null | grep -q ":${SS_PORT} "; then
                success "Shadowsocks on 127.0.0.1:${SS_PORT} | Pass: ${SS_PASSWORD}"
            else
                error "Shadowsocks failed to start on port ${SS_PORT}"
                # Auto-retry with different port
                local new_port
                new_port=$(find_available_port "tcp" "${FALLBACK_SS_PORTS[@]}")
                if [[ -n "$new_port" && "$new_port" != "$SS_PORT" ]]; then
                    warn "Retrying with port ${new_port}..."
                    SS_PORT="$new_port"
                    TARGET_PORT="$SS_PORT"
                    TARGET_ADDR="127.0.0.1:${SS_PORT}"
                    sed -i "s/\"server_port\": [0-9]*/\"server_port\": ${SS_PORT}/" /etc/shadowsocks-libev/config.json
                    systemctl restart ss-backend 2>/dev/null || systemctl restart shadowsocks-libev 2>/dev/null || true
                    sleep 1
                    ss -tlnp 2>/dev/null | grep -q ":${SS_PORT} " && \
                        success "Shadowsocks on 127.0.0.1:${SS_PORT} (fallback)" || \
                        error "Shadowsocks still failing"
                fi
            fi
            ;;
        socks)
            step "Setting up SOCKS5 backend..."
            # Try dante first, then microsocks as fallback
            local socks_started=false

            if apt-get install -y -qq dante-server >/dev/null 2>&1; then
                local iface
                iface=$(ip route show default | awk '{print $5}' | head -1)
                cat > /etc/danted.conf <<EOF
logoutput: syslog
internal: 127.0.0.1 port = ${SOCKS_PORT}
external: ${iface}
socksmethod: none
clientmethod: none
client pass { from: 127.0.0.0/8 to: 0.0.0.0/0 log: error }
socks pass { from: 0.0.0.0/0 to: 0.0.0.0/0 protocol: tcp udp log: error }
EOF
                systemctl enable danted >/dev/null 2>&1 || true
                systemctl restart danted >/dev/null 2>&1 && socks_started=true
            fi

            if [[ "$socks_started" == "false" ]]; then
                warn "Dante failed, trying microsocks..."
                if command -v microsocks &>/dev/null || apt-get install -y -qq microsocks >/dev/null 2>&1; then
                    cat > /etc/systemd/system/microsocks.service <<MSEOF
[Unit]
Description=MicroSOCKS
After=network.target
[Service]
Type=simple
ExecStart=$(command -v microsocks) -i 127.0.0.1 -p ${SOCKS_PORT}
Restart=always
[Install]
WantedBy=multi-user.target
MSEOF
                    systemctl daemon-reload
                    systemctl enable microsocks >/dev/null 2>&1
                    systemctl restart microsocks >/dev/null 2>&1 && socks_started=true
                fi
            fi

            $socks_started && success "SOCKS5 on 127.0.0.1:${SOCKS_PORT}" || error "SOCKS5 setup failed"
            ;;
    esac
}

# ═══ BUG FIX #2 & #3: Fixed systemd service ═══
create_server_service() {
    step "Creating systemd service..."

    # ═══ BUG FIX #2: Read reset-seed CONTENT, not file path ═══
    local reset_seed_value
    reset_seed_value=$(cat "$CONFIG_DIR/reset-seed" 2>/dev/null)
    if [[ -z "$reset_seed_value" ]]; then
        reset_seed_value=$(openssl rand -hex 32)
        echo "$reset_seed_value" > "$CONFIG_DIR/reset-seed"
        chmod 600 "$CONFIG_DIR/reset-seed"
    fi

    # ═══ Detect actual CLI flags by checking --help ═══
    local server_bin="$INSTALL_DIR/bin/slipstream-server"
    local use_seed_file=false
    local help_output=""
    help_output=$("$server_bin" --help 2>&1 || true)

    # Check if binary expects file path or value for reset-seed
    if echo "$help_output" | grep -qi "reset-seed.*file\|seed-file"; then
        use_seed_file=true
    fi

    # Build ExecStart command
    local exec_cmd="${server_bin}"

    # Try to detect supported flags
    if echo "$help_output" | grep -qi "\-\-dns-listen-port\|dns.listen.port"; then
        exec_cmd+=" --dns-listen-port ${DNS_PORT}"
    elif echo "$help_output" | grep -qi "\-\-listen\|\-l"; then
        exec_cmd+=" --listen 0.0.0.0:${DNS_PORT}"
    fi

    if echo "$help_output" | grep -qi "\-\-target-address\|target.addr"; then
        exec_cmd+=" --target-address ${TARGET_ADDR}"
    elif echo "$help_output" | grep -qi "\-\-upstream\|\-u"; then
        exec_cmd+=" --upstream ${TARGET_ADDR}"
    fi

    if echo "$help_output" | grep -qi "\-\-domain\|\-d"; then
        exec_cmd+=" --domain ${TUNNEL_DOMAIN}"
    fi

    if echo "$help_output" | grep -qi "\-\-cert"; then
        exec_cmd+=" --cert ${CONFIG_DIR}/cert.pem"
    fi

    if echo "$help_output" | grep -qi "\-\-key"; then
        exec_cmd+=" --key ${CONFIG_DIR}/key.pem"
    fi

    if [[ "$use_seed_file" == "true" ]]; then
        exec_cmd+=" --reset-seed ${CONFIG_DIR}/reset-seed"
    elif echo "$help_output" | grep -qi "\-\-reset-seed"; then
        exec_cmd+=" --reset-seed ${reset_seed_value}"
    fi

    if echo "$help_output" | grep -qi "\-\-max-connections\|max.conn"; then
        exec_cmd+=" --max-connections 256"
    fi

    # ═══ BUG FIX #3: Fixed systemd capabilities ═══
    # ProtectSystem=strict conflicts with CAP_NET_BIND_SERVICE on many systems
    # Use User=root for port <1024, or use setcap approach
    local need_caps=""
    if [[ "$DNS_PORT" -lt 1024 ]]; then
        # Try setcap first (allows running as non-root)
        if command -v setcap &>/dev/null; then
            setcap 'cap_net_bind_service=+ep' "$server_bin" 2>/dev/null || true
        fi
        need_caps="yes"
    fi

    cat > /etc/systemd/system/slipstream-server.service <<EOF
[Unit]
Description=SlipTunnel Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${exec_cmd}
Restart=always
RestartSec=3
LimitNOFILE=65535
EOF

    # Only add security restrictions if port >= 1024
    if [[ "$DNS_PORT" -ge 1024 ]]; then
        cat >> /etc/systemd/system/slipstream-server.service <<EOF
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
EOF
    else
        # For privileged ports, be less restrictive
        cat >> /etc/systemd/system/slipstream-server.service <<EOF
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
EOF
    fi

    cat >> /etc/systemd/system/slipstream-server.service <<EOF

[Install]
WantedBy=multi-user.target
EOF

    mkdir -p "$LOG_DIR"
    systemctl daemon-reload
    systemctl enable slipstream-server >/dev/null 2>&1

    # ═══ Stop any existing instance first ═══
    systemctl stop slipstream-server 2>/dev/null || true
    sleep 1
    systemctl start slipstream-server

    # ═══ BUG FIX #4: Auto-retry with different port if fails ═══
    sleep 3
    if systemctl is-active --quiet slipstream-server; then
        success "slipstream-server is RUNNING on port ${DNS_PORT}"
    else
        warn "Service failed on port ${DNS_PORT}"

        # Show error for debugging
        journalctl -u slipstream-server --no-pager -n 10 2>/dev/null | tail -5

        # Try fallback ports
        for fallback_port in "${FALLBACK_DNS_PORTS[@]}"; do
            [[ "$fallback_port" == "$DNS_PORT" ]] && continue

            if ss -ulnp 2>/dev/null | grep -q ":${fallback_port} "; then
                continue
            fi

            warn "Trying fallback port: ${fallback_port}..."
            DNS_PORT="$fallback_port"

            # Rebuild exec command with new port
            sed -i "s/--dns-listen-port [0-9]*/--dns-listen-port ${DNS_PORT}/" /etc/systemd/system/slipstream-server.service 2>/dev/null
            sed -i "s/--listen [^ ]*/--listen 0.0.0.0:${DNS_PORT}/" /etc/systemd/system/slipstream-server.service 2>/dev/null

            # Update capabilities if needed
            if [[ "$DNS_PORT" -ge 1024 ]]; then
                # Remove capability lines since they're not needed
                sed -i '/AmbientCapabilities/d; /CapabilityBoundingSet/d' /etc/systemd/system/slipstream-server.service 2>/dev/null
            fi

            systemctl daemon-reload
            systemctl restart slipstream-server
            sleep 3

            if systemctl is-active --quiet slipstream-server; then
                success "slipstream-server RUNNING on fallback port ${DNS_PORT}"
                break
            fi
        done

        if ! systemctl is-active --quiet slipstream-server; then
            error "All ports failed! Debug with: journalctl -u slipstream-server -n 50"
        fi
    fi
}

optimize_kernel() {
    step "Optimizing kernel..."
    cat > /etc/sysctl.d/99-slipstream.conf <<'EOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 1048576 16777216
net.ipv4.tcp_wmem=4096 1048576 16777216
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.core.netdev_max_backlog=5000
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.core.somaxconn=4096
net.ipv4.ip_forward=1
net.ipv4.ip_local_port_range=1024 65535
# Stealth: reduce TCP fingerprint
net.ipv4.tcp_timestamps=0
net.ipv4.icmp_echo_ignore_all=1
EOF
    sysctl --system >/dev/null 2>&1
    success "Kernel optimized (stealth mode)"
}

# ═══ BUG FIX #9: Open firewall ports ═══
open_firewall_ports() {
    step "Configuring firewall..."
    local ports_to_open=("${DNS_PORT}/udp" "${DNS_PORT}/tcp")

    # Detect and configure firewall
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi "active"; then
        substep "UFW detected (active)"
        for p in "${ports_to_open[@]}"; do
            ufw allow "$p" >/dev/null 2>&1 && substep "Opened: $p"
        done
        ufw reload >/dev/null 2>&1 || true
        success "UFW rules added"

    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        substep "firewalld detected (active)"
        for p in "${ports_to_open[@]}"; do
            firewall-cmd --permanent --add-port="$p" >/dev/null 2>&1 && substep "Opened: $p"
        done
        firewall-cmd --reload >/dev/null 2>&1 || true
        success "firewalld rules added"

    elif command -v iptables &>/dev/null; then
        substep "Using iptables"
        for p in "${ports_to_open[@]}"; do
            local port_num="${p%%/*}" proto="${p##*/}"
            # Check if rule already exists
            if ! iptables -C INPUT -p "$proto" --dport "$port_num" -j ACCEPT 2>/dev/null; then
                iptables -I INPUT -p "$proto" --dport "$port_num" -j ACCEPT 2>/dev/null && substep "Opened: $p"
            fi
        done
        # Try to save rules persistently
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save >/dev/null 2>&1 || true
        elif command -v iptables-save &>/dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
        fi
        success "iptables rules added"

    else
        info "No active firewall detected — skipping"
    fi
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/tunnel.conf" <<EOF
TUNNEL_MODE=${TUNNEL_MODE}
TUNNEL_DOMAIN=${TUNNEL_DOMAIN}
NS_HOSTNAME=${NS_HOSTNAME}
SERVER_IP=${SERVER_IP}
DNS_PORT=${DNS_PORT}
TARGET_PORT=${TARGET_PORT}
TARGET_ADDR=${TARGET_ADDR}
EOF
    [[ "$TUNNEL_MODE" == "shadowsocks" ]] && cat >> "$CONFIG_DIR/tunnel.conf" <<EOF
SS_PASSWORD=${SS_PASSWORD}
SS_METHOD=${SS_METHOD}
SS_PORT=${SS_PORT}
EOF
    [[ "$TUNNEL_MODE" == "socks" ]] && echo "SOCKS_PORT=${SOCKS_PORT}" >> "$CONFIG_DIR/tunnel.conf"
    chmod 600 "$CONFIG_DIR/tunnel.conf"
    success "Config saved"
}

show_dns_records() {
    echo ""
    divider
    echo -e "  ${BOLD}${YELLOW}⚠ REQUIRED DNS Records${RST}"
    divider
    echo ""

    # Use printf with fixed widths so table never breaks
    local col_type=8 col_name=24 col_value=24

    echo -e "  ${BG_WHITE}${FG_BLACK}${BOLD}$(printf '  %-*s   %-*s   %-*s  ' $col_type "Type" $col_name "Name" $col_value "Value")${RST}"
    echo -e "  ${BG_WHITE}${FG_BLACK}$(printf '  %-*s   %-*s   %-*s  ' $col_type "--------" $col_name "------------------------" $col_value "------------------------")${RST}"
    echo -e "  ${BG_WHITE}${BLUE}${BOLD}$(printf '  %-*s   %-*s   %-*s  ' $col_type "A" $col_name "${NS_HOSTNAME}" $col_value "${SERVER_IP}")${RST}"
    echo -e "  ${BG_WHITE}${BLUE}${BOLD}$(printf '  %-*s   %-*s   %-*s  ' $col_type "NS" $col_name "${TUNNEL_DOMAIN}" $col_value "${NS_HOSTNAME}")${RST}"
    echo -e "  ${BG_WHITE}${FG_BLACK}$(printf '  %-*s   %-*s   %-*s  ' $col_type "" $col_name "" $col_value "")${RST}"
    echo ""

    if [[ "$DNS_PORT" != "53" ]]; then
        echo -e "  ${YELLOW}${BOLD}  NOTE:${RST} ${WHITE}DNS port is ${CYAN}${DNS_PORT}${WHITE} (non-standard)${RST}"
        echo ""
        echo -e "  ${RED}${BOLD}  CRITICAL:${RST} ${WHITE}Recursive resolvers use port 53.${RST}"
        echo -e "  ${WHITE}  Iran client MUST use DIRECT resolver:${RST}"
        echo -e "  ${CYAN}  ${SERVER_IP}:${DNS_PORT}${RST}"
        echo ""
        echo -e "  ${YELLOW}  Recommended: Fix port 53 on server.${RST}"
    fi
    echo ""
    echo -e "  ${RED}${BOLD}  IMPORTANT:${RST}"
    echo -e "  ${WHITE}  Delete any A record for '${TUNNEL_DOMAIN}'!${RST}"
    echo -e "  ${WHITE}  Test: ${CYAN}dig NS ${TUNNEL_DOMAIN} +short${RST}"
    echo ""
}

verify_server() {
    step "Verifying server..."
    local ok=true

    if [[ -x "$INSTALL_DIR/bin/slipstream-server" ]]; then
        success "Binary: OK"
    else
        error "Binary: MISSING"
        ok=false
    fi

    # Wait a bit for service to fully start
    local attempt=0
    while [[ $attempt -lt 5 ]]; do
        if systemctl is-active --quiet slipstream-server; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    if systemctl is-active --quiet slipstream-server; then
        success "Service: RUNNING"
    else
        error "Service: NOT RUNNING"
        # Show last few log lines for debugging
        echo ""
        warn "Last service logs:"
        journalctl -u slipstream-server --no-pager -n 5 2>/dev/null | while read -r line; do
            echo -e "    ${DIM}${line}${RST}"
        done
        echo ""
        ok=false
    fi

    sleep 1
    if ss -ulnp 2>/dev/null | grep -q ":${DNS_PORT} "; then
        success "Port ${DNS_PORT}/UDP: LISTENING"
    else
        warn "Port ${DNS_PORT}/UDP: not yet listening"
    fi

    case "$TUNNEL_MODE" in
        shadowsocks)
            if ss -tlnp 2>/dev/null | grep -q ":${SS_PORT} "; then
                success "Shadowsocks port ${SS_PORT}: LISTENING"
            else
                warn "Shadowsocks port ${SS_PORT}: not listening"
            fi ;;
        socks)
            if ss -tlnp 2>/dev/null | grep -q ":${SOCKS_PORT} "; then
                success "SOCKS port ${SOCKS_PORT}: LISTENING"
            else
                warn "SOCKS port ${SOCKS_PORT}: not listening"
            fi ;;
    esac

    $ok && success "Server verification passed!" || warn "Some checks failed - review above"
}

# ═══════════════════════════════════════════════════════════════
#  IRAN PACKAGE (Enhanced)
# ═══════════════════════════════════════════════════════════════

create_iran_package() {
    step "Building Iran transfer package..."

    rm -rf "$PACKAGE_DIR"
    mkdir -p "$PACKAGE_DIR"/{bin,config,scripts}

    if [[ -x "$INSTALL_DIR/bin/slipstream-client" ]]; then
        cp "$INSTALL_DIR/bin/slipstream-client" "$PACKAGE_DIR/bin/"
        chmod +x "$PACKAGE_DIR/bin/slipstream-client"
        success "Client binary packaged"
    else
        error "Client binary not found!"
        error "Run full installation first (option 1)"
        return 1
    fi

    cp "$CONFIG_DIR/cert.pem" "$PACKAGE_DIR/config/"

    cat > "$PACKAGE_DIR/config/connection.conf" <<EOF
TUNNEL_DOMAIN=${TUNNEL_DOMAIN}
NS_HOSTNAME=${NS_HOSTNAME}
SERVER_IP=${SERVER_IP}
DNS_PORT=${DNS_PORT}
TUNNEL_MODE=${TUNNEL_MODE}
EOF
    [[ "$TUNNEL_MODE" == "shadowsocks" ]] && cat >> "$PACKAGE_DIR/config/connection.conf" <<EOF
SS_PASSWORD=${SS_PASSWORD}
SS_METHOD=${SS_METHOD}
SS_PORT=${SS_PORT}
EOF
    # If non-standard DNS port, add direct resolver hint
    [[ "$DNS_PORT" != "53" ]] && echo "DIRECT_RESOLVER=${SERVER_IP}:${DNS_PORT}" >> "$PACKAGE_DIR/config/connection.conf"

    generate_iran_script > "$PACKAGE_DIR/scripts/setup.sh"
    chmod +x "$PACKAGE_DIR/scripts/setup.sh"

    cat > "$PACKAGE_DIR/install.sh" <<'INST'
#!/usr/bin/env bash
cd "$(dirname "$0")"
bash scripts/setup.sh "$@"
INST
    chmod +x "$PACKAGE_DIR/install.sh"

    local archive="slipstream-iran-$(date +%Y%m%d-%H%M%S).tar.gz"
    cd /tmp && tar -czf "/root/${archive}" -C "$PACKAGE_DIR" .
    local sz
    sz=$(du -h "/root/${archive}" | awk '{print $1}')

    echo ""
    divider
    echo -e "  ${BOLD}${GREEN}📦 Transfer Package Ready!${RST}"
    divider
    echo -e "  ${WHITE}  File: ${CYAN}${BOLD}/root/${archive}${RST} (${sz})"
    echo -e "  ${WHITE}  SCP:  ${CYAN}scp /root/${archive} user@iran-server:/root/${RST}"
    echo ""
    echo -e "  ${WHITE}  On Iran server:${RST}"
    echo -e "  ${CYAN}  mkdir -p /tmp/st && tar -xzf ${archive} -C /tmp/st && cd /tmp/st && bash install.sh${RST}"
    echo ""
    echo -e "  ${YELLOW}⚠ DNS resolver(s) required — public DNS may be blocked${RST}"
    echo ""
}

generate_iran_script() {
cat <<'IRAN_EOF'
#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  SlipTunnel v4.0 Iran Client - Auto-Recovery + Resolver Fallback
# ═══════════════════════════════════════════════════════════════

RST='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
RED='\033[38;5;196m'; GREEN='\033[38;5;46m'; YELLOW='\033[38;5;226m'
BLUE='\033[38;5;39m'; CYAN='\033[38;5;51m'; WHITE='\033[38;5;255m'
ORANGE='\033[38;5;208m'; MAGENTA='\033[38;5;201m'
LIME='\033[38;5;118m'; GRAY='\033[38;5;245m'; PURPLE='\033[38;5;141m'
BG_RED='\033[48;5;196m'; FG_WHITE='\033[38;5;255m'; FG_BLACK='\033[38;5;232m'
MC1='\033[38;5;80m'; MC2='\033[38;5;142m'; MC3='\033[38;5;166m'; MC4='\033[38;5;183m'

SS_PASSWORD="${SS_PASSWORD:-}"; SS_METHOD="${SS_METHOD:-}"; SS_PORT="${SS_PORT:-}"
SOCKS_PORT="${SOCKS_PORT:-}"; RESOLVERS="${RESOLVERS:-}"; RESOLVER_FLAGS="${RESOLVER_FLAGS:-}"
LOCAL_LISTEN_PORT="${LOCAL_LISTEN_PORT:-5201}"

INSTALL_DIR="/opt/slipstream-tunnel"
CONFIG_DIR="/etc/slipstream"
LOG_DIR="/var/log/slipstream"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Fallback local listen ports
FALLBACK_LISTEN_PORTS=(5201 5202 5203 5301 5401)

# ═══ Built-in Iran DNS Resolvers (560 tested from real Iran server) ═══
IRAN_RESOLVERS=(
    "109.122.236.62:53"
    "109.125.129.170:53"
    "109.125.129.234:53"
    "109.125.133.206:53"
    "109.125.134.92:53"
    "109.125.136.149:53"
    "109.125.137.170:53"
    "109.125.138.89:53"
    "109.125.141.78:53"
    "109.125.145.79:53"
    "109.125.150.34:53"
    "109.125.160.147:53"
    "109.125.160.205:53"
    "109.162.128.193:53"
    "109.201.13.186:53"
    "109.201.13.187:53"
    "109.201.13.188:53"
    "109.201.13.189:53"
    "109.201.13.190:53"
    "109.230.204.64:53"
    "109.230.204.66:53"
    "109.230.223.170:53"
    "109.230.72.110:53"
    "109.230.80.218:53"
    "109.230.80.219:53"
    "109.230.80.220:53"
    "109.230.80.222:53"
    "109.230.80.242:53"
    "109.230.81.54:53"
    "109.230.82.114:53"
    "109.230.83.155:53"
    "109.230.88.22:53"
    "109.230.89.155:53"
    "109.230.89.156:53"
    "109.230.89.157:53"
    "109.230.89.158:53"
    "109.230.90.106:53"
    "109.230.90.238:53"
    "109.230.92.174:53"
    "109.230.92.182:53"
    "109.230.93.138:53"
    "109.230.94.130:53"
    "109.230.94.246:53"
    "109.230.95.196:53"
    "109.232.1.158:53"
    "109.232.1.6:53"
    "109.232.2.123:53"
    "109.232.2.63:53"
    "109.232.3.3:53"
    "109.238.190.93:53"
    "109.70.237.25:53"
    "151.232.3.161:53"
    "151.232.3.162:53"
    "151.232.39.202:53"
    "151.232.8.14:53"
    "151.232.8.80:53"
    "151.232.8.82:53"
    "151.232.8.87:53"
    "151.232.8.88:53"
    "151.232.8.89:53"
    "151.232.8.94:53"
    "151.233.50.143:53"
    "151.233.55.181:53"
    "151.233.56.110:53"
    "151.233.58.9:53"
    "151.234.2.254:53"
    "151.234.245.230:53"
    "151.234.31.125:53"
    "151.234.87.114:53"
    "151.234.87.40:53"
    "151.235.123.9:53"
    "176.102.240.123:53"
    "176.102.240.200:53"
    "176.102.251.1:53"
    "176.102.253.1:53"
    "176.122.210.190:53"
    "176.122.210.2:53"
    "176.122.210.6:53"
    "176.65.240.82:53"
    "176.65.240.83:53"
    "176.65.240.84:53"
    "176.65.240.85:53"
    "176.65.240.86:53"
    "176.65.240.91:53"
    "176.65.240.92:53"
    "176.65.240.93:53"
    "176.65.240.94:53"
    "176.65.241.236:53"
    "176.65.252.198:53"
    "176.65.252.214:53"
    "176.65.252.26:53"
    "176.65.252.69:53"
    "176.65.252.71:53"
    "176.65.252.81:53"
    "176.65.252.96:53"
    "176.65.253.135:53"
    "176.65.253.200:53"
    "176.65.253.241:53"
    "176.65.253.242:53"
    "176.65.253.243:53"
    "176.65.253.244:53"
    "176.65.253.245:53"
    "176.65.253.246:53"
    "176.65.253.32:53"
    "176.65.253.55:53"
    "176.65.253.69:53"
    "176.65.253.87:53"
    "176.65.254.130:53"
    "176.65.254.241:53"
    "176.65.254.61:53"
    "176.65.254.85:53"
    "176.65.254.86:53"
    "178.131.111.49:53"
    "178.131.113.81:53"
    "178.131.135.230:53"
    "178.131.30.3:53"
    "178.173.128.16:53"
    "178.173.131.62:53"
    "178.173.134.236:53"
    "178.173.134.72:53"
    "178.173.140.171:53"
    "178.173.142.159:53"
    "178.173.142.210:53"
    "178.173.142.5:53"
    "178.173.143.116:53"
    "178.173.143.150:53"
    "178.173.143.161:53"
    "178.173.144.175:53"
    "178.173.144.240:53"
    "178.173.144.45:53"
    "178.173.147.133:53"
    "178.173.147.227:53"
    "178.173.147.238:53"
    "178.173.147.242:53"
    "178.173.147.58:53"
    "178.173.147.73:53"
    "178.173.163.202:53"
    "178.173.193.77:53"
    "178.215.8.18:53"
    "178.215.8.54:53"
    "178.216.248.235:53"
    "178.216.248.236:53"
    "178.216.248.237:53"
    "178.22.122.101:53"
    "178.22.126.2:53"
    "178.239.151.228:53"
    "178.252.129.30:53"
    "178.252.132.222:53"
    "178.252.134.106:53"
    "178.252.135.53:53"
    "178.252.135.54:53"
    "178.252.141.134:53"
    "178.252.141.50:53"
    "178.252.146.186:53"
    "178.252.147.146:53"
    "178.252.147.148:53"
    "178.252.147.150:53"
    "178.252.165.118:53"
    "178.252.171.234:53"
    "178.252.171.74:53"
    "178.252.176.131:53"
    "178.252.177.170:53"
    "178.252.181.52:53"
    "178.252.183.11:53"
    "178.252.183.28:53"
    "178.252.184.154:53"
    "185.100.44.28:53"
    "185.100.46.56:53"
    "185.100.47.11:53"
    "185.100.47.161:53"
    "185.100.47.249:53"
    "185.103.130.34:53"
    "185.103.87.182:53"
    "185.105.121.10:53"
    "185.109.61.228:53"
    "185.109.61.7:53"
    "185.109.62.105:53"
    "185.109.62.108:53"
    "185.109.63.146:53"
    "185.109.74.119:53"
    "185.109.75.41:53"
    "185.109.83.55:53"
    "185.11.69.56:53"
    "185.11.69.99:53"
    "185.11.70.230:53"
    "185.11.70.233:53"
    "185.11.70.55:53"
    "185.110.252.97:53"
    "185.112.150.24:53"
    "185.112.150.26:53"
    "185.112.36.106:53"
    "185.112.36.123:53"
    "185.112.36.172:53"
    "185.112.36.181:53"
    "185.112.36.188:53"
    "185.112.36.197:53"
    "185.112.36.205:53"
    "185.112.36.215:53"
    "185.112.36.217:53"
    "185.112.36.223:53"
    "185.112.37.128:53"
    "185.112.37.186:53"
    "185.112.37.218:53"
    "185.112.37.5:53"
    "185.112.38.137:53"
    "185.112.38.182:53"
    "185.112.38.230:53"
    "185.112.38.64:53"
    "185.112.38.96:53"
    "185.112.39.129:53"
    "185.112.39.151:53"
    "185.112.39.160:53"
    "185.112.39.181:53"
    "185.112.39.60:53"
    "185.112.39.7:53"
    "185.115.168.109:53"
    "185.115.169.223:53"
    "185.116.20.97:53"
    "185.116.22.177:53"
    "185.117.139.163:53"
    "185.117.139.164:53"
    "185.117.139.165:53"
    "185.117.139.166:53"
    "185.117.139.168:53"
    "185.117.139.169:53"
    "185.117.139.170:53"
    "185.117.139.171:53"
    "185.117.139.172:53"
    "185.117.139.173:53"
    "185.117.139.84:53"
    "185.118.152.185:53"
    "185.118.155.122:53"
    "185.124.115.104:53"
    "185.125.248.229:53"
    "185.125.252.226:53"
    "185.126.1.166:53"
    "185.126.10.33:53"
    "185.126.10.9:53"
    "185.126.11.241:53"
    "185.126.14.243:53"
    "185.126.16.27:53"
    "185.126.202.235:53"
    "185.126.203.103:53"
    "185.126.4.33:53"
    "185.126.5.40:53"
    "185.126.5.41:53"
    "185.126.5.49:53"
    "185.128.152.137:53"
    "185.128.82.90:53"
    "185.129.168.241:53"
    "185.129.199.5:53"
    "185.129.200.200:53"
    "185.129.213.170:53"
    "185.129.215.165:53"
    "185.129.217.203:53"
    "185.129.217.38:53"
    "185.134.98.166:53"
    "185.136.193.41:53"
    "185.136.194.34:53"
    "185.136.194.35:53"
    "185.136.194.36:53"
    "185.136.194.37:53"
    "185.136.194.38:53"
    "185.136.194.39:53"
    "185.136.194.40:53"
    "185.136.194.41:53"
    "185.136.194.42:53"
    "185.136.194.43:53"
    "185.136.194.45:53"
    "185.136.194.46:53"
    "185.137.108.1:53"
    "185.137.108.106:53"
    "185.137.108.211:53"
    "185.137.25.208:53"
    "185.137.25.214:53"
    "185.137.25.215:53"
    "185.137.25.216:53"
    "185.137.25.223:53"
    "185.137.25.72:53"
    "185.137.25.74:53"
    "185.137.25.79:53"
    "185.137.27.40:53"
    "185.137.27.42:53"
    "185.137.27.43:53"
    "185.137.27.45:53"
    "185.137.27.46:53"
    "185.137.27.47:53"
    "185.139.64.21:53"
    "185.139.64.9:53"
    "185.140.234.1:53"
    "185.140.234.47:53"
    "185.140.4.65:53"
    "185.140.4.66:53"
    "185.140.4.67:53"
    "185.140.4.77:53"
    "185.140.4.78:53"
    "185.140.4.79:53"
    "185.141.132.69:53"
    "185.142.156.235:53"
    "185.142.158.162:53"
    "185.142.95.10:53"
    "185.143.235.253:53"
    "185.145.186.130:53"
    "185.145.186.80:53"
    "185.145.187.161:53"
    "185.147.161.195:53"
    "185.147.161.200:53"
    "185.147.163.206:53"
    "185.147.40.10:53"
    "185.147.40.12:53"
    "185.147.40.210:53"
    "185.147.41.42:53"
    "185.153.208.77:53"
    "185.155.10.202:53"
    "185.155.10.60:53"
    "185.155.14.130:53"
    "185.155.15.27:53"
    "185.161.112.33:53"
    "185.161.112.34:53"
    "185.161.39.174:53"
    "185.164.72.97:53"
    "185.164.74.240:53"
    "185.165.119.49:53"
    "185.169.20.234:53"
    "185.172.0.218:53"
    "185.172.0.238:53"
    "185.172.213.123:53"
    "185.172.213.4:53"
    "185.172.3.162:53"
    "185.172.68.13:53"
    "185.172.68.31:53"
    "185.172.68.32:53"
    "185.172.68.76:53"
    "185.172.70.70:53"
    "185.176.59.49:53"
    "185.177.158.60:53"
    "185.179.168.114:53"
    "185.179.168.115:53"
    "185.179.168.116:53"
    "185.179.168.117:53"
    "185.179.168.118:53"
    "185.179.168.119:53"
    "185.179.168.120:53"
    "185.179.168.121:53"
    "185.179.168.123:53"
    "185.179.168.124:53"
    "185.179.168.126:53"
    "185.179.168.14:53"
    "185.179.168.16:53"
    "185.179.168.18:53"
    "185.179.168.19:53"
    "185.179.168.24:53"
    "185.179.168.31:53"
    "185.179.168.36:53"
    "185.179.168.4:53"
    "185.179.168.47:53"
    "185.18.213.184:53"
    "185.180.128.69:53"
    "185.180.130.133:53"
    "185.180.130.229:53"
    "185.181.180.138:53"
    "185.182.222.219:53"
    "185.186.243.250:53"
    "185.191.76.142:53"
    "185.191.79.208:53"
    "185.191.79.210:53"
    "185.191.79.211:53"
    "185.192.113.26:53"
    "185.193.209.33:53"
    "185.193.209.34:53"
    "185.193.209.35:53"
    "185.193.209.36:53"
    "185.193.209.37:53"
    "185.193.209.38:53"
    "185.193.209.39:53"
    "185.193.209.40:53"
    "185.193.209.41:53"
    "185.193.209.42:53"
    "185.193.209.43:53"
    "185.193.209.44:53"
    "185.193.209.45:53"
    "185.193.209.46:53"
    "185.206.93.158:53"
    "185.208.148.3:53"
    "185.208.181.252:53"
    "185.208.181.253:53"
    "185.208.181.254:53"
    "185.21.68.53:53"
    "185.215.154.23:53"
    "185.224.176.112:53"
    "185.224.176.125:53"
    "185.224.176.127:53"
    "185.224.176.14:53"
    "185.224.176.190:53"
    "185.224.176.220:53"
    "185.224.176.24:53"
    "185.224.176.41:53"
    "185.224.176.82:53"
    "185.224.177.187:53"
    "185.224.177.33:53"
    "185.224.179.17:53"
    "185.224.179.186:53"
    "185.224.179.204:53"
    "185.224.179.90:53"
    "185.235.196.6:53"
    "185.237.84.18:53"
    "185.237.84.188:53"
    "185.237.85.10:53"
    "185.237.85.5:53"
    "185.237.86.140:53"
    "185.237.87.139:53"
    "185.237.87.228:53"
    "185.254.165.5:53"
    "185.255.208.194:53"
    "185.26.34.227:53"
    "185.3.202.129:53"
    "185.4.29.181:53"
    "185.42.225.68:53"
    "185.49.86.202:53"
    "185.51.200.1:53"
    "185.53.140.6:53"
    "185.53.141.35:53"
    "185.53.141.54:53"
    "185.55.226.25:53"
    "185.55.226.26:53"
    "185.66.228.17:53"
    "185.66.230.195:53"
    "185.71.194.141:53"
    "185.72.25.146:53"
    "185.72.25.226:53"
    "185.72.25.85:53"
    "185.72.25.86:53"
    "185.72.26.218:53"
    "185.72.27.232:53"
    "185.79.156.191:53"
    "185.8.174.140:53"
    "185.8.175.145:53"
    "185.8.175.187:53"
    "185.82.165.10:53"
    "185.82.165.66:53"
    "185.83.182.107:53"
    "185.83.182.218:53"
    "185.83.196.13:53"
    "185.83.196.134:53"
    "185.83.196.150:53"
    "185.83.196.247:53"
    "185.83.196.90:53"
    "185.83.198.46:53"
    "185.83.199.123:53"
    "185.83.88.22:53"
    "185.89.112.20:53"
    "185.89.112.26:53"
    "185.89.115.185:53"
    "185.89.115.195:53"
    "185.95.152.148:53"
    "185.99.212.92:53"
    "185.99.213.56:53"
    "188.0.240.2:53"
    "188.0.240.4:53"
    "188.0.240.6:53"
    "188.121.100.200:53"
    "188.121.110.163:53"
    "188.121.129.219:53"
    "188.121.129.226:53"
    "188.121.129.227:53"
    "188.121.129.228:53"
    "188.121.129.238:53"
    "188.121.132.140:53"
    "188.121.145.182:53"
    "188.121.145.94:53"
    "188.121.146.226:53"
    "188.121.147.166:53"
    "188.121.147.246:53"
    "188.121.148.186:53"
    "188.121.148.190:53"
    "188.121.148.46:53"
    "188.121.149.114:53"
    "188.121.157.186:53"
    "188.121.157.234:53"
    "188.121.158.211:53"
    "188.121.99.199:53"
    "188.136.130.160:53"
    "188.136.133.224:53"
    "188.136.133.225:53"
    "188.136.133.81:53"
    "188.136.133.82:53"
    "188.136.133.83:53"
    "188.136.138.41:53"
    "188.136.154.51:53"
    "188.136.162.104:53"
    "188.136.172.48:53"
    "188.136.174.118:53"
    "188.136.174.131:53"
    "188.136.174.133:53"
    "188.136.174.134:53"
    "188.136.174.214:53"
    "188.136.174.34:53"
    "188.136.174.86:53"
    "188.136.196.1:53"
    "188.136.208.242:53"
    "188.136.208.249:53"
    "188.136.208.251:53"
    "188.136.208.254:53"
    "188.136.208.6:53"
    "188.158.158.158:53"
    "188.208.150.68:53"
    "188.208.151.64:53"
    "188.211.78.196:53"
    "188.211.81.72:53"
    "188.213.209.31:53"
    "188.213.66.139:53"
    "188.213.66.140:53"
    "188.213.66.90:53"
    "188.213.77.26:53"
    "188.213.79.116:53"
    "188.75.126.74:53"
    "188.75.87.195:53"
    "188.75.95.21:53"
    "188.75.95.22:53"
    "188.75.95.66:53"
    "193.148.65.244:53"
    "193.200.148.149:53"
    "193.200.148.28:53"
    "193.200.148.58:53"
    "194.150.68.128:53"
    "194.150.68.199:53"
    "194.150.68.28:53"
    "194.150.68.29:53"
    "194.150.68.51:53"
    "194.150.70.180:53"
    "194.150.71.157:53"
    "194.225.101.17:53"
    "194.225.101.18:53"
    "194.225.101.32:53"
    "194.225.115.10:53"
    "194.225.115.9:53"
    "194.225.144.2:53"
    "194.225.152.10:53"
    "194.225.26.41:53"
    "194.225.92.15:53"
    "194.225.92.17:53"
    "194.33.105.89:53"
    "194.33.107.107:53"
    "194.33.107.108:53"
    "194.48.198.108:53"
    "194.59.214.30:53"
    "194.59.215.36:53"
    "194.59.215.37:53"
    "194.60.209.26:53"
    "194.60.210.66:53"
    "194.9.57.148:53"
    "213.176.123.5:53"
    "217.219.187.3:53"
    "217.219.72.194:53"
    "31.24.234.37:53"
    "31.47.37.92:53"
    "5.202.100.100:53"
    "5.202.100.101:53"
    "80.191.209.105:53"
    "85.185.157.2:53"
)

# ═══ Smart Resolver Benchmark & Selection ═══
benchmark_resolvers() {
    local max_wait="${1:-3}"
    local tmpdir="/tmp/slipstream-bench-$$"

    # Generate unique random string for testing recursive resolution
    local rand_str
    rand_str="slptest$(head -c 6 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || echo $RANDOM$RANDOM)"

    step "Benchmarking ${#IRAN_RESOLVERS[@]} resolvers..."
    echo ""
    echo -e "  ${WHITE}  Test 1: TCP connectivity (port 53)${RST}"
    echo -e "  ${WHITE}  Test 2: Cached DNS (google.com)${RST}"
    echo -e "  ${WHITE}  Test 3: ${BOLD}Recursive DNS (random unique query)${RST}"
    echo -e "  ${DIM}  Only resolvers passing all 3 tests work for tunneling${RST}"
    echo ""

    rm -rf "$tmpdir"
    mkdir -p "$tmpdir"

    local pids=() idx=0 batch_size=50

    for entry in "${IRAN_RESOLVERS[@]}"; do
        local ip="${entry%%:*}"
        local rest="${entry#*:}"
        local port="${rest%%:*}"
        local isp="${rest#*:}"
        # If no ISP field, generate short label from IP
        [[ "$isp" == "$port" || -z "$isp" ]] && isp="${ip##*.}"

        (
            # TEST 1: TCP connectivity
            if ! timeout "$max_wait" bash -c "echo >/dev/tcp/${ip}/${port}" 2>/dev/null; then
                echo "FAIL:tcp:${ip}:${port}:${isp}" > "${tmpdir}/fail_${ip}"
                exit 1
            fi

            local start_t end_t ms=999

            if command -v dig &>/dev/null; then
                # TEST 2: Standard DNS (could be cached - just verifies DNS works)
                if ! dig "@${ip}" -p "${port}" "google.com" A +short +time=2 +tries=1 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+'; then
                    echo "FAIL:dns:${ip}:${port}:${isp}" > "${tmpdir}/fail_${ip}"
                    exit 1
                fi

                # TEST 3: RECURSIVE resolution with unique random query
                # This is the REAL test - a random subdomain that can't be cached
                # We query a random subdomain of a known domain
                # If resolver returns NXDOMAIN or any response (not timeout), it did recursive resolution
                start_t=$(date +%s%N 2>/dev/null || echo 0)

                local recursive_ok=false
                # Query random subdomain - if we get ANY response (even NXDOMAIN), recursive works
                local dig_result
                dig_result=$(dig "@${ip}" -p "${port}" "${rand_str}.google.com" A +time=2 +tries=1 +noall +comments 2>/dev/null)
                # If dig returned something (not timeout), the resolver did recursive lookup
                if [[ -n "$dig_result" ]]; then
                    recursive_ok=true
                fi

                # Also test with another random to be sure
                if [[ "$recursive_ok" == "false" ]]; then
                    dig_result=$(dig "@${ip}" -p "${port}" "${rand_str}.cloudflare.com" A +time=2 +tries=1 +noall +comments 2>/dev/null)
                    [[ -n "$dig_result" ]] && recursive_ok=true
                fi

                if [[ "$recursive_ok" == "false" ]]; then
                    echo "FAIL:recursive:${ip}:${port}:${isp}" > "${tmpdir}/fail_${ip}"
                    exit 1
                fi

                end_t=$(date +%s%N 2>/dev/null || echo 0)

            elif command -v nslookup &>/dev/null; then
                # Fallback: nslookup test
                start_t=$(date +%s%N 2>/dev/null || echo 0)
                if ! timeout "$max_wait" nslookup "${rand_str}.google.com" "${ip}" 2>/dev/null | grep -qi "server\|answer\|name"; then
                    echo "FAIL:recursive:${ip}:${port}:${isp}" > "${tmpdir}/fail_${ip}"
                    exit 1
                fi
                end_t=$(date +%s%N 2>/dev/null || echo 0)
            else
                # No DNS tools - TCP test only (with warning)
                start_t=$(date +%s%N 2>/dev/null || echo 0)
                end_t=$start_t
            fi

            # Calculate latency
            if [[ ${#start_t} -gt 10 && ${#end_t} -gt 10 ]]; then
                ms=$(( (end_t - start_t) / 1000000 ))
            else
                ms=1
            fi
            [[ $ms -le 0 ]] && ms=1
            [[ $ms -gt $((max_wait * 1000)) ]] && ms=$((max_wait * 1000))

            echo "${ms}:${ip}:${port}:${isp}" > "${tmpdir}/ok_${ip}"

        ) &
        pids+=($!)
        idx=$((idx + 1))

        if [[ $((idx % batch_size)) -eq 0 ]]; then
            for p in "${pids[@]}"; do wait "$p" 2>/dev/null; done
            pids=()
            printf "\r    ${BLUE}→${RST} ${DIM}Tested ${idx}/${#IRAN_RESOLVERS[@]}...${RST}\033[K"
        fi
    done

    for p in "${pids[@]}"; do wait "$p" 2>/dev/null; done
    echo ""

    # Collect results
    local results=() fail_tcp=0 fail_dns=0 fail_recursive=0

    for f in "$tmpdir"/fail_*; do
        [[ -f "$f" ]] || continue
        local reason
        reason=$(cat "$f" | cut -d: -f1-2)
        case "$reason" in
            FAIL:tcp) fail_tcp=$((fail_tcp + 1)) ;;
            FAIL:dns) fail_dns=$((fail_dns + 1)) ;;
            FAIL:recursive) fail_recursive=$((fail_recursive + 1)) ;;
        esac
    done

    for f in "$tmpdir"/ok_*; do
        [[ -f "$f" ]] && results+=("$(cat "$f")")
    done
    rm -rf "$tmpdir"

    echo ""
    # Show failure breakdown
    local total=${#IRAN_RESOLVERS[@]}
    local passed=${#results[@]}
    info "Results: ${passed}/${total} passed"
    [[ $fail_tcp -gt 0 ]] && echo -e "    ${RED}✘${RST} ${fail_tcp} failed TCP (port blocked)"
    [[ $fail_dns -gt 0 ]] && echo -e "    ${RED}✘${RST} ${fail_dns} failed basic DNS"
    [[ $fail_recursive -gt 0 ]] && echo -e "    ${YELLOW}⚠${RST} ${fail_recursive} ${BOLD}no recursive resolution${RST} ${DIM}(green but useless!)${RST}"
    echo ""

    if [[ ${#results[@]} -eq 0 ]]; then
        error "No working resolvers found!"
        echo -e "  ${YELLOW}  All resolvers failed recursive DNS test.${RST}"
        echo -e "  ${WHITE}  This means they can't forward queries to your tunnel.${RST}"
        echo -e "  ${WHITE}  Try manual resolvers or a different ISP.${RST}"
        return 1
    fi

    IFS=$'\n' sorted=($(printf '%s\n' "${results[@]}" | sort -t: -k1 -n)); unset IFS

    echo -e "  ${BOLD}${GREEN}${passed} resolvers with REAL recursive DNS:${RST}"
    echo ""

    printf "  ${BG_WHITE}${FG_BLACK}${BOLD}  %-3s  %-18s  %-8s  %-12s  ${RST}\n" "#" "Resolver" "Speed" "ISP"
    printf "  ${BG_WHITE}${FG_BLACK}  %-3s  %-18s  %-8s  %-12s  ${RST}\n" "---" "------------------" "--------" "------------"

    local rank=0
    for entry in "${sorted[@]}"; do
        rank=$((rank + 1))
        local ms="${entry%%:*}"
        local rest="${entry#*:}"
        local r_ip="${rest%%:*}"
        rest="${rest#*:}"
        local r_port="${rest%%:*}"
        local r_isp="${rest#*:}"
        [[ "$r_isp" == "$r_port" || -z "$r_isp" ]] && r_isp="${r_ip%.*}.*"

        local color="${GREEN}"
        [[ $ms -gt 100 ]] && color="${YELLOW}"
        [[ $ms -gt 500 ]] && color="${RED}"

        local mark=" "
        [[ $rank -le 3 ]] && mark="*"

        printf "  ${BG_WHITE}${FG_BLACK}  ${color}${BOLD}%s%-2d${RST}${BG_WHITE}  ${BLUE}%-18s${RST}${BG_WHITE}  ${color}%5d ms${RST}${BG_WHITE}  ${FG_BLACK}%-12s  ${RST}\n" \
            "$mark" "$rank" "${r_ip}:${r_port}" "$ms" "$r_isp"

        [[ $rank -ge 15 ]] && break
    done
    echo ""

    BENCHMARK_RESULTS=("${sorted[@]}")
    return 0
}

select_best_resolvers() {
    # Select top N resolvers from benchmark results
    local count="${1:-3}"
    local selected=""
    local selected_flags=""
    local idx=0

    for entry in "${BENCHMARK_RESULTS[@]}"; do
        [[ $idx -ge $count ]] && break
        local rest="${entry#*:}"
        local r_ip="${rest%%:*}"
        rest="${rest#*:}"
        local r_port="${rest%%:*}"

        [[ -n "$selected" ]] && selected+=","
        selected+="${r_ip}:${r_port}"
        selected_flags+="--resolver ${r_ip}:${r_port} "
        idx=$((idx + 1))
    done

    SELECTED_RESOLVERS="$selected"
    SELECTED_RESOLVER_FLAGS="$selected_flags"
}

info()    { echo -e "  ${CYAN}ℹ${RST}  ${WHITE}$1${RST}"; }
success() { echo -e "  ${GREEN}✔${RST}  ${GREEN}$1${RST}"; }
warn()    { echo -e "  ${YELLOW}⚠${RST}  ${YELLOW}$1${RST}"; }
error()   { echo -e "  ${RED}✘${RST}  ${RED}$1${RST}"; }
step()    { echo -e "\n  ${MAGENTA}▶${RST} ${BOLD}${WHITE}$1${RST}"; }
substep() { echo -e "    ${BLUE}→${RST} ${DIM}${WHITE}$1${RST}"; }
divider() { echo -e "  ${DIM}${GRAY}─────────────────────────────────────────────────────${RST}"; }

ask_input() {
    local prompt="$1" default="${2:-}" var_name="$3"
    if [[ -n "$default" ]]; then
        echo -ne "  ${ORANGE}?${RST}  ${WHITE}${prompt}${RST} ${DIM}[${default}]${RST}: "
    else
        echo -ne "  ${ORANGE}?${RST}  ${WHITE}${prompt}${RST}: "
    fi
    read -r input; input="${input:-$default}"; printf -v "$var_name" '%s' "$input"
}

confirm() {
    echo -ne "  ${YELLOW}?${RST}  ${WHITE}$1${RST} ${DIM}(y/n)${RST}: "
    read -r answer; [[ "$answer" =~ ^[Yy]$ ]]
}

find_available_port() {
    local ports=("$@")
    for port in "${ports[@]}"; do
        if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            echo "$port"; return 0
        fi
    done
    echo ""; return 1
}

print_banner() {
    clear
    echo ""
    echo -e "  ${BG_RED}${FG_WHITE}${BOLD}                                            ${RST}"
    echo -e "  ${BG_RED}${FG_WHITE}${BOLD}   ███████╗██╗     ██╗████████╗██╗   ██╗    ${RST}"
    echo -e "  ${BG_RED}${FG_WHITE}${BOLD}   ██╔════╝██║     ██║╚══██╔══╝██║   ██║    ${RST}"
    echo -e "  ${BG_RED}${FG_WHITE}${BOLD}   ███████╗██║     ██║   ██║   ██║   ██║    ${RST}"
    echo -e "  ${BG_RED}${FG_WHITE}${BOLD}   ╚════██║██║     ██║   ██║   ██║   ██║    ${RST}"
    echo -e "  ${BG_RED}${FG_WHITE}${BOLD}   ███████║███████╗██║   ██║   ╚██████╔╝    ${RST}"
    echo -e "  ${BG_RED}${FG_WHITE}${BOLD}   ╚══════╝╚══════╝╚═╝   ╚═╝    ╚═════╝    ${RST}"
    echo -e "  ${BG_RED}${FG_WHITE}${BOLD}                                            ${RST}"
    echo -e "  ${BG_RED}${FG_WHITE}${BOLD}   SlipTunnel v4 | Iran Client              ${RST}"
    echo -e "  ${BG_RED}${FG_WHITE}${BOLD}   Auto-Recovery | Stealth Mode             ${RST}"
    echo -e "  ${BG_RED}${FG_WHITE}${BOLD}                                            ${RST}"
    echo ""
}

# ─── Core Functions ───

cleanup_existing_client() {
    step "Removing existing tunnel..."
    for svc in slipstream-client slipstream-watchdog.timer; do
        if systemctl list-unit-files 2>/dev/null | grep -q "$svc"; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc}.service" "/etc/systemd/system/${svc}.timer"
        fi
    done
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" 2>/dev/null || true
    rm -f /etc/systemd/system/slipstream-watchdog.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    success "Cleaned up"
}

install_shortcut_client() {
    local script_path
    script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
    local perm_path="/usr/local/bin/sliptunnel.sh"
    [[ "$script_path" != "$perm_path" ]] && cp "$script_path" "$perm_path" 2>/dev/null || true
    chmod +x "$perm_path" 2>/dev/null || true
    cat > /usr/local/bin/st <<'SC'
#!/usr/bin/env bash
exec bash /usr/local/bin/sliptunnel.sh "$@"
SC
    chmod +x /usr/local/bin/st 2>/dev/null || true
    ln -sf /usr/local/bin/st /usr/local/bin/slt 2>/dev/null || true
    success "Shortcut: type ${BOLD}${CYAN}st${RST}${GREEN} or ${BOLD}${CYAN}slt${RST}${GREEN} to run"
}

load_config() {
    step "Loading configuration..."
    if [[ -f "$SCRIPT_DIR/config/connection.conf" ]]; then
        source "$SCRIPT_DIR/config/connection.conf"
        success "Loaded from package"
    elif [[ -f "$CONFIG_DIR/client.conf" ]]; then
        source "$CONFIG_DIR/client.conf"
        success "Loaded from existing config"
    else
        warn "No bundled config"
        ask_input "Tunnel domain" "" TUNNEL_DOMAIN
        ask_input "Server IP" "" SERVER_IP
        ask_input "DNS port" "53" DNS_PORT
        ask_input "Mode (shadowsocks/socks/ssh/forward)" "shadowsocks" TUNNEL_MODE
    fi
    echo ""
    echo -e "  ${WHITE}  Domain: ${LIME}${TUNNEL_DOMAIN}${RST}"
    echo -e "  ${WHITE}  Server: ${LIME}${SERVER_IP}${RST}"
    echo -e "  ${WHITE}  DNS:    ${LIME}${DNS_PORT}${RST}"
    echo -e "  ${WHITE}  Mode:   ${LIME}${TUNNEL_MODE}${RST}"
    echo ""
}

install_client() {
    step "Installing client..."
    mkdir -p "$INSTALL_DIR/bin" "$CONFIG_DIR" "$LOG_DIR"

    # Install dig for DNS benchmarking (optional but recommended)
    if ! command -v dig &>/dev/null; then
        substep "Installing dnsutils for resolver benchmarking..."
        apt-get install -y -qq dnsutils 2>/dev/null || \
            yum install -y -q bind-utils 2>/dev/null || true
    fi

    if [[ -f "$SCRIPT_DIR/bin/slipstream-client" ]]; then
        cp "$SCRIPT_DIR/bin/slipstream-client" "$INSTALL_DIR/bin/"
        chmod +x "$INSTALL_DIR/bin/slipstream-client"

        # Verify binary actually runs
        if "$INSTALL_DIR/bin/slipstream-client" --help >/dev/null 2>&1; then
            success "Client binary installed and verified"
        elif "$INSTALL_DIR/bin/slipstream-client" --version >/dev/null 2>&1; then
            success "Client binary installed and verified"
        else
            # May need missing libs
            local missing
            missing=$(ldd "$INSTALL_DIR/bin/slipstream-client" 2>/dev/null | grep "not found" || true)
            if [[ -n "$missing" ]]; then
                warn "Missing libraries detected:"
                echo "$missing" | while read -r line; do echo "    $line"; done
                substep "Attempting to install missing libs..."
                apt-get install -y -qq libssl3 libgcc-s1 2>/dev/null || true
            fi
            success "Client binary installed (could not fully verify)"
        fi
    else
        error "Client binary not found in package!"; exit 1
    fi

    [[ -f "$SCRIPT_DIR/config/cert.pem" ]] && cp "$SCRIPT_DIR/config/cert.pem" "$CONFIG_DIR/"
}

configure_client() {
    step "Client configuration..."
    echo ""

    # Auto-find available listen port
    local listen_port
    listen_port=$(find_available_port "${FALLBACK_LISTEN_PORTS[@]}")
    [[ -z "$listen_port" ]] && listen_port="5201"
    ask_input "Local listen port" "$listen_port" listen_port

    # Verify port is free
    if ss -tlnp 2>/dev/null | grep -q ":${listen_port} "; then
        warn "Port ${listen_port} is occupied!"
        listen_port=$(find_available_port "${FALLBACK_LISTEN_PORTS[@]}")
        if [[ -n "$listen_port" ]]; then
            info "Auto-selected: ${listen_port}"
        else
            ask_input "Enter a free port" "5301" listen_port
        fi
    fi

    echo ""
    divider
    echo -e "  ${BOLD}${CYAN}DNS Resolver Selection${RST}"
    divider
    echo ""

    if [[ -n "${DIRECT_RESOLVER:-}" ]]; then
        echo -e "  ${RED}${BOLD}  ⚠ Server uses non-standard DNS port!${RST}"
        echo -e "  ${LIME}    ${DIRECT_RESOLVER}${RST}  ${DIM}(REQUIRED — direct to server)${RST}"
        echo ""
        echo -e "  ${WHITE}  Using direct resolver mode (not recursive).${RST}"
        local resolvers="${DIRECT_RESOLVER}"
    else
        echo -e "  ${MC1}${BOLD}1)${RST} ${MC1}Auto-detect best resolvers${RST} ${DIM}(Recommended)${RST}"
        echo -e "  ${MC2}${BOLD}2)${RST} ${MC2}Enter resolvers manually${RST}"
        echo ""
        local resolver_choice
        ask_input "Select" "1" resolver_choice

        local resolvers=""

        if [[ "$resolver_choice" == "1" ]]; then
            # ═══ Auto-benchmark mode ═══
            if benchmark_resolvers; then
                echo ""
                local how_many
                ask_input "How many resolvers to use?" "3" how_many
                [[ "$how_many" -lt 1 ]] && how_many=1
                [[ "$how_many" -gt 10 ]] && how_many=10

                select_best_resolvers "$how_many"
                resolvers="$SELECTED_RESOLVERS"

                echo ""
                success "Selected top ${how_many}: ${resolvers}"
                echo ""
                echo -e "  ${CYAN}ℹ${RST}  ${WHITE}All ${how_many} resolvers will be used simultaneously.${RST}"
                echo -e "  ${WHITE}    If one goes down, the others keep the tunnel alive.${RST}"
            else
                warn "Auto-detect failed. Switching to manual mode..."
                resolver_choice="2"
            fi
        fi

        if [[ "$resolver_choice" == "2" ]]; then
            # ═══ Manual mode ═══
            echo ""
            echo -e "  ${WHITE}  Enter resolver IP(s)${RST}"
            echo -e "  ${WHITE}  Separated by ${BOLD}comma${RST}${WHITE} or ${BOLD}space${RST}${WHITE} or ${BOLD}one per line${RST}"
            echo -e "  ${DIM}  Port 53 is auto-added. Example: 185.137.25.214${RST}"
            echo -e "  ${DIM}  Or with port: 185.137.25.214:53${RST}"
            echo ""
            echo -e "  ${WHITE}  Top picks from previous tests:${RST}"
            echo -e "  ${LIME}    185.137.25.214  185.89.112.26${RST}"
            echo -e "  ${LIME}    46.245.89.51    178.22.122.101${RST}"
            echo -e "  ${LIME}    176.65.241.236  109.230.204.64${RST}"
            echo ""

            echo -e "  ${CYAN}  Type IPs then press Enter (empty line to finish):${RST}"
            local manual_input="" line_input=""
            while true; do
                echo -ne "  ${ORANGE}>${RST} "
                read -r line_input
                [[ -z "$line_input" ]] && break
                # Append with comma
                [[ -n "$manual_input" ]] && manual_input+=","
                # Replace spaces and newlines with commas
                manual_input+="$(echo "$line_input" | tr ' \t' ',')"
            done

            if [[ -n "$manual_input" ]]; then
                resolvers="$manual_input"
            else
                warn "No input — using defaults"
                resolvers="185.137.25.214,185.89.112.26,46.245.89.51"
            fi
        fi
    fi

    # ═══ Normalize resolver list ═══
    # Handle multiple commas, spaces, clean duplicates
    local fixed=""
    local clean_input
    # Replace multiple commas with single, remove empty entries
    clean_input=$(echo "$resolvers" | tr ',' '\n' | tr ' ' '\n' | sed '/^$/d' | sort -u)
    while IFS= read -r r; do
        r=$(echo "$r" | xargs 2>/dev/null || echo "$r")
        [[ -z "$r" ]] && continue
        # Validate it looks like an IP
        local ip_part="${r%%:*}"
        if [[ ! "$ip_part" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            warn "Skipping invalid: ${r}"
            continue
        fi
        [[ "$r" != *":"* ]] && r="${r}:53"
        [[ -n "$fixed" ]] && fixed+=","
        fixed+="$r"
    done <<< "$clean_input"
    resolvers="$fixed"

    if [[ -z "$resolvers" ]]; then
        error "No valid resolvers!"
        return 1
    fi

    # ═══ Final connectivity verification ═══
    substep "Final verification of selected resolvers..."
    local working_resolvers="" fail_count=0
    IFS=',' read -ra test_arr <<< "$resolvers"
    for tr in "${test_arr[@]}"; do
        local ip="${tr%%:*}" port="${tr##*:}"
        if timeout 5 bash -c "echo >/dev/tcp/${ip}/${port}" 2>/dev/null; then
            echo -e "    ${GREEN}✔${RST} ${tr} OK"
            [[ -n "$working_resolvers" ]] && working_resolvers+=","
            working_resolvers+="$tr"
        else
            echo -e "    ${RED}✘${RST} ${tr} unreachable"
            fail_count=$((fail_count + 1))
        fi
    done

    if [[ -n "$working_resolvers" ]]; then
        resolvers="$working_resolvers"
    elif [[ $fail_count -gt 0 ]]; then
        warn "No resolvers reachable!"
        confirm "Continue anyway?" || { error "Cancelled."; return 1; }
    fi

    # Build resolver flags (multiple --resolver flags for redundancy)
    local resolver_flags=""
    IFS=',' read -ra r_arr <<< "$resolvers"
    for r in "${r_arr[@]}"; do
        resolver_flags+="--resolver $(echo "$r" | xargs) "
    done

    LOCAL_LISTEN_PORT="$listen_port"
    RESOLVERS="$resolvers"
    RESOLVER_FLAGS="$resolver_flags"

    # Save config
    cat > "$CONFIG_DIR/client.conf" <<CEOF
LOCAL_LISTEN_PORT=${listen_port}
RESOLVERS=${resolvers}
TUNNEL_DOMAIN=${TUNNEL_DOMAIN}
SERVER_IP=${SERVER_IP}
DNS_PORT=${DNS_PORT}
TUNNEL_MODE=${TUNNEL_MODE}
CEOF
    [[ "$TUNNEL_MODE" == "shadowsocks" ]] && cat >> "$CONFIG_DIR/client.conf" <<CEOF
SS_PASSWORD=${SS_PASSWORD:-}
SS_METHOD=${SS_METHOD:-chacha20-ietf-poly1305}
SS_PORT=${SS_PORT:-8388}
CEOF
    chmod 600 "$CONFIG_DIR/client.conf"
    success "Client configured"
}

create_client_service() {
    step "Creating service..."

    # ═══ Detect actual CLI flags ═══
    local client_bin="$INSTALL_DIR/bin/slipstream-client"
    local help_output=""
    help_output=$("$client_bin" --help 2>&1 || true)

    local exec_cmd="${client_bin}"

    # Build command based on actual supported flags
    if echo "$help_output" | grep -qi "\-\-tcp-listen-port\|tcp.listen"; then
        exec_cmd+=" --tcp-listen-port ${LOCAL_LISTEN_PORT}"
    elif echo "$help_output" | grep -qi "\-\-listen\|\-l"; then
        exec_cmd+=" --listen 127.0.0.1:${LOCAL_LISTEN_PORT}"
    fi

    if echo "$help_output" | grep -qi "\-\-domain\|\-d"; then
        exec_cmd+=" --domain ${TUNNEL_DOMAIN}"
    fi

    if echo "$help_output" | grep -qi "\-\-cert"; then
        exec_cmd+=" --cert ${CONFIG_DIR}/cert.pem"
    fi

    # Add resolver flags
    exec_cmd+=" ${RESOLVER_FLAGS}"

    cat > /etc/systemd/system/slipstream-client.service <<SEOF
[Unit]
Description=SlipTunnel Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${exec_cmd}
Restart=always
RestartSec=3
LimitNOFILE=65535
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SEOF

    # Kernel tweaks
    cat > /etc/sysctl.d/99-slipstream.conf <<'KEOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.core.somaxconn=4096
net.ipv4.ip_forward=1
net.ipv4.tcp_timestamps=0
KEOF
    sysctl --system >/dev/null 2>&1 || true

    systemctl daemon-reload
    systemctl enable slipstream-client >/dev/null 2>&1
    systemctl stop slipstream-client 2>/dev/null || true
    sleep 1
    systemctl start slipstream-client

    sleep 3
    if systemctl is-active --quiet slipstream-client; then
        success "slipstream-client is RUNNING"
    else
        warn "Service may be starting..."

        # Show error for debugging
        journalctl -u slipstream-client --no-pager -n 5 2>/dev/null | tail -3

        # Auto-retry with different listen port
        for fallback_port in "${FALLBACK_LISTEN_PORTS[@]}"; do
            [[ "$fallback_port" == "$LOCAL_LISTEN_PORT" ]] && continue
            if ss -tlnp 2>/dev/null | grep -q ":${fallback_port} "; then continue; fi

            warn "Retrying with port ${fallback_port}..."
            LOCAL_LISTEN_PORT="$fallback_port"
            sed -i "s/--tcp-listen-port [0-9]*/--tcp-listen-port ${LOCAL_LISTEN_PORT}/" /etc/systemd/system/slipstream-client.service 2>/dev/null
            sed -i "s/--listen [^ ]*/--listen 127.0.0.1:${LOCAL_LISTEN_PORT}/" /etc/systemd/system/slipstream-client.service 2>/dev/null
            systemctl daemon-reload
            systemctl restart slipstream-client
            sleep 3
            if systemctl is-active --quiet slipstream-client; then
                success "Client RUNNING on fallback port ${LOCAL_LISTEN_PORT}"
                # Update saved config
                sed -i "s/LOCAL_LISTEN_PORT=.*/LOCAL_LISTEN_PORT=${LOCAL_LISTEN_PORT}/" "$CONFIG_DIR/client.conf" 2>/dev/null
                break
            fi
        done

        systemctl is-active --quiet slipstream-client || \
            error "Client failed to start. Debug: journalctl -u slipstream-client -n 50"
    fi
}

verify_tunnel() {
    step "Verifying tunnel..."
    local max=20 attempt=0

    while [[ $attempt -lt $max ]]; do
        attempt=$((attempt + 1))
        printf "\r    ${BLUE}→${RST} ${DIM}Checking... ${attempt}/${max}${RST}"
        if systemctl is-active --quiet slipstream-client && \
           ss -tlnp 2>/dev/null | grep -q ":${LOCAL_LISTEN_PORT} "; then
            echo ""
            success "Tunnel ACTIVE on port ${LOCAL_LISTEN_PORT}"
            echo ""
            divider
            echo -e "  ${BOLD}${GREEN}🎉 Tunnel Established!${RST}"
            divider

            if [[ "$TUNNEL_MODE" == "shadowsocks" ]]; then
                echo ""
                echo -e "  ${WHITE}  Shadowsocks Client Settings:${RST}"
                echo -e "  ${WHITE}    Server:   ${LIME}127.0.0.1${RST}"
                echo -e "  ${WHITE}    Port:     ${LIME}${LOCAL_LISTEN_PORT}${RST}"
                echo -e "  ${WHITE}    Password: ${LIME}${SS_PASSWORD:-see config}${RST}"
                echo -e "  ${WHITE}    Method:   ${LIME}${SS_METHOD:-chacha20-ietf-poly1305}${RST}"
            elif [[ "$TUNNEL_MODE" == "socks" ]]; then
                echo -e "  ${WHITE}  SOCKS5: ${LIME}127.0.0.1:${LOCAL_LISTEN_PORT}${RST}"
            else
                echo -e "  ${WHITE}  Endpoint: ${LIME}127.0.0.1:${LOCAL_LISTEN_PORT}${RST}"
            fi
            echo ""
            return 0
        fi
        sleep 2
    done

    echo ""
    warn "Tunnel verification timeout."
    echo ""

    # Diagnostic
    echo -e "  ${BOLD}${YELLOW}Diagnostics:${RST}"
    if ! systemctl is-active --quiet slipstream-client; then
        echo -e "  ${RED}✘${RST} Service is not running"
        echo -e "  ${DIM}  Last logs:${RST}"
        journalctl -u slipstream-client --no-pager -n 5 2>/dev/null | while read -r line; do
            echo -e "    ${DIM}${line}${RST}"
        done
    fi
    if ! ss -tlnp 2>/dev/null | grep -q ":${LOCAL_LISTEN_PORT} "; then
        echo -e "  ${RED}✘${RST} Port ${LOCAL_LISTEN_PORT} not listening"
    fi

    # Check resolver connectivity
    if [[ -n "${RESOLVERS:-}" ]]; then
        IFS=',' read -ra ra <<< "$RESOLVERS"
        for rv in "${ra[@]}"; do
            local rip="${rv%%:*}" rport="${rv##*:}"
            if timeout 3 bash -c "echo >/dev/tcp/${rip}/${rport}" 2>/dev/null; then
                echo -e "  ${GREEN}✔${RST} Resolver ${rv}: TCP reachable"

                # Real test: query the actual tunnel domain
                if command -v dig &>/dev/null && [[ -n "${TUNNEL_DOMAIN:-}" ]]; then
                    local rand_q="tst$(head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || echo $RANDOM)"
                    local dig_out
                    dig_out=$(dig "@${rip}" -p "${rport}" "${rand_q}.${TUNNEL_DOMAIN}" A +time=3 +tries=1 +noall +comments 2>/dev/null)
                    if [[ -n "$dig_out" ]]; then
                        echo -e "  ${GREEN}✔${RST} Resolver ${rv}: ${BOLD}recursive DNS works${RST}"
                    else
                        echo -e "  ${RED}✘${RST} Resolver ${rv}: ${BOLD}recursive DNS FAILED${RST}"
                        echo -e "    ${DIM}Query for ${rand_q}.${TUNNEL_DOMAIN} timed out${RST}"
                        echo -e "    ${YELLOW}This resolver can't reach your tunnel server!${RST}"
                    fi
                fi
            else
                echo -e "  ${RED}✘${RST} Resolver ${rv}: unreachable"
            fi
        done
    fi
    echo ""
    echo -e "  ${WHITE}  Manual check: ${CYAN}journalctl -u slipstream-client -f${RST}"
    echo ""
}

# ═══ Auto-generate x-ui Outbound Config ═══
generate_xui_config() {
    step "Generating x-ui Outbound Config"
    echo ""

    # Load config if not already loaded
    [[ -f "$CONFIG_DIR/client.conf" ]] && source "$CONFIG_DIR/client.conf"

    local listen="${LOCAL_LISTEN_PORT:-5201}"
    local pass="${SS_PASSWORD:-}"
    local method="${SS_METHOD:-chacha20-ietf-poly1305}"
    local mode="${TUNNEL_MODE:-shadowsocks}"

    if [[ -z "$pass" && "$mode" == "shadowsocks" ]]; then
        warn "Shadowsocks password not found in config!"
        ask_input "Enter SS password from server" "" pass
    fi

    local config_file="/root/xui-outbound.json"

    if [[ "$mode" == "shadowsocks" ]]; then
        cat > "$config_file" <<XEOF
{
  "protocol": "shadowsocks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": ${listen},
        "method": "${method}",
        "password": "${pass}"
      }
    ]
  },
  "tag": "dns-tunnel"
}
XEOF
    elif [[ "$mode" == "socks" ]]; then
        cat > "$config_file" <<XEOF
{
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": ${listen}
      }
    ]
  },
  "tag": "dns-tunnel"
}
XEOF
    else
        cat > "$config_file" <<XEOF
{
  "protocol": "freedom",
  "settings": {
    "redirect": "127.0.0.1:${listen}"
  },
  "tag": "dns-tunnel"
}
XEOF
    fi

    chmod 600 "$config_file"

    echo ""
    divider
    echo -e "  ${BOLD}${GREEN}x-ui Outbound Config${RST}"
    divider
    echo ""
    echo -e "  ${CYAN}$(cat "$config_file")${RST}"
    echo ""
    divider
    echo ""
    echo -e "  ${WHITE}  Saved to: ${LIME}${config_file}${RST}"
    echo ""
    echo -e "  ${BOLD}${YELLOW}How to use in x-ui:${RST}"
    echo -e "  ${WHITE}  1. Open x-ui panel${RST}"
    echo -e "  ${WHITE}  2. Go to Xray Settings > Outbounds${RST}"
    echo -e "  ${WHITE}  3. Paste the JSON above as outbound${RST}"
    echo -e "  ${WHITE}  4. Save and restart x-ui${RST}"
    echo ""
    echo -e "  ${DIM}  Or view anytime: cat ${config_file}${RST}"
    echo ""
}

# ─── Management Functions ───

show_status() {
    print_banner
    step "Status"
    echo ""
    if systemctl is-active --quiet slipstream-client 2>/dev/null; then
        echo -e "  ${GREEN}●${RST} slipstream-client: ${GREEN}${BOLD}RUNNING${RST}"
    else
        echo -e "  ${RED}●${RST} slipstream-client: ${RED}${BOLD}STOPPED${RST}"
    fi
    if [[ -f "$CONFIG_DIR/client.conf" ]]; then
        source "$CONFIG_DIR/client.conf"
        echo ""
        echo -e "  ${WHITE}  Domain:    ${LIME}${TUNNEL_DOMAIN:-N/A}${RST}"
        echo -e "  ${WHITE}  Server:    ${LIME}${SERVER_IP:-N/A}${RST}"
        echo -e "  ${WHITE}  DNS Port:  ${LIME}${DNS_PORT:-53}${RST}"
        echo -e "  ${WHITE}  Listen:    ${LIME}${LOCAL_LISTEN_PORT:-N/A}${RST}"
        echo -e "  ${WHITE}  Mode:      ${LIME}${TUNNEL_MODE:-N/A}${RST}"
        echo -e "  ${WHITE}  Resolvers: ${LIME}${RESOLVERS:-N/A}${RST}"
    fi
    echo ""
    local port="${LOCAL_LISTEN_PORT:-5201}"
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        echo -e "  ${GREEN}●${RST} Port ${port}: ${GREEN}LISTENING${RST}"
    else
        echo -e "  ${RED}●${RST} Port ${port}: ${RED}NOT LISTENING${RST}"
    fi
    echo ""
}

service_control() {
    print_banner
    step "Service Control"
    echo ""
    if systemctl is-active --quiet slipstream-client 2>/dev/null; then
        echo -e "  ${GREEN}●${RST} Current: ${GREEN}${BOLD}RUNNING${RST}"
    else
        echo -e "  ${RED}●${RST} Current: ${RED}${BOLD}STOPPED${RST}"
    fi
    echo ""
    echo -e "  ${MC1}${BOLD}1)${RST} ${MC1}Start${RST}"
    echo -e "  ${MC2}${BOLD}2)${RST} ${MC2}Stop${RST}"
    echo -e "  ${MC3}${BOLD}3)${RST} ${MC3}Restart${RST}"
    echo -e "  ${MC4}${BOLD}4)${RST} ${MC4}Reload config${RST}"
    echo ""
    local c; ask_input "Select" "" c
    case "$c" in
        1) systemctl start slipstream-client; sleep 2
           systemctl is-active --quiet slipstream-client && success "Started" || error "Failed to start" ;;
        2) systemctl stop slipstream-client; success "Stopped" ;;
        3) systemctl restart slipstream-client; sleep 2
           systemctl is-active --quiet slipstream-client && success "Restarted" || error "Failed" ;;
        4) systemctl daemon-reload; systemctl restart slipstream-client; sleep 2; success "Reloaded" ;;
    esac
    echo ""
}

health_check() {
    print_banner
    step "Health Check"
    echo ""
    local pass=0 total=0

    total=$((total+1))
    if systemctl is-active --quiet slipstream-client 2>/dev/null; then
        echo -e "  ${GREEN}✔${RST} Service: active"; pass=$((pass+1))
    else
        echo -e "  ${RED}✘${RST} Service: inactive"
        # Auto-recovery attempt
        if confirm "Attempt auto-recovery?"; then
            systemctl restart slipstream-client
            sleep 3
            systemctl is-active --quiet slipstream-client && { success "Recovered!"; pass=$((pass+1)); } || error "Recovery failed"
        fi
    fi

    total=$((total+1))
    [[ -f "$CONFIG_DIR/client.conf" ]] && source "$CONFIG_DIR/client.conf"
    local port="${LOCAL_LISTEN_PORT:-5201}"
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        echo -e "  ${GREEN}✔${RST} Port ${port}: listening"; pass=$((pass+1))
    else echo -e "  ${RED}✘${RST} Port ${port}: not listening"; fi

    total=$((total+1))
    if timeout 3 bash -c "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
        echo -e "  ${GREEN}✔${RST} TCP connect: OK"; pass=$((pass+1))
    else echo -e "  ${RED}✘${RST} TCP connect: failed"; fi

    total=$((total+1))
    local errs
    errs=$(journalctl -u slipstream-client --since "5 min ago" --no-pager 2>/dev/null | grep -ci "error\|panic\|fatal" || echo 0)
    if [[ "$errs" -eq 0 ]]; then
        echo -e "  ${GREEN}✔${RST} No errors in 5 min"; pass=$((pass+1))
    else echo -e "  ${YELLOW}⚠${RST} ${errs} errors in 5 min"; fi

    # Resolver test
    if [[ -n "${RESOLVERS:-}" ]]; then
        IFS=',' read -ra ra <<< "$RESOLVERS"
        for rv in "${ra[@]}"; do
            total=$((total+1))
            local rip="${rv%%:*}" rport="${rv##*:}"
            if timeout 3 bash -c "echo >/dev/tcp/${rip}/${rport}" 2>/dev/null; then
                echo -e "  ${GREEN}✔${RST} Resolver ${rv}: reachable"; pass=$((pass+1))
            else echo -e "  ${RED}✘${RST} Resolver ${rv}: unreachable"; fi
        done
    fi

    echo ""
    local pct=$((pass*100/total))
    local col="${GREEN}"; [[ $pct -lt 70 ]] && col="${YELLOW}"; [[ $pct -lt 50 ]] && col="${RED}"
    echo -e "  ${BOLD}${col}Result: ${pass}/${total} passed (${pct}%)${RST}"
    [[ $pct -eq 100 ]] && echo -e "  ${GREEN}  ✓ Tunnel is healthy${RST}" || echo -e "  ${YELLOW}  ⚠ Issues detected${RST}"
    echo ""
}

live_monitor() {
    print_banner
    step "Live Traffic Monitor (Ctrl+C to exit)"
    echo ""; divider

    local iface
    iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    [[ -z "$iface" ]] && iface="eth0"
    trap 'echo -e "\n\n  ${CYAN}Stopped${RST}\n"; return 0' INT

    local prx=0 ptx=0 pt=0
    while true; do
        local now rx tx
        now=$(date +%s%N)
        rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)

        if [[ $pt -ne 0 ]]; then
            local dt=$(((now-pt)/1000000)); [[ $dt -eq 0 ]] && dt=1
            local rxr=$(((rx-prx)*1000/dt)) txr=$(((tx-ptx)*1000/dt))
            local rxf txf
            if [[ $rxr -gt 1048576 ]]; then rxf="$(echo "scale=1;$rxr/1048576"|bc) MB/s"
            elif [[ $rxr -gt 1024 ]]; then rxf="$(echo "scale=0;$rxr/1024"|bc) KB/s"
            else rxf="${rxr} B/s"; fi
            if [[ $txr -gt 1048576 ]]; then txf="$(echo "scale=1;$txr/1048576"|bc) MB/s"
            elif [[ $txr -gt 1024 ]]; then txf="$(echo "scale=0;$txr/1024"|bc) KB/s"
            else txf="${txr} B/s"; fi

            local svc="${RED}●${RST}"; systemctl is-active --quiet slipstream-client 2>/dev/null && svc="${GREEN}●${RST}"

            printf "\033[2K\r"
            echo -e "  ┌────────────────────────────────────────┐"
            printf "  │ ${CYAN}%s${RST}  Svc:%b                        │\n" "$(date '+%H:%M:%S')" "$svc"
            printf "  │ ${GREEN}▼${RST} %-14s ${ORANGE}▲${RST} %-14s    │\n" "$rxf" "$txf"
            echo -e "  └────────────────────────────────────────┘"
            printf "\033[4A"
        fi
        prx=$rx; ptx=$tx; pt=$now; sleep 1
    done
    trap - INT
}

# ═══ Enhanced Watchdog with resolver rotation ═══
setup_watchdog() {
    print_banner
    step "Watchdog Management (Enhanced)"
    echo ""
    if systemctl is-active --quiet slipstream-watchdog.timer 2>/dev/null; then
        echo -e "  ${GREEN}●${RST} Watchdog: ${GREEN}${BOLD}ACTIVE${RST}"
        echo ""
        if confirm "Disable?"; then
            systemctl stop slipstream-watchdog.timer 2>/dev/null
            systemctl disable slipstream-watchdog.timer 2>/dev/null
            rm -f /opt/slipstream-tunnel/watchdog.sh /etc/systemd/system/slipstream-watchdog.*
            systemctl daemon-reload
            success "Disabled"
        fi
    else
        echo -e "  ${RED}●${RST} Watchdog: ${RED}${BOLD}INACTIVE${RST}"
        echo ""
        if confirm "Enable? (auto-restarts + resolver check every 30s)"; then
            mkdir -p "$INSTALL_DIR"
            cat > "$INSTALL_DIR/watchdog.sh" <<'WD'
#!/usr/bin/env bash
LOG="/var/log/slipstream/watchdog.log"
CONF="/etc/slipstream/client.conf"
mkdir -p "$(dirname "$LOG")"
ts() { echo "[$(date -Iseconds)] $1" >> "$LOG"; }

# Trim log if too large
[[ -f "$LOG" ]] && [[ $(wc -c < "$LOG") -gt 1048576 ]] && tail -100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

# Check service
if ! systemctl is-active --quiet slipstream-client; then
    ts "WARN: client down, restarting..."
    systemctl restart slipstream-client
    sleep 5
    if systemctl is-active --quiet slipstream-client; then
        ts "OK: client recovered"
    else
        ts "ERROR: client restart failed"
        # Check if port is blocked
        [[ -f "$CONF" ]] && source "$CONF"
        wd_port="${LOCAL_LISTEN_PORT:-5201}"
        if ss -tlnp 2>/dev/null | grep -q ":${wd_port} "; then
            ts "ERROR: port ${wd_port} occupied by another process, killing..."
            fuser -k "${wd_port}/tcp" 2>/dev/null
            sleep 2
            systemctl restart slipstream-client
            sleep 3
            systemctl is-active --quiet slipstream-client && ts "OK: recovered after port kill" || ts "ERROR: still failed"
        fi
    fi
fi

# Check resolver connectivity
if [[ -f "$CONF" ]]; then
    source "$CONF"
    if [[ -n "${RESOLVERS:-}" ]]; then
        IFS=',' read -ra wd_resolvers <<< "$RESOLVERS"
        wd_any_ok=false
        for wd_r in "${wd_resolvers[@]}"; do
            wd_ip="${wd_r%%:*}"; wd_rport="${wd_r##*:}"
            if timeout 3 bash -c "echo >/dev/tcp/${wd_ip}/${wd_rport}" 2>/dev/null; then
                wd_any_ok=true
                break
            fi
        done
        if [[ "$wd_any_ok" == "false" ]]; then
            ts "WARN: all resolvers unreachable"
        fi
    fi
fi
WD
            chmod +x "$INSTALL_DIR/watchdog.sh"
            cat > /etc/systemd/system/slipstream-watchdog.service <<WDS
[Unit]
Description=SlipTunnel Watchdog
[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/watchdog.sh
WDS
            cat > /etc/systemd/system/slipstream-watchdog.timer <<WDT
[Unit]
Description=SlipTunnel Watchdog Timer
[Timer]
OnBootSec=30
OnUnitActiveSec=30
[Install]
WantedBy=timers.target
WDT
            systemctl daemon-reload
            systemctl enable --now slipstream-watchdog.timer >/dev/null 2>&1
            success "Enabled (checks every 30s, auto-recovery)"
        fi
    fi
    echo ""
}

search_logs() {
    print_banner
    step "Search Logs"
    echo ""
    echo -e "  ${MC1}${BOLD}1)${RST} ${MC1}By keyword${RST}"
    echo -e "  ${MC2}${BOLD}2)${RST} ${MC2}Errors only${RST}"
    echo -e "  ${MC3}${BOLD}3)${RST} ${MC3}Connection logs${RST}"
    echo -e "  ${MC4}${BOLD}4)${RST} ${MC4}By time range${RST}"
    echo ""
    local c; ask_input "Select" "1" c
    case "$c" in
        1) local kw; ask_input "Keyword" "" kw; journalctl -u slipstream-client --no-pager 2>/dev/null | grep -i --color=always "$kw" | tail -100 ;;
        2) journalctl -u slipstream-client --no-pager 2>/dev/null | grep -i --color=always "error\|panic\|fatal" | tail -50 ;;
        3) journalctl -u slipstream-client --no-pager 2>/dev/null | grep -i --color=always "connect\|listen\|close\|timeout" | tail -50 ;;
        4) local s; ask_input "Since (e.g. '1 hour ago')" "1 hour ago" s; journalctl -u slipstream-client --since "$s" --no-pager 2>/dev/null | tail -200 ;;
    esac
    echo ""
}

export_logs() {
    print_banner
    step "Export Logs"
    local path="/root/slipstream-logs-$(date +%Y%m%d-%H%M%S)"
    echo ""
    echo -e "  ${MC1}${BOLD}1)${RST} ${MC1}All logs${RST}"
    echo -e "  ${MC2}${BOLD}2)${RST} ${MC2}Full diagnostic report${RST}"
    echo ""
    local c; ask_input "Select" "2" c
    case "$c" in
        1) journalctl -u slipstream-client --no-pager > "${path}.log" 2>/dev/null; success "Saved: ${path}.log" ;;
        2)
            {
                echo "═══ SlipTunnel Client Diagnostic v4 ═══"
                echo "Date: $(date) | Host: $(hostname) | Kernel: $(uname -r)"
                echo ""; echo "── Service ──"
                systemctl status slipstream-client 2>/dev/null || echo "Not found"
                echo ""; echo "── Config ──"
                cat "$CONFIG_DIR/client.conf" 2>/dev/null || echo "N/A"
                echo ""; echo "── Ports ──"
                ss -tlnp 2>/dev/null
                echo ""; echo "── Memory ──"
                free -h 2>/dev/null
                echo ""; echo "── Resolver Tests ──"
                if [[ -f "$CONFIG_DIR/client.conf" ]]; then
                    source "$CONFIG_DIR/client.conf"
                    IFS=',' read -ra ra <<< "${RESOLVERS:-}"
                    for rv in "${ra[@]}"; do
                        local rip="${rv%%:*}" rport="${rv##*:}"
                        timeout 3 bash -c "echo >/dev/tcp/${rip}/${rport}" 2>/dev/null && echo "$rv: OK" || echo "$rv: FAILED"
                    done
                fi
                echo ""; echo "── Logs (500) ──"
                journalctl -u slipstream-client --no-pager -n 500 2>/dev/null
                echo ""; echo "── Watchdog ──"
                cat /var/log/slipstream/watchdog.log 2>/dev/null | tail -50 || echo "No watchdog logs"
            } > "${path}-report.txt"
            success "Saved: ${path}-report.txt"
            ;;
    esac
    echo ""
}

uninstall_client() {
    print_banner
    step "Uninstall"
    echo ""
    if confirm "Remove SlipTunnel completely?"; then
        systemctl stop slipstream-client 2>/dev/null || true
        systemctl disable slipstream-client 2>/dev/null || true
        systemctl stop slipstream-watchdog.timer 2>/dev/null || true
        systemctl disable slipstream-watchdog.timer 2>/dev/null || true
        rm -f /etc/systemd/system/slipstream-client.service
        rm -f /etc/systemd/system/slipstream-watchdog.*
        systemctl daemon-reload
        iptables -t nat -F 2>/dev/null || true
        rm -f /etc/sysctl.d/99-slipstream.conf
        sysctl --system >/dev/null 2>&1 || true
        rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
        echo ""
        success "SlipTunnel completely removed"
    else
        info "Cancelled"
    fi
    echo ""
}

# ─── Menu ───

show_menu() {
    print_banner
    divider
    echo ""
    echo -e "  ${MC1}${BOLD} 1)${RST}  ${MC1}Install & Setup Tunnel${RST}"
    echo -e "  ${MC1}${BOLD} 2)${RST}  ${MC1}Reconfigure${RST}"
    echo -e "  ${MC1}${BOLD} 3)${RST}  ${MC1}Full Status${RST}"
    echo -e "  ${MC1}${BOLD} 4)${RST}  ${MC1}Start / Stop / Restart${RST}"
    echo ""
    echo -e "  ${MC2}${BOLD} 5)${RST}  ${MC2}Live Traffic Monitor${RST}"
    echo -e "  ${MC2}${BOLD} 6)${RST}  ${MC2}Health Check + Auto-Recovery${RST}"
    echo -e "  ${MC2}${BOLD} 7)${RST}  ${MC2}Live Log${RST}"
    echo -e "  ${MC2}${BOLD} 8)${RST}  ${MC2}Search Logs${RST}"
    echo ""
    echo -e "  ${MC3}${BOLD} 9)${RST}  ${MC3}Export Logs${RST}"
    echo -e "  ${MC3}${BOLD}10)${RST}  ${MC3}Toggle Watchdog (Enhanced)${RST}"
    echo -e "  ${MC3}${BOLD}11)${RST}  ${MC3}Cleanup Logs${RST}"
    echo -e "  ${MC3}${BOLD}12)${RST}  ${MC3}Re-benchmark Resolvers${RST}"
    echo -e "  ${MC3}${BOLD}13)${RST}  ${MC3}Generate x-ui Outbound Config${RST}"
    echo -e "  ${MC4}${BOLD}14)${RST}  ${MC4}Uninstall${RST}"
    echo -e "  ${MC4}${BOLD} 0)${RST}  ${MC4}Exit${RST}"
    echo ""
}

main() {
    if [[ $EUID -ne 0 ]]; then echo -e "  ${RED}✘ Run as root${RST}"; exit 1; fi
    install_shortcut_client

    while true; do
        show_menu
        local c; ask_input "Select" "" c
        case "$c" in
            1) print_banner; cleanup_existing_client; load_config; install_client; configure_client; create_client_service; verify_tunnel
               generate_xui_config; install_shortcut_client
               confirm "Enable Watchdog?" && setup_watchdog
               echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            2) print_banner; cleanup_existing_client; load_config; configure_client; create_client_service; verify_tunnel
               generate_xui_config
               echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            3) show_status; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            4) service_control; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            5) live_monitor; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            6) health_check; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            7) print_banner; step "Live Log (Ctrl+C to exit)"; echo ""
               journalctl -u slipstream-client -f --no-pager 2>/dev/null | while IFS= read -r line; do
                   if echo "$line"|grep -qi "error\|panic"; then echo -e "  ${RED}${line}${RST}"
                   elif echo "$line"|grep -qi "warn"; then echo -e "  ${YELLOW}${line}${RST}"
                   else echo -e "  ${WHITE}${line}${RST}"; fi
               done; echo -e "\n  ${DIM}Press Enter...${RST}"; read -r ;;
            8) search_logs; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            9) export_logs; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            10) setup_watchdog; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            11) print_banner; step "Cleanup"
                echo -e "  ${MC1}1)${RST} ${MC1}Older than 7 days${RST}"
                echo -e "  ${MC2}2)${RST} ${MC2}Older than 30 days${RST}"
                echo -e "  ${MC3}3)${RST} ${MC3}All${RST}"
                local lc; ask_input "Select" "1" lc
                case "$lc" in
                    1) journalctl --vacuum-time=7d 2>/dev/null; success "Done" ;;
                    2) journalctl --vacuum-time=30d 2>/dev/null; success "Done" ;;
                    3) confirm "Sure?" && { journalctl --rotate 2>/dev/null; journalctl --vacuum-time=1s 2>/dev/null; success "Done"; } ;;
                esac; echo -e "\n  ${DIM}Press Enter...${RST}"; read -r ;;
            12) print_banner
                if benchmark_resolvers; then
                    echo ""
                    if confirm "Apply best resolvers and restart tunnel?"; then
                        local how_many
                        ask_input "How many resolvers?" "3" how_many
                        select_best_resolvers "$how_many"
                        RESOLVERS="$SELECTED_RESOLVERS"
                        RESOLVER_FLAGS="$SELECTED_RESOLVER_FLAGS"
                        # Update config
                        [[ -f "$CONFIG_DIR/client.conf" ]] && {
                            sed -i "s|^RESOLVERS=.*|RESOLVERS=${RESOLVERS}|" "$CONFIG_DIR/client.conf"
                        }
                        # Update service
                        local client_bin="$INSTALL_DIR/bin/slipstream-client"
                        local help_out; help_out=$("$client_bin" --help 2>&1 || true)
                        local exec_cmd="${client_bin}"
                        if echo "$help_out" | grep -qi "\-\-tcp-listen-port"; then
                            exec_cmd+=" --tcp-listen-port ${LOCAL_LISTEN_PORT:-5201}"
                        elif echo "$help_out" | grep -qi "\-\-listen"; then
                            exec_cmd+=" --listen 127.0.0.1:${LOCAL_LISTEN_PORT:-5201}"
                        fi
                        echo "$help_out" | grep -qi "\-\-domain" && exec_cmd+=" --domain ${TUNNEL_DOMAIN}"
                        echo "$help_out" | grep -qi "\-\-cert" && exec_cmd+=" --cert ${CONFIG_DIR}/cert.pem"
                        exec_cmd+=" ${RESOLVER_FLAGS}"
                        sed -i "s|^ExecStart=.*|ExecStart=${exec_cmd}|" /etc/systemd/system/slipstream-client.service
                        systemctl daemon-reload
                        systemctl restart slipstream-client
                        sleep 3
                        systemctl is-active --quiet slipstream-client && success "Tunnel restarted with new resolvers" || error "Restart failed"
                    fi
                fi
                echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            13) generate_xui_config; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            14) uninstall_client; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            0|q|Q) echo -e "\n  ${CYAN}Goodbye!${RST}\n"; exit 0 ;;
            *) warn "Invalid"; sleep 1 ;;
        esac
    done
}

main "$@"
IRAN_EOF
}

# ═══════════════════════════════════════════════════════════════
#  ABROAD SERVER - MANAGEMENT
# ═══════════════════════════════════════════════════════════════

abroad_status() {
    print_banner
    step "Server Status"
    echo ""
    for svc in slipstream-server shadowsocks-libev ss-backend danted microsocks; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${GREEN}●${RST} ${svc}: ${GREEN}${BOLD}RUNNING${RST}"
        elif systemctl list-unit-files 2>/dev/null | grep -q "$svc"; then
            echo -e "  ${RED}●${RST} ${svc}: ${RED}${BOLD}STOPPED${RST}"
        fi
    done
    if [[ -f "$CONFIG_DIR/tunnel.conf" ]]; then
        source "$CONFIG_DIR/tunnel.conf"
        echo ""
        echo -e "  ${WHITE}  Mode:   ${LIME}${TUNNEL_MODE:-N/A}${RST}"
        echo -e "  ${WHITE}  Domain: ${LIME}${TUNNEL_DOMAIN:-N/A}${RST}"
        echo -e "  ${WHITE}  IP:     ${LIME}${SERVER_IP:-N/A}${RST}"
        echo -e "  ${WHITE}  DNS:    ${LIME}${DNS_PORT:-53}/UDP${RST}"
        echo -e "  ${WHITE}  Target: ${LIME}${TARGET_ADDR:-N/A}${RST}"
    fi
    echo ""
    local dp="${DNS_PORT:-53}"
    if ss -ulnp 2>/dev/null | grep -q ":${dp} "; then
        echo -e "  ${GREEN}●${RST} DNS Port ${dp}/UDP: ${GREEN}LISTENING${RST}"
    else
        echo -e "  ${RED}●${RST} DNS Port ${dp}/UDP: ${RED}NOT LISTENING${RST}"
    fi
    echo ""
}

abroad_svc_control() {
    print_banner; step "Service Control"; echo ""
    echo -e "  ${MC1}${BOLD}1)${RST} ${MC1}Start all${RST}"
    echo -e "  ${MC2}${BOLD}2)${RST} ${MC2}Stop all${RST}"
    echo -e "  ${MC3}${BOLD}3)${RST} ${MC3}Restart all${RST}"
    echo -e "  ${MC4}${BOLD}4)${RST} ${MC4}Restart slipstream-server only${RST}"
    echo ""
    local c; ask_input "Select" "" c
    local services="slipstream-server shadowsocks-libev ss-backend danted microsocks"
    case "$c" in
        1) for s in $services; do systemctl start "$s" 2>/dev/null && success "${s} started" || true; done ;;
        2) for s in $services; do systemctl stop "$s" 2>/dev/null && success "${s} stopped" || true; done ;;
        3) for s in $services; do systemctl restart "$s" 2>/dev/null && success "${s} restarted" || true; done ;;
        4) systemctl restart slipstream-server 2>/dev/null; sleep 2
           systemctl is-active --quiet slipstream-server && success "Restarted" || error "Failed" ;;
    esac; echo ""
}

abroad_health() {
    print_banner; step "Server Health Check"; echo ""
    local pass=0 total=0

    total=$((total+1))
    if systemctl is-active --quiet slipstream-server 2>/dev/null; then
        echo -e "  ${GREEN}✔${RST} slipstream-server: active"; pass=$((pass+1))
    else
        echo -e "  ${RED}✘${RST} slipstream-server: inactive"
        # Show last error
        journalctl -u slipstream-server --no-pager -n 3 2>/dev/null | tail -3 | while read -r line; do
            echo -e "    ${DIM}${line}${RST}"
        done
    fi

    total=$((total+1))
    source "$CONFIG_DIR/tunnel.conf" 2>/dev/null || true
    if ss -ulnp 2>/dev/null | grep -q ":${DNS_PORT:-53} "; then
        echo -e "  ${GREEN}✔${RST} DNS port ${DNS_PORT:-53}: active"; pass=$((pass+1))
    else echo -e "  ${RED}✘${RST} DNS port ${DNS_PORT:-53}: inactive"; fi

    total=$((total+1))
    if [[ -f "$CONFIG_DIR/cert.pem" ]]; then
        local exp
        exp=$(openssl x509 -in "$CONFIG_DIR/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
        echo -e "  ${GREEN}✔${RST} Certificate valid until: ${exp}"; pass=$((pass+1))
    else echo -e "  ${RED}✘${RST} Certificate: missing"; fi

    total=$((total+1))
    local errs
    errs=$(journalctl -u slipstream-server --since "5 min ago" --no-pager 2>/dev/null | grep -ci "error\|panic" || echo 0)
    if [[ "$errs" -eq 0 ]]; then
        echo -e "  ${GREEN}✔${RST} No errors in 5 min"; pass=$((pass+1))
    else echo -e "  ${YELLOW}⚠${RST} ${errs} errors in 5 min"; fi

    # Backend check
    total=$((total+1))
    case "${TUNNEL_MODE:-}" in
        shadowsocks)
            if ss -tlnp 2>/dev/null | grep -q ":${SS_PORT:-8388} "; then
                echo -e "  ${GREEN}✔${RST} Shadowsocks backend: active"; pass=$((pass+1))
            else echo -e "  ${RED}✘${RST} Shadowsocks backend: inactive"; fi
            ;;
        socks)
            if ss -tlnp 2>/dev/null | grep -q ":${SOCKS_PORT:-1080} "; then
                echo -e "  ${GREEN}✔${RST} SOCKS backend: active"; pass=$((pass+1))
            else echo -e "  ${RED}✘${RST} SOCKS backend: inactive"; fi
            ;;
        *) pass=$((pass+1)) ;;
    esac

    echo ""
    local pct=$((pass*100/total))
    local col="${GREEN}"; [[ $pct -lt 70 ]] && col="${YELLOW}"; [[ $pct -lt 50 ]] && col="${RED}"
    echo -e "  ${BOLD}${col}Result: ${pass}/${total} passed (${pct}%)${RST}"
    echo ""
}

uninstall_abroad() {
    print_banner; step "Uninstall"; echo ""
    if confirm "Remove SlipTunnel completely?"; then
        for svc in slipstream-server shadowsocks-libev ss-backend danted microsocks slipstream-server-watchdog.timer; do
            systemctl stop "$svc" 2>/dev/null; systemctl disable "$svc" 2>/dev/null
        done
        rm -f /etc/systemd/system/slipstream-server.service /etc/systemd/system/slipstream-server-watchdog.*
        rm -f /etc/systemd/system/ss-backend.service /etc/systemd/system/microsocks.service
        systemctl daemon-reload

        # Restore systemd-resolved if we disabled it
        if [[ -f /etc/systemd/resolved.conf.d/no-stub.conf ]]; then
            rm -f /etc/systemd/resolved.conf.d/no-stub.conf
            systemctl restart systemd-resolved 2>/dev/null || true
        fi

        rm -f /etc/sysctl.d/99-slipstream.conf; sysctl --system >/dev/null 2>&1 || true
        rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$PACKAGE_DIR"
        rm -f /etc/shadowsocks-libev/config.json
        if confirm "Remove Rust toolchain?"; then
            rustup self uninstall -y 2>/dev/null || true
        fi
        echo ""; success "SlipTunnel completely removed"
    fi; echo ""
}

# ═══════════════════════════════════════════════════════════════
#  MAIN MENU
# ═══════════════════════════════════════════════════════════════

show_main_menu() {
    print_banner
    divider
    echo ""
    echo -e "  ${MC1}${BOLD} 1)${RST}  ${MC1}Full Installation (Build + Configure + Package)${RST}"
    echo -e "  ${MC1}${BOLD} 2)${RST}  ${MC1}Reconfigure${RST}"
    echo -e "  ${MC1}${BOLD} 3)${RST}  ${MC1}Rebuild Iran Package${RST}"
    echo -e "  ${MC1}${BOLD} 4)${RST}  ${MC1}Show DNS Records${RST}"
    echo ""
    echo -e "  ${MC2}${BOLD} 5)${RST}  ${MC2}Full Status${RST}"
    echo -e "  ${MC2}${BOLD} 6)${RST}  ${MC2}Start / Stop / Restart${RST}"
    echo -e "  ${MC2}${BOLD} 7)${RST}  ${MC2}Live Traffic Monitor${RST}"
    echo -e "  ${MC2}${BOLD} 8)${RST}  ${MC2}Server Health Check${RST}"
    echo ""
    echo -e "  ${MC3}${BOLD} 9)${RST}  ${MC3}Live Log${RST}"
    echo -e "  ${MC3}${BOLD}10)${RST}  ${MC3}Search Logs${RST}"
    echo -e "  ${MC3}${BOLD}11)${RST}  ${MC3}Export Logs${RST}"
    echo ""
    echo -e "  ${MC4}${BOLD}12)${RST}  ${MC4}Cleanup Logs${RST}"
    echo -e "  ${MC4}${BOLD}13)${RST}  ${MC4}Uninstall${RST}"
    echo -e "  ${MC4}${BOLD} 0)${RST}  ${MC4}Exit${RST}"
    echo ""
}

main() {
    check_root
    install_shortcut
    while true; do
        show_main_menu
        local c; ask_input "Select" "" c
        case "$c" in
            1)  print_banner
                cleanup_existing
                detect_system; install_dependencies; install_rust
                build_slipstream; generate_certs
                collect_config; setup_backend
                optimize_kernel; open_firewall_ports; create_server_service; save_config
                verify_server; show_dns_records
                confirm "Create Iran package now?" && create_iran_package
                install_shortcut
                echo ""; success "Setup complete!"
                echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            2)  print_banner; collect_config; setup_backend
                open_firewall_ports; create_server_service; save_config; show_dns_records
                echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            3)  print_banner
                [[ -f "$CONFIG_DIR/tunnel.conf" ]] && { source "$CONFIG_DIR/tunnel.conf"; create_iran_package; } || error "Run install first"
                echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            4)  print_banner
                [[ -f "$CONFIG_DIR/tunnel.conf" ]] && { source "$CONFIG_DIR/tunnel.conf"; show_dns_records; } || error "Run install first"
                echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            5)  abroad_status; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            6)  abroad_svc_control; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            7)  print_banner; step "Live Monitor (Ctrl+C to exit)"; echo ""
                local iface
                iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
                [[ -z "$iface" ]] && iface="eth0"
                trap 'echo -e "\n${CYAN}Stopped${RST}"; break' INT
                local prx=0 ptx=0 pt=0
                while true; do
                    local now rx tx
                    now=$(date +%s%N)
                    rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null||echo 0)
                    tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null||echo 0)
                    if [[ $pt -ne 0 ]]; then
                        local dt=$(((now-pt)/1000000)); [[ $dt -eq 0 ]] && dt=1
                        local rxr=$(((rx-prx)*1000/dt)) txr=$(((tx-ptx)*1000/dt))
                        printf "\r  ${GREEN}▼${RST} %10d B/s  ${ORANGE}▲${RST} %10d B/s" "$rxr" "$txr"
                    fi
                    prx=$rx; ptx=$tx; pt=$now; sleep 1
                done
                trap - INT; echo -e "\n  ${DIM}Press Enter...${RST}"; read -r ;;
            8)  abroad_health; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            9)  print_banner; step "Live Log (Ctrl+C to exit)"; echo ""
                journalctl -u slipstream-server -f --no-pager 2>/dev/null
                echo -e "\n  ${DIM}Press Enter...${RST}"; read -r ;;
            10) print_banner; step "Search Logs"; echo ""
                echo -e "  ${MC1}1)${RST} ${MC1}Keyword${RST}  ${MC2}2)${RST} ${MC2}Errors${RST}  ${MC3}3)${RST} ${MC3}Time range${RST}"
                echo ""; local sc; ask_input "Select" "1" sc
                case "$sc" in
                    1) local kw; ask_input "Keyword" "" kw; journalctl -u slipstream-server --no-pager 2>/dev/null | grep -i --color=always "$kw" | tail -100 ;;
                    2) journalctl -u slipstream-server --no-pager 2>/dev/null | grep -i --color=always "error\|panic\|fatal" | tail -50 ;;
                    3) local st; ask_input "Since" "1 hour ago" st; journalctl -u slipstream-server --since "$st" --no-pager 2>/dev/null | tail -200 ;;
                esac; echo -e "\n  ${DIM}Press Enter...${RST}"; read -r ;;
            11) print_banner; step "Export Logs"
                local p="/root/slipstream-server-$(date +%Y%m%d-%H%M%S)"
                { echo "═══ Server Diagnostic v4 ═══"; echo "$(date) | $(hostname) | $(uname -r)"
                  echo ""; systemctl status slipstream-server 2>/dev/null || true
                  echo ""; cat "$CONFIG_DIR/tunnel.conf" 2>/dev/null || true
                  echo ""; ss -ulnp 2>/dev/null; echo ""; ss -tlnp 2>/dev/null
                  echo ""; free -h 2>/dev/null
                  echo ""; journalctl -u slipstream-server --no-pager -n 500 2>/dev/null
                } > "${p}.txt"; success "Saved: ${p}.txt"
                echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            12) print_banner; step "Cleanup Logs"
                echo -e "  ${MC1}1)${RST} 7 days  ${MC2}2)${RST} 30 days  ${MC3}3)${RST} All"
                local lc; ask_input "Select" "1" lc
                case "$lc" in
                    1) journalctl --vacuum-time=7d 2>/dev/null; success "Done" ;;
                    2) journalctl --vacuum-time=30d 2>/dev/null; success "Done" ;;
                    3) confirm "Sure?" && { journalctl --rotate; journalctl --vacuum-time=1s; success "Done"; } ;;
                esac; echo -e "\n  ${DIM}Press Enter...${RST}"; read -r ;;
            13) uninstall_abroad; echo -e "  ${DIM}Press Enter...${RST}"; read -r ;;
            0|q|Q) echo -e "\n  ${CYAN}Goodbye!${RST}\n"; exit 0 ;;
            *) warn "Invalid"; sleep 1 ;;
        esac
    done
}

main "$@"
