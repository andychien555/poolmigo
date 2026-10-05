import { useUserDerived } from '@/store/selectors';
import { Mark } from '@/components/brand/Mark';

/** One useful line about the user's own position, shown once connected. */
export function Sidekick() {
  const d = useUserDerived();
  let line: React.ReactNode;
  if (d.hasPositions) line = <>Your vaults are rebalancing and compounding on their own. Nothing to do.</>;
  else line = <>Pick a vault below to start. Deposit one asset and the vault does the rest.</>;
  return (
    <p className="inline-flex items-center gap-2.5 rounded border border-stroke-strong bg-background-base/55 py-[7px] pl-2 pr-3 text-sm text-weak">
      <Mark size={20} className="text-strong" />
      <span>{line}</span>
    </p>
  );
}
