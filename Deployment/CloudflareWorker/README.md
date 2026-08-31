# Surge Relay Worker

This Worker exposes generated modules from a private GitHub repository without placing a GitHub token in the Surge subscription URL.

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

Replace the placeholder owner and repository values in `wrangler.jsonc` before deployment. Also update the branch or module directory when your Surge Relay settings use different values.
