# Polymarket Cantina Scope

Snapshot of the smart-contract scope from the public Cantina bounty at:

`https://cantina.xyz/bounties/ff945ca2-2a6e-4b83-b1b6-7a0cd3b94bea`

This repo is a source archive, not an official upstream. Each bundle under `contracts/` contains the verified source tree for one in-scope on-chain address from the Polygon scope. When an address is an upgradeable proxy, the bundle is written against the implementation contract and the proxy mapping is recorded in `metadata.json`.

## Layout

- `contracts/<Name>-<address>/sources/`: verified source files for that scope item
- `contracts/<Name>-<address>/metadata.json`: explorer metadata plus proxy resolution data
- `contracts/<Name>-<address>/abi.json`: ABI as returned by the explorer
- `metadata/cantina-scope.json`: snapshot of the in-scope contract list
- `metadata/contracts.json`: generated manifest for all bundles
- `scripts/fetch-scope.mjs`: refresh script

## Refresh

```bash
ETHERSCAN_API_KEY=... \
POLYGON_RPC_URL=... \
node scripts/fetch-scope.mjs
```

`POLYGON_RPC_URL` can be any Polygon mainnet JSON-RPC endpoint. The current fetch flow uses the RPC endpoint only to detect and resolve proxies.
