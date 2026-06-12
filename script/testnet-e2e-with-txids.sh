#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source .env

NETWORK="${1:-base-sepolia}"
REACTIVE_WAIT_SECONDS="${REACTIVE_WAIT_SECONDS:-180}"
REACTIVE_POLL_SECONDS="${REACTIVE_POLL_SECONDS:-8}"
CALLBACK_WAIT_SECONDS="${CALLBACK_WAIT_SECONDS:-240}"
CALLBACK_POLL_SECONDS="${CALLBACK_POLL_SECONDS:-8}"
REQUIRE_LIVE_REACTIVE="${REQUIRE_LIVE_REACTIVE:-1}"
DEMO_MINT="${DEMO_MINT:-1}"

lower() {
  tr '[:upper:]' '[:lower:]' <<<"$1"
}

hex_quantity() {
  local value="$1"
  if [[ "$value" == 0x* ]]; then
    echo "$value"
  else
    printf '0x%x' "$value"
  fi
}

first_word() {
  awk '{print $1}' <<<"$1"
}

case "$NETWORK" in
  base-sepolia)
    DESTINATION_RPC_URL="$BASE_SEPOLIA_RPC_URL"
    DESTINATION_CHAIN_ID=84532
    EXPLORER="https://sepolia.basescan.org/tx/"
    CALLBACK_PROXY="${BASE_SEPOLIA_CALLBACK_PROXY:?BASE_SEPOLIA_CALLBACK_PROXY is required}"
    TOKEN0="${TOKEN0:-${FEECOMPOUNDER_BASE_SEPOLIA_TOKEN0:-}}"
    TOKEN1="${TOKEN1:-${FEECOMPOUNDER_BASE_SEPOLIA_TOKEN1:-}}"
    HOOK_ADDRESS="${HOOK_ADDRESS:-${FEECOMPOUNDER_BASE_SEPOLIA_HOOK:-}}"
    AAVE_ADAPTER="${AAVE_ADAPTER:-${FEECOMPOUNDER_BASE_SEPOLIA_AAVE_ADAPTER:-}}"
    MORPHO_ADAPTER="${MORPHO_ADAPTER:-${FEECOMPOUNDER_BASE_SEPOLIA_MORPHO_ADAPTER:-}}"
    POOL_REINVEST_ADAPTER="${POOL_REINVEST_ADAPTER:-${FEECOMPOUNDER_BASE_SEPOLIA_POOL_REINVEST_ADAPTER:-}}"
    RSC_ADDRESS="${RSC_ADDRESS:-${FEECOMPOUNDER_BASE_SEPOLIA_RSC:-}}"
    ;;
  sepolia)
    DESTINATION_RPC_URL="$ETH_SEPOLIA_RPC_URL"
    DESTINATION_CHAIN_ID=11155111
    EXPLORER="https://sepolia.etherscan.io/tx/"
    CALLBACK_PROXY="${SEPOLIA_CALLBACK_PROXY:?SEPOLIA_CALLBACK_PROXY is required}"
    ;;
  unichain-sepolia)
    DESTINATION_RPC_URL="$UNICHAIN_SEPOLIA_RPC_URL"
    DESTINATION_CHAIN_ID=1301
    EXPLORER="https://sepolia.uniscan.xyz/tx/"
    CALLBACK_PROXY="${UNICHAIN_SEPOLIA_CALLBACK_PROXY:?UNICHAIN_SEPOLIA_CALLBACK_PROXY is required}"
    TOKEN0="${TOKEN0:-${FEECOMPOUNDER_UNICHAIN_SEPOLIA_TOKEN0:-}}"
    TOKEN1="${TOKEN1:-${FEECOMPOUNDER_UNICHAIN_SEPOLIA_TOKEN1:-}}"
    HOOK_ADDRESS="${HOOK_ADDRESS:-${FEECOMPOUNDER_UNICHAIN_SEPOLIA_HOOK:-}}"
    AAVE_ADAPTER="${AAVE_ADAPTER:-${FEECOMPOUNDER_UNICHAIN_SEPOLIA_AAVE_ADAPTER:-}}"
    MORPHO_ADAPTER="${MORPHO_ADAPTER:-${FEECOMPOUNDER_UNICHAIN_SEPOLIA_MORPHO_ADAPTER:-}}"
    POOL_REINVEST_ADAPTER="${POOL_REINVEST_ADAPTER:-${FEECOMPOUNDER_UNICHAIN_SEPOLIA_POOL_REINVEST_ADAPTER:-}}"
    RSC_ADDRESS="${RSC_ADDRESS:-${FEECOMPOUNDER_UNICHAIN_SEPOLIA_RSC:-}}"
    ;;
  *)
    echo "Unknown network: $NETWORK" >&2
    exit 1
    ;;
esac

PRIVATE_KEY="${PRIVATE_KEY:?PRIVATE_KEY is required}"
REACTIVE_RPC_URL="${REACTIVE_RPC_URL:?REACTIVE_RPC_URL is required}"
RVM_ID="${RVM_ID:-$(cast wallet address --private-key "$PRIVATE_KEY")}"
ACTOR="$(cast wallet address --private-key "$PRIVATE_KEY")"
POOL_FEE="${POOL_FEE:-${FEECOMPOUNDER_POOL_FEE:-3000}}"
TICK_SPACING="${TICK_SPACING:-${FEECOMPOUNDER_TICK_SPACING:-60}}"
RAW_FEE0="${RAW_FEE0:-20000000000000000000}"
RAW_FEE1="${RAW_FEE1:-10000000000000000000}"
CALLBACK_GAS_LIMIT="${CALLBACK_GAS_LIMIT:-1500000}"

for required in DESTINATION_RPC_URL HOOK_ADDRESS RSC_ADDRESS TOKEN0 TOKEN1 AAVE_ADAPTER MORPHO_ADAPTER POOL_REINVEST_ADAPTER; do
  if [[ -z "${!required:-}" ]]; then
    echo "Missing $required for $NETWORK. Deploy first or set it in .env." >&2
    exit 1
  fi
done

rnk_call() {
  local method="$1"
  local params="$2"
  curl -sS "$REACTIVE_RPC_URL" \
    -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}"
}

send_dest() {
  local label="$1"
  shift
  local output tx status attempt
  echo
  echo "== $label =="
  for attempt in 1 2 3; do
    set +e
    output="$(cast send "$@" --rpc-url "$DESTINATION_RPC_URL" --private-key "$PRIVATE_KEY" 2>&1)"
    status=$?
    set -e
    printf '%s\n' "$output" >&2
    if [[ "$status" == "0" ]]; then
      break
    fi
    if grep -Eqi "nonce too low|replacement transaction underpriced|already known" <<<"$output" && [[ "$attempt" != "3" ]]; then
      echo "Retrying $label after pending-nonce response..."
      sleep 15
      continue
    fi
    return "$status"
  done
  tx="$(grep -Eo '0x[a-fA-F0-9]{64}' <<<"$output" | tail -1)"
  echo "$label txid: $tx"
  echo "$label url: ${EXPLORER}${tx}"
  LAST_TX="$tx"
}

send_reactive() {
  local label="$1"
  shift
  local output tx status attempt
  echo
  echo "== $label =="
  for attempt in 1 2 3; do
    set +e
    output="$(cast send "$@" --rpc-url "$REACTIVE_RPC_URL" --private-key "$PRIVATE_KEY" --legacy 2>&1)"
    status=$?
    set -e
    printf '%s\n' "$output" >&2
    if [[ "$status" == "0" ]]; then
      break
    fi
    if grep -Eqi "nonce too low|replacement transaction underpriced|already known" <<<"$output" && [[ "$attempt" != "3" ]]; then
      echo "Retrying $label after pending-nonce response..."
      sleep 15
      continue
    fi
    return "$status"
  done
  tx="$(grep -Eo '0x[a-fA-F0-9]{64}' <<<"$output" | tail -1)"
  echo "$label txid: $tx"
  echo "$label url: https://lasna.reactscan.net/tx/$tx"
  LAST_TX="$tx"
}

verify_rnk_filter() {
  local topic="$1"
  local filters
  filters="$(
    rnk_call "rnk_getFilters" "[]" \
      | jq --arg chain "$DESTINATION_CHAIN_ID" \
        --arg hook "$(lower "$HOOK_ADDRESS")" \
        --arg rsc "$(lower "$RSC_ADDRESS")" \
        --arg topic "$(lower "$topic")" '
          (if (.result | type) == "object" then .result.TopicFilters else .result end)[]?
          | select((.ChainId | tostring) == $chain)
          | select(((.Contract // "") | ascii_downcase) == $hook)
          | select(((.Topics[0] // "") | ascii_downcase) == $topic)
          | . as $filter
          | $filter.Configs[]
          | select((.Contract | ascii_downcase) == $rsc)
          | select(.Active == true)
          | {
              chainId: $filter.ChainId,
              hook: $filter.Contract,
              topic0: $filter.Topics[0],
              reactiveContract: .Contract,
              rvmId: .RvmId,
              active: .Active
            }
        '
  )"

  if [[ -z "$filters" ]]; then
    return 1
  fi

  RVM_ID="$(jq -r '.rvmId' <<<"$filters" | head -n 1)"
  echo "$filters" | jq -r '
    "  chainId: " + (.chainId | tostring)
    + "\n  hook: " + .hook
    + "\n  topic0: " + .topic0
    + "\n  reactive contract: " + .reactiveContract
    + "\n  rvmId: " + .rvmId
    + "\n  active: " + (.active | tostring)
  '
}

wait_for_rvm_tx() {
  local ref_tx="$1"
  local deadline tx txs vm_info last_number start_number rvm_tx_number logs callback_topic
  callback_topic="$(cast sig-event 'Callback(uint256,address,uint64,bytes)')"
  deadline=$((SECONDS + REACTIVE_WAIT_SECONDS))

  echo
  echo "Waiting for ReactVM transaction for FeesAccrued tx $ref_tx..."
  while ((SECONDS <= deadline)); do
    vm_info="$(rnk_call "rnk_getVm" "[\"$RVM_ID\"]")"
    last_number="$(jq -r '.result.lastTxNumber // "0x0"' <<<"$vm_info")"
    start_number="$(printf '0x%x' "$((16#${last_number#0x} > 96 ? 16#${last_number#0x} - 96 : 0))")"
    txs="$(
      rnk_call "rnk_getTransactions" "[\"$RVM_ID\",\"$start_number\",\"0x80\"]" \
        | jq -c --arg ref "$(lower "$ref_tx")" '
          .result
          | reverse[]?
          | select(((.refTx // "") | ascii_downcase) == $ref)
        '
    )"

    while IFS= read -r tx; do
      [[ -z "$tx" ]] && continue
      RVM_TX_HASH="$(jq -r '.hash' <<<"$tx")"
      rvm_tx_number="$(jq -r '.number' <<<"$tx")"
      logs="$(rnk_call "rnk_getTransactionLogs" "[\"$RVM_ID\",\"$rvm_tx_number\"]")"
      echo "$tx" | jq -r --arg url "https://lasna.reactscan.net/tx/$RVM_TX_HASH" '
        "  RVM transaction"
        + "\n    rvm tx hash: " + .hash
        + "\n    rvm tx url: " + $url
        + "\n    rvm tx number: " + .number
        + "\n    status: " + (.status | tostring)
        + "\n    ref chain: " + (.refChainId | tostring)
        + "\n    ref tx: " + .refTx
      '
      echo "  RVM logs"
      echo "$logs" | jq -r '.result[]? | "    address: " + .address + "\n    topic0: " + .topics[0] + "\n    txHash: " + .txHash'
      if jq -e --arg topic "$(lower "$callback_topic")" \
        '.result[]? | select((.topics[0] | ascii_downcase) == $topic)' <<<"$logs" >/dev/null; then
        echo "  Callback event found in RVM logs."
        return 0
      fi
      echo "  RVM tx did not emit Callback; continuing to poll for a callback-emitting RVM tx..."
    done <<<"$txs"

    sleep "$REACTIVE_POLL_SECONDS"
  done

  echo "No ReactVM transaction found within ${REACTIVE_WAIT_SECONDS}s for $ref_tx." >&2
  [[ "$REQUIRE_LIVE_REACTIVE" == "1" ]] && return 1
  return 0
}

wait_for_compound_callback() {
  local from_block="$1"
  local topic logs deadline latest scan_from scan_to
  topic="$(cast sig-event 'CompoundExecuted(bytes32,address,uint256,uint256,uint256,uint256,uint256)')"
  deadline=$((SECONDS + CALLBACK_WAIT_SECONDS))
  scan_from=$((from_block))

  echo
  echo "Waiting for destination Reactive callback / CompoundExecuted..."
  while ((SECONDS <= deadline)); do
    latest="$(cast block-number --rpc-url "$DESTINATION_RPC_URL")"
    while ((scan_from <= latest)); do
      scan_to=$((scan_from + 9))
      if ((scan_to > latest)); then
        scan_to="$latest"
      fi
      logs="$(
        cast rpc --rpc-url "$DESTINATION_RPC_URL" eth_getLogs \
          "{\"fromBlock\":\"$(hex_quantity "$scan_from")\",\"toBlock\":\"$(hex_quantity "$scan_to")\",\"address\":\"$HOOK_ADDRESS\",\"topics\":[\"$topic\",\"$POOL_ID\"]}" \
          2>/dev/null || echo "[]"
      )"

      if [[ "$(jq 'length' <<<"$logs")" != "0" ]]; then
        CALLBACK_TX_HASH="$(jq -r '.[-1].transactionHash' <<<"$logs")"
        jq -r --arg url "${EXPLORER}${CALLBACK_TX_HASH}" '
          .[-1]
          | "  Reactive destination callback / CompoundExecuted"
            + "\n    destination txid: " + .transactionHash
            + "\n    destination url: " + $url
            + "\n    block: " + .blockNumber
            + "\n    poolId topic: " + .topics[1]
            + "\n    route topic: " + .topics[2]
        ' <<<"$logs"
        return 0
      fi
      scan_from=$((scan_to + 1))
    done

    sleep "$CALLBACK_POLL_SECONDS"
  done

  echo "No CompoundExecuted callback found within ${CALLBACK_WAIT_SECONDS}s." >&2
  [[ "$REQUIRE_LIVE_REACTIVE" == "1" ]] && return 1
  return 0
}

echo "FeeCompounder live Reactive E2E"
echo "Network: $NETWORK"
echo "Hook: $HOOK_ADDRESS"
echo "RSC: $RSC_ADDRESS"
echo "Callback proxy: $CALLBACK_PROXY"
echo "RVM sender: $RVM_ID"
echo "Token0: $TOKEN0"
echo "Token1: $TOKEN1"
echo
echo "Demo story"
echo "  User perspective: an LP deposits demo inventory into the FeeCompounder hook and receives shares."
echo "  Market perspective: swaps/fee activity report backed fees into the hook, creating idle fee inventory."
echo "  Reactive perspective: Lasna observes the FeesAccrued event, evaluates gates, picks the best route, and emits a callback."
echo "  Destination perspective: the callback proxy calls the hook, the hook authenticates proxy + RVM sender, and fees compound into the chosen route."

echo
echo "Phase 0: Build and test locally"
echo "  This proves the local unit/fuzz suite before spending testnet gas."
forge test

POOL_KEY="($TOKEN0,$TOKEN1,$POOL_FEE,$TICK_SPACING,$HOOK_ADDRESS)"
POOL_ID="$(cast call "$HOOK_ADDRESS" 'poolId((address,address,uint24,int24,address))(bytes32)' "$POOL_KEY" --rpc-url "$DESTINATION_RPC_URL")"
echo
echo "Phase 1: Derived real pool identity"
echo "  The pool key is the canonical identity the hook and RSC must agree on."
echo "Pool key: $POOL_KEY"
echo "Pool ID:  $POOL_ID"

echo
echo "Phase 2: Wire destination hook callback auth"
echo "  The hook must trust the destination callback proxy and the explicit RVM sender encoded by the RSC."
current_proxy="$(cast call "$HOOK_ADDRESS" 'callbackProxy()(address)' --rpc-url "$DESTINATION_RPC_URL")"
current_sender="$(cast call "$HOOK_ADDRESS" 'reactiveSender()(address)' --rpc-url "$DESTINATION_RPC_URL")"
if [[ "$(lower "$current_proxy")" != "$(lower "$CALLBACK_PROXY")" || "$(lower "$current_sender")" != "$(lower "$RVM_ID")" ]]; then
  send_dest "Set hook Reactive auth" "$HOOK_ADDRESS" \
    'setReactiveAuth(address,address,address)' "$CALLBACK_PROXY" "$RVM_ID" "$ACTOR"
else
  echo "Hook Reactive auth already wired."
fi

echo
echo "Phase 3: Wire Lasna RSC pool, routes, decision gates, and subscription"
echo "  The RSC receives the same pool key, route adapters, APY preferences, and demo-friendly gates."
if [[ "${SKIP_RSC_CONFIG:-0}" == "1" ]]; then
  echo "Skipping RSC config because SKIP_RSC_CONFIG=1."
else
  send_reactive "Configure RSC pool" "$RSC_ADDRESS" \
    'configurePool(bytes32,(address,address,uint24,int24,address))' "$POOL_ID" "$POOL_KEY"
  send_reactive "Configure RSC routes" "$RSC_ADDRESS" \
    'configureRoutes(address,address,address)' "$AAVE_ADAPTER" "$MORPHO_ADAPTER" "$POOL_REINVEST_ADAPTER"
  send_reactive "Configure RSC APYs" "$RSC_ADDRESS" \
    'updateAPYs(uint256,uint256,uint256)' "${AAVE_APY_BPS:-550}" "${MORPHO_APY_BPS:-900}" "${POOL_APY_BPS:-400}"
  send_reactive "Configure RSC demo gates" "$RSC_ADDRESS" \
    'setDecisionConfig(uint256,uint256,uint256)' "${MIN_THRESHOLD:-1}" "${GAS_CEILING:-1000000000000000}" "${COOLDOWN_BLOCKS:-0}"
fi

fees_topic="$(cast sig-event 'FeesAccrued(bytes32,uint256,uint256,uint256,uint256,uint256,uint256)')"
echo
echo "RNK filter proof"
echo "  This proves Lasna is actively subscribed to FeesAccrued from this exact hook/topic/chain."
if ! verify_rnk_filter "$fees_topic"; then
  echo "No active RNK filter found. Calling configureSubscription() once..."
  send_reactive "Configure Lasna subscription" "$RSC_ADDRESS" 'configureSubscription()'
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if verify_rnk_filter "$fees_topic"; then
      break
    fi
    if [[ "$attempt" == "10" ]]; then
      echo "RNK filter did not become visible after configureSubscription()." >&2
      exit 1
    fi
    echo "Waiting for RNK filter indexing..."
    sleep 6
  done
fi

echo
echo "Phase 4: Callback payment check"
echo "  A Reactive callback can be queued but not delivered if callback debt is unpaid, so we prove debt is zero."
debt="$(first_word "$(cast call "$HOOK_ADDRESS" 'callbackDebt()(uint256)' --rpc-url "$DESTINATION_RPC_URL")")"
hook_balance="$(cast balance "$HOOK_ADDRESS" --rpc-url "$DESTINATION_RPC_URL")"
echo "Callback debt: $debt"
echo "Hook native balance: $hook_balance"
if [[ "$debt" != "0" ]]; then
  send_dest "Fund hook for callback debt" "$HOOK_ADDRESS" --value "${CALLBACK_DEBT_TOPUP:-0.001ether}"
  send_dest "Cover callback debt" "$HOOK_ADDRESS" 'coverCallbackDebt()'
fi

echo
echo "Phase 5: Prepare demo balances and LP shares"
echo "  The LP receives/mints demo assets, approves the hook, and deposits so shares exist before compounding."
if [[ "$DEMO_MINT" == "1" ]]; then
  send_dest "Mint demo token0" "$TOKEN0" 'mint(address,uint256)' "$ACTOR" "${DEMO_MINT_AMOUNT:-200000000000000000000}"
  send_dest "Mint demo token1" "$TOKEN1" 'mint(address,uint256)' "$ACTOR" "${DEMO_MINT_AMOUNT:-200000000000000000000}"
fi
MAX_UINT=115792089237316195423570985008687907853269984665640564039457584007913129639935
allowance0="$(first_word "$(cast call "$TOKEN0" 'allowance(address,address)(uint256)' "$ACTOR" "$HOOK_ADDRESS" --rpc-url "$DESTINATION_RPC_URL")")"
allowance1="$(first_word "$(cast call "$TOKEN1" 'allowance(address,address)(uint256)' "$ACTOR" "$HOOK_ADDRESS" --rpc-url "$DESTINATION_RPC_URL")")"
if [[ "$allowance0" == "$MAX_UINT" ]]; then
  echo "Token0 allowance already maxed."
else
  send_dest "Approve token0 to hook" "$TOKEN0" 'approve(address,uint256)' "$HOOK_ADDRESS" "$MAX_UINT"
fi
if [[ "$allowance1" == "$MAX_UINT" ]]; then
  echo "Token1 allowance already maxed."
else
  send_dest "Approve token1 to hook" "$TOKEN1" 'approve(address,uint256)' "$HOOK_ADDRESS" "$MAX_UINT"
fi

shares="$(first_word "$(cast call "$HOOK_ADDRESS" 'lpShares(bytes32,address)(uint256)' "$POOL_ID" "$ACTOR" --rpc-url "$DESTINATION_RPC_URL")")"
if [[ "$shares" == "0" ]]; then
  send_dest "LP deposit for demo accounting" "$HOOK_ADDRESS" \
    'depositForDemo((address,address,uint24,int24,address),uint256,uint256,address)' "$POOL_KEY" \
    "${DEMO_DEPOSIT0:-50000000000000000000}" "${DEMO_DEPOSIT1:-50000000000000000000}" "$ACTOR"
else
  echo "LP already has shares: $shares"
fi

echo
echo "Phase 6: Emit backed FeesAccrued boundary event"
echo "  This simulates swap fees landing in the hook; the tx is the origin-chain proof Reactive must observe."
send_dest "FeesAccrued boundary event" "$HOOK_ADDRESS" \
  'reportFees((address,address,uint24,int24,address),uint256,uint256)' "$POOL_KEY" "$RAW_FEE0" "$RAW_FEE1"
FEES_TX_HASH="$LAST_TX"
FEES_BLOCK="$(jq -r '.blockNumber' <<<"$(cast receipt "$FEES_TX_HASH" --rpc-url "$DESTINATION_RPC_URL" --json)")"
echo "FeesAccrued tx URL: ${EXPLORER}${FEES_TX_HASH}"
echo "FeesAccrued block: $FEES_BLOCK"

echo
echo "Phase 7: Prove Reactive handled the origin event"
echo "  We poll RNK near the RVM tail and require a Lasna transaction that references the origin tx and emits Callback."
wait_for_rvm_tx "$FEES_TX_HASH"

echo
echo "Phase 8: Prove destination callback settled the compound"
echo "  We scan the destination chain for CompoundExecuted emitted by the hook for this pool."
wait_for_compound_callback "$FEES_BLOCK"

echo
echo "Phase 9: Final state readback"
final_debt="$(first_word "$(cast call "$HOOK_ADDRESS" 'callbackDebt()(uint256)' --rpc-url "$DESTINATION_RPC_URL")")"
final_pending="$(cast call "$HOOK_ADDRESS" 'pendingFeesFor(bytes32)(uint256,uint256)' "$POOL_ID" --rpc-url "$DESTINATION_RPC_URL")"
route_token0="$(first_word "$(cast call "$MORPHO_ADAPTER" 'managedAssets(address)(uint256)' "$TOKEN0" --rpc-url "$DESTINATION_RPC_URL")")"
route_token1="$(first_word "$(cast call "$MORPHO_ADAPTER" 'managedAssets(address)(uint256)' "$TOKEN1" --rpc-url "$DESTINATION_RPC_URL")")"
lp_shares="$(first_word "$(cast call "$HOOK_ADDRESS" 'lpShares(bytes32,address)(uint256)' "$POOL_ID" "$ACTOR" --rpc-url "$DESTINATION_RPC_URL")")"
echo "  callbackDebt: $final_debt"
echo "  pendingFeesFor(poolId): $final_pending"
echo "  morpho managed token0: $route_token0"
echo "  morpho managed token1: $route_token1"
echo "  LP shares: $lp_shares"

echo
echo "E2E proof complete"
echo "FeesAccrued boundary event: ${EXPLORER}${FEES_TX_HASH}"
echo "RVM queued callback: https://lasna.reactscan.net/tx/${RVM_TX_HASH:-unavailable}"
echo "Reactive destination callback / CompoundExecuted: ${EXPLORER}${CALLBACK_TX_HASH:-unavailable}"
