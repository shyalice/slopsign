# Installation support

Signing and IPA storage run on the device. Installation uses a local HTTPS
server inside the app; no application upload service or database is required.

`TLS/package_identity.py` packages a dedicated certificate for that local
server. See [TLS configuration](TLS/README.md).

Only the packaging code belongs in source control. Generated packages,
configuration files, ACME credentials and private keys are excluded. A public
build can import its local-server TLS identity in Installation settings or
include one during release packaging.
