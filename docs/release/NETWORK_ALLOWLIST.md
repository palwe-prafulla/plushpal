# Privacy Network Allowlist

Local conversation has an empty network allowlist. Any unexpected connection is a release blocker.

| Parent-enabled operation | Allowed destination | Data boundary |
|---|---|---|
| Model install/update | HTTPS host and redirect hosts in the signed model manifest | Public model identifier, byte ranges; no child or character data |
| Curated search | `api.search.brave.com:443`; validated public HTTPS evidence pages | Sanitized bounded query; no conversation/session/voice identifiers |
| Experimental OpenAI turn | `api.openai.com:443` | Age band, policy version, alias, bounded recent text/current text; `store: false`; no local IDs or binary assets |

All clients disable ambient proxies in the private-beta implementation, validate TLS, bound bodies/deadlines, and reject private/link-local/loopback DNS answers. Provider changes require a signed eligibility-registry update and a new privacy capture.
