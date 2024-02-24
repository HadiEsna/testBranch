## Noya smart contracts

**This repo contains noya smart contract**

_the scope for the audit is all the files in the contracts folder_

Contracts

- **Accounting manager** : This contract is responsible for managing the deposits and withdrawals of the users, holding users shares as an ERC20 token and calculating its value based on a base token.
- **Vault manager** : this contract is responsible for managing the vaults, it handles the connection between the "connectors" and the Accounting manager.
- **Connectors** : these set of contracts are responsible for the connection between the vault manager and the external protocols, it handles the deposits and withdrawals from the external protocols. They hold the assets and report the value of the assets to the vault manager.
- **Omnichain Handler** : these smart contracts are responsible for the connection between the vault manager and the external protocols on other chains. It handles the bridging to other chains and communication with those chains through Layer Zero infrastructure.
- **Noya Value Oracle** : this contract is responsible for calculating the value of the other tokens/positions that the connectors hold. The result is used by accounting manager to calculate the value of the shares.
- **Noya Bridge and Swap handler** : this contract is responsible for handling the bridging and swaps. We are using LiFi for this purpose but this contract is designed to be able to support other bridges and swaps in the future. Other contracts will be explained in the docs in detail.
