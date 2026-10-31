# Indirizzi dei deploy su Sepolia

Questi file registrano gli indirizzi dei contratti effettivamente deployati su
Sepolia (testnet pubblica, `chainId` 11155111) per gli esperimenti descritti
nella tesi. Sono solo dati pubblici (indirizzi, hash di transazione, ABI) —
nessuna chiave privata.

- **`sepolia-demo.json`** — deploy usato dalla demo end-to-end (console +
  rete di nodi MPC + `SolvencyRegistry`), prodotto da
  `scripts/deploy/AaveV4DeploySepoliaDemo.s.sol` e dal successivo
  `scripts/deploy/FixSpokeInstance.s.sol` (vedi il campo `deployTransactions`
  per lo storico dei due broadcast). Il campo `notes.orphanedContracts` elenca
  gli indirizzi di deploy falliti/superati durante lo sviluppo — restano
  comunque pubblicamente visibili su Sepolia ma non vanno usati.
- **`sepolia-full-deploy.json`** — un deploy separato dello stack Aave V4
  completo sulla stessa rete, senza gli indirizzi specifici della demo
  (`SolvencyRegistry`, asset/price-feed demo).

Entrambi i file erano rimasti solo sulla macchina di sviluppo (non
committati), senza alcuna copia altrove: aggiunti qui perché il deploy reale
dietro i risultati della tesi fosse verificabile anche dopo la cancellazione
di quella macchina.
