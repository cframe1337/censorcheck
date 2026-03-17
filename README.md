# censorcheck

A lightweight shell script for assessing the accessibility of websites potentially subject to Deep Packet Inspection (DPI) or geographic restrictions. Designed for environments with BusyBox/ash (e.g., OpenWrt routers) and POSIX‑compatible systems.

## Important Note on Status Codes

Some websites may not return expected HTTP status codes due to security or anti‑bot measures:

- Services such as `chatgpt.com` and `claude.ai` consistently return `403` because of JavaScript verification, even when accessed from unrestricted regions.
- Websites like `intel.com` may respond with `200` but still display blocking notifications in their content.
- Results should be verified manually if the behaviour appears inconsistent with the actual location.

## Features

- Tests both HTTP and HTTPS protocols for each domain.
- Detects various access outcomes: available, blocked, redirected, or access denied.
- Includes predefined lists of commonly DPI‑blocked and geo‑restricted websites.
- Supports custom domain lists via an input file.
- Configurable connection timeout and retry parameters.
- Colour‑coded terminal output for readability.
- Optional JSON output for integration with other tools.
- Detects DNS hijacking by comparing responses from regular DNS and DNS‑over‑HTTPS.
- Compatible with BusyBox/ash (OpenWrt, embedded systems) and full POSIX environments.

## Included Domain Lists

The script ships with two predefined sets of domains:

- **DPI Blocking** – social media, video platforms, and other frequently restricted services.
- **Geographic Restrictions** – popular streaming services and platforms that enforce geo‑blocking.

## Dependencies

- `curl` – for HTTP/HTTPS requests.
- `nslookup` – for DNS resolution (typically provided by `dnsutils` or BusyBox).
- `netcat` – for basic IP reachability checks; **Ncat** (from Nmap) is recommended for full timeout support.  
  *On BusyBox systems without Ncat, a fallback using `timeout` + `nc` is attempted.*

## Installation

Download the script and make it executable:

```sh
wget https://raw.githubusercontent.com/cframe1337/censorcheck/refs/heads/master/censorcheck.sh
chmod +x censorcheck.sh
```

## Usage

Basic examples

```sh
./censorcheck.sh --help # Display help
./censorcheck.sh --mode dpi # Check only DPI‑blocked sites
./censorcheck.sh --mode both --ipv6 # Use IPv6 for all checks
./censorcheck.sh --file my-sites.txt --timeout 10 --retries 3 # Check domains from a custom file with extended timeout
./censorcheck.sh --domain example.com --proxy 127.0.0.1:1080 # Test a single domain through a SOCKS5 proxy
./censorcheck.sh --domain example.com --https-only # Test only HTTPS for a specific domain
./censorcheck.sh --mode dpi --json # Output results in JSON format
```

You can also run the script directly from a URL (if wget is available):

```sh
ash <(wget -qO- https://raw.githubusercontent.com/cframe1337/censorcheck/refs/heads/master/censorcheck.sh) --mode dpi
```

*All options listed in the help message can be combined.*

## Options

```sh
Usage: censorcheck.sh [OPTIONS]

Checks accessibility of websites that might be blocked by DPI or geolocation restrictions

Options:
  -h, --help         Display this help message and exit
  -m, --mode         Set checking mode: 'dpi', 'geoblock', or 'both' (default: both)
  -t, --timeout      Set connection timeout in seconds (default: 5)
  -r, --retries      Set number of connection retries (default: 2)
  -u, --user-agent   Set custom User-Agent string (default: Mozilla/5.0 ...)
  -f, --file         Read domains from specified file instead of built-in lists
  -6, --ipv6         Use IPv6 (default: IPv4)
  -p, --proxy        Use SOCKS5 proxy (format: host:port)
  -d, --domain       Specify a single domain to check
  --http-only        Check only HTTP protocol
  --https-only       Check only HTTPS protocol
  -j, --json         Output results in JSON format

Examples:
  censorcheck.sh                               # Check all predefined domains
  censorcheck.sh --mode dpi                    # Check only DPI-blocked sites
  censorcheck.sh --timeout 10 --retries 3      # Longer timeout and more retries
  censorcheck.sh --user-agent "MyAgent/1.0"    # Custom User-Agent
  censorcheck.sh --file my-domains.txt         # Check domains from custom file
  censorcheck.sh --ipv6                        # Use IPv6
  censorcheck.sh --proxy 127.0.0.1:1080        # Check via SOCKS5 proxy
  censorcheck.sh --domain example.com          # Check a single domain
  censorcheck.sh --file my-domains.txt --json  # Output JSON
```

The domain file should contain one domain per line. Lines starting with # are ignored.

## Custom Domain List

Create a plain text file with one domain per line:

```text
# My custom domains
example.com
test-site.net
# Commented lines are ignored
another-domain.org

# Empty lines are also ignored
```

Then run:

```sh
./censorcheck.sh --file my-domains.txt
```

## Output Interpretation

The script produces colour‑coded output (unless JSON mode is enabled):

- Green – Site is available (HTTP 200).
- Red – Site is blocked, unreachable, or returns access denied (HTTP 403).
- Blue – Site redirects to another URL.
- Orange – Other HTTP status codes.

When DNS hijacking is detected, a warning is displayed before the results.

## Contributing

Contributions are welcome. Please submit pull requests to enhance functionality, add new domains to the predefined lists, or improve compatibility.

## TODO

All things from original repo.
