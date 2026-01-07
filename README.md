# Code4rena Audit Report: Panoptic V1 - H-01 Double Interest Charge

## 🎯 Quick Summary

**Finding**: Partial Interest Repayment Leads to Double Counting of Interest  
**Severity**: HIGH  
**Component**: `CollateralTracker.sol::_accrueInterest()`  
**Repository**: [code-423n4/2025-12-panoptic](https://github.com/code-423n4/2025-12-panoptic)  
**Date**: January 6, 2026

---

## 📋 Table of Contents

1. [Executive Summary](#executive-summary)
2. [Vulnerability Details](#vulnerability-details)
3. [Proof of Concept](#proof-of-concept)
4. [Impact Analysis](#impact-analysis)
5. [Recommended Fix](#recommended-fix)
6. [Running the PoC](#running-the-poc)
7. [Additional Resources](#additional-resources)

---

## Executive Summary

### The Bug in Plain English

When a user cannot afford to pay their full interest (they are "insolvent"), the Panoptic protocol burns their entire collateral balance as a partial payment. However, the protocol **does not update the user's interest checkpoint** (`userBorrowIndex`). 

This means when the user later deposits funds and triggers interest accrual again, the protocol recalculates interest from the **old checkpoint** - effectively charging them for the **same time period twice**.

**Result**: Users pay their partial payment amount PLUS the full interest amount = massive overcharge.

### Quick Example

```
1. User borrows 100 tokens
2. Interest accrues: 15 tokens owed
3. User only has 10 tokens → INSOLVENT
4. Protocol burns user's 10 tokens as partial payment ✅
5. Protocol DOES NOT update checkpoint ❌ (THE BUG)
6. User deposits 100 tokens later
7. Protocol recalculates: "You owe 15 tokens" (same as before!)
8. Total paid: 10 + 15 = 25 tokens
9. Actual debt: 15 tokens
10. User loses 10 tokens (66% overcharge)
```

---

## Vulnerability Details

### Affected Code

**File**: `contracts/CollateralTracker.sol`  
**Function**: `_accrueInterest(address owner, bool isDeposit)`  
**Lines**: 916-942

```solidity
if (shares > userBalance) {
    if (!isDeposit) {
        // Calculate partial payment value
        burntInterestValue = Math
            .mulDiv(userBalance, _totalAssets, totalSupply())
            .toUint128();

        emit InsolvencyPenaltyApplied(
            owner,
            userInterestOwed,
            burntInterestValue,
            userBalance
        );

        /// Insolvent case: Pay what you can
        _burn(_owner, userBalance);

        /// @dev DO NOT update index. By keeping the user's old baseIndex, 
        /// their debt continues to compound correctly from the original point in time.
        userBorrowIndex = userState.rightSlot(); // ❌ KEEPS OLD INDEX - THIS IS THE BUG
    } else {
        // Deposit path: also keeps old index
        burntInterestValue = 0;
        userBorrowIndex = userState.rightSlot(); // ❌ SAME BUG
    }
} else {
    // Solvent case: Pay in full
    _burn(_owner, shares);
    // userBorrowIndex is correctly updated to currentBorrowIndex at line 897 ✅
}
```

### Why The Comment Is Wrong

The code comment states:
> "By keeping the user's old baseIndex, their debt continues to compound correctly from the original point in time."

This would be correct **IF NO PAYMENT WAS MADE**. However:
- ✅ A payment WAS made (shares were burned)
- ✅ `burntInterestValue` correctly tracks the payment
- ❌ But the index is not updated, so the protocol "forgets" the payment
- ❌ Future interest is calculated as if no payment occurred

### Root Cause

The protocol has a logical inconsistency:
1. **Action**: User pays partial interest by burning shares
2. **Accounting**: Protocol tracks payment in `burntInterestValue`
3. **State Update**: Protocol DOES NOT update `userBorrowIndex`
4. **Result**: Next accrual recalculates interest from old checkpoint

This violates the fundamental lending protocol invariant:
> **Payment + Index Update = Debt Reduction**

---

## Proof of Concept

### Files Included

1. **`BUG_ANALYSIS.md`** - Comprehensive technical analysis with mathematical proofs
2. **`test/foundry/core/PoC_H01_DoubleInterestCharge.t.sol`** - Full Foundry test suite
3. **`MITIGATION_STRATEGIES.md`** - Three detailed fix approaches with trade-offs
4. **`README.md`** - This file

### Test Overview

The PoC includes two main tests:

#### Test 1: Demonstrates The Bug
```solidity
function test_DoubleInterestCharge_AfterPartialPayment() public
```

**What it does:**
1. ✅ Setup user with 100 token borrow, index 1.0
2. ✅ Time passes, index increases to 1.15
3. ✅ User owes 15 shares, has only 10 shares
4. ✅ Partial payment: burns 10 shares
5. ❌ **BUG**: Index remains at 1.0 (not updated to 1.15)
6. ✅ User deposits 100 new shares
7. ❌ **DOUBLE CHARGE**: Interest recalculated as 15 shares (from 1.0 to 1.15)
8. 💰 **LOSS**: Total paid 25 shares vs actual debt 15 shares = 10 share loss (66% overcharge)

#### Test 2: Shows Correct Behavior
```solidity
function test_CorrectBehavior_IfBugFixed() public
```

**What it does:**
- Same setup as Test 1
- BUT: manually updates `userBorrowIndex` after partial payment
- Result: User only pays 15 shares total (10 partial + 5 remaining)
- No overcharge

### Console Output Example

```
=== PoC: Double Interest Charge After Partial Payment ===

STEP 1: Setup Initial State
---------------------------
User borrowed principal:     100 tokens
User borrow index:           1000 (1.0)
User collateral balance:     10 shares
Total assets in system:      1000 tokens
Total shares in system:      1000 shares

STEP 2: Time Passes, Interest Accrues
--------------------------------------
Current borrow index:        1150 (1.15)
Interest owed:               15 tokens
Interest owed:               15 shares
User balance:                10 shares
User is INSOLVENT:           YES

STEP 3: Partial Payment - User's Balance Burned
------------------------------------------------
Balance before:              10 shares
Balance after:               0 shares
Amount burned (paid):        10 shares
User borrow index after payment: 1000 (OLD INDEX - NOT UPDATED)
Expected (if bug):           1000 (OLD INDEX - NOT UPDATED)
Expected (if fixed):         1150 (NEW INDEX - UPDATED)

STEP 4: User Deposits New Funds to Recover
-------------------------------------------
User deposits:               100 shares
New balance:                 100 shares

STEP 5: Interest Accrual Triggered Again
-----------------------------------------
Balance before:              100 shares
Balance after:               85 shares
Amount charged:              15 shares

STEP 6: Calculate Total Loss to User
-------------------------------------
First payment (partial):     10 shares
Second payment (full):       15 shares
--------------------------------------------------
TOTAL PAID:                  25 shares
ACTUAL DEBT:                 15 shares
--------------------------------------------------
LOSS TO USER:                10 shares
OVERCHARGE:                  66%

=== VULNERABILITY CONFIRMED ===
User was charged twice for the same interest period
This is due to userBorrowIndex not being updated after partial payment
```

---

## Impact Analysis

### Severity Justification: HIGH

| Criteria | Assessment | Justification |
|----------|------------|---------------|
| **Likelihood** | MEDIUM | Happens naturally during high utilization or volatile markets. No malicious intent required. |
| **Impact** | HIGH | Direct, measurable loss of user funds. Can be 50-100% of partial payment amount. |
| **Affected Users** | MEDIUM | Any user who becomes insolvent and later deposits funds. |
| **Protocol Risk** | HIGH | Breaks core protocol invariant, damages user trust. |

### Financial Impact Examples

| Scenario | Partial Payment | Full Interest | Second Charge | Total Paid | Loss | Loss % |
|----------|----------------|---------------|---------------|------------|------|--------|
| Small Position | 10 shares | 15 shares | 15 shares | 25 shares | 10 shares | 66% |
| Medium Position | 50 shares | 100 shares | 100 shares | 150 shares | 50 shares | 50% |
| Large Position | 500 shares | 1000 shares | 1000 shares | 1500 shares | 500 shares | 50% |

### Real-World Scenarios

1. **Market Volatility**: User's collateral value drops due to price movement → becomes insolvent
2. **High Utilization**: Interest rates spike during high demand → user can't keep up
3. **Temporary Insolvency**: User waits for funds transfer → becomes temporarily insolvent
4. **Recovery Attempt**: User deposits more collateral to recover → gets double-charged

All of these are **normal, expected behaviors** - not edge cases or attack scenarios.

---

## Recommended Fix

### Approach: Interest Capitalization (Strategy 1)

**Why this approach:**
- ✅ Industry standard (Compound, Aave use similar logic)
- ✅ Simple implementation (minimal code changes)
- ✅ Low gas cost (no additional storage)
- ✅ Clear semantics (unpaid interest becomes debt)

### Code Changes

**File**: `contracts/CollateralTracker.sol`  
**Lines**: 930-934

```diff
                    /// Insolvent case: Pay what you can
                    _burn(_owner, userBalance);

-                   /// @dev DO NOT update index. By keeping the user's old baseIndex, 
-                   /// their debt continues to compound correctly from the original point in time.
-                   userBorrowIndex = userState.rightSlot();
+                   // Calculate unpaid interest
+                   uint128 unpaidInterest = userInterestOwed - burntInterestValue;
+                   
+                   // Convert unpaid interest back to principal units
+                   uint128 unpaidPrincipal = uint128(
+                       Math.mulDiv(
+                           unpaidInterest,
+                           uint128(userState.rightSlot()),
+                           currentBorrowIndex
+                       )
+                   );
+                   
+                   // Capitalize unpaid interest into netBorrows
+                   netBorrows += int128(unpaidPrincipal);
+                   
+                   // Update index to prevent double counting
+                   userBorrowIndex = int128(currentBorrowIndex);
```

### What This Does

1. **Calculates unpaid interest**: `15 - 10 = 5 shares`
2. **Converts to principal**: `5 shares * (1.0 / 1.15) ≈ 4.35 tokens`
3. **Adds to debt**: `netBorrows += 4.35 tokens`
4. **Updates checkpoint**: `userBorrowIndex = 1.15`

**Result**: User's debt is now 104.35 tokens at index 1.15. Future interest compounds from this new state. No double-charging occurs.

### Alternative Approaches

See `MITIGATION_STRATEGIES.md` for two additional approaches:
- **Strategy 2**: Credit system (tracks partial payments separately)
- **Strategy 3**: Proportional index update (mathematically elegant but complex)

---

## Running the PoC

### Prerequisites

```bash
# Foundry installed
forge --version

# Repository cloned
git clone https://github.com/code-423n4/2025-12-panoptic.git
cd 2025-12-panoptic
```

### Install Dependencies

```bash
# Install Foundry dependencies
forge install

# Update git submodules
git submodule update --init --recursive
```

### Run The PoC Test

```bash
# Run the specific PoC test with verbose output
forge test --match-contract PoC_H01_DoubleInterestCharge --match-test test_DoubleInterestCharge_AfterPartialPayment -vvv

# Run all PoC tests
forge test --match-contract PoC_H01_DoubleInterestCharge -vvv

# Run with gas report
forge test --match-contract PoC_H01_DoubleInterestCharge --gas-report
```

### Expected Output

You should see:
- ✅ Test passes (bug is confirmed to exist)
- ✅ Console logs showing the double charge
- ✅ Assertions confirming overcharge amount
- ✅ Clear demonstration of the vulnerability

### Verify The Fix

To test the mitigation:
1. Apply the code changes from the "Recommended Fix" section
2. Re-run the PoC test
3. The test should now FAIL (because the bug is fixed)
4. Run `test_CorrectBehavior_IfBugFixed` - should PASS

---

## Additional Resources

### Documentation Files

1. **`BUG_ANALYSIS.md`**
   - Technical deep-dive with mathematical proofs
   - Interest accrual mechanism explanation
   - Root cause analysis
   - Edge case documentation

2. **`MITIGATION_STRATEGIES.md`**
   - Three detailed fix approaches
   - Implementation code for each strategy
   - Comparison matrix with pros/cons
   - Recommendation with justification

3. **`test/foundry/core/PoC_H01_DoubleInterestCharge.t.sol`**
   - Full Foundry test suite
   - Helper functions for state manipulation
   - Detailed console logging
   - Both bug demonstration and correct behavior tests

### Related Code

**Key Files to Review:**
- `contracts/CollateralTracker.sol` - Main vulnerable file
- `libraries/Math.sol` - Math utilities used in calculations
- `types/LeftRight.sol` - State packing for interest tracking
- `types/MarketState.sol` - Global state management

**Key Functions:**
- `_accrueInterest()` - Main vulnerable function (line 886)
- `_getUserInterest()` - Interest calculation (line 1045)
- `_calculateCurrentInterestState()` - Global index updates (line 985)

### Testing Utilities

The PoC uses `CollateralTrackerHarness` from the existing test suite, which provides:
- `mintShares()` - Add shares to user balance
- `burnShares()` - Remove shares from user balance
- `setPoolAssets()` - Set total assets
- `setTotalSupply()` - Set total shares
- `setMarketState()` - Manipulate global state

---

## Timeline & Next Steps

### Immediate Actions (Critical)

1. **Review**: Protocol team reviews this report
2. **Verify**: Run the PoC to confirm the vulnerability
3. **Assess**: Determine if any users have been affected
4. **Communicate**: Prepare user communication if needed

### Short-Term (Within 1 Week)

1. **Implement Fix**: Apply Strategy 1 (Interest Capitalization)
2. **Test**: Comprehensive testing including:
   - Unit tests for all edge cases
   - Integration tests with other protocol components
   - Fuzz testing with random scenarios
   - Stress testing with extreme values
3. **Audit**: External security audit of the fix
4. **Deploy**: Testnet deployment and monitoring

### Medium-Term (Within 1 Month)

1. **Mainnet Deployment**: Deploy fix to production
2. **Monitor**: Watch for any issues or edge cases
3. **Compensate**: If users were affected, consider compensation
4. **Document**: Update all documentation and user guides

### Long-Term

1. **Post-Mortem**: Conduct internal review of how this was missed
2. **Process Improvement**: Update review processes to catch similar issues
3. **Education**: Train team on index-based interest accrual patterns

---

## Contact & Attribution

**Submitted By**: Security Researcher  
**Date**: January 6, 2026  
**Platform**: Code4rena  
**Contest**: Panoptic V1 Audit

For questions or clarifications, please refer to the Code4rena platform.

---

## Disclaimer

This report is provided for informational purposes as part of a security audit. The information contained herein should be independently verified before implementation. The author takes no responsibility for any actions taken based on this report.

---

## Appendix: Technical Terms

| Term | Definition |
|------|------------|
| **Borrow Index** | Accumulator tracking total interest accrued over time. Similar to a "price" of debt. |
| **User Borrow Index** | User's checkpoint of the global index when they last settled interest. |
| **Interest Insolvent** | User's collateral balance is insufficient to pay the full interest owed. |
| **Capitalization** | Converting unpaid interest into principal (adding it to the debt). |
| **netBorrows** | User's borrowed principal amount (in asset units). |
| **burntInterestValue** | Amount of interest paid via burning shares (in asset units). |

---

## Version History

- **v1.0** (2026-01-06): Initial report creation
  - Bug analysis completed
  - PoC test implemented
  - Three mitigation strategies documented
  - Recommendation: Strategy 1 (Interest Capitalization)

---

## License

This audit report is provided under the MIT License for educational and security research purposes.

---

**End of Report**

For detailed technical analysis, see `BUG_ANALYSIS.md`.  
For mitigation details, see `MITIGATION_STRATEGIES.md`.  
For executable proof, see `test/foundry/core/PoC_H01_DoubleInterestCharge.t.sol`.
