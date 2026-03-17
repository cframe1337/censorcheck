#!/bin/sh

readonly SCRIPT_NAME=$(basename "$0")
DEPENDENCIES="curl jq"

# Colors
readonly COLOR_WHITE="\033[97m"
readonly COLOR_RED="\033[31m"
readonly COLOR_GREEN="\033[32m"
readonly COLOR_BLUE="\033[36m"
readonly COLOR_ORANGE="\033[33m"
readonly COLOR_RESET="\033[0m"
readonly CURL_SEPARATOR="--UNIQUE-SEPARATOR--"

# Config
DNS_SERVERS="1.1.1.1 8.8.8.8 9.9.9.9"
DOH_SERVERS="https://cloudflare-dns.com/dns-query https://dns.google/dns-query https://dns.quad9.net/dns-query"

TIMEOUT=5
RETRIES=4
MODE="both"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:148.0) Gecko/20100101 Firefox/148.0"
DOMAINS_FILE=""
IP_VERSION="4"
PROXY=""
SINGLE_DOMAIN=""
PROTOCOL="both"
JSON_OUTPUT=false

DPI_BLOCKED_SITES="youtube.com discord.com instagram.com facebook.com x.com linkedin.com rutracker.org digitalocean.com amnezia.org getoutline.org mailfence.com flibusta.is rezka.ag"
GEO_BLOCKED_SITES="spotify.com netflix.com patreon.com swagger.io snyk.io mongodb.com autodesk.com graylog.org redis.io"

# Messages
readonly MSG_AVAILABLE="Available"
readonly MSG_BLOCKED="Blocked"
readonly MSG_BLOCKED_TEMPLATE="$MSG_BLOCKED or site didn't respond after %ss timeout"
readonly MSG_REDIRECT="Redirected"
readonly MSG_ACCESS_DENIED="Denied"
readonly MSG_OTHER="Responded with status code"

TEXT_RESULTS=""

error_exit() {
    printf "[%b%s%b] %b%s%b\n" "$COLOR_RED" "ERROR" "$COLOR_RESET" "$COLOR_WHITE" "$1" "$COLOR_RESET" >&2
    display_help
    exit "${2:-1}"
}

show_progress() {
    if ! $JSON_OUTPUT; then
        printf "\r\033[K%b[%d/%d] Checking:%b %b%s%b" \
            "$COLOR_BLUE" "$1" "$2" "$COLOR_RESET" "$COLOR_WHITE" "$3" "$COLOR_RESET"
    fi
}

clear_progress() {
    if ! $JSON_OUTPUT; then
        printf "\r%80s\r" " "
    fi
}

cleanup() {
    clear_progress
    exit 130
}

display_help() {
    cat <<EOF

Usage: $SCRIPT_NAME [OPTIONS]

Checks accessibility of websites that might be blocked by DPI or geolocation restrictions

Options:
  -h, --help         Display this help message and exit
  -m, --mode         Set checking mode: 'dpi', 'geoblock', or 'both' (default: $MODE)
  -t, --timeout      Set connection timeout in seconds (default: $TIMEOUT)
  -r, --retries      Set number of connection retries (default: $RETRIES)
  -u, --user-agent   Set custom User-Agent string (default: $USER_AGENT)
  -f, --file         Read domains from specified file instead of using built-in lists
  -6, --ipv6         Use IPv6 (default: IPv$IP_VERSION)
  -p, --proxy        Use SOCKS5 proxy (format: host:port)
  -d, --domain       Specify a single domain to check
  --http-only        Test only HTTP
  --https-only       Test only HTTPS
  -j, --json         Output results in JSON format
EOF
}

is_installed() {
    command -v "$1" >/dev/null 2>&1
}

check_missing_dependencies() {
    local missing=""
    for pkg in $DEPENDENCIES; do
        if ! is_installed "$pkg"; then
            missing="$missing $pkg"
        fi
    done
    echo "$missing"
}

prompt_for_installation() {
    printf "Missing dependencies:%s\n" "$1"
    printf "Do you want to install them? [y/N]: "
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) exit 0 ;;
    esac
}

get_package_manager() {
    if [ -f /etc/openwrt_release ]; then
        echo "opkg"
        return
    fi
    if [ -d /data/data/com.termux ]; then
        echo "termux"
        return
    fi
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            debian|ubuntu)        echo "apt" ;;
            arch)                  echo "pacman" ;;
            fedora)                echo "dnf" ;;
            centos|rhel|rocky|almalinux)
                if command -v dnf >/dev/null 2>&1; then echo "dnf"; else echo "yum"; fi
                ;;
            *) error_exit "Unknown distribution: $ID. Please install dependencies manually." ;;
        esac
    else
        error_exit "Unable to determine distribution. Please install dependencies manually."
    fi
}

install_with_package_manager() {
    local pkg_manager="$1"
    shift
    local packages="$*"
    local use_sudo=""

    [ "$(id -u)" -ne 0 ] && use_sudo="sudo"

    case "$pkg_manager" in
        apt)
            $use_sudo apt update
            $use_sudo env NEEDRESTART_MODE=a apt install -y $packages
            ;;
        pacman)
            $use_sudo pacman -Syy --noconfirm $packages
            ;;
        dnf)
            $use_sudo dnf install -y $packages
            ;;
        yum)
            $use_sudo yum install -y $packages
            ;;
        termux)
            apt update
            apt install -y $packages
            ;;
        opkg)
            opkg update
            opkg install $packages
            ;;
        *) error_exit "Unknown package manager: $pkg_manager" ;;
    esac
}

install_dependencies() {
    local missing_pkgs
    missing_pkgs=$(check_missing_dependencies)
    [ -z "$missing_pkgs" ] && return 0

    prompt_for_installation "$missing_pkgs"
    pkg_manager=$(get_package_manager)
    install_with_package_manager "$pkg_manager" $missing_pkgs
}

check_ipv6_support() {
    if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
        return 0
    fi
    return 1
}

parse_arguments() {
    while [ $# -gt 0 ]; do
        case $1 in
            -h|--help) display_help; exit 0 ;;
            -m|--mode)
                case "$2" in dpi|geoblock|both) MODE=$2 ;;
                    *) error_exit "Invalid mode: $2" ;; esac
                shift 2
                ;;
            -t|--timeout)
                if echo "$2" | grep -q '^[0-9]\+$'; then TIMEOUT=$2
                else error_exit "Invalid timeout: $2"; fi
                shift 2
                ;;
            -r|--retries)
                if echo "$2" | grep -q '^[0-9]\+$'; then RETRIES=$2
                else error_exit "Invalid retries: $2"; fi
                shift 2
                ;;
            -u|--user-agent)
                [ -n "$2" ] && USER_AGENT=$2 || error_exit "User-Agent empty"
                shift 2
                ;;
            -f|--file)
                [ -f "$2" ] && DOMAINS_FILE="$2" || error_exit "File '$2' not found"
                shift 2
                ;;
            -6|--ipv6)
                check_ipv6_support || error_exit "IPv6 not supported"
                IP_VERSION="6"
                shift
                ;;
            -p|--proxy)
                [ -n "$2" ] && PROXY="$2" || error_exit "Proxy address empty"
                shift 2
                ;;
            -d|--domain)
                [ -n "$2" ] && SINGLE_DOMAIN="$2" || error_exit "Domain empty"
                shift 2
                ;;
            --http-only) PROTOCOL="http"; shift ;;
            --https-only) PROTOCOL="https"; shift ;;
            -j|--json) JSON_OUTPUT=true; shift ;;
            *) error_exit "Unknown option: $1" ;;
        esac
    done
}

print_header() {
    local mode
    cat <<'EOF'
---------------------------------------------------------------------------------

 ██████╗███████╗███╗   ██╗███████╗ ██████╗ ██████╗  ██████╗██╗  ██╗███████╗ ██████╗██╗  ██╗
██╔════╝██╔════╝████╗  ██║██╔════╝██╔═══██╗██╔══██╗██╔════╝██║  ██║██╔════╝██╔════╝██║ ██╔╝
██║     █████╗  ██╔██╗ ██║███████╗██║   ██║██████╔╝██║     ███████║█████╗  ██║     █████╔╝
██║     ██╔══╝  ██║╚██╗██║╚════██║██║   ██║██╔══██╗██║     ██╔══██║██╔══╝  ██║     ██╔═██╗
╚██████╗███████╗██║ ╚████║███████║╚██████╔╝██║  ██║╚██████╗██║  ██║███████╗╚██████╗██║  ██╗
 ╚═════╝╚══════╝╚═╝  ╚═══╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝

---------------------------------------------------------------------------------
EOF

    printf "\nTimeout: %b%ss%b | Retries: %b%s%b\n" "$COLOR_WHITE" "$TIMEOUT" "$COLOR_RESET" "$COLOR_WHITE" "$RETRIES" "$COLOR_RESET"

    case $MODE in
        dpi) mode="DPI" ;;
        geoblock) mode="Geoblock" ;;
        both) mode="DPI and Geoblock" ;;
    esac

    if [ -z "$DOMAINS_FILE" ] && [ -z "$SINGLE_DOMAIN" ]; then
        printf "Mode: %b%s%b\n" "$COLOR_WHITE" "$mode" "$COLOR_RESET"
    fi

    printf "User-Agent: %b%s%b\n" "$COLOR_WHITE" "$USER_AGENT" "$COLOR_RESET"

    if [ -n "$DOMAINS_FILE" ]; then
        printf "Source: %b%s%b\n" "$COLOR_WHITE" "$DOMAINS_FILE" "$COLOR_RESET"
    elif [ -n "$SINGLE_DOMAIN" ]; then
        printf "Single Domain: %b%s%b\n" "$COLOR_WHITE" "$SINGLE_DOMAIN" "$COLOR_RESET"
    fi

    printf "IP Version: %bIPv%s%b\n" "$COLOR_WHITE" "$IP_VERSION" "$COLOR_RESET"

    if [ -n "$PROXY" ]; then
        printf "Proxy: %b%s%b\n" "$COLOR_WHITE" "$PROXY" "$COLOR_RESET"
    fi

    check_dns_hijacking
}

read_domains_from_file() {
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        case "$line" in
            ""|\#*) continue ;;
            *) echo "$line" ;;
        esac
    done < "$1"
}

execute_curl() {
    local url=$1
    local protocol=$2
    local follow_redirects=$3
    local ip_version_to_use=${4:-$IP_VERSION}
    local curl_output
    local curl_opts="-s --compressed -o /dev/null -w \"%{http_code}${CURL_SEPARATOR}%{redirect_url}\" --retry $RETRIES --connect-timeout $TIMEOUT --max-time $((TIMEOUT * 2)) -A \"$USER_AGENT\""

    case "$ip_version_to_use" in
        4) curl_opts="$curl_opts -4" ;;
        6) curl_opts="$curl_opts -6" ;;
    esac

    if [ -n "$PROXY" ]; then
        curl_opts="$curl_opts --proxy socks5://$PROXY"
    fi

    if [ "$follow_redirects" = "true" ]; then
        curl_opts="$curl_opts -L"
    fi

    if curl_output=$(eval curl $curl_opts "${protocol}://${url}" 2>/dev/null); then
        echo "$curl_output"
    else
        echo "000${CURL_SEPARATOR}"
    fi
}

format_result() {
    local protocol=$1 status_code=$2 redirect_url=$3 msg first_word rest first_word_color

    if [ -z "$status_code" ] || [ "$status_code" = "000" ] || [ "$status_code" -eq 0 ]; then
        msg=$(printf "$MSG_BLOCKED_TEMPLATE" "$TIMEOUT")
    elif [ "$status_code" -ge 300 ] && [ "$status_code" -lt 400 ]; then
        msg=$(printf "$MSG_REDIRECT (%s) to %s" "$status_code" "${redirect_url:-<empty>}")
    elif [ "$status_code" -eq 200 ]; then
        msg="$MSG_AVAILABLE ($status_code)"
    elif [ "$status_code" -eq 403 ]; then
        msg="$MSG_ACCESS_DENIED ($status_code)"
    else
        msg="$MSG_OTHER $status_code"
    fi

    first_word="${msg%% *}"
    rest="${msg#* }"

    case "$first_word" in
        Blocked|Denied) first_word_color=$COLOR_RED ;;
        Available)      first_word_color=$COLOR_GREEN ;;
        Redirected)     first_word_color=$COLOR_BLUE ;;
        *)              first_word_color=$COLOR_ORANGE ;;
    esac

    printf "  %b%s%b: %b%s%b %s\n" "$COLOR_WHITE" "$protocol" "$COLOR_RESET" "$first_word_color" "$first_word" "$COLOR_RESET" "$rest"
}

get_domains_to_check() {
    if [ -n "$SINGLE_DOMAIN" ]; then
        echo "$SINGLE_DOMAIN"
    elif [ -z "$DOMAINS_FILE" ]; then
        case $MODE in
            dpi)      echo "$DPI_BLOCKED_SITES" ;;
            geoblock) echo "$GEO_BLOCKED_SITES" ;;
            both)     echo "$DPI_BLOCKED_SITES $GEO_BLOCKED_SITES" ;;
        esac
    else
        read_domains_from_file "$DOMAINS_FILE"
    fi
}

get_single_check_result() {
    local domain=$1 protocol=$2 follow_redirects=$3 ip_version=$4
    local response status_code redirect_url

    response=$(execute_curl "$domain" "$protocol" "$follow_redirects" "$ip_version")
    status_code="${response%%$CURL_SEPARATOR*}"
    redirect_url="${response#*$CURL_SEPARATOR}"

    jq -n \
        --argjson status "${status_code:-0}" \
        --arg redirect_url "${redirect_url:-}" \
        '{ "status": ($status|tonumber), "redirect_url": (if $redirect_url == "" then null else $redirect_url end) }'
}

gather_single_domain_result() {
    local domain=$1 ipv6_supported=false
    local http_ipv4=null http_ipv6=null https_ipv4=null https_ipv6=null

    check_ipv6_support && ipv6_supported=true

    if [ "$PROTOCOL" = "both" ] || [ "$PROTOCOL" = "http" ]; then
        http_ipv4=$(get_single_check_result "$domain" "HTTP" false 4)
        if $ipv6_supported; then http_ipv6=$(get_single_check_result "$domain" "HTTP" false 6); fi
    fi
    if [ "$PROTOCOL" = "both" ] || [ "$PROTOCOL" = "https" ]; then
        https_ipv4=$(get_single_check_result "$domain" "HTTPS" true 4)
        if $ipv6_supported; then https_ipv6=$(get_single_check_result "$domain" "HTTPS" true 6); fi
    fi

    jq -n \
        --arg service "$domain" \
        --argjson http_ipv4 "$http_ipv4" \
        --argjson http_ipv6 "$http_ipv6" \
        --argjson https_ipv4 "$https_ipv4" \
        --argjson https_ipv6 "$https_ipv6" \
        '{
            "service": $service,
            "http": { "ipv4": $http_ipv4, "ipv6": $http_ipv6 },
            "https": { "ipv4": $https_ipv4, "ipv6": $https_ipv6 }
        }'
}

get_domain_ip() {
    local domain=$1
    # BusyBox nslookup output usually looks like:
    # Name:      example.com
    # Address 1: 93.184.216.34
    # or
    # Address: 93.184.216.34
    # We grab the last address field found after the name.
    nslookup "$domain" 2>/dev/null | awk '/^Name:/ {found=1} found && /^Address/ {print $NF; exit}'
}

get_domain_ips_via_dns() {
    local domain=$1 server=$2 output
    if [ -n "$server" ]; then
        output=$(nslookup "$domain" "$server" 2>/dev/null)
    else
        output=$(nslookup "$domain" 2>/dev/null)
    fi
    echo "$output" | awk '/^Address/ {print $NF}'
}

get_domain_ips_via_doh() {
    local domain=$1 doh_server=$2
    curl -s -H "accept: application/dns-json" "${doh_server}?name=${domain}&type=A" | \
        jq -r '.Answer[]?.data // empty' 2>/dev/null
}

have_ip_intersection() {
    local list1="$1" list2="$2"
    for ip1 in $list1; do
        for ip2 in $list2; do
            [ "$ip1" = "$ip2" ] && return 0
        done
    done
    return 1
}

check_dns_hijacking() {
    local test_domains="rutracker.org linkedin.com flibusta.is"
    local regular_dns_ips doh_ips hijacked_domain hijacked_ip found_ip

    for test_domain in $test_domains; do
        regular_dns_ips=""; doh_ips=""

        for dns_server in $DNS_SERVERS; do
            regular_dns_ips=$(get_domain_ips_via_dns "$test_domain" "$dns_server")
            [ -n "$regular_dns_ips" ] && break
        done

        for doh_server in $DOH_SERVERS; do
            doh_ips=$(get_domain_ips_via_doh "$test_domain" "$doh_server")
            [ -n "$doh_ips" ] && break
        done

        if [ -n "$regular_dns_ips" ] && [ -n "$doh_ips" ]; then
            if ! have_ip_intersection "$regular_dns_ips" "$doh_ips"; then
                hijacked_domain="$test_domain"
                hijacked_ip=$(echo "$regular_dns_ips" | head -n1)
                break
            fi
        fi
    done

    if [ -n "$hijacked_domain" ]; then
        printf "\n%b%s%b %s %b%s%b %s %b%s%b\n\n" \
            "$COLOR_RED" "DNS HIJACKING DETECTED!" "$COLOR_RESET" \
            "ISP redirects" "$COLOR_WHITE" "$hijacked_domain" "$COLOR_RESET" "to" \
            "$COLOR_RED" "$hijacked_ip" "$COLOR_RESET"
        printf "%b%s%b\n" "$COLOR_ORANGE" "Warning: DNS hijacking affects check accuracy." "$COLOR_RESET"
    else
        printf "\n%b%s%b\n" "$COLOR_GREEN" "No DNS hijacking detected." "$COLOR_RESET"
    fi
}

is_ip_reachable() {
    if command -v nc >/dev/null 2>&1; then
        ncat -z -w 2 "$1" 443 2>/dev/null
        return $?
    else
        curl -s --connect-timeout 2 -o /dev/null "https://$1" 2>/dev/null
        return $?
    fi
}

make_json_error() {
    local domain="$1" error_code="$2" msg
    case "$error_code" in
        nxdomain) msg="Domain does not exist" ;;
        blocked_by_ip) msg="Blocked by IP" ;;
        *) msg="Unknown error" ;;
    esac

    jq -n --arg service "$domain" --arg msg "$msg" --arg code "$error_code" \
        '{ "service": $service, "error": $msg, "error_code": $code, "http": null, "https": null }'
}

summarize_status_description() {
    local status_code=$1 redirect_url=$2 msg
    if [ -z "$status_code" ] || [ "$status_code" = "000" ] || [ "$status_code" -eq 0 ]; then
        msg=$(printf "$MSG_BLOCKED_TEMPLATE" "$TIMEOUT")
    elif [ "$status_code" -ge 300 ] && [ "$status_code" -lt 400 ]; then
        msg=$(printf "%s (%s) -> %s" "$MSG_REDIRECT" "$status_code" "${redirect_url:-<empty>}")
    elif [ "$status_code" -eq 200 ]; then
        msg="$MSG_AVAILABLE ($status_code)"
    elif [ "$status_code" -eq 403 ]; then
        msg="$MSG_ACCESS_DENIED ($status_code)"
    else
        msg="$MSG_OTHER $status_code"
    fi
    echo "$msg"
}

colorize_summary() {
    local message="$1" first_word rest color
    first_word="${message%% *}"
    rest="${message#* }"
    [ "$first_word" = "$message" ] && rest=""

    case "$first_word" in
        Blocked|Denied) color=$COLOR_RED ;;
        Available)      color=$COLOR_GREEN ;;
        Redirected)     color=$COLOR_BLUE ;;
        N/A|Skipped)    color=$COLOR_ORANGE ;;
        *)              color=$COLOR_ORANGE ;;
    esac

    printf "%b%s%b %s" "$color" "$first_word" "$COLOR_RESET" "$rest"
}

summarize_protocol_result() {
    local result_json=$1 protocol=$2 data status redirect

    if [ "$PROTOCOL" != "both" ] && [ "$PROTOCOL" != "$protocol" ]; then
        echo "Skipped"; return
    fi

    data=$(echo "$result_json" | jq -c --arg p "$protocol" '
        if .[$p].ipv4.status != 0 then .[$p].ipv4
        elif .[$p].ipv6.status != 0 then .[$p].ipv6
        else .[$p].ipv4 end')

    status=$(echo "$data" | jq -r '.status')
    redirect=$(echo "$data" | jq -r '.redirect_url // ""')

    if [ "$status" = "null" ] || [ -z "$data" ]; then
        echo "N/A"
    else
        summarize_status_description "$status" "$redirect"
    fi
}

add_text_result_row() {
    local service=$1 ip=$2 http_cell=$3 https_cell=$4
    TABLE_DATA="${TABLE_DATA}${service}	${ip}	${http_cell}	${https_cell}\n"
}

print_table_results() {
    printf "\n%b%-30s %-15s %-10s %-10s%b\n" "\033[1m" "Service" "IP" "HTTP" "HTTPS" "\033[0m"

    printf "%b" "$TABLE_DATA" | while IFS="	" read -r service ip http https; do
        [ -z "$service" ] && continue
        printf "%-30s %-15s " "$service" "$ip"
        colorize_summary "$http"
        printf " "
        colorize_summary "$https"
        printf "\n"
    done
}

run_checks_and_print() {
    local domains all_results_json="[]" current_index=0 total_domains

    domains=$(get_domains_to_check)
    set -- $domains
    total_domains=$#

    TABLE_DATA=""

    if ! $JSON_OUTPUT; then
        print_header
        printf "\n"
    fi

    for domain in $domains; do
        current_index=$((current_index + 1))
        show_progress "$current_index" "$total_domains" "$domain"

        local ip_address
        ip_address=$(get_domain_ip "$domain")

        if [ -z "$ip_address" ]; then
            if $JSON_OUTPUT; then
                all_results_json=$(echo "$all_results_json" | jq --argjson item "$(make_json_error "$domain" nxdomain)" '. + [$item]')
            else
                add_text_result_row "$domain" "N/A" "NX Domain" "NX Domain"
            fi
            continue
        fi

        if ! is_ip_reachable "$ip_address"; then
             if $JSON_OUTPUT; then
                all_results_json=$(echo "$all_results_json" | jq --argjson item "$(make_json_error "$domain" blocked_by_ip)" '. + [$item]')
            else
                add_text_result_row "$domain" "$ip_address" "IP Blocked" "IP Blocked"
            fi
            continue
        fi

        local domain_result_json
        domain_result_json=$(gather_single_domain_result "$domain")

        if $JSON_OUTPUT; then
            all_results_json=$(echo "$all_results_json" | jq --argjson item "$domain_result_json" '. + [$item]')
        else
            http_res=$(summarize_protocol_result "$domain_result_json" "http")
            https_res=$(summarize_protocol_result "$domain_result_json" "https")
            add_text_result_row "$domain" "$ip_address" "$http_res" "$https_res"
        fi
    done

    clear_progress

    if $JSON_OUTPUT; then
        jq -n --argjson results "$all_results_json" '{ "version": 1, "results": $results }'
        return
    fi

    print_table_results
}

main() {
    set -e
    trap cleanup EXIT INT TERM

    install_dependencies
    parse_arguments "$@"
    run_checks_and_print

    trap - EXIT INT TERM
}

main "$@"
