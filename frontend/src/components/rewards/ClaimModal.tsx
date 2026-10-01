import { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import { PROTOCOL } from '@/demo/data/protocol';
import { CONSTANTS } from '@/demo/constants';
import * as m from '@/demo/math';
import { cx, fmtDate, fmtInt, fmtToken, fmtUsd } from '@/lib/format';
import { useStore } from '@/store/useStore';
import { useUserDerived } from '@/store/selectors';
import { Button } from '@/components/ui/Button';
import { LocksList } from './LocksList';

const TX_DELAY = 1500;
type Choice = 'now' | 'lock';

/** Claim pending PMG: now at 50%, or lock 90 days for 100%. A sheet from the right, over the page it was opened from. */
export function ClaimModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, onClose]);
  if (!open) return null;
  return createPortal(
    <div className="fixed inset-0 z-50 flex justify-end" role="dialog" aria-modal aria-label="Rewards">
      <div className="absolute inset-0 bg-black/60 backdrop-blur-[4px]" onClick={onClose} />
      <aside className="relative grid h-full w-[min(500px,100vw)] content-start gap-7 overflow-y-auto border-l border-line-2 bg-dusk px-[18px] pb-24 pt-[22px] shadow-[-30px_0_80px_rgb(0_0_0/0.5)] animate-slide-in sm:px-[26px]">
        <div className="flex items-center justify-between gap-3">
          <p className="eyebrow">Rewards</p>
          <button onClick={onClose} className="grid h-8 w-8 shrink-0 place-items-center rounded border border-line text-ink-2 hover:border-line-2 hover:text-ink" aria-label="Close">✕</button>
        </div>
        <Claim onDone={onClose} />
        <LocksList />
      </aside>
    </div>,
    document.body,
  );
}

function Claim({ onDone }: { onDone: () => void }) {
  const d = useUserDerived();
  const claimInstant = useStore((s) => s.claimInstant);
  const claimLock = useStore((s) => s.claimLock);
  const pushToast = useStore((s) => s.pushToast);
  const [choice, setChoice] = useState<Choice>('lock');
  const [busy, setBusy] = useState(false);
  const forfeitsAdded = useStore((s) => s.forfeitsAdded);
  const pool = PROTOCOL.redistribution.fromForfeits + forfeitsAdded + PROTOCOL.redistribution.fromBuybacks;
  const split = m.claimSplit(d.pendingTide);
  const empty = d.pendingTide < 0.005;
  const unlockDate = fmtDate(Date.now() + CONSTANTS.LOCK_DAYS * 86_400_000);

  const submit = async () => {
    setBusy(true);
    await new Promise((r) => setTimeout(r, TX_DELAY));
    if (choice === 'now') {
      const got = claimInstant();
      pushToast({ title: 'Claim confirmed', detail: `${fmtToken(got, 1)} PMG sent to your wallet`, tone: 'up' });
    } else {
      const lock = claimLock();
      if (lock) pushToast({ title: 'Lock confirmed', detail: `${fmtToken(lock.amount, 1)} PMG unlocks ${fmtDate(lock.unlockAt)}`, tone: 'up' });
    }
    setBusy(false);
    onDone();
  };

  return (
    <>
      <section className="grid gap-2">
        <h2 className="text-sm text-ink-3">Pending rewards</h2>
        <div className="display num text-[46px] leading-none tracking-[-0.015em] text-tide">
          {fmtToken(d.pendingTide, 2)} <span className="text-xl">PMG</span>
        </div>
        <p className="text-sm text-ink-2 num">≈ {fmtUsd(d.pendingTide * CONSTANTS.TIDE_PRICE, { compact: false, cents: true })} · PMG ${CONSTANTS.TIDE_PRICE.toFixed(3)}</p>
      </section>

      <section>
        <h3 className="eyebrow mb-3">How to receive it</h3>
        <div className="grid gap-2.5" role="group" aria-label="Claim option">
          <Option
            selected={choice === 'now'}
            onSelect={() => setChoice('now')}
            disabled={empty}
            title="Claim now"
            amount={split.instant}
            note={`You receive ${Math.round(CONSTANTS.INSTANT_CLAIM_RATIO * 100)}% today. The other ${fmtToken(split.forfeited, 1)} goes to lockers.`}
            bar={<><i className="block h-full bg-ink" style={{ width: `${CONSTANTS.INSTANT_CLAIM_RATIO * 100}%` }} /><i className="hatch block h-full flex-1" /></>}
          />
          <Option
            selected={choice === 'lock'}
            onSelect={() => setChoice('lock')}
            disabled={empty}
            title={`Lock ${CONSTANTS.LOCK_DAYS} days`}
            amount={split.locked}
            note={`100% after ${CONSTANTS.LOCK_DAYS} days, plus a share of forfeits. Unlocks ${unlockDate}.`}
            bar={<><i className="block h-full flex-1 bg-ink" /><i className="block h-full w-3.5 shrink-0 bg-sun" /></>}
          />
        </div>
      </section>

      <section className="grid gap-3">
        <Button block variant="tide" onClick={submit} disabled={empty} loading={busy}>
          {busy ? 'Confirming…' : empty ? 'Nothing to claim yet' : choice === 'now' ? `Claim ${fmtToken(split.instant, 1)} PMG` : `Lock ${fmtToken(split.locked, 1)} PMG`}
        </Button>
        <p className="text-xs text-ink-3 num">Lockers share this week's pool of {fmtInt(pool)} PMG from forfeits and buybacks.</p>
      </section>
    </>
  );
}

/** One way to receive the rewards. The bar shows what is kept, what is given up (hatched) and what is added (sun). */
function Option({ selected, onSelect, disabled, title, amount, note, bar }: { selected: boolean; onSelect: () => void; disabled: boolean; title: string; amount: number; note: string; bar: React.ReactNode }) {
  return (
    <button
      onClick={onSelect}
      aria-pressed={selected}
      disabled={disabled}
      className={cx(
        'grid w-full gap-2.5 rounded border px-4 py-3.5 text-left transition-colors disabled:cursor-not-allowed disabled:opacity-50',
        selected ? 'border-sun bg-sun/[0.05]' : 'border-line-2 hover:border-ink-3',
      )}
    >
      <span className="flex items-baseline justify-between gap-2.5">
        <span className="text-base font-medium text-ink">{title}</span>
        <span className="display num text-xl text-ink">{fmtToken(amount, 1)}</span>
      </span>
      <span className="flex h-2.5 gap-0.5" aria-hidden>{bar}</span>
      <span className={cx('text-xs', selected ? 'text-ink-2' : 'text-ink-3')}>{note}</span>
    </button>
  );
}
