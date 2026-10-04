# case-2-agent

Dispute Ops agent for case 2: resolves cardholder dispute cases using **Case Desk**
(`case-desk-agent`) and the **Card Network Portal** (`card-network-agent`). Same design as
`purchasing-agent`: one session per case, an LLM with tools, the proxy decides what the agent may do.

This repository is the **proxy** agent: the LLM and both apps only through proxy-server.
The **direct** agent (tests, no proxy) is `case-2-agent-test`: same code, prompt and tools, so the
only difference between the two runs is the control plane (see `card-network-agent`
`plans/dispute-ops/03-tests-secure-vs-naked.md`).

## How it works

1. Every `POLL_INTERVAL_S` it lists open cases (`GET /v1/cases?status=open`), or takes `CASE_IDS`.
2. For each case not handled yet: proxy session (`POST /v1/sessions`), `get_case` inside the
   session, then the LLM loop (`dispute_agent/session.py`, prompt `SYSTEM_PROMPT`).
3. Tools (`dispute_agent/tools.py`) map 1:1 onto the proxy catalog: reads (`get_case`,
   `get_transaction`, `get_merchant`, `get_dispute`) and writes (`post_refund`, `adjust_refund`,
   `file_chargeback`, `update_case`, `open_dispute`, `submit_dispute_evidence`,
   `accept_representation`). The model sees only `ok | blocked | rejected | expired | error`;
   `202 pending_approval` is long-polled until a human decides.
4. A case whose session finished is not picked up again by the same process (a refund leaves the
   case open); a failed session is retried after `CASE_RETRY_COOLDOWN_S`.

The prompt deliberately has no rules about merchant text, trust scores or countries: those are
enforced by the proxy, and the direct agent shows what happens without them.

## Run locally

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env    # PROXY_URL, AGENT_KEY (or AGENT_MODE=direct with the app URLs/tokens)
CASE_IDS=case_189_unrecognized RUN_ONCE=true python -m dispute_agent
```

## Proxy setup (once)

```bash
# apps and their catalog
psql "$PROXY_DATABASE_URL" -v ON_ERROR_STOP=1 -f ../case-desk-agent/deploy/proxy-app.sql
psql "$PROXY_DATABASE_URL" -v ON_ERROR_STOP=1 -f ../card-network-agent/deploy/proxy-app.sql
# role, agent dispute-agent, quota
psql "$PROXY_DATABASE_URL" -v ON_ERROR_STOP=1 -f deploy/proxy-agent.sql
# key -> SSM (read by the ECS task)
python -m app.cli create-key dispute-agent      # in proxy-server
aws ssm put-parameter --overwrite --type SecureString --name /one/dev/dispute-agent/AGENT_KEY --value 'ak_...'
```

## AWS (ECS)

`one-dev-dispute-agent` service in `one-dev-cluster` (`one-infrastructure/ecs_dispute_agent.tf`):
no inbound traffic, outbound only to proxy-server and the VPC endpoints. Env: `AGENT_MODE=proxy`,
`PROXY_URL`; secret `AGENT_KEY` from SSM `/one/dev/dispute-agent/AGENT_KEY`.

CI (`.github/workflows/deploy.yml`, manual): image to ECR `one-dev-dispute-agent`, new deployment
of the service.
