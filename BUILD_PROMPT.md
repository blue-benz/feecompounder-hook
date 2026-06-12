# Build Prompt: FeeCompounder Hook

You are building FeeCompounder Hook to production quality.

Before writing code, read:

1. `README.md`
2. `SPEC.md`
3. every first-party file under `src/`, `test/`, `script/`, and `frontend/src/`
4. `context/README.md`
5. `context/uniswap-docs/docs/static/v4-llms.txt`
6. `context/uhi-workshops/workshops/week-2-build-first-hook/README.md`
7. `context/uhi-workshops/workshops/week-2-testing-your-first-hook/README.md`
8. `context/reactive-network/reactive-test-lib/README.md`
9. `context/reactive-network/reactive-test-lib/test/CallbackAuth.t.sol`
10. `lib/reactive-lib/src/abstract-base/AbstractReactive.sol`
11. `lib/reactive-lib/src/interfaces/IReactive.sol`
12. `lib/v4-hooks-public/src/base/BaseHook.sol`

Then build and harden the system:

1. Preserve conservative v4 permissions unless explicitly auditing a return-delta fee-capture path.
2. Keep the fee reserve backed by actual token transfers before emitting `FeesAccrued`.
3. Keep Reactive legacy Lasna compatibility:
   - RPC `https://lasna-rpc.rnk.dev/`
   - chain id `5318007`
   - system contract `0x0000000000000000000000000000000000fffFfF`
   - library `Reactive-Network/reactive-lib`
4. Use explicit callback identity in payloads:
   - hook must check `msg.sender == callbackProxy`
   - hook must check encoded `sender == reactiveSender`
5. Maintain share accounting invariants:
   - deposits after compounding receive fewer shares
   - shares remain proportional across multiple compounds
   - withdrawals receive principal plus pending/route value
6. Expand tests until meaningful line and branch coverage is effectively complete:
   - unit tests
   - fuzz tests
   - integration tests
   - fork tests for Sepolia/Base Sepolia/Unichain Sepolia where RPC and funds exist
   - Reactive callback simulation tests
7. Keep scripts operational:
   - deploy hook/adapters
   - deploy RSC on Lasna
   - configure subscription
   - configure pool key in RSC
   - run labelled E2E
   - print explorer URLs for every tx
8. Keep frontend judge-facing and focused on the actual workflow:
   - LP shares
   - fee reserve
   - gas gate
   - APY route selection
   - compound execution
   - withdrawal

Acceptance criteria:

- `forge build` passes
- `forge test` passes
- coverage command runs and reports the remaining gaps
- `script/LocalE2E.s.sol` demonstrates a full flow
- frontend builds with `npm run build`
- deployment scripts read `.env` and never hardcode private keys
- README and SPEC clearly disclose the current backed fee-reporting model and production fee-capture work remaining
