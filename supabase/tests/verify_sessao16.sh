#!/usr/bin/env bash
# verify_sessao16.sh — Sessão 16 (ADR-021) validação real no dev.
# Reset + replay 0001→0029 + inventário (+whatsapp_conversations + notifications.recipient_phone)
# + 10 suítes de regressão (zero regressão esperada — 0029 é schema-prep, sem tocar RPCs).
# Roda contra o dev rtoyfiqngyicqtuzwfhz — NUNCA produção.
# Requer: ~/.supabase/vio10_dev_pat, jq, curl.
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MIG="$SCRIPT_DIR/../migrations"
TESTS="$SCRIPT_DIR"

PAT=$(cat ~/.supabase/vio10_dev_pat)
PROJ=rtoyfiqngyicqtuzwfhz
EP="https://api.supabase.com/v1/projects/$PROJ/database/query"
HDR=(-H "Authorization: Bearer $PAT" -H "Content-Type: application/json" -H "User-Agent: supabase-cli/2.115.0")

VERDICT=/tmp/vio10_verdict.sql
cat > "$VERDICT" <<'VSQL'
do $v$
declare f int;
begin
  select num_failed() into f;
  create temp table _tap(line text) on commit drop;
  insert into _tap select * from finish();
  insert into _tap values ('__FAILED=' || f);
end $v$;
select
  (select replace(line,'__FAILED=','')::int from _tap where line like '__FAILED=%') as failed,
  (select count(*) from _tap where line like 'not ok%') as not_ok,
  (select count(*) from _tap where line like 'ok %' or line like 'not ok%') as test_lines,
  (select line from _tap where line like '1..%') as plan_line,
  (select string_agg(line,' | ') from _tap where line like 'not ok%' or line like '# Looks%') as diag;
VSQL

runq() { jq -n --arg q "$1" '{query:$q}' | curl -s --max-time 240 -X POST "${HDR[@]}" --data-binary @- "$EP"; }
isfail() { echo "$1" | grep -q '"message"'; }

RESET='drop schema if exists public cascade; drop schema if exists harness cascade; delete from auth.users; create schema public; grant usage,create on schema public to postgres, anon, authenticated, service_role;'
echo "=== RESET ==="
R=$(runq "$RESET"); isfail "$R" && { echo "RESETFAIL: $R"; exit 1; } || echo "RESET OK"

echo "=== REPLAY 0001..0029 ==="
i=0
for f in $(ls "$MIG" | sort); do
  i=$((i+1))
  R=$(runq "$(cat "$MIG/$f")")
  if isfail "$R"; then echo "MIGFAIL $f:"; echo "$R" | head -c 1500; echo; exit 1; else echo "MIGOK $f"; fi
done
echo "replay done ($i migrations)"

echo "=== INVENTORY ==="
runq "select
  (select count(*) from information_schema.tables where table_schema='public') as tables,
  (select count(*) from pg_tables where schemaname='public' and rowsecurity) as rls_tables,
  (select count(*) from information_schema.columns where table_schema='public' and table_name='notifications' and column_name='recipient_phone') as notif_phone_col,
  (select count(*) from pg_constraint where conrelid='public.notifications'::regclass and conname='notifications_at_least_one_recipient_chk') as notif_chk,
  (select count(*) from information_schema.tables where table_schema='public' and table_name='whatsapp_conversations') as whatsapp_conv_tbl,
  (select count(*) from pg_tables where schemaname='public' and tablename='whatsapp_conversations' and rowsecurity) as whatsapp_conv_rls,
  (select count(*) from information_schema.role_table_grants where grantee='anon' and table_schema='public' and privilege_type in ('INSERT','UPDATE','DELETE','SELECT')) as anon_grants_public,
  (select count(*) from information_schema.role_table_grants where grantee='authenticated' and table_schema='public' and table_name='whatsapp_conversations') as auth_wa_grants;"

echo "=== 10 SUÍTES DE REGRESSÃO ==="
PASS=0; FAIL=0
run_tap() { # $1=name $2=file (pgTAP c/ finish)
  { echo 'begin;'; sed '/select \* from finish()/d' "$TESTS/$2"; cat "$VERDICT"; echo 'rollback;'; } > /tmp/v10_$1.sql
  R=$(runq "$(cat /tmp/v10_$1.sql)")
  failed=$(echo "$R" | jq -r '.[0].failed // empty' 2>/dev/null)
  if [ "$failed" = "0" ]; then echo "PASS $1 (failed=$failed)"; PASS=$((PASS+1)); else echo "FAIL $1 (failed=$failed): $R"; FAIL=$((FAIL+1)); fi
}
run_direct() { # $1=name $2=file (consolida total/passed/failed)
  R=$(runq "$(cat "$TESTS/$2")")
  failed=$(echo "$R" | jq -r '.[0].failed // empty' 2>/dev/null)
  if [ "$failed" = "0" ]; then echo "PASS $1 (failed=$failed)"; PASS=$((PASS+1)); else echo "FAIL $1 (failed=$failed): $R" | head -c 1500; echo; FAIL=$((FAIL+1)); fi
}

run_tap   invariants    test_vio10_invariants.sql
run_tap   rpcs          test_vio10_rpcs.sql
run_direct authz        test_vio10_authz.sql
run_direct auth_lifecycle test_vio10_auth_lifecycle.sql
run_direct creation     test_vio10_creation.sql
run_direct pricing      test_vio10_pricing.sql
run_direct dispatch     test_vio10_dispatch.sql
run_direct bid          test_vio10_bid.sql
run_direct lifecycle    test_vio10_lifecycle.sql
run_direct pod_completo test_vio10_pod_completo.sql

echo "=== RESUMO: $PASS pass, $FAIL fail ==="
[ "$FAIL" = "0" ] && echo "VEREDITO: GO (10/10 + replay 0029 limpo)" || echo "VEREDITO: NO-GO"