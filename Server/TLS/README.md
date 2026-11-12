# Local HTTPS certificate

The app serves its installation manifest and IPA on the device at port 14302.
Use a dedicated hostname with a DNS-only A record pointing to `127.0.0.1` and a
publicly trusted certificate issued for that hostname, for example using ACME
DNS-01.

Package the full certificate chain and its dedicated private key:

```sh
python3 Server/TLS/package_identity.py \
  --host install.example.com \
  --fullchain /path/to/fullchain.pem \
  --private-key /path/to/privkey.pem \
  --public-base https://updates.example.com/installation \
  --bundle-output Signer/Resources/Installation/server.p12
```

The output directory contains `server.p12` and `installation.json`. For builds
that use automatic certificate updates, serve those files at `--public-base`
over HTTPS and set that configuration URL in Installation settings. Repackage
a renewed certificate before the current one expires.

This identity is distributed to app users. It must belong to a dedicated
installation hostname: never use a website's ordinary private key or an app
signing certificate. Configuration includes the package password; that password
does not make a distributed TLS key confidential.

Keep ACME account keys, DNS API tokens, app signing identities and generated
packages out of Git. The app's signing certificates, passwords and IPA files
are not required by the update server and stay on the device.

A source checkout builds without a bundled P12. Import the local-server identity
in Installation settings, configure its HTTPS update endpoint, or add the P12
locally when packaging a release. `Scripts/package-preview.sh` includes a local
`Signer/Resources/Installation/server.p12` before it signs the package. The app checks certificate trust and hostname
matching before it starts the installation server.
