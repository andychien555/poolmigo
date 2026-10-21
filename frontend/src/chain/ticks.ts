/**
 * Uniswap v3/v4 TickMath, ported verbatim from `contracts/src/adapters/uniswap/TickMath.sol` (the
 * same constants, the same rounding) so a tick read from an adapter's `positionState()` lands on
 * exactly the sqrt ratio the pool uses. Pure bigint, no reads.
 *
 * A tick is in its pool's sqrt-ratio domain: sqrtPriceX96 = sqrt(1.0001^tick) · 2^96, the price being
 * token1 per token0 in raw units — the same quantity as `slot0().sqrtPriceX96`.
 *
 * Imports are relative (none needed here), like spot.ts: plain module, runnable under tsx.
 */

export const MIN_TICK = -887272;
export const MAX_TICK = 887272;
export const MIN_SQRT_RATIO = 4295128739n;
export const MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342n;

const MAX_UINT256 = (1n << 256n) - 1n;

/** The ladder: (bit of |tick|, Q128.128 multiplier), as in the contract. */
const LADDER: readonly (readonly [number, bigint])[] = [
  [0x2, 0xfff97272373d413259a46990580e213an],
  [0x4, 0xfff2e50f5f656932ef12357cf3c7fdccn],
  [0x8, 0xffe5caca7e10e4e61c3624eaa0941cd0n],
  [0x10, 0xffcb9843d60f6159c9db58835c926644n],
  [0x20, 0xff973b41fa98c081472e6896dfb254c0n],
  [0x40, 0xff2ea16466c96a3843ec78b326b52861n],
  [0x80, 0xfe5dee046a99a2a811c461f1969c3053n],
  [0x100, 0xfcbe86c7900a88aedcffc83b479aa3a4n],
  [0x200, 0xf987a7253ac413176f2b074cf7815e54n],
  [0x400, 0xf3392b0822b70005940c7a398e4b70f3n],
  [0x800, 0xe7159475a2c29b7443b29c7fa6e889d9n],
  [0x1000, 0xd097f3bdfd2022b8845ad8f792aa5825n],
  [0x2000, 0xa9f746462d870fdf8a65dc1f90e061e5n],
  [0x4000, 0x70d869a156d2a1b890bb3df62baf32f7n],
  [0x8000, 0x31be135f97d08fd981231505542fcfa6n],
  [0x10000, 0x9aa508b5b7a84e1c677de54f3e99bc9n],
  [0x20000, 0x5d6af8dedb81196699c329225ee604n],
  [0x40000, 0x2216e584f5fa1ea926041bedfe98n],
  [0x80000, 0x48a170391f7dc42444e8fa2n],
];

/**
 * The contract's intermediate Q128.128 ratio for `tick` (before the Q128.96 downcast): 1/sqrt(1.0001^|tick|)
 * from the ladder, inverted for a positive tick. Exported for the constant-level tests.
 */
export function ratioX128AtTick(tick: number): bigint {
  if (!Number.isInteger(tick)) throw new RangeError(`tick ${tick} is not an integer`);
  const absTick = Math.abs(tick);
  if (absTick > MAX_TICK) throw new RangeError(`tick ${tick} out of range`);
  let ratio = absTick & 0x1 ? 0xfffcb933bd6fad37aa2d162d1a594001n : 0x100000000000000000000000000000000n;
  for (const [bit, mul] of LADDER) if (absTick & bit) ratio = (ratio * mul) >> 128n;
  if (tick > 0) ratio = MAX_UINT256 / ratio;
  return ratio;
}

/** sqrt(1.0001^tick) · 2^96 as Q64.96, rounded up exactly as `TickMath.getSqrtRatioAtTick`. */
export function getSqrtRatioAtTick(tick: number): bigint {
  const ratio = ratioX128AtTick(tick);
  return (ratio >> 32n) + (ratio % (1n << 32n) === 0n ? 0n : 1n);
}

/** The greatest tick whose sqrt ratio is ≤ `sqrtPriceX96` (`TickMath.getTickAtSqrtRatio`). */
export function getTickAtSqrtRatio(sqrtPriceX96: bigint): number {
  if (!(sqrtPriceX96 >= MIN_SQRT_RATIO && sqrtPriceX96 < MAX_SQRT_RATIO)) throw new RangeError('sqrt ratio out of range');
  const ratio = sqrtPriceX96 << 32n;

  // Most significant bit, by halving (the assembly blocks above `log_2`).
  let r = ratio;
  let msb = 0n;
  for (const [shift, bound] of [
    [7n, 0xffffffffffffffffffffffffffffffffn],
    [6n, 0xffffffffffffffffn],
    [5n, 0xffffffffn],
    [4n, 0xffffn],
    [3n, 0xffn],
    [2n, 0xfn],
    [1n, 0x3n],
  ] as const) {
    const f = r > bound ? 1n << shift : 0n;
    msb |= f;
    r >>= f;
  }
  msb |= r > 1n ? 1n : 0n;

  r = msb >= 128n ? ratio >> (msb - 127n) : ratio << (127n - msb);

  // Signed int256 arithmetic: BigInt's two's-complement `|` and arithmetic `>>` match Solidity's.
  let log2 = (msb - 128n) << 64n;
  for (let bit = 63n; bit >= 50n; bit--) {
    r = (r * r) >> 127n;
    const f = r >> 128n;
    log2 |= f << bit;
    r >>= f;
  }

  const logSqrt10001 = log2 * 255738958999603826347141n; // Q128.128
  const tickLow = Number((logSqrt10001 - 3402992956809132418596140100660247210n) >> 128n);
  const tickHi = Number((logSqrt10001 + 291339464771989622907027621153398088495n) >> 128n);
  return tickLow === tickHi ? tickLow : getSqrtRatioAtTick(tickHi) <= sqrtPriceX96 ? tickHi : tickLow;
}
