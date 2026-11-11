#!/usr/bin/env bash
# Deploys ReflexArb: two pools + executor on Base Sepolia, reactive contract on Reactive Lasna.
# Needs: PK (deployer key), ME (its address), BASE_SEPOLIA_RPC, LASNA_RPC. Writes deployments/latest.json.
set -euo pipefail
cd "$(dirname "$0")/.."

CALLBACK_PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585   # Base Sepolia callback proxy (Reactive docs)
ORIGIN_CHAIN=84532
THRESHOLD_BPS=${THRESHOLD_BPS:-80}
RC_FUNDING=${RC_FUNDING:-0.4ether}       # lREACT for reactive transactions and callbacks
EXECUTOR_FUNDING=${EXECUTOR_FUNDING:-0.002ether}  # Base Sepolia ETH for callback gas

create() { # chain-rpc contract args... ; prints deployed address
  local rpc=$1; shift
  forge create --broadcast --rpc-url "$rpc" --private-key "$PK" "$@" 2>&1 | awk '/Deployed to:/ {print $3}'
}
send() { cast send --rpc-url "$1" --private-key "$PK" "${@:2}" >/dev/null; }

echo "== Base Sepolia: tokens and pools"
T0=$(create "$BASE_SEPOLIA_RPC" src/MiniToken.sol:MiniToken --constructor-args "Reflex Token Zero" "RX0")
T1=$(create "$BASE_SEPOLIA_RPC" src/MiniToken.sol:MiniToken --constructor-args "Reflex USD" "RXUSD")
POOL_A=$(create "$BASE_SEPOLIA_RPC" src/MiniPool.sol:MiniPool --constructor-args "$T0" "$T1")
POOL_B=$(create "$BASE_SEPOLIA_RPC" src/MiniPool.sol:MiniPool --constructor-args "$T0" "$T1")
echo "T0=$T0 T1=$T1 POOL_A=$POOL_A POOL_B=$POOL_B"

send "$BASE_SEPOLIA_RPC" "$T0" "mint(address,uint256)" "$ME" 100000ether
send "$BASE_SEPOLIA_RPC" "$T1" "mint(address,uint256)" "$ME" 1000000ether
for P in "$POOL_A" "$POOL_B"; do
  send "$BASE_SEPOLIA_RPC" "$T0" "approve(address,uint256)" "$P" "$(cast max-uint)"
  send "$BASE_SEPOLIA_RPC" "$T1" "approve(address,uint256)" "$P" "$(cast max-uint)"
  send "$BASE_SEPOLIA_RPC" "$P" "addLiquidity(uint256,uint256)" 10000ether 30000ether
done

echo "== Reactive Lasna: reactive contract"
RC=$(create "$LASNA_RPC" src/ReflexArbReactive.sol:ReflexArbReactive --value "$RC_FUNDING" \
  --constructor-args "$ORIGIN_CHAIN" "$POOL_A" "$POOL_B" "$THRESHOLD_BPS" 0)
echo "RC=$RC"

echo "== Base Sepolia: executor (callback contract)"
EX=$(create "$BASE_SEPOLIA_RPC" src/ReflexArbExecutor.sol:ReflexArbExecutor --value "$EXECUTOR_FUNDING" \
  --constructor-args "$CALLBACK_PROXY" "$RC" "$POOL_A" "$POOL_B")
send "$BASE_SEPOLIA_RPC" "$T1" "mint(address,uint256)" "$EX" 100000ether
echo "EX=$EX"

echo "== Reactive Lasna: point the reactive contract at the executor"
send "$LASNA_RPC" "$RC" "configure(address,uint256,uint256)" "$EX" "$THRESHOLD_BPS" 0

echo "== Base Sepolia: poke both pools so the reactive contract learns their current reserves"
# Liquidity was added before the subscription existed; an empty addLiquidity emits a fresh Sync.
sleep 5
send "$BASE_SEPOLIA_RPC" "$POOL_A" "addLiquidity(uint256,uint256)" 0 0
send "$BASE_SEPOLIA_RPC" "$POOL_B" "addLiquidity(uint256,uint256)" 0 0

mkdir -p deployments
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
  "deployer": "$ME"
}
JSON
cat deployments/latest.json
