// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "../src/ForkFlip.sol";

/// Deploys ForkFlip to Fork in Hood (chain 36754663) and seeds the bankroll in
/// the same transaction, so the contract is never live with nothing behind it.
///
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url https://rpc.forkinhood.com --broadcast
///
/// Reads from the environment:
///   PRIVATE_KEY  deployer key, also the initial owner unless OWNER is set
///   OWNER        optional, the address allowed to withdraw the bankroll
///   BANKROLL     initial house capital in wei         (default 100 ether)
///   EDGE_BPS     house edge in basis points, max 500  (default 200 = 1.98x)
///   MIN_BET      smallest accepted stake in wei       (default 0.01 ether)
///   MAX_BET      largest accepted stake in wei        (default 10 ether)
contract Deploy is Script {
    /// Public so a test can assert it still matches ForkFlip.MAX_EDGE_BPS.
    function flipMaxEdge() public pure returns (uint256) {
        return 500; // ForkFlip.MAX_EDGE_BPS, checked by test_deployScriptCapMatchesContract
    }

    function run() external returns (ForkFlip flip) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER", deployer);
        uint256 bankroll = vm.envOr("BANKROLL", uint256(100 ether));
        uint256 edge = vm.envOr("EDGE_BPS", uint256(200));
        uint256 minBet = vm.envOr("MIN_BET", uint256(0.01 ether));
        uint256 maxBet = vm.envOr("MAX_BET", uint256(10 ether));

        require(deployer.balance >= bankroll, "deployer cannot fund that bankroll");
        // Checked before the cast, not after: uint16(65736) is 200, which would
        // deploy at an edge nobody asked for instead of reverting.
        require(edge <= flipMaxEdge(), "EDGE_BPS above the contract's cap");

        vm.startBroadcast(pk);
        flip = new ForkFlip{value: bankroll}(owner, uint16(edge), minBet, maxBet);
        vm.stopBroadcast();

        console2.log("ForkFlip     ", address(flip));
        console2.log("owner        ", owner);
        console2.log("bankroll wei ", bankroll);
        console2.log("edge bps     ", edge);
        console2.log("");
        console2.log("Set CFG.contract in index.html to the address above.");
    }
}
