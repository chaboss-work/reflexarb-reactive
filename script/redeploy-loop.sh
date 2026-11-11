#!/usr/bin/env bash
# Replaces only the reactive contract (Lasna) and the executor (Base Sepolia), keeping the tokens and
# pools from deployments/latest.json. The previous deployment is kept as deployments/<timestamp>.json.
# Needs: PK, ME, BASE_SEPOLIA_RPC, LASNA_RPC (see .secrets/env.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

CALLBACK_PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585   # Base Sepolia callback proxy (Reactive docs)
ORIGIN_CHAIN=84532
THRESHOLD_BPS=${THRESHOLD_BPS:-80}
COOLDOWN_SEC=${COOLDOWN_SEC:-0}
RC_FUNDING=${RC_FUNDING:-0.6ether}
EXECUTOR_FUNDING=${EXECUTOR_FUNDING:-0.003ether}

j() { python -c "import json,sys; print(json.load(open('deployments/latest.json'))['$1'])"; }
T0=$(j token0); T1=$(j token1); POOL_A=$(j poolA); POOL_B=$(j poolB)
OLD_RC=$(j reactive); OLD_EX=$(j executor)
echo "reusing T0=$T0 T1=$T1 POOL_A=$POOL_A POOL_B=$POOL_B"

create() { # rpc contract args... ; prints deployed address
  local rpc=$1; shift
  forge create --broadcast --rpc-url "$rpc" --private-key "$PK" "$@" 2>&1 | awk '/Deployed to:/ {print $3}'
}
send() { cast send --rpc-url "$1" --private-key "$PK" "${@:2}" >/dev/null; }

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
cp deployments/latest.json "deployments/$STAMP.json"

echo "== Reactive Lasna: new reactive contract"
RC=$(create "$LASNA_RPC" src/ReflexArbReactive.sol:ReflexArbReactive --value "$RC_FUNDING" \
  --constructor-args "$ORIGIN_CHAIN" "$POOL_A" "$POOL_B" "$THRESHOLD_BPS" "$COOLDOWN_SEC")
[ -n "$RC" ] || { echo "reactive deploy failed"; exit 1; }
echo "RC=$RC"

echo "== Base Sepolia: new executor"
EX=$(create "$BASE_SEPOLIA_RPC" src/ReflexArbExecutor.sol:ReflexArbExecutor --value "$EXECUTOR_FUNDING" \
  --constructor-args "$CALLBACK_PROXY" "$RC" "$POOL_A" "$POOL_B")
[ -n "$EX" ] || { echo "executor deploy failed"; exit 1; }
send "$BASE_SEPOLIA_RPC" "$T1" "mint(address,uint256)" "$EX" 100000ether
echo "EX=$EX"

echo "== Lasna: point the reactive contract at the executor"
send "$LASNA_RPC" "$RC" "configure(address,uint256,uint256)" "$EX" "$THRESHOLD_BPS" "$COOLDOWN_SEC"

echo "== Base Sepolia: poke both pools so the new reactive contract learns their reserves"
sleep 5
send "$BASE_SEPOLIA_RPC" "$POOL_A" "addLiquidity(uint256,uint256)" 0 0
send "$BASE_SEPOLIA_RPC" "$POOL_B" "addLiquidity(uint256,uint256)" 0 0

cat > deployments/latest.json <<JSON
{
  "originChainId": $ORIGIN_CHAIN,
  "reactiveChainId": 5318007,
  "callbackProxy": "$CALLBACK_PROXY",
  "token0": "$T0",
  "token1": "$T1",
  "poolA": "$POOL_A",
  "poolB": "$POOL_B",
  "executor": "$EX",
  "reactive": "$RC",
  "thresholdBps": $THRESHOLD_BPS,
  "cooldownSec": $COOLDOWN_SEC,
  "deployer": "$ME",
  "previous": {"reactive": "$OLD_RC", "executor": "$OLD_EX", "file": "deployments/$STAMP.json"}
}
JSON
cat deployments/latest.json
