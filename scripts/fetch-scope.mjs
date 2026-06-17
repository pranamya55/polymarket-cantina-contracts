#!/usr/bin/env node

import { mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const OUT_DIR = process.cwd();
const BOUNTY_ID = "ff945ca2-2a6e-4b83-b1b6-7a0cd3b94bea";
const BOUNTY_URL = `https://cantina.xyz/bounties/${BOUNTY_ID}`;
const SCOPE_URL = `${BOUNTY_URL}?assetGroup=0&overviewTab=1`;
const USER_AGENT = "polymarket-cantina-contracts-sync";
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY;
const POLYGON_RPC_URL = process.env.POLYGON_RPC_URL;

const IMPLEMENTATION_SLOT =
  "0x360894A13BA1A3210667C828492DB98DCA3E2076CC3735A920A3CA505D382BBC";
const BEACON_SLOT =
  "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50";
const IMPLEMENTATION_SELECTOR = "0x5c60da1b";
const EXPLORER_DELAY_MS = 600;

function assertConfig() {
  if (!ETHERSCAN_API_KEY) {
    throw new Error("Missing ETHERSCAN_API_KEY");
  }
  if (!POLYGON_RPC_URL) {
    throw new Error("Missing POLYGON_RPC_URL");
  }
}

function defaultHeaders(extraHeaders = {}) {
  return {
    "user-agent": USER_AGENT,
    ...extraHeaders,
  };
}

async function fetchText(url, init = {}) {
  const response = await fetch(url, {
    ...init,
    headers: defaultHeaders(init.headers ?? {}),
  });

  if (!response.ok) {
    throw new Error(`Request failed for ${url}: ${response.status} ${response.statusText}`);
  }

  return response.text();
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function rpc(method, params) {
  const response = await fetch(POLYGON_RPC_URL, {
    method: "POST",
    headers: defaultHeaders({ "content-type": "application/json" }),
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method,
      params,
    }),
  });

  if (!response.ok) {
    throw new Error(`RPC ${method} failed: ${response.status} ${response.statusText}`);
  }

  const json = await response.json();
  if (json.error) {
    throw new Error(`RPC ${method} failed: ${JSON.stringify(json.error)}`);
  }
  return json.result;
}

function slotToAddress(value) {
  if (!value || /^0x0+$/i.test(value)) {
    return null;
  }
  return `0x${value.slice(-40)}`;
}

function decodeAddressWord(value) {
  if (!value || value === "0x") {
    return null;
  }
  const hex = value.replace(/^0x/, "");
  if (hex.length < 64) {
    return null;
  }
  const address = `0x${hex.slice(-40)}`;
  return /^0x0+$/i.test(address) ? null : address;
}

async function detectProxy(address) {
  const [code, implementationRaw, beaconRaw] = await Promise.all([
    rpc("eth_getCode", [address, "latest"]),
    rpc("eth_getStorageAt", [address, IMPLEMENTATION_SLOT, "latest"]),
    rpc("eth_getStorageAt", [address, BEACON_SLOT, "latest"]),
  ]);

  const implementation = slotToAddress(implementationRaw);
  const beacon = slotToAddress(beaconRaw);

  if (implementation) {
    return {
      codeSize: Math.max((code.length - 2) / 2, 0),
      isProxy: true,
      proxyType: "eip1967",
      implementation,
      beacon: null,
    };
  }

  if (beacon) {
    const beaconResult = await rpc("eth_call", [{ to: beacon, data: IMPLEMENTATION_SELECTOR }, "latest"]);
    const beaconImplementation = decodeAddressWord(beaconResult);
    return {
      codeSize: Math.max((code.length - 2) / 2, 0),
      isProxy: Boolean(beaconImplementation),
      proxyType: beaconImplementation ? "beacon" : null,
      implementation: beaconImplementation,
      beacon,
    };
  }

  return {
    codeSize: Math.max((code.length - 2) / 2, 0),
    isProxy: false,
    proxyType: null,
    implementation: null,
    beacon: null,
  };
}

function decodeBountyFromHtml(html) {
  const framePattern = /self\.__next_f\.push\(\[1,"([\s\S]*?)"\]\)<\/script>/g;
  let match;

  while ((match = framePattern.exec(html))) {
    const decoded = JSON.parse(`"${match[1]}"`);
    if (!decoded.includes('"bounty"') || !decoded.includes(`"${BOUNTY_ID}"`)) {
      continue;
    }

    const payload = JSON.parse(decoded.slice(decoded.indexOf(":") + 1));
    const bounty = findBounty(payload);
    if (bounty) {
      return bounty;
    }
  }

  throw new Error(`Unable to locate bounty ${BOUNTY_ID} in the Cantina page payload`);
}

function findBounty(value) {
  if (!value || typeof value !== "object") {
    return null;
  }

  if (value.bounty?.id === BOUNTY_ID) {
    return value.bounty;
  }

  if (Array.isArray(value)) {
    for (const item of value) {
      const bounty = findBounty(item);
      if (bounty) {
        return bounty;
      }
    }
    return null;
  }

  for (const child of Object.values(value)) {
    const bounty = findBounty(child);
    if (bounty) {
      return bounty;
    }
  }

  return null;
}

function extractAddress(reference) {
  const match = reference.match(/0x[a-fA-F0-9]{40}/);
  if (!match) {
    throw new Error(`Unable to extract address from ${reference}`);
  }
  return match[0];
}

function normalizeScopeAsset(asset) {
  return {
    assetId: asset.id,
    name: asset.name.trim(),
    description: (asset.description || "").trim(),
    address: extractAddress(asset.reference),
    explorerUrl: asset.reference,
  };
}

function extractScope(bounty) {
  const assetGroup = bounty.assetGroups?.find((group) => !group.outOfScope && /smart contract/i.test(group.name));
  if (!assetGroup) {
    throw new Error("Unable to locate the smart-contract asset group in the Cantina bounty payload");
  }

  const contracts = (assetGroup.assets || []).map(normalizeScopeAsset);
  if (!contracts.length) {
    throw new Error("Smart-contract asset group is empty");
  }

  return { assetGroup, contracts };
}

async function getSource(address) {
  for (let attempt = 1; attempt <= 5; attempt += 1) {
    const url = new URL("https://api.etherscan.io/v2/api");
    url.searchParams.set("chainid", "137");
    url.searchParams.set("module", "contract");
    url.searchParams.set("action", "getsourcecode");
    url.searchParams.set("address", address);
    url.searchParams.set("apikey", ETHERSCAN_API_KEY);

    const response = await fetch(url, {
      headers: defaultHeaders(),
    });
    if (!response.ok) {
      throw new Error(`Explorer source fetch failed for ${address}: ${response.status} ${response.statusText}`);
    }

    const payload = await response.json();
    const result = payload.result;

    if (Array.isArray(result) && result.length > 0 && result[0].SourceCode) {
      return result[0];
    }

    const reason =
      typeof result === "string"
        ? result
        : payload.message || "unknown explorer response";
    const retryable =
      /rate limit|timeout|temporar|busy|max/i.test(reason) ||
      !Array.isArray(result);

    if (!retryable || attempt === 5) {
      throw new Error(`Explorer source fetch failed for ${address}: ${reason}`);
    }

    await sleep(EXPLORER_DELAY_MS * attempt);
  }
}

function parseSourceFiles(entry) {
  const sourceCode = (entry.SourceCode || "").trim();
  if (!sourceCode) {
    return [];
  }

  let normalized = sourceCode;
  if (normalized.startsWith("{{") && normalized.endsWith("}}")) {
    normalized = normalized.slice(1, -1);
  }

  if (normalized.startsWith("{")) {
    const parsed = JSON.parse(normalized);
    if (parsed.sources && typeof parsed.sources === "object") {
      return Object.entries(parsed.sources).map(([filePath, value]) => ({
        filePath,
        content: typeof value === "string" ? value : value.content,
      }));
    }
  }

  return [
    {
      filePath: entry.ContractFileName || `${entry.ContractName || "Contract"}.sol`,
      content: sourceCode,
    },
  ];
}

function sanitizeSegment(value) {
  return value
    .replace(/[^a-zA-Z0-9._-]+/g, "_")
    .replace(/^_+|_+$/g, "");
}

function safeRelative(filePath) {
  const normalized = path.posix.normalize(filePath.replace(/\\/g, "/"));
  if (normalized.startsWith("/") || normalized.startsWith("../") || normalized === "..") {
    throw new Error(`Unsafe source path: ${filePath}`);
  }
  return normalized;
}

async function writeJson(filePath, value) {
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

async function materializeContract(contract) {
  const proxy = await detectProxy(contract.address);
  const resolvedAddress = proxy.implementation || contract.address;
  const sourceEntry = await getSource(resolvedAddress);
  const files = parseSourceFiles(sourceEntry);

  const bundleName = `${sanitizeSegment(contract.name)}-${contract.address}`;
  const bundleRoot = path.join(OUT_DIR, "contracts", bundleName);
  const sourceRoot = path.join(bundleRoot, "sources");

  await mkdir(sourceRoot, { recursive: true });

  for (const file of files) {
    const relativePath = safeRelative(file.filePath);
    const outputPath = path.join(sourceRoot, relativePath);
    await mkdir(path.dirname(outputPath), { recursive: true });
    await writeFile(outputPath, file.content);
  }

  let abi;
  try {
    abi = JSON.parse(sourceEntry.ABI);
  } catch {
    abi = sourceEntry.ABI;
  }

  const metadata = {
    assetId: contract.assetId,
    name: contract.name,
    description: contract.description,
    address: contract.address,
    explorerUrl: contract.explorerUrl,
    fetchedAt: new Date().toISOString(),
    codeSize: proxy.codeSize,
    proxy: {
      isProxy: proxy.isProxy,
      proxyType: proxy.proxyType,
      implementation: proxy.implementation,
      beacon: proxy.beacon,
      resolvedAddress,
    },
    explorer: {
      resolvedAddress,
      contractName: sourceEntry.ContractName,
      contractFileName: sourceEntry.ContractFileName,
      compilerVersion: sourceEntry.CompilerVersion,
      compilerType: sourceEntry.CompilerType,
      optimizationUsed: sourceEntry.OptimizationUsed,
      runs: sourceEntry.Runs,
      evmVersion: sourceEntry.EVMVersion,
      constructorArguments: sourceEntry.ConstructorArguments,
      licenseType: sourceEntry.LicenseType,
      sourceFiles: files.map((file) => file.filePath),
    },
  };

  await writeJson(path.join(bundleRoot, "metadata.json"), metadata);
  await writeJson(path.join(bundleRoot, "abi.json"), abi);

  return metadata;
}

async function main() {
  assertConfig();

  const html = await fetchText(SCOPE_URL);
  const bounty = decodeBountyFromHtml(html);
  const { assetGroup, contracts } = extractScope(bounty);
  const fetchedAt = new Date().toISOString();

  await rm(path.join(OUT_DIR, "contracts"), { recursive: true, force: true });
  await rm(path.join(OUT_DIR, "metadata"), { recursive: true, force: true });

  await writeJson(path.join(OUT_DIR, "metadata", "bounty.json"), bounty);
  await writeJson(path.join(OUT_DIR, "metadata", "cantina-scope.json"), {
    fetchedAt,
    snapshotDate: fetchedAt.slice(0, 10),
    bountyId: bounty.id,
    bountyUrl: bounty.url || BOUNTY_URL,
    bountyName: bounty.name,
    company: bounty.company?.name || null,
    status: bounty.status,
    network: "polygon",
    totalRewardPot: bounty.totalRewardPot,
    assetGroup: {
      id: assetGroup.id,
      name: assetGroup.name,
      description: assetGroup.description,
      rewards: assetGroup.rewards,
    },
    contracts,
  });

  const manifest = [];
  for (const contract of contracts) {
    console.log(`Fetching ${contract.name} (${contract.address})`);
    const metadata = await materializeContract(contract);
    manifest.push(metadata);
    await sleep(EXPLORER_DELAY_MS);
  }

  await writeJson(path.join(OUT_DIR, "metadata", "contracts.json"), manifest);
  console.log(`Wrote ${manifest.length} contract bundles to ${path.join(OUT_DIR, "contracts")}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
