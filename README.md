# Polymarket Cantina Scope

Snapshot of the public smart-contract scope from the Polymarket Cantina bounty at:

`https://cantina.xyz/bounties/ff945ca2-2a6e-4b83-b1b6-7a0cd3b94bea`

This repo is a source archive, not an official upstream repository. Each bundle under `contracts/` contains the verified source tree for one current in-scope Polygon address. When an address is an upgradeable proxy, the bundle is written against the resolved implementation contract and the proxy mapping is recorded in `metadata.json`.

## Snapshot

- Generated at: `2026-06-17T20:52:32.678Z`
- In-scope smart-contract assets: `32`
- Contract bundles written: `32`
- Proxy-resolved bundles: `10`
- Archived source files: `600`
- Network: `Polygon PoS (Chain ID 137)`
- Maximum reward: `$5,000,000`

## Layout

- `contracts/<Name>-<address>/sources/`: verified source files for that scope item
- `contracts/<Name>-<address>/metadata.json`: explorer metadata plus proxy resolution data
- `contracts/<Name>-<address>/abi.json`: ABI as returned by the explorer
- `metadata/cantina-scope.json`: normalized smart-contract scope extracted from the live public Cantina page
- `metadata/bounty.json`: raw public bounty payload extracted from Cantina
- `metadata/contracts.json`: generated manifest for all bundles
- `scripts/fetch-scope.mjs`: refresh script

## Refresh

```bash
ETHERSCAN_API_KEY=... \
POLYGON_RPC_URL=... \
node scripts/fetch-scope.mjs
```

`POLYGON_RPC_URL` can be any Polygon mainnet JSON-RPC endpoint. The current fetch flow uses the RPC endpoint only to detect and resolve proxies.

## Notes

- The refresh script now pulls the current smart-contract scope directly from the public Cantina bounty page instead of using a hardcoded list.
- The rebuild wipes `contracts/` and `metadata/` before regeneration so removed scope items do not linger.
- Verified source retrieval is done through Etherscan V2 with `chainid=137`.
