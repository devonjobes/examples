# Local LLM Stack on a Single Node

**A 20B-class inference endpoint and an agent gateway on one small AMD host, behind one private-CA certificate.**

This is an architecture note for a self-hosted LLM stack: a single machine running k3s,
serving a quantized 20B model through llama.cpp on the GPU, plus an agent gateway that
uses that model and a shared web-search service. Everything — inference, search, the
UI, certificates — stays on the LAN.

What the build demonstrates:

- fitting a useful model into a hard memory and bandwidth budget on integrated
  hardware, and knowing when the answer is "change the model" rather than "change the
  backend";
- packaging a GPU workload so the vendor-specific access (device nodes, group IDs)
  is explicit and testable outside Kubernetes first;
- one hostname, path-based routing, and a private CA instead of a public one, with
  the trade-offs that follow;
- treating configuration as state: a seeded file on a volume that becomes
  authoritative after first boot.

---

## Conventions

Host-specific values are placeholders throughout. Numbers that look concrete (group
IDs, image sizes, model dimensions) are the values observed on the original host and
are illustrative.

| Placeholder | Meaning |
|---|---|
| `<HOST>` | The single hostname clients use, published over mDNS (a `.local` name) |
| `<NODE_IP>` | The host's LAN address, also a SAN on the certificate |
| `<NODE_NAME>` | The k3s node name |
| `<MODEL_DIR>` | Host directory holding the GGUF file |
| `<CONFIG_DIR>` | Directory holding the Kubernetes manifests and TLS scripts |
| `<RENDER_GID>` | Group ID that owns the GPU render node (allocated dynamically) |
| `<LAN_CIDR>` | LAN subnet used for the trusted-proxy allowlist |

---

## 1. At a glance

| | |
|---|---|
| **Host** | Single-node k3s on Ubuntu Server LTS, one small AMD APU |
| **GPU** | AMD Radeon 890M iGPU (Strix Point, `gfx1150`), 32 GB unified memory, ~22 GiB usable Vulkan budget |
| **Model** | gpt-oss-20b, MXFP4 quant (~11.3 GiB), served on llama.cpp **Vulkan** |
| **Serving** | `llama-server` on :9090, OpenAI-compatible `/v1`, one slot, 131k context (the model's full trained window) |
| **Agent** | OpenClaw Gateway in namespace `openclaw` (:18789) |
| **Search** | Shared SearXNG + FlareSolverr stack behind one MCP service |
| **Ingress** | k3s Traefik, one hostname, path split `/llm` and `/`, TLS from a private CA |

Two facts drive the whole design:

1. **Inference never crosses the ingress layer.** The gateway calls the llama.cpp
   `ClusterIP` service directly over HTTP inside the cluster. Traefik and TLS exist
   only for humans and external API clients.
2. **The GPU belongs to one namespace.** The gateway has no GPU access and no model
   weights; it is a client of the model API.

---

## 2. Architecture

```
                          LAN client (laptop / phone)
                                     │
                    https://<HOST>   (TLS, private CA)
                                     │
                      ┌──────────────▼───────────────┐
                      │ Reverse proxy          :443  │
                      │  /llm/*  → llama-server:9090 │
                      │  /       → gateway:18789     │
                      └───────┬───────────────┬──────┘
        namespace llama-cpp-vulkan                namespace openclaw
   ┌──────────────────────────▼─────────┐  ┌──▼─────────────────────────────────┐
   │ Pod llama-cpp-vulkan-*             │  │ Pod openclaw-*                     │
   │                                    │  │                                    │
   │  llama-server :9090                │  │  gateway :18789 (UI + WS)          │
   │   ├─ gpt-oss-20b on Vulkan0        │  │  gog (stdio MCP)                   │
   │   └─ MCP client (stdio bridge)     │  │  github (remote MCP)               │
   │                                    │  │  PVC <state dir> 10 GiB            │
   └─────────────────┬──────────────────┘  └─────────────────┬──────────────────┘
                     │                                       │
                     └───────────────────┬───────────────────┘
                                         │  MCP over HTTP
                                         │  search-mcp.search.svc:3000/mcp
               ┌─────────────────────────▼─────────────────────────┐
               │ namespace search                                  │
               │  Pod search-*                                     │
               │   mcp-searxng :3000  (Service/search-mcp)         │
               │   searxng :8080      (loopback only)              │
               │   flaresolverr :8191 (in-pod only)                │
               └───────────────────────────────────────────────────┘
```

The gateway also calls the model directly over
`http://llama-cpp-vulkan.llama-cpp-vulkan.svc.cluster.local:9090/v1`; the ingress
layer is not in that path.

### 2.1 Request paths

| Path | Serves | Auth |
|---|---|---|
| `https://<HOST>/llm/` | llama.cpp web UI (trailing slash required) | None |
| `https://<HOST>/llm/v1` | OpenAI-compatible API base | None |
| `https://<HOST>/llm/health` | `{"status":"ok"}` once the model is loaded | None |
| `https://<HOST>/` | Agent Control UI | Gateway token |
| `http://<HOST>/...` | Redirect to HTTPS | — |
| `http://<NODE_IP>/llm/...` | Redirect to `https://<HOST>/llm/...` | — |
| `http://llama-cpp-vulkan.llama-cpp-vulkan.svc:9090/v1` | In-cluster model API | None |
| `http://127.0.0.1:18789/` | `port-forward` fallback for the UI | Gateway token |


### 2.2 Cluster objects

**`llama-cpp-vulkan`** — the GPU namespace

| Object | Notes |
|---|---|
| `Deployment` | 1 replica; `llama-server` plus a one-shot model-download init |
| `Service` | `ClusterIP`, 9090 |
| `ConfigMap` | `mcp.json`: one search entry, reached through a stdio bridge |
| `Secret` (TLS) | Router certificate for `<HOST>` |
| `NetworkPolicy` | Only TCP 9090 reachable from other pods |
| `IngressRoute` ×2 | `websecure` for `/llm`; `web` → HTTPS redirect |
| `Middleware` ×4 | Trailing-slash fix, `/llm` strip, HTTPS redirect, IP redirect |

**`openclaw`** — the agent namespace

| Object | Notes |
|---|---|
| `Deployment` | 1 replica, `Recreate`; three init containers, one gateway container |
| `PersistentVolumeClaim` | 10 GiB `local-path`, mounted at the agent state root |
| `Service` | `ClusterIP`, 18789 |
| `ConfigMap` | Gateway config + workspace rules, seeded **only when missing** |
| `Secret` | Gateway token, model-provider key, keyring password, GitHub token |
| `Secret` (TLS) | Router certificate for `<HOST>` (TLS secrets are namespace-scoped) |
| `NetworkPolicy` | Only the ingress namespace may reach 18789 |
| `IngressRoute` ×2 | `websecure` for `/` excluding `/llm`; `web` → HTTPS redirect |

**`search`** — shared by both consumers

| Object | Notes |
|---|---|
| `Deployment` | 1 replica; MCP server container plus two native sidecars |
| `Service` | `ClusterIP`, 3000 |
| `ConfigMap` | Metasearch settings, JSON output enabled |
| `Secret` | Metasearch secret (lives here, not in the consumer namespaces) |
| `NetworkPolicy` | Port 3000 from the two consumer namespaces only |

### 2.3 Resource envelope

| Workload | Requests | Limits |
|---|---|---|
| `llama-server` | 12 GiB RAM, 8 CPU, 1 GPU | 20 GiB RAM, 12 CPU, 1 GPU |
| `gateway` | 256 MiB, 100m | 3 GiB, 1 CPU |
| `mcp-searxng` | 128 MiB, 100m | 512 MiB, 500m |
| `searxng` | 256 MiB, 100m | 768 MiB, 1 CPU |
| `flaresolverr` | 512 MiB, 500m | 1536 MiB, 1 CPU |

The gateway runs under a V8 heap cap well below its container limit, because heavy CLI
commands share the same cgroup: raising the memory limit is the correct fix for
pressure, not raising the heap.

---

## 3. Decisions and why

The system converged on: **single-node k3s, Vulkan rather than ROCm, gpt-oss-20b rather
than a dense 14B, the gateway in its own namespace, path routing on one hostname, and a
private CA.**

| # | Decision | Why | Rejected |
|---|---|---|---|
| D1 | Single-node k3s on bare Ubuntu | One box; k3s supplies the service load balancer, Traefik and a local-path provisioner with no control-plane burden | Minikube, kind, kubeadm — each adds a layer without benefit on one host |
| D2 | Abandon Ollama | Its runtime filters this iGPU out of the GPU path; older releases could not pull current models; forcing the Vulkan backend hung or produced zero tokens | Vendor workaround environment variables — none survived |
| D3 | llama.cpp with the **Vulkan** backend | ROCm on this APU was slow and needed unofficial overrides; Vulkan uses the host RADV stack, needs only the DRM device nodes, and cut the image from ~22 GB to ~821 MB | ROCm build — worked, but slow and heavy |
| D4 | **gpt-oss-20b MXFP4** as the served model | ~11.3 GiB fits the 20 GiB container and the ~22 GiB usable Vulkan budget with room for the model's full 131k context; MXFP4 is the model's native quant; its chat template carries reasoning effort and tool calls | Dense Qwen3-14B (~4.6 t/s); Qwen3-30B-A3B (18.6 GB, failed to load); Gemma-26B-A4B (evaluated) |
| D5 | One slot, 131k context, `--jinja`, low reasoning effort | One GPU, one model; a single slot keeps latency predictable and stops background title generation from competing with real work. The chat template requires `--jinja`, and reasoning effort is passed as a template argument | Multiple slots — more KV cache and queueing, no throughput win on one iGPU |
| D6 | **No browser in the stack** | The headless-browser sidecar and its MCP bridge were removed: bare headless shells are blocked by most sites, the reduced tool surface was three verbs, llama.cpp discards image parts of tool results, and the model is text-only. Page text comes from the search server's URL-read tool, which needs no browser | Chromium sidecars; Chromium inside the gateway image |
| D7 | Gateway in its own namespace | Isolation boundary: only the UI is published, the service stays `ClusterIP`, and the model is reached across namespaces by DNS | Same-pod variant — kept as a reference only, never run alongside |
| D8 | Path routing: UI at `/`, model at `/llm` | One hostname, one certificate, no extra DNS names. `/llm` is stripped because the server has no prefix support; the gateway router excludes `/llm` instead of stripping it | Subdomains (more DNS/cert work); a `/bot` prefix (removed) |
| D9 | Private CA for a `.local` name | Public CAs cannot issue for `.local` (reserved for mDNS) and no public validation method applies; a private root trusted once per client is the practical browser-trusted option | ACME/Let's Encrypt (not issuable); DNS-01 on a public zone (rolled back by choice); public-IP cert (needs a public IP, 6-day lifetime); plain self-signed (browser warnings) |
| D10 | Local model primary; hosted models for fallback, vision and utility | Keeps normal chat and tool use on the LAN and the GPU; hosted models only handle images, titles and failover. There is no difficulty router — "think harder" is a deliberate model switch | A second local model — would queue on the single slot |
| D11 | Google Workspace via a CLI/MCP pair, plus a WhatsApp channel | The CLI gives Gmail/Drive/Docs/Sheets/Calendar tools and contacts without a browser; WhatsApp is a native channel with DM pairing and an open group policy | Gmail-as-a-channel (does not exist in this build); hosted Google MCP preview (not used) |
| D12 | Config lives on the volume after first boot | The gateway can be reconfigured from the UI without losing state; the ConfigMap is a seed, not a live source | Treating the ConfigMap as authoritative — changes are silently ignored after first boot |
| D13 | **One shared search stack** | Both consumers are MCP clients of one service: one metasearch config, one result cache, and one renderer/solver (the expensive part). Decoupled from the GPU pod's 12 GB model reloads | Two sets of sidecars; calling into the GPU pod's own search sidecar, which coupled search availability to model restarts |

### 3.1 Why this host

The host is a 32 GB unified-memory APU: a laptop-class CPU with a Radeon 890M iGPU and
no discrete card. That is the whole point — one low-power box, no PCIe GPU, no
separate power/cooling budget — and it sets a hard ceiling. Everything downstream
(model size, backend, context length, slot count) follows from that ceiling rather
than from preference.

Three lessons came out of the hardware selection, in order of how much they cost to
learn:

1. **Pick the model for the GPU you have, not the other way round.** A 14B dense model
   and a 20B mixture-of-experts model are both "small", but they are not equivalent on
   a bandwidth-limited iGPU.
2. **Drivers are part of the model.** The GPU stack, the kernel driver and the
   container's userspace loader are three separate things, and any one of them missing
   produces the same useless symptom: silent CPU fallback.
3. **Memory is the real constraint.** Unified memory means the GPU budget and the
   system budget are the same pool, and the graphics translation table default caps
   what the GPU may take from it.

### 3.2 Why llama.cpp and not Ollama

The APU sits in a gap: the vendor's runtime compiles for the target (`gfx1150`) but
filters integrated GPUs at runtime, with only the larger sibling part allow-listed; the
allow-list change was rejected after crashes during graph reservation. Older releases
recognised the GPU but could not pull current models. Forcing the Vulkan backend
produced hangs, crashes, or 100% GPU utilisation with zero tokens.

llama.cpp has no allow-list and no validation gate, and it compiles for the exact
target. That is why it *replaced* Ollama rather than being added beside it.

### 3.3 Why Vulkan and not ROCm

The ROCm image worked but generated at **4.36–4.64 tokens/second** on a dense 14B,
with prompt processing around 62 t/s. Vulkan raised prompt processing to **191 t/s**
and cut the image from ~22 GB to ~821 MB — but generation stayed ~4.6 t/s, because a
dense 14B model is bandwidth-bound on this iGPU.

That result is the important one: the backend was never the bottleneck. The fix was
architectural — a model that reads far less memory per token.

Two vendor-specific lessons carried over into the final manifests:

- The ROCm tuning variables are ROCm-only and were removed for Vulkan.
- The render node is owned by a **dynamically allocated group**, not by the `video`
  group. If the pod's supplemental groups omit it, llama.cpp silently falls back to
  CPU. This is the single most common way this deployment breaks on a new host.

### 3.4 Why this model

| Model | Size | Outcome |
|---|---|---|
| Qwen2.5-7B Q4 | ~4.7 GB | First test; replaced |
| Qwen3-14B Q4 | ~9 GB | Dense; 4.4–4.6 t/s on both backends; replaced |
| Qwen3-30B-A3B Q4 | ~18.6 GB | Failed to load: GPU out of memory for command submission, device lost; exceeds the default GTT budget |
| Gemma-26B-A4B Q4 | ~16.8 GB | Evaluated as a mixture-of-experts alternative; not deployed |
| **gpt-oss-20b MXFP4** | **~11.3 GiB** | **Final**; the full 131k context fits |

The final model is a mixture-of-experts design: 20.9B parameters stored, a small
fraction active per token. On a bandwidth-bound iGPU that matters more than parameter
count — the bytes read per generated token are what set the token rate.

| Property | Value |
|---|---|
| File size | 12,109,566,624 bytes (~11.3 GiB) |
| Parameters | ~20.9B (mixture of experts) |
| Served context | 131,072 tokens (the model's trained window) |
| Quantization | MXFP4 (the model's native format) |
| Usable GPU memory reported | ~14,600 MiB |

The 30B failure was a host-level memory budget problem, not a manifest bug: the weights
alone exceeded what the GPU was allowed to map. The ceiling is now raised to 20 GB, which
is what makes the full 131k context possible — see [4.3](#43-the-gpu-memory-ceiling) for the
knob, its cap and the measured cost.

---

## 4. Serving design

### 4.1 The image

An off-the-shelf image does not satisfy two requirements, so the deployed image is
built from a short multi-stage recipe and imported into the cluster's containerd —
there is no registry in the loop.

1. **Vulkan for this APU.** llama.cpp is compiled from source with the Vulkan backend
   enabled, so the binary is guaranteed to contain the backend plus a matching loader
   and userspace driver set. The host supplies only the kernel driver and device nodes.
2. **A Node runtime for the MCP bridge.** The search MCP server is reached through a
   stdio-to-HTTP bridge that lives in the `llama-server` container. The image therefore
   carries Node 24 at the exact path the MCP config references. A plain llama.cpp image
   has no Node.

Design notes that matter on a rebuild:

- The image is roughly 821 MB, versus ~22 GB for the ROCm equivalent. That difference
  is why the disk layout works at all.
- Fetching the weights at pod start adds minutes of first-start latency, so the model
  is downloaded once by an idempotent one-shot init container into a host directory
  that is mounted at the same path in the pod. Restarts reuse the file.
- The GPU must be proven *outside* Kubernetes before deploying: run the image
  directly with the device node passed through and list devices. If that prints only
  the CPU, the problem is the image or the group mapping, not the manifest.
- Build inputs (the llama.cpp revision, the bridge package version) are the two things
  that must be pinned for a reproducible rebuild; the recipe leaves both floating.

### 4.2 The serving profile

| Choice | Reason |
|---|---|
| All layers offloaded (`-ngl 99`) | The model must sit entirely in GPU-addressed memory |
| One slot | Predictable latency; no queueing between chat, tools and background jobs |
| 131k context | Matches the gateway's declared window; see [4.3](#43-the-gpu-memory-ceiling) and [5.2](#52-context-budget) |
| Batch and micro-batch 512 | Fastest prompt processing observed on this iGPU |
| Jinja templates + reasoning-effort argument | The model's chat template carries reasoning effort and tool calls; without it, tool use degrades |
| Sampling: temperature 1.0, top-p 1.0, top-k off | The model's recommended sampling |
| MCP server config file | Registers the search server at startup through the stdio bridge |
| CORS pinned to the HTTPS origin | The browser UI and API calls come from one origin |
| No model alias | The API reports the model id as the file path; clients that validate ids strictly need an alias |

Two things that look like misconfiguration and are not:

- **Flash attention reports itself disabled.** On this backend and GPU it is
  unsupported over KV rows. Quantized KV cache attempts make it worse (30–69% slower
  historically), so the default f16 cache is kept.
- **`/health` returns 503 for minutes after start.** The model is being loaded from
  disk; startup probes allow for it.

### 4.3 The GPU memory ceiling

On an APU the GPU has no memory of its own: it addresses system RAM through the graphics
translation table, and the default ceiling is roughly half of RAM. That ceiling — not the
container limit — is what caps context length, because the weights and the KV cache both
have to fit under it.

| Knob | Default | Deployed | Effect |
|---|---|---|---|
| `amdgpu.gttsize` | ~half of RAM | 20,480 MB | Raises the address space the GPU may map |
| `ttm.pages_limit` | ~14.26 GB (half of RAM, in 4 KiB pages) | 5,242,880 pages (20 GiB) | The allocator's cap on buffer objects; binds when lower than `gttsize` |

**Set both.** `gttsize` only builds the aperture; the pages behind it come from TTM, so
raising one without the other produces a window that looks bigger than the memory it can
back. The kernel says so plainly, in two lines that are easy to scroll past:

```
amdgpu: GTT size has been set as 21474836480 but TTM size has been set as 15309492224, this is unusual
amdgpu: Configuring gttsize via module parameter is deprecated, please use ttm.pages_limit
```

Give them the same value and the warning disappears. `ttm.pages_limit` is a permission,
not a reservation: it does not take memory at boot, it just lets TTM hand out up to that
much.

Cost, measured rather than estimated: each step of 32k tokens adds 0.85–1.0 GiB, about
**30 KiB per token**. At the full 131k the GPU holds 14.8 GiB (13.4 GiB of GTT plus
1.4 GiB of the 2 GiB firmware carve-out), and the server still reports **7,369 MiB free**
of its 22,528 MiB budget. Loading the whole window takes about five seconds when the
model file is in page cache.

Read the total from the server, not from `vulkaninfo`: the driver splits the budget
across two heaps, and llama.cpp sums them. Querying before the ceiling was raised showed
~14,600 MiB; after raising both knobs the same command reports 22,528 MiB.

Raising the ceiling is a boot-time change: edit the kernel command line, regenerate the
boot config, reboot. No pod restart can pick it up.

### 4.4 Rollouts need `Recreate` with one GPU

The deployment requests `amd.com/gpu: 1` and the node advertises exactly one. The default
`RollingUpdate` strategy surges a second pod before terminating the first, and that pod
sits `Pending` forever waiting for a GPU the old pod is still holding. The old revision
keeps serving and the rollout hangs, which reads as a stuck deploy rather than a
scheduling problem.

`strategy: Recreate` is the honest setting for a single-GPU workload: the old pod
terminates, the new one loads in its place. The cost is a gap equal to the model load —
seconds when the file is in page cache, about 20 s cold — which is the right trade for a
single-slot service.

---

## 5. Agent gateway design

The gateway is one replica — two gateways must never share the state directory — on a
10 GiB node-local volume, with a non-root, read-only root filesystem and no service
account token. `/tmp` is the only writable path, supplied by an `emptyDir`.

### 5.1 Init ordering

Three init containers, in order, because each depends on the previous:

1. **Ownership repair.** The local-path provisioner creates the volume root
   root-owned. The gateway's plugin and CLI paths require the unprivileged UID to own
   the state root, so this chowns it, repairs stray root-owned files left by one-off
   pods, and sets a restrictive mode.
2. **Helper install.** Downloads a single static CLI binary for Google Workspace to the
   volume (cached across restarts) and writes wrapper scripts plus a keyring password
   file. The wrappers exist because **MCP stdio children do not inherit the container
   environment**: without an explicit home directory the CLI falls back to the
   read-only image layer and fails with a permission error. This is a class of bug
   worth designing around once rather than debugging per integration.
3. **Config seed.** Copies the gateway config and workspace rules from the ConfigMap
   **only if missing**, then prepares the writable `/tmp` subdirectory.

### 5.2 Context budget

The gateway reserves the provider's `maxTokens` out of the declared context window
before sizing a prompt:

```
prompt budget = context window − maxTokens
```

The original split left the prompt budget a few thousand tokens short of a typical
tool-heavy turn, so turns ran in compaction mode and tool results could be dropped
before the model saw them — which presents as "the page came back empty" even though
the fetch succeeded. Both numbers moved together: to 40,960 in the config, then to
65,536, and finally to the model's full 131,072 once both GPU knobs were set.

| Setting | Original | Now |
|---|---|---|
| Server context | 32,768 | 131,072 |
| Gateway context window | 32,768 | 131,072 |
| Gateway max output tokens | 8,192 | 6,144 |
| Prompt budget | 24,576 | 124,928 |

**The failure mode is drift between the two sides.** For a while the gateway's config
declared 40,960 while the server still ran 32,768, because the manifest had been edited
and never applied. The gateway then budgeted 34,816 and sent prompts the server silently
truncated; the real budget was 26,624. The number that matters is
`min(server, gateway) − maxTokens`, so both sides change in the same pass, and the check
afterwards is the server's own `n_ctx_slot`, not the config file.

The full 4× move cost 2.9 GiB of KV cache and was proven by sending a 120,476-token
prompt through the service and getting a 200 back — not by reading the config. Prompt
throughput falls with length, as it must: about 630 t/s at 57k tokens, 227 t/s at 120k,
because attention cost grows with the window. A full-window turn therefore spends roughly
nine minutes in prompt processing before the first token comes back — the window is
headroom for the occasional long document, not a target for every turn.

When prompts still grow, the levers are the tool catalog and the workspace rules, not
the window: a trimmed search schema, capped result counts and result sizes, and
narrowing the largest remaining toolset (the code-host MCP server, ~30 tools) at the
server rather than in the prompt.

### 5.3 Model lanes

| Purpose | Model | Note |
|---|---|---|
| Chat, tools, general work | Local `gpt-oss-20b` | Primary; on the LAN, on the GPU |
| Failure / overflow | Hosted large model | Fallbacks run only when the primary errors |
| Images, screenshots, PDFs | Hosted vision model | Automatic when the active model is text-only |
| Titles, narration, small tasks | Hosted small model | Deliberate: with one local slot, utility traffic would queue behind real work |

There is no difficulty-based router. Deeper reasoning is a deliberate model switch, and
vision is routed automatically because the local model has no projector.

### 5.4 Configuration is state

The seed only applies when the file is missing. After first boot the volume copy is
authoritative:

- changes made through the UI survive restarts;
- editing the ConfigMap alone changes nothing — including bind mode, allowed origins,
  trusted proxies, providers, channels, MCP servers and agents.

That is a good property (no lost UI edits) with a sharp edge (a "config change" that
appears to do nothing). Deliberate reseeds discard UI changes and **drop plugin
registrations**, which live in the config, while extension code and channel pairings
survive on the volume. For a single key, editing the volume copy in place is the
lower-risk path.

### 5.5 Trusted proxies

Traffic arrives from the ingress controller inside the cluster's pod network, and the
service load balancer rewrites external clients to a single in-cluster source address.
The gateway therefore trusts the pod CIDR and falls back to the forwarded client
address; without that, it rejects requests as unattributed rather than serving them.

---

## 6. Networking, TLS and search

### 6.1 One hostname, path split

A single hostname and a single certificate serve both the UI and the model:

- `/llm` → model service, after the prefix is stripped;
- everything else → gateway, unchanged, including assets and WebSocket.

Two routing details are load-bearing rather than cosmetic:

- **The trailing slash on `/llm/`.** The model's web UI is a SvelteKit build that
  computes its base path from the current location. At `/llm` that base is empty, so
  its own asset and API requests hit the host root and the page renders blank. A
  redirect middleware rewrites bare `/llm` to `/llm/`. The regex matches only the bare
  path, so API traffic is untouched.
- **The gateway router must exclude `/llm`.** Because it adds no strip rule, a plain
  catch-all would swallow the model path.

### 6.2 Why a private CA

`.local` is reserved for mDNS: public CAs are barred from issuing for it and no public
validation method can complete. A public IP certificate would need a public address and
a 6-day renewal cycle. The chosen path is a local CA:

| Item | Value |
|---|---|
| Root | RSA-4096, ~10 years, trusted once per client |
| Leaf | RSA-2048, 820 days, `DNS:<HOST>` and `IP:<NODE_IP>` SANs |
| Termination | At the ingress controller; both workloads keep serving plain HTTP inside the cluster |
| Secrets | One per namespace — TLS secrets do not cross namespace boundaries |

The leaf lifetime is deliberately under 825 days because Apple rejects longer-lived
leaves. Rotation re-issues only the leaf: the root and every client's trust stay put,
so a roughly two-yearly re-issue is the whole chore — a good candidate for a scheduled
system job.

Ordering matters: the TLS secret must exist before the routes, or the ingress
controller logs a missing-certificate warning and serves its default certificate.

Access control is a separate problem from transport security, and it is not solved
here: the model endpoint accepts anonymous requests. The documented options are edge
basic auth or an API key on the server itself — the latter also protects the port from
other pods, which edge auth does not.

### 6.3 Search as shared infrastructure

Search started life as a sidecar in the GPU pod, which coupled search availability to
model restarts and duplicated the expensive component. It is now one stack for the
cluster, consumed by both namespaces as ordinary MCP clients:

| Container | Role |
|---|---|
| MCP server | Exposes search and URL-read tools over HTTP on :3000 |
| Metasearch | Loopback-bound, JSON output |
| Renderer/solver | Renders JavaScript pages and clears challenge pages for URL reads |

The two supporting containers run as native sidecars, so the MCP server starts only
after both are healthy. The pod is addressable, but the policy admits only the two
consumer namespaces.

Details that are easy to get wrong, and cost real debugging time:

- **The MCP endpoint runs stateless.** In the default stateful mode, clients open a
  notification stream and the handshake never completes, leaving an empty tool list.
  Stateless mode makes each request self-contained and returns "method not allowed" for
  the stream, which both clients treat as "no server stream".
- **The stdio bridge refuses plain HTTP** unless explicitly allowed, and the shared
  endpoint is HTTP inside the cluster. Without that flag, the tool list silently comes
  back empty.
- **Tool-call timeouts must exceed solver time.** The server's default per-call timeout
  is shorter than one solver acquisition, so the MCP entry carries its own larger
  timeout.
- **The tool list is built once at startup.** Changing the search endpoint requires
  restarting the consumer pod, not just the search pod.

The cost of sharing is one common failure mode: while the search pod is unhealthy, both
consumers lose search — but the model and the gateway keep running. That was the
intended trade.

---

## 7. Security posture

| Control | State |
|---|---|
| Transport | TLS from a private CA on the ingress path; plain HTTP inside the cluster |
| Model endpoint | **Unauthenticated** — TLS encrypts the hop, not the caller |
| Agent UI | Gateway token only; a stolen token is a compromised pod, since the agent can execute commands in its container |
| Pod | Non-root, read-only root filesystem, all capabilities dropped, no service account token, no host path |
| Network policy | Written, but **not enforced** by the default CNI on stock k3s — treat as documentation until the CNI is verified |
| Egress | Open, because plugin and tool installation needs package registries. A deny-by-default policy is documented but not applied |
| Secrets at rest | Encrypted only if the cluster's secrets-encryption option is enabled |
| Agent guardrails | A workspace rule forbids installing software — a rule, not a sandbox |

The most sensitive asset is the mailbox grant: the Google integration can send mail,
holds a refresh token on the volume, and is also reachable by the agent's exec tool,
which bypasses the MCP allowlist. Narrowing it means dropping the send permission, and
accepting that exec access is a separate hole.

---

## 8. Rebuild outline

Ten phases, numbered 0–9, each with the gate that must pass before the next. The order
is not arbitrary: several steps fail confusingly if run out of sequence.

| # | Phase | Gate |
|---|---|---|
| 0 | **Baseline** — Ubuntu Server LTS on the host; note the kernel must provide the in-kernel AMD driver | `lspci` shows the display device |
| 1 | **Storage** — grow the root logical volume across the whole NVMe (the installer allocates a fraction), online | Root filesystem is nearly the full disk |
| 2 | **GPU userspace** — Mesa Vulkan drivers plus tools; add the user to the render and video groups; discover the render node's group ID numerically; raise the GPU memory ceiling on the kernel command line (aperture *and* allocator limit) | `vulkaninfo` reports the RADV device, **not** llvmpipe; the kernel log reports the expected GTT size |
| 3 | **Host identity** — publish a stable `.local` name over mDNS, pinned to the LAN interface; open 80/443 and the mDNS port | The name resolves to the LAN address, not a cluster address |
| 4 | **k3s** — write the config before installing: keep Traefik and the service load balancer, set kubeconfig mode, optional node labels; optionally enable secrets encryption | Node ready, load balancer has the node IP, local-path storage class present |
| 5 | **Model** — place the GGUF on the host model directory; the init container will also fetch it | File size matches the expected bytes |
| 6 | **Image** — build the Vulkan + Node image, import it into containerd (no registry), prove GPU visibility from the image itself | The image lists `Vulkan0` with the iGPU |
| 7 | **Foundations** — three namespaces; the search secret in the search namespace; gateway secrets; private CA and one leaf pushed into **both** namespaces | Both TLS secrets present before any route is applied |
| 8 | **Workloads** — search first, then the model (wait for the load), then the gateway | Search pod healthy; `/health` returns ok; gateway ready |
| 9 | **First boot** — set provider, MCP servers and channels through the UI or the volume copy; understand that the volume wins afterwards | A prompt is answered by the local model |

Constraints worth writing down before starting:

- **Image before pod.** The pull policy is "never", so the node must hold the image
  before the manifest is applied.
- **Secret before route.** Otherwise the ingress layer serves its default certificate
  and clients see a name mismatch rather than a missing-secret error.
- **Search before consumers.** Both consumers build their tool list at startup.
- **First model load is slow.** The init container downloads ~12 GB, then the server
  loads it; first start takes minutes, and the health endpoint is unavailable until
  then.
- **Group IDs are host-specific.** The render group is allocated dynamically, so the
  numeric IDs in the manifest travel with the host, not with the code.
- **One GPU means `Recreate`.** A rolling update cannot place the replacement pod while
  the old one holds the device, so the rollout hangs instead of failing loudly.

---

## 9. Verification layers

Each layer was proven independently, bottom-up, so a failure is attributable rather
than ambiguous.

| Layer | What proves it |
|---|---|
| Host | Device nodes present; render node group ownership matches the pod's supplemental groups |
| GPU in the image | Listing devices from the image shows the iGPU; inside the pod the same command shows the same |
| Model server, direct | Health endpoint OK; model list reports the loaded file and context size; a short completion returns a valid response |
| Context budget | A 120,476-token prompt returns 200 instead of being truncated |
| Ingress | `/llm/health` and `/llm/v1/models` over the hostname; IP URLs redirect; bare `/llm` redirects to `/llm/`; the UI loads with assets and its property endpoint |
| TLS | Handshake against the hostname verifies against the installed CA; issuer and SANs are as issued; a bare-IP handshake fails by design |
| Gateway | Root UI returns HTML; status, model list and MCP status all enumerate the expected entries |
| Search | MCP health reports its transport; the tool catalog in the model UI lists search tools; a JavaScript-only page returns text |
| Integrations | Mail authorization check passes; channel reports connected; plugin lists as enabled |

Distinguishing two identical-looking 404s was worth learning: a plain-text 404 is the
ingress layer finding no route, while a JSON 404 carrying the server's own header means
the route worked and the request reached the model server with the wrong method or
path.

---

## 10. Known gaps and maintenance

| Gap | Consequence |
|---|---|
| No generation benchmark for the final model | The 4.4–4.6 t/s figures belong to the earlier dense model. Prompt processing was measured at ~630 t/s at 57k tokens and ~227 t/s at 120k; generation rate near a full window is still unmeasured |
| Several container tags float | A byte-reproducible rebuild needs digests pinned, including the search images |
| Certificates, tokens and OAuth clients are operator-held | A fresh install re-authorizes the mail integration and re-pairs the chat channel |
| Interactive integration state is not in files | Refresh tokens and channel pairings live on the volume; back it up or re-do them |
| Search is a shared dependency | Its pod restarting removes search from both consumers at once |
| The GPU ceiling is set in the kernel command line | It is a boot-time setting; changing it means editing GRUB, regenerating the boot config and rebooting — not a pod restart |
| One slot | Concurrency is a queue; utility traffic is deliberately routed to a hosted model to keep the slot free |

Maintenance cadence:

| Cadence | Task |
|---|---|
| Monthly | Check the certificate timer and its logs |
| Quarterly | Back up the CA key and the agent volume; verify a restore |
| On gateway upgrade | Back up, bump the tag, apply, run the built-in doctor, re-check MCP status, reinstall plugins if reseeded |
| On model server upgrade | Rebuild with a pinned revision, import, roll out, re-list devices and re-check health |
| On model change | Check the GGUF against the memory budget, and update context length, provider window and download path together |
| On address or hostname change | Re-issue the certificate, update host rules, redirects, CORS origins and allowed origins |
| After editing a manifest | Apply and confirm the object count — apply does not prune removed objects |

---

## 11. Note on provenance and redaction

This document consolidates decisions from a series of working sessions that produced
the manifests, plus the failures that shaped them. It replaces a much longer
reconstruction guide that included every command, both certificate scripts, an
acceptance-test command list and a session-by-session audit.

Removed for publication: the LAN address, the hostname and any public zone name, the
k3s node name, personal phone numbers and chat-group identifiers, the mailbox address,
home-directory paths, session identifiers, and the repository layout of the original
deployment. Retained: the architecture, the decision record and its rejected
alternatives, the measurements that justified the model and backend choice, the
operational failure modes, and the shape of the rebuild.

Where a value is genuinely host-specific — group IDs, image sizes, memory budgets — the
observed number is kept and flagged as illustrative, because the *reasoning* about that
number is the useful part.
