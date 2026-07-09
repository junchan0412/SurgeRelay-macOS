# Surge Relay Worker

This Worker exposes the generated modules from the private `EEliberto/Surge-Relay` repository without placing a GitHub token in the Surge subscription URL.

Configure `GITHUB_TOKEN` as a Cloudflare Worker secret. The token only needs read access to repository contents. The macOS app uses the same repository with read/write contents permission to publish updates.

## Deploy

This example pins Wrangler in `package-lock.json`. Use Node.js 22 or newer, then install the committed dependency graph:

```bash
cd Deployment/CloudflareWorker
npm ci
npx wrangler login
npx wrangler secret put GITHUB_TOKEN
npm run deploy
```

Update `wrangler.jsonc` before deployment when the repository owner, repository name, branch, or module directory differs from the defaults.
