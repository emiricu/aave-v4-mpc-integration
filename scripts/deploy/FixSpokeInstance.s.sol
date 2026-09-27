// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';
import {console2 as console} from 'forge-std/console2.sol';

import {AaveV4SpokeInstanceBatch} from 'src/deployments/batches/AaveV4SpokeInstanceBatch.sol';
import {AaveV4SpokeRolesProcedure} from 'src/deployments/procedures/roles/AaveV4SpokeRolesProcedure.sol';
import {BytecodeHelper} from 'src/deployments/utils/libraries/BytecodeHelper.sol';
import {DeployConstants} from 'src/deployments/utils/libraries/DeployConstants.sol';

import {IHubConfigurator} from 'src/hub/interfaces/IHubConfigurator.sol';
import {ISpokeConfigurator} from 'src/spoke/interfaces/ISpokeConfigurator.sol';
import {ISpoke} from 'src/spoke/interfaces/ISpoke.sol';

import {SolvencyRegistry} from 'src/spoke/SolvencyRegistry.sol';

/// @notice One-off repair script (see docs/solvency-mpc-integration.md deploy notes): the original
/// AaveV4DeploySepoliaDemo.s.sol's AaveV4SpokeInstanceBatch creation reverted on real broadcast
/// (root cause: gas estimation on the public RPC undersized this large nested CREATE2 deployment --
/// confirmed by comparing local dry-run simulation, which always succeeds using exact gas, against the
/// real broadcast; forge script does not abort the remaining queued transactions when one fails, so
/// every downstream call -- addReserve, SolvencyRegistry, setSolvencyRegistry -- silently proceeded
/// referencing a spoke address with no code). This redeploys just the Spoke instance batch (fresh
/// salt), rewires its roles, re-adds the demo reserve against the REAL spoke, deploys a fresh
/// SolvencyRegistry (SPOKE is immutable, so the old instance cannot be repointed), and re-points the
/// spoke at it.
contract FixSpokeInstance is Script {
  address public spoke;
  address public spokeImplementation;
  address public aaveOracle;
  uint256 public reserveId;
  address public solvencyRegistry;

  function run() external {
    address accessManager = vm.envAddress('ACCESS_MANAGER');
    address hub = vm.envAddress('HUB');
    address hubConfigurator = vm.envAddress('HUB_CONFIGURATOR');
    address spokeConfigurator = vm.envAddress('SPOKE_CONFIGURATOR');
    address irStrategy = vm.envAddress('IR_STRATEGY');
    address treasurySpoke = vm.envAddress('TREASURY_SPOKE');
    address demoAsset = vm.envAddress('DEMO_ASSET');
    address demoPriceFeed = vm.envAddress('DEMO_PRICE_FEED');

    vm.startBroadcast();
    (, address deployer, ) = vm.readCallers();

    _deploySpokeInstance(deployer, accessManager);
    _setupRoles(accessManager);
    _reAddReserve(hub, hubConfigurator, spokeConfigurator, irStrategy, treasurySpoke, demoAsset, demoPriceFeed);
    _deployAndWireSolvencyRegistry(accessManager);

    vm.stopBroadcast();

    require(spoke.code.length > 0, 'spoke still has no code');
    require(aaveOracle.code.length > 0, 'aaveOracle still has no code');
    require(solvencyRegistry.code.length > 0, 'solvencyRegistry has no code');
    require(ISpoke(spoke).solvencyRegistry() == solvencyRegistry, 'spoke pointer mismatch');

    console.log('spoke', spoke);
    console.log('spokeImplementation', spokeImplementation);
    console.log('aaveOracle', aaveOracle);
    console.log('reserveId', reserveId);
    console.log('solvencyRegistry', solvencyRegistry);
    console.log('OK: spoke.solvencyRegistry() matches, both have real code');
  }

  function _deploySpokeInstance(address deployer, address accessManager) internal {
    bytes32 salt = keccak256(abi.encodePacked('aave-v4-mpc-solvency-demo-spoke-fix', block.timestamp));

    AaveV4SpokeInstanceBatch batch = new AaveV4SpokeInstanceBatch({
      proxyAdminOwner_: deployer,
      authority_: accessManager,
      spokeBytecode_: BytecodeHelper.getSpokeBytecode(),
      oracleDecimals_: DeployConstants.ORACLE_DECIMALS,
      maxUserReservesLimit_: DeployConstants.MAX_ALLOWED_USER_RESERVES_LIMIT,
      salt_: salt
    });

    spoke = batch.getReport().spokeProxy;
    spokeImplementation = batch.getReport().spokeImplementation;
    aaveOracle = batch.getReport().aaveOracle;

    console.log('deployed spoke', spoke);
    console.log('deployed aaveOracle', aaveOracle);
  }

  function _setupRoles(address accessManager) internal {
    AaveV4SpokeRolesProcedure.setupSpokeAllRoles({accessManager: accessManager, spoke: spoke});
  }

  function _reAddReserve(
    address hub,
    address hubConfigurator,
    address spokeConfigurator,
    address irStrategy,
    address treasurySpoke,
    address demoAsset,
    address demoPriceFeed
  ) internal {
    // addAsset was already correctly executed against the (unaffected) real Hub in the original
    // broadcast; the Hub side is fine. Only addReserve (which targeted the fake spoke) needs redoing.
    // assetId is deterministic (first asset added to this Hub) -- reconfirmed via getReserve below.
    reserveId = ISpokeConfigurator(spokeConfigurator).addReserve({
      spoke: spoke,
      hub: hub,
      assetId: 0,
      priceSource: demoPriceFeed,
      config: ISpoke.ReserveConfig({
        collateralRisk: 15_00,
        paused: false,
        frozen: false,
        borrowable: true,
        receiveSharesEnabled: true
      }),
      dynamicConfig: ISpoke.DynamicReserveConfig({
        collateralFactor: 80_00,
        maxLiquidationBonus: 105_00,
        liquidationFee: 10_00
      })
    });

    // Sanity: confirm the reserve's underlying really is our demo asset, on the real spoke.
    require(
      ISpoke(spoke).getReserve(reserveId).underlying == demoAsset,
      'reserve underlying mismatch'
    );
  }

  function _deployAndWireSolvencyRegistry(address accessManager) internal {
    address[] memory nodes = new address[](3);
    nodes[0] = vm.envAddress('NODE0_ADDRESS');
    nodes[1] = vm.envAddress('NODE1_ADDRESS');
    nodes[2] = vm.envAddress('NODE2_ADDRESS');
    bytes32[] memory nodeCertRefs = new bytes32[](3);
    nodeCertRefs[0] = keccak256('node0-cert-ref-demo');
    nodeCertRefs[1] = keccak256('node1-cert-ref-demo');
    nodeCertRefs[2] = keccak256('node2-cert-ref-demo');

    solvencyRegistry = address(
      new SolvencyRegistry({
        authority_: accessManager,
        spoke_: spoke,
        initialParticipants_: nodes,
        initialCertificateRefs_: nodeCertRefs,
        sessionTimeoutSeconds_: 1200,
        approvalValiditySeconds_: 3600
      })
    );

    ISpoke(spoke).setSolvencyRegistry(solvencyRegistry);
  }
}
