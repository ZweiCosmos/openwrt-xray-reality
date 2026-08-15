# Security Policy

## Secrets

Never commit:

- `client.env`
- `keys/`
- WireGuard / REALITY private keys
- UUID / shortId from a live deployment

`install-server.sh` writes secrets only on the VPS; treat `client-bundle.tar.gz` as confidential.

## Reporting

If you find a vulnerability in these install scripts (e.g. unsafe permissions, command injection), open a GitHub issue without pasting live credentials, or contact the maintainer privately.
