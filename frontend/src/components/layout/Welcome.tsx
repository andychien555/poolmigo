import { Button } from '@/components/ui/Button';
import { useConnectWallet } from '@/chain/useConnectWallet';

/** First-screen job: identify the product, state the benefit, offer a next step. Shown only before connecting. */
export function Welcome() {
  const { connectWallet, isPending } = useConnectWallet();
  return (
    <>
      <p className="eyebrow !text-ink-2">Automated liquidity strategies</p>
      <h1 className="title font-thin text-[clamp(52px,6.4vw,92px)] leading-[0.98] -ml-[0.03em]">
        Markets move.<br />Your range <em className="font-light">follows.</em>
      </h1>
      <div className="flex flex-wrap items-center gap-[18px]">
        <Button variant="tide" onClick={connectWallet} loading={isPending}>Connect wallet</Button>
        <p className="text-md text-ink-2 max-w-[40ch]">Deposit one asset. The vault rebalances and compounds for you.</p>
      </div>
    </>
  );
}
