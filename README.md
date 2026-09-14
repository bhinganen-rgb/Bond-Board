# BondBoard

Peer-issued fixed-rate bonds on BOT Chain. Anyone can issue a bond by posting collateral;
funders pool BOT to buy it; the issuer draws principal, repays with coupon by maturity,
or defaults and forfeits collateral to funders pro-rata.

## Mechanics

- **Issue**: post `collateralBps` (10%-100%) of principal as collateral. Fix `repayAmount > principal` and `maturitySecs` (1d-365d).
- **Fund**: anyone can send BOT until principal is reached. Over-funding is refunded.
- **Draw**: issuer withdraws principal (minus platform fee, default 0.5%). Maturity clock starts.
- **Repay**: issuer sends `repayAmount` any time before `maturity + grace`. Collateral is returned; funders claim their pro-rata share of `repayAmount`.
- **Default**: after `maturity + graceSecs` (default 7 days), anyone can call `seizeCollateral`. Funders claim pro-rata collateral.
- **Cancel**: while still Open, issuer can cancel — funders refunded, collateral returned.

## Quickstart

```bash
npm install
npx hardhat compile
npx hardhat test
cp .env.example .env      # add your PRIVATE_KEY
npm run deploy:testnet
# copy address into frontend/index.html CONTRACT_ADDRESS
```

## Networks

- Testnet: chainId 968, RPC https://rpc.bohr.life, Explorer https://scan.bohr.life
- Mainnet: chainId 677, RPC https://rpc.botchain.ai, Explorer https://scan.botchain.ai

## Risk disclaimers

BondBoard is unaudited experimental software. Collateral can be under 100% of principal —
lenders bear real default risk. There is no oracle, no credit check, no recovery process
beyond seizing on-chain collateral. Only participate with BOT you can afford to lose.
