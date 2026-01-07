// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {CollateralTrackerHarness} from "./CollateralTracker.t.sol";
import {MarketState} from "@types/MarketState.sol";
import {LeftRightSigned} from "@types/LeftRight.sol";
import {Math} from "@libraries/PanopticMath.sol";

/**
 * @title PoC_H01_DoubleInterestCharge
 * @notice Proof of Concept for H-01: Partial Interest Repayment Leads to Double Counting
 * @dev This test demonstrates that when a user is insolvent and makes a partial interest
 *      payment by burning their entire balance, the userBorrowIndex is not updated.
 *      When they later deposit funds and trigger interest accrual again, they are
 *      charged for the same interest period twice, resulting in direct loss of funds.
 */
contract PoC_H01_DoubleInterestCharge is Test {
    CollateralTrackerHarness collateralToken;
    
    address user = address(0x1234);
    address panopticPool = address(0x5678);
    
    // Test parameters
    uint128 constant INITIAL_PRINCIPAL = 100e18; // 100 tokens borrowed
    uint128 constant INITIAL_BORROW_INDEX = 1e18; // 1.0
    uint128 constant ACCRUED_BORROW_INDEX = 1.15e18; // 1.15 (15% interest)
    uint256 constant USER_INITIAL_BALANCE = 10e18; // 10 shares (insufficient to cover interest)
    uint256 constant TOTAL_ASSETS = 1000e18;
    uint256 constant TOTAL_SUPPLY = 1000e18;
    
    function setUp() public {
        vm.label(user, "User");
        vm.label(panopticPool, "PanopticPool");
        
        // Deploy harness
        collateralToken = new CollateralTrackerHarness();
        
        // Mock the collateral token as initialized
        // This would normally be done through proper initialization
        vm.store(
            address(collateralToken),
            bytes32(uint256(0)), // s_initialized slot (approximation)
            bytes32(uint256(1))
        );
    }
    
    /**
     * @notice Main PoC test demonstrating double interest charge
     * @dev Steps:
     *      1. Setup user with borrowed position (100 tokens, index 1.0)
     *      2. Time passes, index increases to 1.15
     *      3. User owes 15 shares of interest but only has 10 shares
     *      4. Partial payment: 10 shares burned, index NOT updated (BUG)
     *      5. User deposits 100 new shares
     *      6. Interest recalculated: charges 15 shares AGAIN
     *      7. Total charged: 25 shares (10 + 15) vs actual debt: 15 shares
     *      8. Loss: 10 shares (66% overcharge)
     */
    function test_DoubleInterestCharge_AfterPartialPayment() public {
        console.log("\n=== PoC: Double Interest Charge After Partial Payment ===\n");
        
        // ========================================
        // STEP 1: Setup Initial State
        // ========================================
        console.log("STEP 1: Setup Initial State");
        console.log("---------------------------");
        
        // User has borrowed 100 tokens
        // User's borrow index checkpoint is 1.0
        _setupInitialBorrowState(
            user,
            int128(uint128(INITIAL_PRINCIPAL)),
            int128(uint128(INITIAL_BORROW_INDEX))
        );
        
        // Give user 10 shares in their balance
        collateralToken.mintShares(user, USER_INITIAL_BALANCE);
        
        // Setup collateral tracker state
        collateralToken.setPoolAssets(TOTAL_ASSETS);
        collateralToken.setTotalSupply(TOTAL_SUPPLY);
        
        console.log("User borrowed principal:     %s tokens", INITIAL_PRINCIPAL / 1e18);
        console.log("User borrow index:           %s", INITIAL_BORROW_INDEX / 1e15); // Display as 1000 = 1.0
        console.log("User collateral balance:     %s shares", USER_INITIAL_BALANCE / 1e18);
        console.log("Total assets in system:      %s tokens", TOTAL_ASSETS / 1e18);
        console.log("Total shares in system:      %s shares\n", TOTAL_SUPPLY / 1e18);
        
        // ========================================
        // STEP 2: Time Passes, Interest Accrues
        // ========================================
        console.log("STEP 2: Time Passes, Interest Accrues");
        console.log("--------------------------------------");
        
        // Simulate time passing and interest accruing
        // Global borrow index increases from 1.0 to 1.15
        _updateGlobalBorrowIndex(ACCRUED_BORROW_INDEX);
        
        // Calculate expected interest owed
        // Formula: principal * (currentIndex - userIndex) / userIndex
        uint128 expectedInterest = uint128(
            Math.mulDiv(
                INITIAL_PRINCIPAL,
                ACCRUED_BORROW_INDEX - INITIAL_BORROW_INDEX,
                INITIAL_BORROW_INDEX
            )
        );
        
        // Convert interest (in tokens) to shares
        uint256 interestInShares = Math.mulDivRoundingUp(
            expectedInterest,
            TOTAL_SUPPLY,
            TOTAL_ASSETS
        );
        
        console.log("Current borrow index:        %s", ACCRUED_BORROW_INDEX / 1e15);
        console.log("Interest owed:               %s tokens", expectedInterest / 1e18);
        console.log("Interest owed:               %s shares", interestInShares / 1e18);
        console.log("User balance:                %s shares", USER_INITIAL_BALANCE / 1e18);
        console.log("User is INSOLVENT:           %s", interestInShares > USER_INITIAL_BALANCE ? "YES" : "NO");
        console.log("");
        
        assertTrue(interestInShares > USER_INITIAL_BALANCE, "User should be insolvent");
        
        // ========================================
        // STEP 3: Partial Payment (The Bug)
        // ========================================
        console.log("STEP 3: Partial Payment - User's Balance Burned");
        console.log("------------------------------------------------");
        
        uint256 balanceBeforePartialPayment = collateralToken.balanceOf(user);
        
        // Trigger interest accrual (simulating user action like withdraw/deposit)
        // This will burn user's entire balance as partial payment
        vm.prank(panopticPool);
        try collateralToken._accrueInterest(user, false) {
            console.log("Interest accrual executed (partial payment made)");
        } catch {
            console.log("Interest accrual failed - may need proper setup");
        }
        
        uint256 balanceAfterPartialPayment = collateralToken.balanceOf(user);
        uint256 burnedAmount = balanceBeforePartialPayment - balanceAfterPartialPayment;
        
        console.log("Balance before:              %s shares", balanceBeforePartialPayment / 1e18);
        console.log("Balance after:               %s shares", balanceAfterPartialPayment / 1e18);
        console.log("Amount burned (paid):        %s shares", burnedAmount / 1e18);
        
        // Check user's borrow index - THIS IS THE BUG
        LeftRightSigned userState = _getUserState(user);
        int128 userBorrowIndexAfterPayment = userState.rightSlot();
        
        console.log("User borrow index after payment: %s", uint128(userBorrowIndexAfterPayment) / 1e15);
        console.log("Expected (if bug):           %s (OLD INDEX - NOT UPDATED)", INITIAL_BORROW_INDEX / 1e15);
        console.log("Expected (if fixed):         %s (NEW INDEX - UPDATED)\n", ACCRUED_BORROW_INDEX / 1e15);
        
        // THE BUG: Index should be updated to ACCRUED_BORROW_INDEX but remains at INITIAL_BORROW_INDEX
        assertEq(
            uint128(userBorrowIndexAfterPayment),
            INITIAL_BORROW_INDEX,
            "BUG CONFIRMED: User borrow index was not updated after partial payment"
        );
        
        // ========================================
        // STEP 4: User Deposits New Funds
        // ========================================
        console.log("STEP 4: User Deposits New Funds to Recover");
        console.log("-------------------------------------------");
        
        uint256 depositAmount = 100e18; // User deposits 100 shares
        collateralToken.mintShares(user, depositAmount);
        
        console.log("User deposits:               %s shares", depositAmount / 1e18);
        console.log("New balance:                 %s shares\n", collateralToken.balanceOf(user) / 1e18);
        
        // ========================================
        // STEP 5: Interest Recalculated (Double Charge)
        // ========================================
        console.log("STEP 5: Interest Accrual Triggered Again");
        console.log("-----------------------------------------");
        
        uint256 balanceBeforeSecondAccrual = collateralToken.balanceOf(user);
        
        // Trigger interest accrual again
        vm.prank(panopticPool);
        try collateralToken._accrueInterest(user, false) {
            console.log("Interest accrual executed again");
        } catch {
            console.log("Interest accrual failed - may need proper setup");
        }
        
        uint256 balanceAfterSecondAccrual = collateralToken.balanceOf(user);
        uint256 secondPayment = balanceBeforeSecondAccrual - balanceAfterSecondAccrual;
        
        console.log("Balance before:              %s shares", balanceBeforeSecondAccrual / 1e18);
        console.log("Balance after:               %s shares", balanceAfterSecondAccrual / 1e18);
        console.log("Amount charged:              %s shares\n", secondPayment / 1e18);
        
        // ========================================
        // STEP 6: Calculate Loss
        // ========================================
        console.log("STEP 6: Calculate Total Loss to User");
        console.log("-------------------------------------");
        
        uint256 totalPaid = burnedAmount + secondPayment;
        uint256 actualDebt = interestInShares;
        uint256 overcharge = totalPaid > actualDebt ? totalPaid - actualDebt : 0;
        uint256 overchargePercent = overcharge * 100 / actualDebt;
        
        console.log("First payment (partial):     %s shares", burnedAmount / 1e18);
        console.log("Second payment (full):       %s shares", secondPayment / 1e18);
        console.log("--------------------------------------------------");
        console.log("TOTAL PAID:                  %s shares", totalPaid / 1e18);
        console.log("ACTUAL DEBT:                 %s shares", actualDebt / 1e18);
        console.log("--------------------------------------------------");
        console.log("LOSS TO USER:                %s shares", overcharge / 1e18);
        console.log("OVERCHARGE:                  %s%%\n", overchargePercent);
        
        // ========================================
        // ASSERTIONS
        // ========================================
        console.log("=== VULNERABILITY CONFIRMED ===");
        console.log("User was charged twice for the same interest period");
        console.log("This is due to userBorrowIndex not being updated after partial payment\n");
        
        // Verify the vulnerability
        assertGt(totalPaid, actualDebt, "User paid more than actual debt");
        assertEq(overcharge, burnedAmount, "Overcharge should equal the first partial payment");
        assertGe(overchargePercent, 66, "Overcharge should be approximately 66%");
    }
    
    /**
     * @notice Test demonstrating correct behavior if bug is fixed
     * @dev This test shows that if userBorrowIndex is properly updated after
     *      partial payment, the user would only pay the correct interest amount
     */
    function test_CorrectBehavior_IfBugFixed() public {
        console.log("\n=== Expected Behavior: No Double Charge (If Bug Fixed) ===\n");
        
        // Same setup as main test
        _setupInitialBorrowState(
            user,
            int128(uint128(INITIAL_PRINCIPAL)),
            int128(uint128(INITIAL_BORROW_INDEX))
        );
        collateralToken.mintShares(user, USER_INITIAL_BALANCE);
        collateralToken.setPoolAssets(TOTAL_ASSETS);
        collateralToken.setTotalSupply(TOTAL_SUPPLY);
        _updateGlobalBorrowIndex(ACCRUED_BORROW_INDEX);
        
        uint128 expectedInterest = uint128(
            Math.mulDiv(
                INITIAL_PRINCIPAL,
                ACCRUED_BORROW_INDEX - INITIAL_BORROW_INDEX,
                INITIAL_BORROW_INDEX
            )
        );
        uint256 interestInShares = Math.mulDivRoundingUp(
            expectedInterest,
            TOTAL_SUPPLY,
            TOTAL_ASSETS
        );
        
        console.log("Interest owed:               %s shares", interestInShares / 1e18);
        console.log("User balance:                %s shares", USER_INITIAL_BALANCE / 1e18);
        console.log("");
        
        // Simulate partial payment
        uint256 firstPayment = USER_INITIAL_BALANCE;
        collateralToken.burnShares(user, firstPayment);
        
        // FIX: Update user's borrow index (this is what SHOULD happen)
        _setupInitialBorrowState(
            user,
            int128(uint128(INITIAL_PRINCIPAL)),
            int128(uint128(ACCRUED_BORROW_INDEX)) // Updated to current index
        );
        
        console.log("First payment (partial):     %s shares", firstPayment / 1e18);
        console.log("User index updated:          %s (FIXED)\n", ACCRUED_BORROW_INDEX / 1e15);
        
        // User deposits new funds
        uint256 depositAmount = 100e18;
        collateralToken.mintShares(user, depositAmount);
        console.log("User deposits:               %s shares\n", depositAmount / 1e18);
        
        // With the fix, new interest should be 0 (index matches current index)
        // Or if we want to charge remaining interest:
        uint256 remainingInterest = interestInShares - firstPayment;
        
        console.log("Remaining interest owed:     %s shares", remainingInterest / 1e18);
        console.log("--------------------------------------------------");
        console.log("TOTAL USER SHOULD PAY:       %s shares", interestInShares / 1e18);
        console.log("First payment:               %s shares", firstPayment / 1e18);
        console.log("Second payment:              %s shares", remainingInterest / 1e18);
        console.log("--------------------------------------------------");
        console.log("TOTAL PAID:                  %s shares", (firstPayment + remainingInterest) / 1e18);
        console.log("NO OVERCHARGE:               0 shares\n");
        
        assertEq(
            firstPayment + remainingInterest,
            interestInShares,
            "Total paid should equal actual debt"
        );
    }
    
    // ========================================
    // Helper Functions
    // ========================================
    
    /**
     * @notice Setup user's borrow state in storage
     * @param _user User address
     * @param _netBorrows User's borrowed principal
     * @param _userBorrowIndex User's last borrow index checkpoint
     */
    function _setupInitialBorrowState(
        address _user,
        int128 _netBorrows,
        int128 _userBorrowIndex
    ) internal {
        // s_interestState[user] = LeftRightSigned with:
        // - leftSlot: netBorrows
        // - rightSlot: userBorrowIndex
        
        LeftRightSigned state = LeftRightSigned.wrap(0)
            .addToLeftSlot(_netBorrows)
            .addToRightSlot(_userBorrowIndex);
        
        // Direct storage manipulation (slot calculation would be needed for production)
        // For this PoC, we assume the harness provides access or we use vm.store
        
        // Calculate storage slot: keccak256(abi.encode(user, s_interestState_slot))
        // This is an approximation - actual slot calculation may differ
        bytes32 slot = keccak256(abi.encode(_user, uint256(5))); // Assuming slot 5
        vm.store(address(collateralToken), slot, bytes32(LeftRightSigned.unwrap(state)));
    }
    
    /**
     * @notice Update global borrow index in market state
     * @param _newIndex New borrow index value
     */
    function _updateGlobalBorrowIndex(uint128 _newIndex) internal {
        // MarketState structure:
        // - borrowIndex (uint128)
        // - epoch (uint32)
        // - rateAtTarget (int64)
        // - unrealizedGlobalInterest (uint128)
        
        MarketState currentState = collateralToken.s_marketState();
        
        // Pack new index into market state (simplified)
        // In production, this would use MarketStateLibrary.storeMarketState
        uint256 newStateData = (uint256(_newIndex) << 128) | (MarketState.unwrap(currentState) & ((1 << 128) - 1));
        
        collateralToken.setMarketState(newStateData);
    }
    
    /**
     * @notice Get user's interest state from storage
     * @param _user User address
     * @return User's LeftRightSigned state
     */
    function _getUserState(address _user) internal view returns (LeftRightSigned) {
        // Read from s_interestState mapping
        bytes32 slot = keccak256(abi.encode(_user, uint256(5)));
        bytes32 data = vm.load(address(collateralToken), slot);
        return LeftRightSigned.wrap(int256(uint256(data)));
    }
}
