import { useEffect } from 'react';
import { createPortal } from 'react-dom';
import type { LiveVaultRow } from '@/chain/useLiveVaults';
import type { ChainSpots } from '@/chain/useSpotPrices';
import { VaultDepositCard } from './DepositCard';

/** The deposit card as an overlay over Markets (`?deposit=<vault id>`), on one live vault. */
export function DepositModal({ row, spots, onClose }: { row: LiveVaultRow | null; spots: ChainSpots | undefined; onClose: () => void }) {
  useEffect(() => {
    if (!row) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [row, onClose]);
  if (!row || !spots) return null;
  return createPortal(
    <div className="fixed inset-0 z-50 flex justify-center px-4 py-12 overflow-y-auto" role="dialog" aria-modal>
      <div className="fixed inset-0 bg-fill-overlay backdrop-blur-[4px]" onClick={onClose} />
      <div className="relative my-auto w-full max-w-[440px] animate-fade-in">
        <button onClick={onClose} className="absolute -top-8 right-0 text-xs text-weak hover:text-strong" aria-label="Close">Close ✕</button>
        <div className="shadow-pop">
          <VaultDepositCard key={row.id} row={row} spots={spots} />
        </div>
      </div>
    </div>,
    document.body,
  );
}
