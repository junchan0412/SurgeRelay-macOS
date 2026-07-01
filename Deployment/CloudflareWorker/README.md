# Surge Relay Worker

This Worker exposes the generated modules from the private `EEliberto/Surge-Relay` repository without placing a GitHub token in the Surge subscription URL.

Configure `GITHUB_TOKEN` as a Cloudflare Worker secret. The token only needs read access to repository contents. The macOS app uses the same repository with read/write contents permission to publish updates.
