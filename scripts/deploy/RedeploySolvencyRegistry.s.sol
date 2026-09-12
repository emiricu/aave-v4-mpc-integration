// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';
import {console2 as console} from 'forge-std/console2.sol';

import {ISpoke} from 'src/spoke/interfaces/ISpoke.sol';
import {SolvencyRegistry} from 'src/spoke/SolvencyRegistry.sol';

/// @notice Minimal redeploy: SPOKE is immutable on SolvencyRegistry, so the existing (already
/// working, unrelated to this change) Spoke/Hub/reserve deployment cannot be repointed in place --
/// only a fresh SolvencyRegistry can pick up the new revealTargetBlockOffset_ constructor param.
/// Does NOT touch Spoke/Hub/reserve at all (unlike FixSpokeInstance.s.sol, which redeployed the
/// whole spoke instance for an unrelated bug) -- only deploys the new registry and re-points the
/// EXISTING spoke at it via setSolvencyRegistry.
contract RedeploySolvencyRegistry is Script {
  address public solvencyRegistry;

  function run() external {
    address accessManager = vm.envAddress('ACCESS_MANAGER');
    address spoke = vm.envAddress('SPOKE');

    address[] memory nodes = new address[](3);
    nodes[0] = vm.envAddress('NODE0_ADDRESS');
    nodes[1] = vm.envAddress('NODE1_ADDRESS');
    nodes[2] = vm.envAddress('NODE2_ADDRESS');
    bytes32[] memory nodeCertRefs = new bytes32[](3);
    nodeCertRefs[0] = keccak256('node0-cert-ref-demo');
    nodeCertRefs[1] = keccak256('node1-cert-ref-demo');
    nodeCertRefs[2] = keccak256('node2-cert-ref-demo');

    vm.startBroadcast();

    solvencyRegistry = address(
      new SolvencyRegistry({
        authority_: accessManager,
        spoke_: spoke,
        initialParticipants_: nodes,
        initialCertificateRefs_: nodeCertRefs,
        sessionTimeoutSeconds_: 1200,
        approvalValiditySeconds_: 3600,
        revealTargetBlockOffset_: 60
      })
    );

    ISpoke(spoke).setSolvencyRegistry(solvencyRegistry);

    vm.stopBroadcast();

    require(solvencyRegistry.code.length > 0, 'solvencyRegistry has no code');
    require(ISpoke(spoke).solvencyRegistry() == solvencyRegistry, 'spoke pointer mismatch');

    console.log('solvencyRegistry', solvencyRegistry);
    console.log('OK: spoke.solvencyRegistry() matches new registry, has real code');
  }
}
