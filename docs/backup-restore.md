# Backup and Restore

The signal-cli data directory contains linked-device credentials. Treat every backup as an active Signal session.

## Back Up

Stop the service, archive the state, then restart:

```bash
sudo systemctl stop signal-cli
sudo tar --xattrs --acls -czf signal-cli-state-$(date +%F).tar.gz /var/lib/signal-cli
sudo systemctl start signal-cli
```

Store the archive in a private location with access controls at least as strict as the VPS itself.

## Restore

Copy the archive onto the target server, then restore ownership and permissions:

```bash
sudo systemctl stop signal-cli
sudo tar --xattrs --acls -xzf signal-cli-state-YYYY-MM-DD.tar.gz -C /
sudo chown -R signal-cli:signal-cli /var/lib/signal-cli
sudo chmod 0700 /var/lib/signal-cli
sudo systemctl start signal-cli
```

Check service health:

```bash
curl -i http://127.0.0.1:8080/api/v1/check
```

## Security Handling

- Do not store backups in a public bucket, shared folder, or source repository.
- Rotate server access if a backup is exposed.
- If linked-device state is compromised, remove the linked device from the primary Signal phone and rebuild the server state.
