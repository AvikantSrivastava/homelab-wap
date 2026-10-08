{
  description = "homelab-wap - WiFi Access Point manager for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = self.packages.${system}.homelab-wap;

          homelab-wap = pkgs.stdenv.mkDerivation {
            pname = "homelab-wap";
            version = "0.1.0";

            src = ./.;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              mkdir -p $out/bin
              cp homelab-wap $out/bin/homelab-wap
              chmod +x $out/bin/homelab-wap

              wrapProgram $out/bin/homelab-wap \
                --prefix PATH : ${pkgs.lib.makeBinPath [
                  pkgs.qrencode
                  pkgs.systemd
                  pkgs.gawk
                  pkgs.gnugrep
                  pkgs.hostapd
                ]}
            '';

            meta = with pkgs.lib; {
              description = "WiFi Access Point manager for homelab";
              license = licenses.mit;
              platforms = platforms.linux;
            };
          };
        });

      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.homelab-wap;
        in
        {
          options.services.homelab-wap = {
            enable = lib.mkEnableOption "homelab-wap WiFi access point";

            ssid = lib.mkOption {
              type = lib.types.str;
              default = "Homelab";
              description = "WiFi network name (SSID)";
            };

            password = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "WiFi password (use passwordFile for secrets)";
            };

            passwordFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "Path to file containing WiFi password";
            };

            interface = lib.mkOption {
              type = lib.types.str;
              default = "wlp192s0";
              description = "WiFi interface to use for AP";
            };

            wanInterface = lib.mkOption {
              type = lib.types.str;
              default = "enp191s0";
              description = "Interface with internet connection (for NAT)";
            };

            channel = lib.mkOption {
              type = lib.types.int;
              default = 36;
              description = "WiFi channel (1-11 for 2.4GHz, 36+ for 5GHz)";
            };

            hwMode = lib.mkOption {
              type = lib.types.enum [ "a" "b" "g" ];
              default = "a";
              description = "Hardware mode: a=5GHz, g=2.4GHz, b=legacy 2.4GHz";
            };

            subnet = lib.mkOption {
              type = lib.types.str;
              default = "10.42.1";
              description = "Subnet prefix for AP network (e.g., 10.42.1 for 10.42.1.0/24)";
            };

            dnsServer = lib.mkOption {
              type = lib.types.str;
              default = "10.42.1.1";
              description = "DNS server for clients (set to Pi-hole address)";
            };

            countryCode = lib.mkOption {
              type = lib.types.str;
              default = "US";
              description = "Country code for regulatory domain";
            };
          };

          config = lib.mkIf cfg.enable {
            # Ensure required packages are available
            environment.systemPackages = [
              self.packages.${pkgs.system}.homelab-wap
              pkgs.qrencode
              pkgs.hostapd
            ];

            # Write config file for CLI
            environment.etc."homelab-wap/config".text = ''
              SSID="${cfg.ssid}"
              INTERFACE="${cfg.interface}"
              WAN_INTERFACE="${cfg.wanInterface}"
              ${lib.optionalString (cfg.password != null) ''PASSWORD="${cfg.password}"''}
              ${lib.optionalString (cfg.passwordFile != null) ''PASSWORD_FILE="${cfg.passwordFile}"''}
            '';

            # Enable IP forwarding
            boot.kernel.sysctl = {
              "net.ipv4.ip_forward" = 1;
            };

            # Main service that coordinates everything
            systemd.services.homelab-wap = {
              description = "Homelab WiFi Access Point";
              after = [ "network.target" ];
              wantedBy = [ ]; # Not started by default, manual control

              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${pkgs.coreutils}/bin/true"; # Dummy, actual work done by dependencies
              };

              # These services are started/stopped together
              wants = [ "hostapd-wap.service" "dnsmasq-wap.service" ];
              before = [ "hostapd-wap.service" "dnsmasq-wap.service" ];
            };

            # Setup interface and NAT before hostapd
            systemd.services.homelab-wap-setup = {
              description = "Setup network for WiFi AP";
              before = [ "hostapd-wap.service" ];
              requiredBy = [ "homelab-wap.service" ];
              partOf = [ "homelab-wap.service" ];

              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;

                ExecStart = pkgs.writeShellScript "homelab-wap-setup" ''
                  set -e

                  # Bring down NetworkManager control of the interface
                  ${pkgs.networkmanager}/bin/nmcli dev set ${cfg.interface} managed no 2>/dev/null || true

                  # Configure interface
                  ${pkgs.iproute2}/bin/ip addr flush dev ${cfg.interface} 2>/dev/null || true
                  ${pkgs.iproute2}/bin/ip addr add ${cfg.subnet}.1/24 dev ${cfg.interface}
                  ${pkgs.iproute2}/bin/ip link set ${cfg.interface} up

                  # Setup NAT with nftables
                  ${pkgs.nftables}/bin/nft -f - <<EOF
                  table ip homelab_wap {
                    chain postrouting {
                      type nat hook postrouting priority srcnat; policy accept;
                      oifname "${cfg.wanInterface}" masquerade
                    }
                    chain forward {
                      type filter hook forward priority filter; policy accept;
                      iifname "${cfg.interface}" oifname "${cfg.wanInterface}" accept
                      iifname "${cfg.wanInterface}" oifname "${cfg.interface}" ct state related,established accept
                    }
                  }
                  EOF

                  echo "Network setup complete"
                '';

                ExecStop = pkgs.writeShellScript "homelab-wap-teardown" ''
                  # Remove NAT rules
                  ${pkgs.nftables}/bin/nft delete table ip homelab_wap 2>/dev/null || true

                  # Release interface back to NetworkManager
                  ${pkgs.iproute2}/bin/ip addr flush dev ${cfg.interface} 2>/dev/null || true
                  ${pkgs.networkmanager}/bin/nmcli dev set ${cfg.interface} managed yes 2>/dev/null || true

                  echo "Network teardown complete"
                '';
              };
            };

            # hostapd configuration
            systemd.services.hostapd-wap = {
              description = "Hostapd WiFi AP";
              after = [ "homelab-wap-setup.service" ];
              requires = [ "homelab-wap-setup.service" ];
              partOf = [ "homelab-wap.service" ];
              wantedBy = [ ]; # Controlled by homelab-wap

              serviceConfig = {
                Type = "simple";
                Restart = "on-failure";
                RestartSec = "5s";

                ExecStartPre = pkgs.writeShellScript "hostapd-wap-pre" ''
                  # Generate hostapd config
                  mkdir -p /run/homelab-wap

                  # Get password
                  PASSWORD=""
                  ${lib.optionalString (cfg.password != null) ''PASSWORD="${cfg.password}"''}
                  ${lib.optionalString (cfg.passwordFile != null) ''PASSWORD="$(cat ${cfg.passwordFile})"''}

                  if [ -z "$PASSWORD" ]; then
                    echo "ERROR: No password configured"
                    exit 1
                  fi

                  cat > /run/homelab-wap/hostapd.conf <<EOF
                  interface=${cfg.interface}
                  driver=nl80211
                  ssid=${cfg.ssid}
                  hw_mode=${cfg.hwMode}
                  channel=${toString cfg.channel}
                  country_code=${cfg.countryCode}

                  # Security
                  wpa=2
                  wpa_passphrase=$PASSWORD
                  wpa_key_mgmt=WPA-PSK
                  rsn_pairwise=CCMP

                  # 802.11n/ac support
                  ieee80211n=1
                  ieee80211ac=1
                  wmm_enabled=1

                  # Logging
                  logger_syslog=-1
                  logger_syslog_level=2
                  EOF

                  chmod 600 /run/homelab-wap/hostapd.conf
                '';

                ExecStart = "${pkgs.hostapd}/bin/hostapd /run/homelab-wap/hostapd.conf";
              };
            };

            # dnsmasq for DHCP
            systemd.services.dnsmasq-wap = {
              description = "DHCP server for WiFi AP";
              after = [ "homelab-wap-setup.service" ];
              requires = [ "homelab-wap-setup.service" ];
              partOf = [ "homelab-wap.service" ];
              wantedBy = [ ]; # Controlled by homelab-wap

              serviceConfig = {
                Type = "simple";
                Restart = "on-failure";
                RestartSec = "5s";

                ExecStartPre = pkgs.writeShellScript "dnsmasq-wap-pre" ''
                  mkdir -p /var/lib/dnsmasq
                '';

                ExecStart = pkgs.writeShellScript "dnsmasq-wap-start" ''
                  exec ${pkgs.dnsmasq}/bin/dnsmasq \
                    --keep-in-foreground \
                    --no-daemon \
                    --interface=${cfg.interface} \
                    --bind-interfaces \
                    --dhcp-range=${cfg.subnet}.50,${cfg.subnet}.150,255.255.255.0,12h \
                    --dhcp-option=option:router,${cfg.subnet}.1 \
                    --dhcp-option=option:dns-server,${cfg.dnsServer} \
                    --dhcp-leasefile=/var/lib/dnsmasq/dnsmasq.leases \
                    --log-dhcp \
                    --log-facility=-
                '';
              };
            };
          };
        };

      # Development shell
      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.qrencode
              pkgs.shellcheck
            ];
          };
        });
    };
}
