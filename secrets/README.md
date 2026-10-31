# secrets/

Files here are bind-mounted read-only into containers at runtime. Nothing in this
directory is committed (see `.gitignore`) and nothing here is ever copied into an image.

| Service   | File                                             | Mounted at                                      |
|-----------|--------------------------------------------------|-------------------------------------------------|
| portfolio | `secrets/portfolio/firebase-service-account.json` | `/run/secrets/firebase-service-account.json`    |

On the Linux VM the container user (uid 10001) must be able to read the file:
`chmod 644 secrets/portfolio/firebase-service-account.json` (the directory itself can stay 700
owned by the deploy user only if you `chown 10001` the file instead).
