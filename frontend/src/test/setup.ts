/**
 * Test-environment pinning. The app reads its WalletConnect project id from `.env.local`, which
 * every developer of this repo has (and CI does not) — the suite must not quietly change behavior
 * with that file. Pinned off here, BEFORE any test module imports the wallet layer, so
 * `walletConnectEnabled` is the same in every environment.
 */
import { vi } from 'vitest';

vi.stubEnv('VITE_WALLETCONNECT_PROJECT_ID', '');
