# homelab-wap

WiFi Access Point manager for NixOS homelabs. Turn your laptop/server into a WiFi hotspot with a simple CLI.

## Features

- **Simple CLI** - `homelab-wap start/stop/status`
- **QR Code** - `homelab-wap show-qr` for easy mobile connection
- **NixOS Module** - Declarative configuration via flake
- **Pi-hole Ready** - Point clients to your local DNS server
- **NAT Included** - Automatically shares your ethernet connection

## Quick Start

### 1. Add to your flake inputs

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    homelab-wap.url = "github:yourusername/homelab-wap";
  };
}
```

### 2. Import the module

```nix
{ inputs, ... }:
{
  imports = [
    inputs.homelab-wap.nixosModules.default
  ];

  services.homelab-wap = {
    enable = true;
    ssid = "MyHomelab";
    passwordFile = "/run/secrets/wifi-password";  # or use sops/agenix
    interface = "wlp192s0";      # your WiFi interface
    wanInterface = "enp191s0";   # interface with internet
    channel = 36;                # 5GHz channel
    hwMode = "a";                # a=5GHz, g=2.4GHz
    dnsServer = "10.42.1.1";     # Pi-hole address
  };
}
```

### 3. Rebuild and use

```bash
sudo nixos-rebuild switch

# Start the access point
homelab-wap start

# Show QR code for easy connection
homelab-wap show-qr

# Check status and connected clients
homelab-wap status

# Stop when done
homelab-wap stop
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `start` | Start the access point |
| `stop` | Stop the access point |
| `restart` | Restart the access point |
| `status` | Show status and connected clients |
| `clients` | List connected devices |
| `show-qr` | Display WiFi QR code in terminal |
| `logs [-f]` | Show logs (use -f to follow) |
| `help` | Show help message |

## Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable the service |
| `ssid` | string | `"Homelab"` | WiFi network name |
| `password` | string | `null` | WiFi password (use passwordFile instead) |
| `passwordFile` | path | `null` | Path to file containing password |
| `interface` | string | `"wlp192s0"` | WiFi interface for AP |
| `wanInterface` | string | `"enp191s0"` | Interface with internet |
| `channel` | int | `36` | WiFi channel |
| `hwMode` | enum | `"a"` | `a`=5GHz, `g`=2.4GHz |
| `subnet` | string | `"10.42.1"` | Subnet prefix (becomes .0/24) |
| `dnsServer` | string | `"10.42.1.1"` | DNS server for clients |
| `countryCode` | string | `"US"` | Regulatory domain |

## Network Topology

```
┌─────────────┐
│ Main Router │
└──────┬──────┘
       │ Ethernet
       ▼
┌──────────────────────────┐
│   Your NixOS Machine     │
│  ┌────────────────────┐  │
│  │ Pi-hole (optional) │  │
│  │    10.42.1.1:53    │  │
│  └─────────┬──────────┘  │
│            │             │
│  ┌─────────┴──────────┐  │
│  │   WiFi AP (wap)    │  │
│  │   10.42.1.0/24     │  │
│  └────────────────────┘  │
└──────────────────────────┘
            │
    ┌───────┴───────┐
    │ WiFi Clients  │
    │ (10.42.1.x)   │
    └───────────────┘
```

## Requirements

- NixOS with flakes enabled
- WiFi card that supports AP mode (`iw list | grep "* AP"`)
- NetworkManager (for interface management)

## Check WiFi AP Support

```bash
nix-shell -p iw -c "iw list" | grep -A 10 "Supported interface modes"
```

Look for `* AP` in the output.

## License

MIT
