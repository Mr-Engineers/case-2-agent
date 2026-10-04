-- Registers the dispute agent in proxy-server (schema proxy): role with access to the apps
-- case_desk and card_network, agent "dispute-agent" with its mandate, hourly quota. Idempotent.
-- Needs the apps registered first (case-desk-agent and card-network-agent deploy/proxy-app.sql).
-- Run against the proxy database (DATABASE_URL of proxy-server):
--   psql "$PROXY_DATABASE_URL" -v ON_ERROR_STOP=1 -f deploy/proxy-agent.sql
-- Then create the agent's key and put it in SSM (read by the one-dev-dispute-agent task):
--   python -m app.cli create-key dispute-agent
--   aws ssm put-parameter --overwrite --type SecureString \
--     --name /one/dev/dispute-agent/AGENT_KEY --value 'ak_...'

begin;

set local proxy.actor = 'case-2-agent';

insert into proxy.roles (id, name, description, status)
values ('role_dispute_operator', 'dispute-operator',
        'Dispute ops: read cases and the card network, refunds, chargebacks, network disputes.', 'active')
on conflict (id) do nothing;

insert into proxy.role_app_grants (role_id, app_id) values
  ('role_dispute_operator', 'case_desk'),
  ('role_dispute_operator', 'card_network')
on conflict do nothing;

insert into proxy.agents (id, name, mandate, llm_models, role_id, limits)
values ('dispute-agent', 'Dispute Ops',
        'Rozwiązuje sprawy sporne posiadaczy kart: dla jednej sprawy czyta transakcję, sprzedawcę i spór w sieci kartowej, '
        'potem zwraca środki klientowi, składa chargeback albo akceptuje odpowiedź sprzedawcy. Kwoty w EUR, nigdy ponad kwotę transakcji.',
        '{}', 'role_dispute_operator', '{"max_denies_per_session": 3}')
on conflict (id) do nothing;

insert into proxy.quotas (id, agent_id, name, "window", cap, burst)
values ('quota_dispute_hourly', 'dispute-agent', 'Hourly cap', '1h', 500, 50)
on conflict (id) do nothing;

commit;
