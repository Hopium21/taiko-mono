// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../Layer1Test.sol";
import "./helpers/TierRouter_With4Tiers.sol";
import "./helpers/Verifier_ToggleStub.sol";

abstract contract TaikoL1Test is Layer1Test {
    bytes32 internal GENESIS_BLOCK_HASH = keccak256("GENESIS_BLOCK_HASH");

    TaikoToken internal bondToken;
    SignalService internal signalService;
    Bridge internal bridge;
    ITierRouter internal tierRouter;
    Verifier_ToggleStub internal tier1Verifier;
    Verifier_ToggleStub internal tier2Verifier;
    Verifier_ToggleStub internal tier3Verifier;
    Verifier_ToggleStub internal tier4Verifier;
    TaikoL1 internal taikoL1;
    uint16 minTierId;
    ITierProvider.Tier internal minTier;
    uint96 livenessBond;

    address internal tSignalService = randAddress();
    address internal taikoL2 = randAddress();

    function setUpOnEthereum() internal override {
        bondToken = deployBondToken();
        signalService = deploySignalService(address(new SignalService()));
        bridge = deployBridge(address(new Bridge()));
        tierRouter = deployTierRouter();
        tier1Verifier = deployVerifier("");
        tier2Verifier = deployVerifier("tier_2");
        tier3Verifier = deployVerifier("tier_3");
        tier4Verifier = deployVerifier("tier_4");
        taikoL1 = deployTaikoL1(getConfig());

        signalService.authorize(address(taikoL1), true);
        minTierId = tierProvider().getMinTier(address(0), 0);
        minTier = tierProvider().getTier(minTierId);
        livenessBond = taikoL1.getConfig().livenessBond;

        mineOneBlockAndWrap(12 seconds);
    }

    function setUpOnTaiko() internal override {
        register("taiko", taikoL2);
        register("signal_service", tSignalService);
    }

    function tierProvider() internal view returns (ITierProvider) {
        return ITierProvider(address(tierRouter));
    }

    // TODO: order and name mismatch
    function giveEthAndTko(address to, uint256 amountTko, uint256 amountEth) internal {
        vm.deal(to, amountEth);
        bondToken.transfer(to, amountTko);

        vm.prank(to);
        bondToken.approve(address(taikoL1), amountTko);

        console2.log("Bond balance :", to, bondToken.balanceOf(to));
        console2.log("Ether balance:", to, to.balance);
    }

    function proposeBlock(
        address proposer,
        bytes4 revertReason
    )
        internal
        returns (TaikoData.BlockMetadataV2 memory)
    {
        vm.prank(proposer);
        if (revertReason != "") vm.expectRevert(revertReason);
        return taikoL1.proposeBlockV2("", new bytes(10));
    }

    function proposeBlock(
        address proposer,
        TaikoData.BlockParamsV2 memory params,
        bytes4 revertReason
    )
        internal
        returns (TaikoData.BlockMetadataV2 memory)
    {
        vm.prank(proposer);
        if (revertReason != "") vm.expectRevert(revertReason);
        return taikoL1.proposeBlockV2(abi.encode(params), new bytes(10));
    }

    function proveBlock(
        address prover,
        TaikoData.BlockMetadataV2 memory meta,
        bytes32 parentHash,
        bytes32 blockHash,
        bytes32 stateRoot,
        uint16 tierId,
        bytes4 revertReason
    )
        internal
    {
        TaikoData.Transition memory tran = TaikoData.Transition({
            parentHash: parentHash,
            blockHash: blockHash,
            stateRoot: stateRoot,
            graffiti: 0x0
        });

        TaikoData.TierProof memory proof;
        proof.tier = tierId;
        proof.data = "proofdata";

        if (revertReason != "") vm.expectRevert(revertReason);
        vm.prank(prover);
        taikoL1.proveBlock(meta.id, abi.encode(meta, tran, proof));
    }

    function getBondTokenBalance(address user) internal view returns (uint256) {
        return bondToken.balanceOf(user) + taikoL1.bondBalanceOf(user);
    }

    function printBlockAndTrans(uint64 blockId) internal view {
        TaikoData.BlockV2 memory blk = taikoL1.getBlockV2(blockId);
        printBlock(blk);

        for (uint32 i = 1; i < blk.nextTransitionId; ++i) {
            printTran(i, taikoL1.getTransition(blockId, i));
        }
    }

    function printStateVariables(string memory label) internal view {
        (TaikoData.SlotA memory a, TaikoData.SlotB memory b) = taikoL1.getStateVariables();
        console2.log("\n==================", label);
        console2.log("---CHAIN:");
        console2.log(" | lastSyncedBlockId:", a.lastSyncedBlockId);
        console2.log(" | lastSynecdAt:", a.lastSynecdAt);
        console2.log(" | lastVerifiedBlockId:", b.lastVerifiedBlockId);
        console2.log(" | numBlocks:", b.numBlocks);
        console2.log(" | lastProposedIn:", b.lastProposedIn);
        console2.log(" | timestamp:", block.timestamp);
    }

    function printBlock(TaikoData.BlockV2 memory blk) internal view {
        printStateVariables("");
        console2.log("---BLOCK#", blk.blockId);
        console2.log(" | proposedAt:", blk.proposedAt);
        console2.log(" | proposedIn:", blk.proposedIn);
        console2.log(" | metaHash:", vm.toString(blk.metaHash));
        console2.log(" | nextTransitionId:", blk.nextTransitionId);
        console2.log(" | verifiedTransitionId:", blk.verifiedTransitionId);
    }

    function printTran(uint64 tid, TaikoData.TransitionState memory ts) internal pure {
        console2.log(" |---TRANSITION#", tid);
        console2.log("   | tier:", ts.tier);
        console2.log("   | prover:", ts.prover);
        console2.log("   | validityBond:", ts.validityBond);
        console2.log("   | contester:", ts.contester);
        console2.log("   | contestBond:", ts.contestBond);
        console2.log("   | timestamp:", ts.timestamp);
        console2.log("   | key (parentHash):", vm.toString(ts.key));
        console2.log("   | blockHash:", vm.toString(ts.blockHash));
        console2.log("   | stateRoot:", vm.toString(ts.stateRoot));
    }

    function deployTierRouter() internal returns (ITierRouter tierRouter_) {
        tierRouter_ = new TierRouter_With4Tiers();
        register("tier_router", address(tierRouter_));
    }

    function deployTaikoL1(TaikoData.Config memory config) internal returns (TaikoL1) {
        return TaikoL1(
            deploy({
                name: "taiko",
                impl: address(new TaikoL1WithConfig()),
                data: abi.encodeCall(
                    TaikoL1WithConfig.initWithConfig,
                    (address(0), address(resolver), GENESIS_BLOCK_HASH, false, config)
                )
            })
        );
    }

    function deployVerifier(bytes32 name) internal returns (Verifier_ToggleStub verifier) {
        verifier = new Verifier_ToggleStub();
        register(name, address(verifier));
    }

    function getConfig() internal view virtual returns (TaikoData.Config memory) {
        return TaikoData.Config({
            chainId: taikoChainId,
            blockMaxProposals: 20,
            blockRingBufferSize: 25,
            maxBlocksToVerify: 16,
            blockMaxGasLimit: 240_000_000,
            livenessBond: 125e18,
            stateRootSyncInternal: 2,
            maxAnchorHeightOffset: 64,
            baseFeeConfig: LibSharedData.BaseFeeConfig({
                adjustmentQuotient: 8,
                sharingPctg: 75,
                gasIssuancePerSecond: 5_000_000,
                minGasExcess: 1_340_000_000, // correspond to 0.008847185 gwei basefee
                maxGasIssuancePerBlock: 600_000_000 // two minutes: 5_000_000 * 120
             }),
            ontakeForkHeight: 0 // or 1
         });
    }
}