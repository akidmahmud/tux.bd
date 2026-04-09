{ config, pkgs, lib, ... }:

let
  zfs = "${pkgs.zfs}/bin/zfs";

  zfsEnsure = dataset: attrs:
    let opts = lib.concatStringsSep " " (map (kv: "-o ${kv}") attrs);
    in "${zfs} list ${dataset} 2>/dev/null || ${zfs} create ${opts} ${dataset}";

  repoDir = "/home/audacioustux/tux.bd";
in {
  imports = [
    ./hardware-configuration.nix
    ./machine.local.nix  # gitignored — see machine.local.nix.example
  ];

  # ── Boot ────────────────────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable             = true;
  boot.loader.systemd-boot.configurationLimit = 5;
  boot.loader.efi.canTouchEfiVariables        = true;
  boot.kernelPackages                         = pkgs.linuxPackages_latest;

  # ── Watchdog ────────────────────────────────────────────────────────────────
  # iTCO_wdt: systemd pets every 15 s; firmware hard-resets after 30 s stall.
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";
    RebootWatchdogSec  = "10m";
    KExecWatchdogSec   = "10m";
  };

  # ── ZFS ─────────────────────────────────────────────────────────────────────
  boot.supportedFilesystems        = [ "zfs" ];
  boot.zfs.forceImportRoot         = false;
  boot.initrd.secrets              = { "/etc/zfs/safe.key" = "/etc/zfs/safe.key"; };
  boot.kernelParams                = [ "zfs.zfs_arc_max=6442450944" ];  # ARC 6 GiB
  boot.extraModprobeConfig         = "options zfs zfs_txg_timeout=30";  # batch writes
  networking.hostId                = "8424e348";
  services.zfs.autoScrub           = { enable = true; interval = "weekly"; };
  services.zfs.trim.enable         = true;

  # ── Snapshots (sanoid) ──────────────────────────────────────────────────────
  # rpool/safe/* — all persistent data. Retention: 24h / 14d / 3mo.
  services.sanoid = {
    enable   = true;
    datasets =
      let snap = { hourly = 24; daily = 14; monthly = 3; autosnap = true; autoprune = true; };
      in {
        "rpool/safe/home"        = snap;
        "rpool/safe/persist"     = snap;
        "rpool/safe/garage-meta" = snap;
        "rpool/safe/garage-data" = snap;
      };
  };

  # ── Backup: syncoid (local) + rclone (remote) ───────────────────────────────
  # Stage 1 — daily ZFS mirror: rpool/safe/* → rpool/backup/*
  # Stage 2 — daily rclone push to backup-crypt remote
  #           (skipped gracefully if /persist/backup/rclone.conf absent)
  services.syncoid = {
    enable   = true;
    interval = "daily";
    commands = {
      "safe-home"    = { source = "rpool/safe/home";    target = "rpool/backup/home";    extraArgs = [ "--no-privilege-elevation" ]; };
      "safe-persist" = { source = "rpool/safe/persist"; target = "rpool/backup/persist"; extraArgs = [ "--no-privilege-elevation" ]; };
    };
  };

  systemd.services.zfs-backup-init = {
    description   = "Ensure ZFS backup datasets exist";
    wantedBy      = [ "multi-user.target" ];
    after         = [ "zfs.target" ];
    before        = [ "syncoid-safe-home.service" "syncoid-safe-persist.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      ${zfsEnsure "rpool/backup"         [ "mountpoint=none" ]}
      ${zfsEnsure "rpool/backup/home"    [ "mountpoint=/backup/home" ]}
      ${zfsEnsure "rpool/backup/persist" [ "mountpoint=/backup/persist" ]}
    '';
  };

  systemd.services.zfs-backup = {
    description   = "ZFS off-disk backup via rclone";
    after         = [ "network-online.target" "syncoid-safe-home.service" "syncoid-safe-persist.service" ];
    wants         = [ "network-online.target" ];
    serviceConfig = { Type = "oneshot"; User = "root"; TimeoutStartSec = "2h"; };
    script = pkgs.writeShellApplication {
      name  = "zfs-backup";
      runtimeInputs = [ pkgs.rclone ];
      text  = ''
        conf=/persist/backup/rclone.conf
        [[ -f $conf ]] || { echo "rclone.conf not found, skipping"; exit 0; }
        rclone sync --config "$conf" --checksum --transfers 4 /backup backup-crypt:homeserver-backup
      '';
    } + "/bin/zfs-backup";
  };

  systemd.timers.zfs-backup = {
    wantedBy    = [ "timers.target" ];
    timerConfig = { OnCalendar = "daily"; RandomizedDelaySec = "30min"; Persistent = true; };
  };

  # ── Garage S3 ───────────────────────────────────────────────────────────────
  # Single-node, ZFS-backed: garage-meta (lz4) + garage-data (off, 1M records).
  # Secrets: /persist/garage/secrets.env (GARAGE_RPC_SECRET, GARAGE_ADMIN_TOKEN)
  systemd.services.garage-zfs-init = {
    description   = "Ensure ZFS datasets for Garage exist";
    wantedBy      = [ "multi-user.target" ];
    after         = [ "zfs.target" ];
    before        = [ "garage.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      ${zfsEnsure "rpool/safe/garage-meta" [ "mountpoint=/var/lib/garage/meta" "compression=lz4" ]}
      ${zfsEnsure "rpool/safe/garage-data" [ "mountpoint=/var/lib/garage/data" "compression=off" "recordsize=1M" ]}
      chown garage:garage /var/lib/garage/meta /var/lib/garage/data
      chmod 750           /var/lib/garage/meta /var/lib/garage/data
    '';
  };

  services.garage = {
    enable          = true;
    package         = pkgs.garage_2;
    environmentFile = "/persist/garage/secrets.env";
    settings = {
      replication_factor              = 1;
      db_engine                       = "lmdb";
      metadata_dir                    = "/var/lib/garage/meta";
      data_dir                        = "/var/lib/garage/data";
      metadata_fsync                  = true;
      metadata_auto_snapshot_interval = "6h";
      block_size                      = "1M";
      rpc_bind_addr                   = "[::]:3901";
      rpc_public_addr                 = "127.0.0.1:3901";
      s3_api = { api_bind_addr = "[::]:3900"; s3_region = "garage"; root_domain = ".s3.garage.localhost"; };
      admin.api_bind_addr             = "127.0.0.1:3903";
    };
  };

  # Static garage user — DynamicUser breaks ZFS dataset ownership across reboots.
  systemd.services.garage = {
    after    = lib.mkMerge [ (lib.mkDefault [ "network.target" "network-online.target" ]) [ "garage-zfs-init.service" ] ];
    requires = [ "garage-zfs-init.service" ];
    serviceConfig = { DynamicUser = lib.mkForce false; User = "garage"; Group = "garage"; };
  };

  users.users.garage  = { isSystemUser = true; group = "garage"; description = "Garage S3 daemon"; };
  users.groups.garage = {};

  # ── Swap ────────────────────────────────────────────────────────────────────
  # ZRAM first (NixOS auto-sets higher priority); NVMe swap only under pressure.
  # NVMe partuuid is in hardware.local.nix (gitignored).
  zramSwap                           = { enable = true; algorithm = "zstd"; memoryPercent = 50; };
  boot.kernel.sysctl."vm.swappiness" = 10;

  # ── Laptop-as-server ────────────────────────────────────────────────────────
  services.logind.settings.Login = {
    HandleLidSwitch              = "ignore";
    HandleLidSwitchExternalPower = "ignore";
  };
  systemd.sleep.extraConfig = ''
    AllowSuspend=no
    AllowHibernation=no
    AllowHybridSleep=no
    AllowSuspendThenHibernate=no
  '';

  # ── Networking ──────────────────────────────────────────────────────────────
  time.timeZone                    = "Asia/Dhaka";
  networking.hostName              = "audacioustux-lap-hp1";
  networking.networkmanager.enable = true;

  # ── Firewall ────────────────────────────────────────────────────────────────
  # LAN (192.168.31.0/24) + tailscale0 trusted. Docker iptables=false —
  # all container traffic routes through Traefik.
  networking.firewall = {
    enable            = true;
    trustedInterfaces = [ "tailscale0" ];
    allowedTCPPorts   = [ 22 80 443 1080 3900 3901 ];
    allowedUDPPorts   = [ 443 1080 41641 ];
    extraCommands = ''
      iptables -I nixos-fw 1 -p tcp -m multiport --dports 22,80,443,1080,3900,3901 ! -s 192.168.31.0/24 -i wlo1 -j nixos-fw-refuse
      iptables -I nixos-fw 1 -p udp -m multiport --dports 443,1080               ! -s 192.168.31.0/24 -i wlo1 -j nixos-fw-refuse
    '';
    extraStopCommands = ''
      iptables -D nixos-fw -p tcp -m multiport --dports 22,80,443,1080,3900,3901 ! -s 192.168.31.0/24 -i wlo1 -j nixos-fw-refuse 2>/dev/null || true
      iptables -D nixos-fw -p udp -m multiport --dports 443,1080               ! -s 192.168.31.0/24 -i wlo1 -j nixos-fw-refuse 2>/dev/null || true
    '';
  };

  # ── Services ────────────────────────────────────────────────────────────────
  services.tailscale  = { enable = true; openFirewall = true; };
  services.fail2ban   = { enable = true; maxretry = 5; };
  services.avahi      = { enable = true; nssmdns4 = true; publish = { enable = true; addresses = true; }; };

  services.sing-box = {
    enable   = true;
    settings = {
      log.level = "info";
      inbounds  = [{ type = "socks"; tag = "socks-in"; listen = "0.0.0.0"; listen_port = 1080; sniff = true; }];
      outbounds = [{ type = "direct"; tag = "direct"; }];
    };
  };

  services.openssh = {
    enable   = true;
    settings = { PermitRootLogin = "no"; PasswordAuthentication = false; KbdInteractiveAuthentication = false; };
  };

  # ── Docker ──────────────────────────────────────────────────────────────────
  virtualisation.docker = {
    enable                   = true;
    storageDriver            = "zfs";
    daemon.settings.iptables = false;
    autoPrune                = { enable = true; dates = "weekly"; flags = [ "--all" ]; };
  };

  # ── Infra compose stack (Traefik + Portainer) ───────────────────────────────
  systemd.tmpfiles.rules = [
    "d /persist/portainer     0700 root root -"
    "d /persist/traefik       0700 root root -"
    "d /persist/traefik/certs 0700 root root -"
  ];

  systemd.services.infra-compose = {
    description = "Infra compose stack (Traefik + Portainer)";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "docker.service" "network-online.target" "tailscaled.service" ];
    wants       = [ "network-online.target" ];
    requires    = [ "docker.service" ];
    serviceConfig = {
      Type             = "oneshot";
      RemainAfterExit  = true;
      WorkingDirectory = "/persist/compose/infra";
      ExecStart        = "${pkgs.docker-compose}/bin/docker-compose up -d --pull missing --remove-orphans";
      ExecStop         = "${pkgs.docker-compose}/bin/docker-compose down";
      TimeoutStartSec  = "5min";
    };
  };

  # ── Users ───────────────────────────────────────────────────────────────────
  users.mutableUsers                        = false;
  users.users.root.hashedPassword           = "!";
  security.sudo.wheelNeedsPassword          = false;

  users.users.audacioustux = {
    isNormalUser = true;
    extraGroups  = [ "wheel" "networkmanager" "docker" ];
    # hashedPassword in machine.local.nix (gitignored)
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXWBoJfED5lM/FJUoGLxUqAac/NWCQymTCaGeaiWNjv"
    ];
  };

  # ── Nix ─────────────────────────────────────────────────────────────────────
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 14d"; };

  # ── Packages ────────────────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    git curl wget btop iotop
    sanoid rclone age openssl
    docker-compose neovim
  ];

  # ── Config repo auto-sync ───────────────────────────────────────────────────
  # File change in ~/tux.bd → immediate commit. Daily timer → push to GitHub.
  systemd.services.config-repo-commit = {
    description   = "Auto-commit changes in ~/tux.bd";
    serviceConfig = {
      Type             = "oneshot";
      User             = "audacioustux";
      WorkingDirectory = repoDir;
      ExecStart        = pkgs.writeShellApplication {
        name          = "config-repo-commit";
        runtimeInputs = [ pkgs.git ];
        text          = ''
          git add -A
          git diff --cached --quiet || git commit -m "auto: sync $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        '';
      } + "/bin/config-repo-commit";
    };
  };

  systemd.paths.config-repo-commit = {
    wantedBy   = [ "multi-user.target" ];
    pathConfig = { PathChanged = repoDir; };
  };

  systemd.services.config-repo-push = {
    description   = "Daily git push for ~/tux.bd";
    after         = [ "network-online.target" ];
    wants         = [ "network-online.target" ];
    serviceConfig = {
      Type             = "oneshot";
      User             = "audacioustux";
      WorkingDirectory = repoDir;
      ExecStart        = pkgs.writeShellApplication {
        name          = "config-repo-push";
        runtimeInputs = [ pkgs.git ];
        text          = "git push";
      } + "/bin/config-repo-push";
    };
  };

  systemd.timers.config-repo-push = {
    wantedBy    = [ "timers.target" ];
    timerConfig = { OnCalendar = "daily"; RandomizedDelaySec = "30min"; Persistent = true; };
  };

  system.stateVersion = "25.11";
}
