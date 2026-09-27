// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';
import {console2 as console} from 'forge-std/console2.sol';

import {InputUtils} from 'src/deployments/utils/libraries/InputUtils.sol';
import {OrchestrationReports} from 'src/deployments/libraries/OrchestrationReports.sol';
import {AaveV4DeployOrchestration} from 'src/deployments/orchestration/AaveV4DeployOrchestration.sol';
import {BytecodeHelper} from 'src/deployments/utils/libraries/BytecodeHelper.sol';
import {MetadataLogger} from 'src/deployments/utils/MetadataLogger.sol';
import {Roles} from 'src/deployments/utils/libraries/Roles.sol';

import {IAccessManager} from 'src/dependencies/openzeppelin/IAccessManager.sol';
import {WETH9} from 'src/dependencies/weth/WETH9.sol';
import {IHubConfigurator} from 'src/hub/interfaces/IHubConfigurator.sol';
import {ISpokeConfigurator} from 'src/spoke/interfaces/ISpokeConfigurator.sol';
import {ISpoke} from 'src/spoke/interfaces/ISpoke.sol';
import {IAssetInterestRateStrategy} from 'src/hub/AssetInterestRateStrategy.sol';
import {IAaveOracle} from 'src/spoke/interfaces/IAaveOracle.sol';

import {SolvencyRegistry} from 'src/spoke/SolvencyRegistry.sol';

import {MockERC20} from 'tests/helpers/mocks/MockERC20.sol';
import {MockPriceFeed} from 'tests/helpers/mocks/MockPriceFeed.sol';

/// @title AaveV4DeploySepoliaDemo
/// @notice Thesis demo deploy script: a minimal Aave V4 instance (1 Hub, 1 Spoke, no gateways, no
/// position managers -- callers act as their own position manager, the ISpoke default) on Sepolia,
/// extended with SolvencyRegistry (the MPC consortium commit-reveal gate, see
/// docs/solvency-mpc-integration.md) wired into the Spoke, plus one mock reserve (MockERC20 +
/// MockPriceFeed, same pattern already used throughout this repo's own test suite) so the demo has
/// something to supply/borrow. Not part of the thesis-scoped Solidity deliverable itself -- purely
/// operational tooling to stand up a live, inspectable demo.
contract AaveV4DeploySepoliaDemo is Script {
  uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
  string internal constant OUTPUT_DIR = 'output/reports/deployments/';

  // Deployed addresses, kept as contract storage (not function-local variables) specifically to avoid
  // "stack too deep" -- this script isn't compiled with via-ir (only src/hub|spoke/instances/*.sol are,
  // see foundry.toml), and the full deploy flow has too many simultaneously-live values for the EVM's
  // 16-slot local stack otherwise.
  address public accessManager;
  address public hub;
  address public irStrategy;
  address public spoke;
  address public aaveOracle;
  address public hubConfigurator;
  address public spokeConfigurator;
  address public treasurySpoke;
  address public demoAsset;
  address public demoPriceFeed;
  uint256 public reserveId;
  address public solvencyRegistry;
  address public deployer;

  function run() external {
    require(block.chainid == SEPOLIA_CHAIN_ID, 'expected Sepolia (11155111)');

    vm.createDir(OUTPUT_DIR, true);
    MetadataLogger logger = new MetadataLogger(OUTPUT_DIR);

    vm.startBroadcast();
    (, deployer, ) = vm.readCallers();

    _deployCore(logger);
    _deployMockReserve();
    _deploySolvencyRegistry();

    vm.stopBroadcast();

    console.log('--- deploy complete ---');
    console.log('chainId', block.chainid);
    console.log('deployer', deployer);
  }

  function _deployCore(MetadataLogger logger) internal {
    address weth = address(new WETH9());

    string[] memory hubLabels = new string[](1);
    hubLabels[0] = 'demo';
    string[] memory spokeLabels = new string[](1);
    spokeLabels[0] = 'demo';

    InputUtils.FullDeployInputs memory inputs = InputUtils.FullDeployInputs({
      accessManagerAdmin: deployer,
      proxyAdminOwner: deployer,
      hubAdmin: deployer,
      hubConfiguratorAdmin: deployer,
      treasurySpokeOwner: deployer,
      spokeAdmin: deployer,
      spokeConfiguratorAdmin: deployer,
      gatewayOwner: deployer,
      positionManagerOwner: deployer,
      nativeWrapper: weth,
      deployNativeTokenGateway: false,
      deploySignatureGateway: false,
      deployPositionManagers: false,
      grantRoles: true,
      hubLabels: hubLabels,
      spokeLabels: spokeLabels,
      spokeMaxReservesLimits: new uint16[](0),
      salt: keccak256(abi.encodePacked('aave-v4-mpc-solvency-demo', block.timestamp, deployer))
    });

    OrchestrationReports.FullDeploymentReport memory report = AaveV4DeployOrchestration
      .deployAaveV4(
        logger,
        deployer,
        inputs,
        BytecodeHelper.getHubBytecode(),
        BytecodeHelper.getSpokeBytecode()
      );

    accessManager = report.authorityBatchReport.accessManager;
    hub = report.hubInstanceBatchReports[0].report.hubProxy;
    irStrategy = report.hubInstanceBatchReports[0].report.irStrategy;
    spoke = report.spokeInstanceBatchReports[0].report.spokeProxy;
    aaveOracle = report.spokeInstanceBatchReports[0].report.aaveOracle;
    hubConfigurator = report.configuratorBatchReport.hubConfigurator;
    spokeConfigurator = report.configuratorBatchReport.spokeConfigurator;
    treasurySpoke = report.treasurySpokeBatchReport.treasurySpoke;

    console.log('accessManager', accessManager);
    console.log('hub', hub);
    console.log('spoke', spoke);
    console.log('aaveOracle', aaveOracle);
    console.log('hubConfigurator', hubConfigurator);
    console.log('spokeConfigurator', spokeConfigurator);
  }

  function _deployMockReserve() internal {
    demoAsset = address(new MockERC20());
    demoPriceFeed = address(new MockPriceFeed(IAaveOracle(aaveOracle).decimals(), 'DEMO/USD', 1e8));

    IAssetInterestRateStrategy.InterestRateData memory irData = IAssetInterestRateStrategy
      .InterestRateData({
        optimalUsageRatio: 90_00,
        baseDrawnRate: 5_00,
        rateGrowthBeforeOptimal: 5_00,
        rateGrowthAfterOptimal: 5_00
      });

    uint256 assetId = IHubConfigurator(hubConfigurator).addAsset({
      hub: hub,
      underlying: demoAsset,
      feeReceiver: treasurySpoke,
      liquidityFee: 5_00,
      irStrategy: irStrategy,
      irData: abi.encode(irData)
    });

    reserveId = ISpokeConfigurator(spokeConfigurator).addReserve({
      spoke: spoke,
      hub: hub,
      assetId: assetId,
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

    console.log('demoAsset', demoAsset);
    console.log('demoPriceFeed', demoPriceFeed);
    console.log('reserveId', reserveId);
  }

  function _deploySolvencyRegistry() internal {
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

    // setSolvencyRegistry is wired to SPOKE_CONFIGURATOR_ROLE (see Roles.getSpokeConfiguratorRoleSelectors),
    // already granted to the deployer (spokeConfiguratorAdmin) by deployAaveV4 above (grantRoles: true).
    ISpoke(spoke).setSolvencyRegistry(solvencyRegistry);

    console.log('solvencyRegistry', solvencyRegistry);
  }
}
