# vaultwarden-ubuntu-install

Deploys Vaultwarden on Ubuntu via Docker Compose, with an auto-generated argon2 admin token.

## Usage

```bash
chmod +x install_vaultwarden.sh
sudo ./install_vaultwarden.sh --dry-run
sudo ./install_vaultwarden.sh
```

See the comments at the top of `install_vaultwarden.sh` for full details
(requirements, options, security guarantees, known limitations).

## License

MIT

