import { createPublicClient, defineChain, http } from 'viem';
const c = createPublicClient({ chain: defineChain({ id: 46630, name: 'demo', nativeCurrency:{name:'Ether',symbol:'ETH',decimals:18}, rpcUrls:{default:{http:['http://127.0.0.1:8547']}}, contracts:{multicall3:{address:'0xca11bde05977b3631167028862be2a173976ca11',blockCreated:0}} }), transport: http('http://127.0.0.1:8547') });
const vault = '0x97076CA9EEE0E8637c0373A25d8d14a17f7c6a1e';
const abi = [{type:'function',name:'totalSupply',inputs:[],outputs:[{type:'uint256'}],stateMutability:'view'}] as const;
try {
  const t = await c.readContract({ address: vault, abi, functionName: 'totalSupply' });
  console.log('solo supply:', t.toString());
} catch (e) { console.log('solo FAIL:', String(e).slice(0,100)); }
try {
  const r = await c.multicall({ contracts: [{ address: vault, abi, functionName: 'totalSupply' }], allowFailure: true });
  console.log('multicall supply:', JSON.stringify(r).slice(0,120));
} catch (e) { console.log('multicall FAIL:', String(e).slice(0,120)); }
