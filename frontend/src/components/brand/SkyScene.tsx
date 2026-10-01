import { useEffect, useRef, useState } from 'react';
import { cx } from '@/lib/format';
import { Scene } from './Scene';
import type { DuskScene } from './duskScene';

function canUseWebGL(): boolean {
  if (typeof window === 'undefined' || !('WebGLRenderingContext' in window)) return false;
  try {
    const c = document.createElement('canvas');
    return Boolean(c.getContext('webgl2') || c.getContext('webgl'));
  } catch {
    return false;
  }
}

/**
 * The scene, alive: the sun (the price) drifts, and when it leaves the gap the stones slide to
 * re-centre on it. The still drawing shows first and stays if WebGL is not available; the 3D
 * scene and three.js load on demand and fade in over it.
 *
 * `offset` moves the stones sideways on wide frames so copy beside them stays clear.
 */
export function SkyScene({ className, offset = -6 }: { className?: string; offset?: number }) {
  const host = useRef<HTMLDivElement>(null);
  const [live, setLive] = useState(false);

  useEffect(() => {
    if (!canUseWebGL()) return;
    let scene: DuskScene | null = null;
    let cancelled = false;
    import('./duskScene')
      .then(({ createDuskScene }) => {
        if (cancelled || !host.current) return;
        scene = createDuskScene(host.current, { offset });
        setLive(scene !== null);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
      scene?.dispose();
      setLive(false);
    };
  }, [offset]);

  return (
    <div className={cx('overflow-hidden bg-dusk', className)} aria-hidden>
      <Scene className={cx('absolute inset-0 h-full w-full transition-opacity duration-700', live && 'opacity-0')} />
      <div
        ref={host}
        className={cx(
          'absolute inset-0 transition-opacity duration-700 [&>canvas]:absolute [&>canvas]:inset-0 [&>canvas]:block [&>canvas]:!h-full [&>canvas]:!w-full',
          live ? 'opacity-100' : 'opacity-0',
        )}
      />
    </div>
  );
}
