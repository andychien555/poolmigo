import { createPublicClient, defineChain, http, parseAbi } from 'viem';
const c = createPublicClient({ chain: defineChain({ id: 4663, name: 'x', nativeCurrency:{name:'Ether',symbol:'ETH',decimals:18}, rpcUrls:{default:{http:['https://rpc.mainnet.chain.robinhood.com']}}, contracts:{multicall3:{address:'0xca11bde05977b3631167028862be2a173976ca11',blockCreated:0}} }), transport: http('https://rpc.mainnet.chain.robinhood.com') });
const routesAbi = parseAbi(['function routes(address from, address to) view returns (address refPool, uint24 swapFee, uint32 twapWindow, uint16 maxSlippageBps, uint16 maxDeviationBps)']);
const v3Abi = parseAbi(['function token0() view returns (address)','function token1() view returns (address)','function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)']);
const USDG = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168';
const ZAP = '0x8187691738907dCCBB34f6Aa82059CCF1Ae3870f';
for (const t of ['0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73','0x39dBED3a2bd333467115dE45665cC57F813C4571']) {
  const route = await c.readContract({ address: ZAP, abi: routesAbi, functionName: 'routes', args: [USDG, t] });
  console.log(t.slice(0,8), 'route refPool:', route[0]);
  if (route[0] === '0x0000000000000000000000000000000000000000') continue;
  const [t0, t1, s0] = await Promise.all([
    c.readContract({ address: route[0], abi: v3Abi, functionName: 'token0' }),
    c.readContract({ address: route[0], abi: v3Abi, functionName: 'token1' }),
    c.readContract({ address: route[0], abi: v3Abi, functionName: 'slot0' }),
  ]);
  console.log('  pool:', t0, t1, 'sqrt:', s0[0].toString().slice(0,16), 'tick:', s0[1]);
}
