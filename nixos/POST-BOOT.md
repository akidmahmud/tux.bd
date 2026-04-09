# Post-boot checklist

## 1. Configure off-disk backup (required to activate remote push)

The `zfs-backup.service` runs daily but silently skips the remote push
until `/persist/backup/rclone.conf` exists.

```bash
# Create the backup credential directory (encrypted at rest by ZFS)
sudo mkdir -p /persist/backup
sudo chmod 700 /persist/backup

# Configure an rclone remote named exactly "backup-crypt"
# Recommended: create a "crypt" remote wrapping your S3-compatible bucket
# (Backblaze B2, Cloudflare R2, AWS S3, etc.)
sudo rclone config --config /persist/backup/rclone.conf

# Test a manual run
sudo systemctl start zfs-backup.service
sudo journalctl -u zfs-backup.service -f
```

The pipeline:
  rpool/safe/home    ─┐
                      ├─ syncoid (daily, ZFS-native) ─► rpool/backup/*
  rpool/safe/persist ─┘                                      │
                                                    rclone sync (daily, after syncoid)
                                                             │
                                                    backup-crypt:homeserver-backup

## 2. Authenticate Tailscale

```bash
sudo tailscale up --ssh
```

The `--ssh` flag enables Tailscale SSH so the server is reachable from
anywhere on your tailnet without exposing port 22 to the internet.

## 3. Verify watchdog is active

```bash
sudo systemctl status systemd-watchdog.service 2>/dev/null \
  || cat /sys/class/watchdog/watchdog0/identity
# Should show: iTCO_wdt
```

## 4. Verify ZFS snapshot schedule

```bash
sudo systemctl status sanoid.timer
sudo systemctl status syncoid-safe-home.timer
sudo systemctl status syncoid-safe-persist.timer
```

## 5. Check ZFS pool health

```bash
sudo zpool status
sudo zpool list
```

## 6. Bootstrap Garage object storage

Garage starts but won't serve requests until secrets are placed and the cluster
layout is initialised. Run once after first `nixos-rebuild switch`:

```bash
# Create secrets file on the encrypted /persist volume
sudo mkdir -p /persist/garage
sudo chmod 700 /persist/garage
echo "GARAGE_RPC_SECRET=$(openssl rand -hex 32)"     | sudo tee    /persist/garage/secrets.env
echo "GARAGE_ADMIN_TOKEN=$(openssl rand -base64 32)" | sudo tee -a /persist/garage/secrets.env
sudo chmod 600 /persist/garage/secrets.env

# Restart so Garage picks up the secrets
sudo systemctl restart garage.service
sudo systemctl status  garage.service

# Find the node ID (shown in garage status)
garage status

# Assign this node to a zone and declare its usable capacity, then apply
garage layout assign -z dc1 -c 900G <NODE_ID>
garage layout apply --version 1

# Verify
garage status
garage stats
```

S3 API is on port 3900 (LAN + tailscale only). Admin API is on 127.0.0.1:3903 (loopback only).
The `garage` CLI wrapper in PATH automatically sources the secrets file.

## 7. Notes

- Boot generations are capped at 5 (EFI partition is 511 MiB).
- Nix GC runs weekly, deleting store paths older than 14 days.
- Weekly ZFS scrub is scheduled; first run happens ~7 days after boot.
- Docker storage driver is ZFS; recordsize on rpool/local/docker is 16K.
- rpool/safe/{home,persist,garage-meta,garage-data} are AES-256-GCM encrypted;
  key is in initrd at /etc/zfs/safe.key (embedded via boot.initrd.secrets).
