#!/usr/bin/env bash
# concurrency_harness.sh — Sessão 10, GATE de produção (ADR-007 / ADR-015).
#
# Valida a atribuição atômica em CONCORRÊNCIA REAL (não simulada): dois backends
# disputando a MESMA corrida em conexões separadas, executando concorrentemente.
# Mecanismo: curls paralelos ao Management API (bash `&` + `wait`). `dblink` está
# bloqueado no dev (role não-superuser; `dblink_connect_u` negado); a senha do banco
# nunca vai para a linha de comando. Ver ADR-015 para o porquê.
#
# Faz: reset + replay 0001→0024 + inventário + 8 suítes de regressão + harness
# (3 races × N runs). Invariante do GATE (ADR-007): ≤1 delivery_assignment ativa por
# delivery_request, exatamente 1 offer 'won', delivery 'assigned', round 'closed'.
#
# Uso:  bash supabase/tests/concurrency_harness.sh [RUNS]   (default RUNS=5)
# Requer: ~/.supabase/vio10_dev_pat (PAT do dev, chmod 600), jq, curl.
# Roda contra o dev rtoyfiqngyicqtuzwfhz — NUNCA produção.
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MIG="$SCRIPT_DIR/../migrations"
TESTS="$SCRIPT_DIR"
SETUP="$SCRIPT_DIR/concurrency_setup.sql"
RUNS=${1:-5}

PAT=$(cat ~/.supabase/vio10_dev_pat)
PROJ=rtoyfiqngyicqtuzwfhz
EP="https://api.supabase.com/v1/projects/$PROJ/database/query"
HDR=(-H "Authorization: Bearer $PAT" -H "Content-Type: application/json" -H "User-Agent: supabase-cli/2.115.0")

# verdict.sql (helper pgTAP — captura num_failed() antes do finish(); ver Sessão 05).
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

# ============================ FASE 1: reset + replay ============================
RESET='drop schema if exists public cascade; drop schema if exists harness cascade; delete from auth.users; create schema public; grant usage,create on schema public to postgres, anon, authenticated, service_role;'
echo "=== RESET ==="
R=$(runq "$RESET"); isfail "$R" && { echo "RESETFAIL: $R"; exit 1; } || echo "RESET OK"

echo "=== REPLAY 0001..0024 ==="
i=0
for f in $(ls "$MIG" | sort); do
  i=$((i+1))
  R=$(runq "$(cat "$MIG/$f")")
  if isfail "$R"; then echo "MIGFAIL $f:"; echo "$R" | head -c 1200; echo; exit 1; else echo "MIGOK $f"; fi
done
echo "replay done ($i migrations)"

echo "=== INVENTORY ==="
runq "select
  (select count(*) from information_schema.tables where table_schema='public') as tables,
  (select count(*) from pg_tables where schemaname='public' and rowsecurity) as rls_tables,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef and p.proname='select_winner_and_claim') as swac_definer,
  (select count(*) from information_schema.role_routine_grants g where g.routine_schema='public' and g.routine_name='select_winner_and_claim' and g.grantee in ('service_role','authenticated')) as swac_exec_grants,
  (select count(*) from information_schema.role_table_grants where grantee='anon' and table_schema='public' and privilege_type in ('INSERT','UPDATE','DELETE','SELECT')) as anon_grants_public;"

# ============================ FASE 2: regressão (8 suítes) ============================
echo "=== REGRESSION: invariants ==="
{ echo 'begin;'; sed '/select \* from finish()/d' "$TESTS/test_vio10_invariants.sql"; cat "$VERDICT"; echo 'rollback;'; } > /tmp/ti10.sql
R=$(runq "$(cat /tmp/ti10.sql)"); echo "$R"
echo "=== REGRESSION: rpcs ==="
{ echo 'begin;'; sed '/select \* from finish()/d' "$TESTS/test_vio10_rpcs.sql"; cat "$VERDICT"; echo 'rollback;'; } > /tmp/tr10.sql
R=$(runq "$(cat /tmp/tr10.sql)"); echo "$R"
echo "=== REGRESSION: authz ===";        R=$(runq "$(cat "$TESTS/test_vio10_authz.sql")"); echo "$R"
echo "=== REGRESSION: auth_lifecycle ==="; R=$(runq "$(cat "$TESTS/test_vio10_auth_lifecycle.sql")"); echo "$R"
echo "=== REGRESSION: creation ===";      R=$(runq "$(cat "$TESTS/test_vio10_creation.sql")"); echo "$R"
echo "=== REGRESSION: pricing ===";       R=$(runq "$(cat "$TESTS/test_vio10_pricing.sql")"); echo "$R"
echo "=== REGRESSION: dispatch ===";      R=$(runq "$(cat "$TESTS/test_vio10_dispatch.sql")"); echo "$R"
echo "=== REGRESSION: bid ===";           R=$(runq "$(cat "$TESTS/test_vio10_bid.sql")"); echo "$R"

# ============================ FASE 3: harness de concorrência real ============================
echo "=== CONCURRENCY SETUP (org + helpers) ==="
R=$(runq "$(cat "$SETUP")"); isfail "$R" && { echo "SETUPFAIL: $R"; exit 1; } || echo "SETUP OK: $R"

# rebuild SQL: cria 3 cenários fresh com tags run-sufixadas (emails únicos) E longitudes
# run-sufixadas. Offset de 1°/run (~111km) >> raio 10km -> isola leftover losers de runs
# anteriores (drivers perdedores ficam active/available sem assignment; sem offset eles
# vazariam para a eligibility de runs posteriores — poluição cross-run, lição Sessão 09).
rebuild_sql() { local run=$1; cat <<SQL
set search_path to public, extensions, pg_catalog;
delete from harness.state where tag in ('A_r${run}','B_r${run}','C_r${run}');
do \$\$
declare v_org uuid; v_biz uuid; b double precision;
begin
  select org_id, biz_id into v_org, v_biz from harness.org where id=1;
  b := 100.0 + ${run};  -- base A por run
  insert into harness.state(tag, ids) values
    ('A_r${run}', harness.mk_scenario('A_r${run}', v_org, v_biz, b,       b+0.001, b+0.002)),
    ('B_r${run}', harness.mk_scenario('B_r${run}', v_org, v_biz, b+100.0, b+100.001, b+100.002)),
    ('C_r${run}', harness.mk_scenario('C_r${run}', v_org, v_biz, b+200.0, b+200.001, b+200.002));
end \$\$;
select count(*) as scenarios from harness.state where tag in ('A_r${run}','B_r${run}','C_r${run}');
SQL
}

# SQL por side (lê IDs de harness.state pelo tag).
claim_sql() { echo "select t.won, t.reason from public.claim_delivery(
  (select (ids->>'delivery_id')::uuid from harness.state where tag='$1'),
  (select (ids->>'driver$2_id')::uuid from harness.state where tag='$1'),
  (select (ids->>'round_id')::uuid from harness.state where tag='$1'),
  (select (ids->>'offer$3_id')::uuid from harness.state where tag='$1'), null) as t;"; }
swac_sql() { echo "select t.ok, t.reason from public.select_winner_and_claim(
  (select (ids->>'round_id')::uuid from harness.state where tag='$1'), 1.0, 1.0, 300) as t;"; }

# assert SQL: lê estado do banco (autoridade) por cenário.
assert_sql() { local run=$1; cat <<SQL
set search_path to public, extensions, pg_catalog;
with s as (select tag, ids from harness.state where tag in ('A_r${run}','B_r${run}','C_r${run}')),
inv as (
 select s.tag,
   (select count(*) from public.delivery_assignments a where a.delivery_request_id=(s.ids->>'delivery_id')::uuid and a.status='active') as n_assign,
   (select count(*) from public.delivery_offers o where o.dispatch_round_id=(s.ids->>'round_id')::uuid and o.status='won') as n_won,
   (select count(*) from public.delivery_offers o where o.dispatch_round_id=(s.ids->>'round_id')::uuid and o.status='lost') as n_lost,
   (select status::text from public.delivery_requests where id=(s.ids->>'delivery_id')::uuid) as del_status,
   (select status::text from public.dispatch_rounds where id=(s.ids->>'round_id')::uuid) as round_status,
   (select (closed_at is not null)::int from public.dispatch_rounds where id=(s.ids->>'round_id')::uuid) as closed_at_set
 from s)
select tag, n_assign, n_won, n_lost, del_status, round_status, closed_at_set,
  (n_assign=1 and n_won=1 and n_lost=1 and del_status='assigned' and round_status='closed' and closed_at_set=1) as invariant_ok
from inv order by tag;
SQL
}

# parser: extrai "<won|ok>|<reason>" do .out; trata erro/deadlock.
# (jq `//` trata false como no-value, por isso usamos has() — won=false deve virar "false".)
side_result() { local f=$1
  if [ ! -s "$f" ]; then echo "EMPTY|"; return; fi
  if jq -e 'type=="array"' "$f" >/dev/null 2>&1; then
    jq -r '.[0] as $r | if ($r|has("won")) then $r.won|tostring
           elif ($r|has("ok")) then $r.ok|tostring else "N/A" end
           + "|" + ($r.reason // "")' "$f" 2>/dev/null
  else
    echo "ERR|"$(jq -r '.message // "unknown"' "$f" 2>/dev/null | head -c 70)
  fi
}

OVERALL_PASS=1
for run in $(seq 1 "$RUNS"); do
  echo "=== RACE run $run/$RUNS ==="
  R=$(runq "$(rebuild_sql "$run")"); isfail "$R" && { echo "REBUILDFAIL run$run: $R"; OVERALL_PASS=0; continue; }
  echo "rebuild: $R"

  # --- Test A: 2 claim_delivery paralelos (mesma delivery, offers diferentes) ---
  A1=/tmp/conc_A1_${run}.out; A2=/tmp/conc_A2_${run}.out
  runq "$(claim_sql A_r${run} 1 1)" > "$A1" 2>&1 & pA1=$!
  runq "$(claim_sql A_r${run} 2 2)" > "$A2" 2>&1 & pA2=$!
  wait $pA1; wait $pA2
  a1r=$(side_result "$A1"); a2r=$(side_result "$A2")
  echo "  A side1: $a1r | side2: $a2r"

  # --- Test B: 2 select_winner_and_claim paralelos (mesmo round) ---
  B1=/tmp/conc_B1_${run}.out; B2=/tmp/conc_B2_${run}.out
  runq "$(swac_sql B_r${run})" > "$B1" 2>&1 & pB1=$!
  runq "$(swac_sql B_r${run})" > "$B2" 2>&1 & pB2=$!
  wait $pB1; wait $pB2
  b1r=$(side_result "$B1"); b2r=$(side_result "$B2")
  echo "  B side1: $b1r | side2: $b2r"

  # --- Test C: SWAC vs claim_delivery direto (mesma delivery/round) ---
  # Race de lock-ordering divergente (ADR-015 D4): PODE dar deadlock (40P01) — Postgres
  # aborta um, o invariante sobrevive. Por isso o veredito do C é só DB-state (RPC não-determinístico).
  C1=/tmp/conc_C1_${run}.out; C2=/tmp/conc_C2_${run}.out
  runq "$(swac_sql C_r${run})" > "$C1" 2>&1 & pC1=$!
  runq "$(claim_sql C_r${run} 2 2)" > "$C2" 2>&1 & pC2=$!
  wait $pC1; wait $pC2
  c1r=$(side_result "$C1"); c2r=$(side_result "$C2")
  echo "  C side1(SWAC): $c1r | side2(claim): $c2r"

  # --- Assert DB-state ---
  R=$(runq "$(assert_sql "$run")")
  echo "  DB invariants: $R"

  # --- Veredito por run ---
  # A: exatamente 1 won=true entre os 2 lados; 1 false (não ERR).
  a_won_true=$(printf '%s\n%s\n' "$a1r" "$a2r" | grep -c '^true|')
  a_has_false=$(printf '%s\n%s\n' "$a1r" "$a2r" | grep -c '^false|')
  a_ok=$( [ "$a_won_true" = 1 ] && [ "$a_has_false" = 1 ] && echo 1 || echo 0 )
  # B: exatamente 1 ok=true+won, 1 ok=false+round_not_open.
  b_won=$(printf '%s\n%s\n' "$b1r" "$b2r" | grep -c '^true|won$')
  b_lost=$(printf '%s\n%s\n' "$b1r" "$b2r" | grep -c '^false|round_not_open$')
  b_ok=$( [ "$b_won" = 1 ] && [ "$b_lost" = 1 ] && echo 1 || echo 0 )
  # C: DB invariant only (RPC pode ser ERR/deadlock — não-determinístico).
  db_ok=$(echo "$R" | jq 'map(select(.invariant_ok==true))|length' 2>/dev/null)
  c_ok=$( [ "$db_ok" = 3 ] && echo 1 || echo 0 )

  echo "  verdict run$run: A=$a_ok B=$b_ok C_db=$c_ok (db_invariants_ok=$db_ok/3)"
  [ "$a_ok" = 1 ] || OVERALL_PASS=0
  [ "$b_ok" = 1 ] || OVERALL_PASS=0
  [ "$c_ok" = 1 ] || OVERALL_PASS=0
done

echo "=========================="
if [ "$OVERALL_PASS" = 1 ]; then
  echo "GATE VERDICT: PASS — atribuição atômica sustentada em $RUNS execuções reais paralelas (Test A/B/C invariante ≤1 assignment ativa)."
else
  echo "GATE VERDICT: FAIL — invariante violado em alguma run (ver acima)."
fi
echo "=========================="