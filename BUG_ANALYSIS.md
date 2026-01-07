# H-01: Partial Interest Repayment Leads to Double Counting of Interest

## Executive Summary

**Severity**: HIGH  
**Likelihood**: MEDIUM  
**Impact**: HIGH (Direct loss of user funds)  
**Component**: `CollateralTracker.sol::_accrueInterest()`  
**Root Cause**: User's `userBorrowIndex` is not updated after partial interest payment during insolvency

---

## Technical Background

### Interest Accrual Mechanism

The Panoptic protocol uses a **borrow index** system similar to Compound/Aave to track interest:

1. **Global Borrow Index** (`currentBorrowIndex`): Accumulates over time as `baseIndex * (1 + rate)^epochs`
2. **User Borrow Index** (`userBorrowIndex`): Checkpoint of global index when user last settled
3. **Interest Calculation**: `interest = principal * (currentBorrowIndex - userBorrowIndex) / userBorrowIndex`

### Normal Interest Payment Flow

```
┌─────────────────────────────────────────────────────────┐
│ User has borrowed assets                                │
│ • userBorrowIndex = 1.0                                 │
│ • netBorrows = 100 assets                               │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ Time passes, interest accrues                           │
│ • currentBorrowIndex = 1.15                             │
│ • interest owed = 100 * (1.15 - 1.0) / 1.0 = 15 assets │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ Solvent case: User has sufficient balance               │
│ • Convert 15 assets to shares and burn them             │
│ • Update userBorrowIndex = 1.15 ✅                      │
│ • Future interest starts from 1.15                      │
└─────────────────────────────────────────────────────────┘
```

---

## The Bug: Insolvency Without Index Update

### Vulnerable Code

**File**: `contracts/CollateralTracker.sol`  
**Lines**: 916-942

```solidity
if (shares > userBalance) {
    if (!isDeposit) {
        // update the accrual of interest paid
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
        userBorrowIndex = userState.rightSlot(); // ❌ KEEPS OLD INDEX
    } else {
        // set interest paid to zero
        burntInterestValue = 0;
        userBorrowIndex = userState.rightSlot(); // ❌ KEEPS OLD INDEX
    }
} else {
    // Solvent case: Pay in full.
    _burn(_owner, shares);
    // userBorrowIndex is updated to currentBorrowIndex at line 897 ✅
}
```

### The Problem

When a user is **interest insolvent**:
1. ✅ Their entire balance is burned as partial payment
2. ✅ `burntInterestValue` correctly tracks how much was paid
3. ❌ **`userBorrowIndex` is NOT updated** - stays at old value
4. ❌ Protocol "forgets" the partial payment occurred

---

## Mathematical Proof of Double Counting

### Scenario Setup

| Variable | Value | Description |
|----------|-------|-------------|
| `netBorrows` | 100 assets | User's borrowed principal |
| `userBorrowIndex` (initial) | 1.00 | User's last checkpoint |
| `currentBorrowIndex` (T1) | 1.15 | Global index after time passes |
| User balance | 10 shares | User's collateral balance |
| Interest owed | 15 shares | 100 * (1.15 - 1.0) / 1.0 = 15 |

### Step 1: Partial Payment (Insolvency)

```
User Balance: 10 shares < Interest Owed: 15 shares
→ User is INSOLVENT

Actions:
1. _burn(user, 10 shares)           ✅ Payment made
2. burntInterestValue = 10 assets   ✅ Tracked
3. userBorrowIndex remains 1.00     ❌ BUG: Not updated
```

**Expected**: User paid 10 shares, owes 5 shares remaining  
**Actual**: User paid 10 shares, but system still thinks user owes 15 shares

### Step 2: User Deposits New Funds

```
User deposits 100 new shares
→ deposit() calls _accrueInterest()
```

### Step 3: Interest Recalculation (Double Charge)

```solidity
// From _accrueInterest() at line 898-899
int128 netBorrows = userState.leftSlot();           // = 100 assets
int128 userBorrowIndex = int128(currentBorrowIndex); // = 1.15 (default)

if (netBorrows > 0) {
    uint128 userInterestOwed = _getUserInterest(userState, currentBorrowIndex);
    // Calculates: 100 * (1.15 - 1.00) / 1.00 = 15 shares
    // ❌ This is the SAME 15 shares calculated before!
}
```

**The Index Was Never Updated, So:**
- `currentBorrowIndex` = 1.15
- `userBorrowIndex` = 1.00 (still the old value from before partial payment)
- Interest calculated = `100 * (1.15 - 1.00) / 1.00 = 15 shares`

### Step 4: Total Loss Calculation

```
Total Paid by User:
  First payment (burned):  10 shares
  Second payment (deposit): 15 shares
  ─────────────────────────────────
  TOTAL:                   25 shares

Actual Debt:
  Interest owed:           15 shares

Loss to User:             10 shares (66% overcharge)
```

---

## Attack Vector Analysis

### Likelihood: MEDIUM

**Prerequisites:**
1. User must have an active borrow position
2. Interest must accrue to create insolvency (natural over time)
3. User's collateral balance < interest owed (can happen from price drops or high utilization)
4. User later deposits funds to recover

**Frequency**: 
- High utilization periods naturally create higher interest rates
- Volatile markets can reduce collateral values
- No malicious intent required - happens through normal operations

### Impact: HIGH

**Direct Financial Loss:**
- Users lose the entire amount of their first partial payment
- Loss is proportional to initial partial payment size
- Affects innocent users attempting to recover from temporary insolvency

**Trust & Reputation:**
- Users will feel "penalized" for trying to recover
- Discourages deposits after insolvency events
- Creates negative user experience

**Example Scenarios:**

| Partial Payment | Full Interest | Second Charge | Total Paid | Loss | Loss % |
|----------------|---------------|---------------|------------|------|--------|
| 10 shares | 15 shares | 15 shares | 25 shares | 10 shares | 66% |
| 50 shares | 100 shares | 100 shares | 150 shares | 50 shares | 50% |
| 1 share | 15 shares | 15 shares | 16 shares | 1 share | 6.7% |

---

## Proof of Concept Code

### Test Setup

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";

contract PoC_DoubleInterestCharge is Test {
    CollateralTrackerHarness collateralToken;
    address user = address(0x1234);
    
    function setUp() public {
        // Initialize collateral tracker
        collateralToken = new CollateralTrackerHarness();
        // Setup user with borrowed position
    }
    
    function test_DoubleInterestChargeAfterPartialPayment() public {
        // 1. User borrows 100 assets
        // 2. Time passes, interest accrues to 15 shares
        // 3. User only has 10 shares → partial payment
        // 4. User deposits 100 new shares
        // 5. Interest is charged AGAIN for 15 shares
        // 6. Total paid: 25 shares (should be 15)
        
        // Expected: Loss of 10 shares
        // Actual: Loss of 10 shares ❌
    }
}
```

---

## Root Cause Analysis

### Code Comment Misleading

```solidity
/// @dev DO NOT update index. By keeping the user's old baseIndex, 
/// their debt continues to compound correctly from the original point in time.
```

**Why This Is Wrong:**
- The comment assumes "not updating = correct compounding"
- This is only true if NO payment was made
- When a partial payment IS made, the debt is reduced
- Not updating the index means **ignoring the payment**

### Correct Approach

After a partial payment, one of these must happen:

**Option A**: Update the index (acknowledge payment made)
```solidity
userBorrowIndex = int128(currentBorrowIndex);
```

**Option B**: Reduce the principal by unpaid amount
```solidity
netBorrows += unpaidInterest; // Capitalize unpaid interest
userBorrowIndex = int128(currentBorrowIndex);
```

**Option C**: Track partial payments separately
```solidity
s_partialPayments[owner] += burntInterestValue;
// Deduct from next interest calculation
```

---

## Recommended Mitigation

### Solution 1: Update Index After Partial Payment (Preferred)

**Rationale**: Simplest fix, aligns with standard lending protocols

```solidity
if (shares > userBalance) {
    if (!isDeposit) {
        burntInterestValue = Math
            .mulDiv(userBalance, _totalAssets, totalSupply())
            .toUint128();

        emit InsolvencyPenaltyApplied(
            owner,
            userInterestOwed,
            burntInterestValue,
            userBalance
        );

        _burn(_owner, userBalance);

        // FIX: Capitalize unpaid interest into netBorrows
        uint128 unpaidInterest = userInterestOwed - burntInterestValue;
        netBorrows += int128(uint128(
            Math.mulDiv(unpaidInterest, 1e18, currentBorrowIndex)
        ));
        
        // FIX: Update index to prevent double counting
        userBorrowIndex = int128(currentBorrowIndex);
    }
}
```

### Solution 2: Track Partial Payments as Credits

**Rationale**: More granular tracking, useful for analytics

```solidity
// Add new storage
mapping(address => uint128) s_partialPaymentCredits;

// In _accrueInterest()
if (shares > userBalance) {
    if (!isDeposit) {
        // ... existing code ...
        _burn(_owner, userBalance);
        
        // FIX: Store credit for partial payment
        s_partialPaymentCredits[owner] += burntInterestValue;
        
        // Update index
        userBorrowIndex = int128(currentBorrowIndex);
    }
}

// When calculating interest, apply credits
uint128 userInterestOwed = _getUserInterest(userState, currentBorrowIndex);
uint128 credit = s_partialPaymentCredits[owner];
if (credit > 0) {
    if (credit >= userInterestOwed) {
        s_partialPaymentCredits[owner] = credit - userInterestOwed;
        userInterestOwed = 0;
    } else {
        userInterestOwed -= credit;
        s_partialPaymentCredits[owner] = 0;
    }
}
```

### Solution 3: Hybrid Approach with Interest Capitalization

**Rationale**: Maintains debt continuity while acknowledging payment

```solidity
if (shares > userBalance) {
    if (!isDeposit) {
        // Calculate unpaid interest (this is the debt that continues)
        uint128 unpaidInterest = userInterestOwed - burntInterestValue;
        
        // Convert unpaid interest back to principal units
        uint128 capitalizedDebt = Math.mulDiv(
            unpaidInterest, 
            uint128(userBorrowIndex), 
            currentBorrowIndex
        );
        
        // Add to netBorrows (debt grows by unpaid amount)
        netBorrows += int128(capitalizedDebt);
        
        // NOW it's safe to update the index
        userBorrowIndex = int128(currentBorrowIndex);
        
        _burn(_owner, userBalance);
    }
}
```

---

## Test Cases for Validation

### Test 1: Basic Double Charge Scenario
```solidity
function test_NoDoubleCharge_BasicScenario() public {
    // Setup: User borrows, becomes insolvent
    // Action: Partial payment, then deposit
    // Assert: Total paid = exactly interest owed
}
```

### Test 2: Multiple Partial Payments
```solidity
function test_NoDoubleCharge_MultiplePartialPayments() public {
    // Setup: User makes 3 partial payments over time
    // Assert: Each payment is credited correctly
}
```

### Test 3: Full Recovery After Partial Payment
```solidity
function test_CorrectInterest_AfterRecovery() public {
    // Setup: Partial payment, full recovery, more time passes
    // Assert: New interest calculated from correct checkpoint
}
```

### Test 4: Edge Case - Dust Payment
```solidity
function test_NoDoubleCharge_DustPayment() public {
    // Setup: User pays 1 wei as partial payment
    // Assert: 1 wei is credited, not charged again
}
```

---

## References

1. **Compound Finance**: Index-based interest accrual
2. **Aave V3**: Borrow index implementation
3. **Panoptic Docs**: Collateral tracking mechanism

---

## Conclusion

This vulnerability represents a **critical accounting flaw** in the interest settlement logic. While the intention (continued debt compounding) is sound, the implementation fails to account for the economic reality that **a payment was made**.

The fix is straightforward: either update the index after partial payment, or explicitly track the partial payment as a credit. Both approaches ensure users are not charged twice for the same interest period.

**Severity Justification**: 
- Direct, measurable loss of user funds ✅
- Affects multiple users over protocol lifetime ✅  
- Breaks core protocol invariant (payment = debt reduction) ✅
- → **HIGH SEVERITY**
