// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DepositSplit} from "contracts/periphery/DepositSplit.sol";

/// @notice Vault-implementation constructor arguments for tests: the implementation pins a {DepositSplit} (immutable)
///         since deposit-deploy (T2d). Stateless, so a fresh one per implementation is equivalent to a shared one.
library VaultImplArgs {
    /// @dev A fresh {DepositSplit} — `new MySunVaultUpgradeable(VaultImplArgs.depositSplit())`.
    function depositSplit() internal returns (address) {
        return address(new DepositSplit());
    }

    /// @dev OZ-plugin options carrying a fresh splitter as the implementation's constructor data.
    function proxyOpts() internal returns (Options memory opts) {
        opts.constructorData = abi.encode(depositSplit());
    }
}
