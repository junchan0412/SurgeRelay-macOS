const githubHeaders = (token) => ({
  Accept: "application/vnd.github.raw+json",
  Authorization: `Bearer ${token}`,
  "User-Agent": "Surge-Relay-Worker/1.0",
  "X-GitHub-Api-Version": "2022-11-28",
});

const encodePath = (path) => path
  .split("/")
  .filter(Boolean)
  .map(encodeURIComponent)
  .join("/");

export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }

    const url = new URL(request.url);
    let requestedPath;
    try {
      requestedPath = decodeURIComponent(url.pathname).replace(/^\/+/, "");
    } catch {
      return new Response("Bad Request", { status: 400 });
    }

    if (!requestedPath) {
      return Response.json({ service: "Surge Relay", status: "ok" }, {
        headers: { "Cache-Control": "no-store" },
      });
    }

    const isModule = requestedPath.endsWith(".sgmodule");
    const isGeneratedAsset = requestedPath.startsWith("assets/") && requestedPath.endsWith(".js");
    if (requestedPath.includes("..") || (!isModule && !isGeneratedAsset)) {
      return new Response("Not Found", { status: 404 });
    }

    if (!env.GITHUB_TOKEN) {
      return new Response("Worker is not configured", { status: 503 });
    }

    const repositoryPath = encodePath(`${env.GITHUB_DIRECTORY}/${requestedPath}`);
    const branch = encodeURIComponent(env.GITHUB_BRANCH || "main");
    const apiURL = `https://api.github.com/repos/${encodeURIComponent(env.GITHUB_OWNER)}/${encodeURIComponent(env.GITHUB_REPOSITORY)}/contents/${repositoryPath}?ref=${branch}`;
    const upstream = await fetch(apiURL, {
      headers: githubHeaders(env.GITHUB_TOKEN),
    });

    if (!upstream.ok) {
      return new Response(upstream.status === 404 ? "Not Found" : "GitHub upstream error", {
        status: upstream.status,
        headers: { "Cache-Control": "no-store" },
      });
    }

    const headers = new Headers(upstream.headers);
    headers.set("Access-Control-Allow-Origin", "*");
    headers.set("Cache-Control", "public, max-age=60, stale-while-revalidate=300");
    headers.set("Content-Type", isModule ? "text/plain; charset=utf-8" : "application/javascript; charset=utf-8");
    headers.delete("Authorization");
    headers.delete("Set-Cookie");

    return new Response(request.method === "HEAD" ? null : upstream.body, {
      status: 200,
      headers,
    });
  },
};
