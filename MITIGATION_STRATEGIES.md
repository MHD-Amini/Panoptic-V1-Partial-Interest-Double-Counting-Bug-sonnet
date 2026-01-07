# Mitigation Strategies for H-01: Double Interest Charge Bug

## Overview

This document provides detailed mitigation strategies for the double interest charge vulnerability in `CollateralTracker.sol`. Three approaches are presented with implementation details, trade-offs, and recommendations.

---

## Strategy 1: Update Index with Interest Capitalization (RECOMMENDED)

### Rationale

When a user makes a partial payment, the unpaid portion of interest should be:
1. Capitalized into the principal (`netBorrows`)
2. User's borrow index updated to current index

This approach maintains debt continuity while acknowledging the payment made.

### Implementation

```solidity
// File: contracts/CollateralTracker.sol
// Lines: 916-942

if (shares > userBalance) {
    if (!isDeposit) {
        // Calculate the value of partial payment
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

        // ===== FIX START =====
        
        // Calculate unpaid interest (in asset units)
        uint128 unpaidInterest = userInterestOwed - burntInterestValue;
        
        // Convert unpaid interest back to principal units
        // This "de-accrues" the unpaid interest to get the principal equivalent
        // Formula: unpaidPrincipal = unpaidInterest * userBorrowIndex / currentBorrowIndex
        uint128 unpaidPrincipal = uint128(
            Math.mulDiv(
                unpaidInterest,
                uint128(userState.rightSlot()), // User's old borrow index
                currentBorrowIndex
            )
        );
        
        // Capitalize unpaid interest into netBorrows
        // This increases the user's debt by the unpaid amount
        netBorrows += int128(unpaidPrincipal);
        
        // Update user's borrow index to prevent double counting
        // Future interest will compound from this new checkpoint
        userBorrowIndex = int128(currentBorrowIndex);
        
        // ===== FIX END =====
        
        // Alternative: If you want to keep it simple and slightly penalize the user
        // for being insolvent, you can capitalize the full unpaid interest:
        // netBorrows += int128(unpaidInterest);
        // userBorrowIndex = int128(currentBorrowIndex);
    } else {
        // ... existing deposit logic ...
    }
}
```

### Test Case

```solidity
function test_Mitigation_InterestCapitalization() public {
    // Setup: User borrows 100, owes 15, has 10
    setupBorrowPosition(user, 100e18, 1.0e18);
    vm.warp(block.timestamp + 365 days);
    
    uint256 interestOwed = 15e18;
    uint256 partialPayment = 10e18;
    uint256 unpaidInterest = 5e18;
    
    // Partial payment
    vm.prank(user);
    collateralToken.accrueInterest();
    
    // Check: Unpaid interest capitalized
    (int128 netBorrows,) = collateralToken.getUserState(user);
    assertEq(netBorrows, 105e18, "Principal should increase by unpaid interest");
    
    // User deposits new funds
    vm.prank(user);
    collateralToken.deposit(100e18, user);
    
    // Interest accrues again - should be from new checkpoint
    vm.warp(block.timestamp + 365 days);
    vm.prank(user);
    collateralToken.accrueInterest();
    
    // Total paid should be: 10 (partial) + 5 (remaining) + new interest
    // NOT: 10 (partial) + 15 (double charge)
    uint256 totalBalance = collateralToken.balanceOf(user);
    assertTrue(totalBalance > 85e18, "User should not be double charged");
}
```

### Pros & Cons

**✅ Pros:**
- Simple, clean implementation
- Maintains debt continuity naturally
- Aligns with standard lending protocol behavior
- Easy to audit and understand

**❌ Cons:**
- Increases user's principal (but this accurately reflects the debt)
- Requires careful conversion between asset and principal units

---

## Strategy 2: Partial Payment Credit System

### Rationale

Track partial payments as "credits" that offset future interest charges. This provides explicit accounting of all payments and remaining debts.

### Implementation

```solidity
// File: contracts/CollateralTracker.sol

// ===== ADD NEW STATE VARIABLE =====
/// @notice Tracks partial interest payments as credits for each user
/// @dev Credits are applied to future interest charges
mapping(address => uint128) public s_partialPaymentCredits;
// ===== END NEW STATE VARIABLE =====

// In _accrueInterest() function:
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

        // ===== FIX START =====
        
        // Store partial payment as credit
        s_partialPaymentCredits[owner] += burntInterestValue;
        
        // Update index since payment was acknowledged
        userBorrowIndex = int128(currentBorrowIndex);
        
        // ===== FIX END =====
    } else {
        // ... existing logic ...
    }
}

// ===== MODIFY INTEREST CALCULATION =====
// After calculating userInterestOwed (line 899):
if (netBorrows > 0) {
    uint128 userInterestOwed = _getUserInterest(userState, currentBorrowIndex);
    
    // Apply any existing credits
    uint128 credit = s_partialPaymentCredits[owner];
    if (credit > 0) {
        if (credit >= userInterestOwed) {
            // Credit covers all interest
            s_partialPaymentCredits[owner] = credit - userInterestOwed;
            userInterestOwed = 0;
        } else {
            // Partial credit
            userInterestOwed -= credit;
            s_partialPaymentCredits[owner] = 0;
        }
    }
    
    // Only proceed with payment if there's remaining interest
    if (userInterestOwed != 0) {
        // ... existing payment logic ...
    }
}
// ===== END MODIFICATION =====
```

### Helper Functions

```solidity
/// @notice Returns the partial payment credit for a user
/// @param user The user address
/// @return credit The amount of credit available
function getPartialPaymentCredit(address user) external view returns (uint128 credit) {
    return s_partialPaymentCredits[user];
}

/// @notice Allows user to view their total debt including credits
/// @param user The user address
/// @return grossDebt Total debt before credits
/// @return credits Available credits
/// @return netDebt Net debt after applying credits
function getUserDebtWithCredits(address user) external view returns (
    uint128 grossDebt,
    uint128 credits,
    uint128 netDebt
) {
    LeftRightSigned userState = s_interestState[user];
    int128 netBorrows = userState.leftSlot();
    
    if (netBorrows > 0) {
        (uint128 currentBorrowIndex,,) = _calculateCurrentInterestState(
            s_assetsInAMM,
            _updateInterestRate()
        );
        grossDebt = _getUserInterest(userState, currentBorrowIndex);
        credits = s_partialPaymentCredits[user];
        netDebt = grossDebt > credits ? grossDebt - credits : 0;
    }
}
```

### Test Case

```solidity
function test_Mitigation_CreditSystem() public {
    setupBorrowPosition(user, 100e18, 1.0e18);
    vm.warp(block.timestamp + 365 days);
    
    // Interest owed: 15, Balance: 10
    vm.prank(user);
    collateralToken.accrueInterest();
    
    // Check credit was stored
    uint128 credit = collateralToken.getPartialPaymentCredit(user);
    assertEq(credit, 10e18, "Credit should equal partial payment");
    
    // User deposits
    vm.prank(user);
    collateralToken.deposit(100e18, user);
    
    // Interest accrues again
    vm.prank(user);
    collateralToken.accrueInterest();
    
    // Credit should be consumed
    credit = collateralToken.getPartialPaymentCredit(user);
    assertEq(credit, 0, "Credit should be fully consumed");
    
    // User should have paid: 10 (credit) + 5 (remaining) = 15 total
    uint256 balance = collateralToken.balanceOf(user);
    assertEq(balance, 95e18, "Balance should reflect correct interest payment");
}
```

### Pros & Cons

**✅ Pros:**
- Explicit accounting of all payments
- Easy to audit payment history
- Provides transparency to users
- Can implement credit expiration if needed

**❌ Cons:**
- Additional storage cost (1 storage slot per user)
- Slightly more complex logic
- Requires careful credit application order

---

## Strategy 3: Hybrid Approach with Partial Index Update

### Rationale

Update the index proportionally based on the fraction of interest paid. This maintains precise debt tracking without full capitalization.

### Implementation

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

        // ===== FIX START =====
        
        // Calculate what fraction of interest was paid
        // paymentRatio = burntInterestValue / userInterestOwed
        uint256 paymentRatio = Math.mulDiv(
            burntInterestValue,
            1e18, // Scale for precision
            userInterestOwed
        );
        
        // Calculate new user index as weighted average
        // newIndex = oldIndex + (currentIndex - oldIndex) * paymentRatio
        uint128 oldIndex = uint128(userState.rightSlot());
        uint128 indexDelta = currentBorrowIndex - oldIndex;
        uint128 indexIncrement = uint128(Math.mulDiv(
            indexDelta,
            paymentRatio,
            1e18
        ));
        
        userBorrowIndex = int128(oldIndex + indexIncrement);
        
        // ===== FIX END =====
    } else {
        // ... existing logic ...
    }
}
```

### Mathematical Example

```
Old Index: 1.0
Current Index: 1.15
Interest Owed: 15 tokens
Payment Made: 10 tokens
Payment Ratio: 10/15 = 66.67%

New Index = 1.0 + (1.15 - 1.0) * 0.6667
          = 1.0 + 0.15 * 0.6667
          = 1.0 + 0.1
          = 1.1

Future interest will compound from 1.1, not 1.0
This means remaining 5 tokens of interest will be charged
from index range 1.1 to 1.15 (not 1.0 to 1.15)
```

### Test Case

```solidity
function test_Mitigation_ProportionalIndexUpdate() public {
    setupBorrowPosition(user, 100e18, 1.0e18);
    vm.warp(block.timestamp + 365 days);
    
    // Interest owed: 15, Payment: 10 (66.67% paid)
    vm.prank(user);
    collateralToken.accrueInterest();
    
    // Check new index
    (, int128 newIndex) = collateralToken.getUserState(user);
    // Expected: 1.0 + (1.15 - 1.0) * 0.6667 = 1.1
    assertApproxEqAbs(uint128(newIndex), 1.1e18, 1e15, "Index should be proportionally updated");
    
    // User deposits
    vm.prank(user);
    collateralToken.deposit(100e18, user);
    
    // Interest accrues again - should only charge remaining 5
    vm.prank(user);
    collateralToken.accrueInterest();
    
    uint256 balance = collateralToken.balanceOf(user);
    assertApproxEqAbs(balance, 95e18, 1e17, "Should charge remaining 5 tokens");
}
```

### Pros & Cons

**✅ Pros:**
- Mathematically elegant
- Precise tracking of partial payments
- No additional storage
- No principal modification

**❌ Cons:**
- More complex logic
- Potential for rounding errors
- Harder to audit
- May confuse users seeing partial index values

---

## Comparison Matrix

| Feature | Strategy 1 (Capitalization) | Strategy 2 (Credits) | Strategy 3 (Proportional) |
|---------|----------------------------|----------------------|---------------------------|
| **Gas Cost** | Low | Medium (extra storage) | Low |
| **Complexity** | Low | Medium | High |
| **Auditability** | High | High | Medium |
| **Precision** | High | High | Medium (rounding) |
| **User Transparency** | Medium | High | Low |
| **Protocol Precedent** | Aave, Compound | None | None |
| **Implementation Risk** | Low | Low | Medium |

---

## Recommendation

**Strategy 1 (Interest Capitalization) is the RECOMMENDED approach** because:

1. ✅ **Industry Standard**: Aligns with proven lending protocols
2. ✅ **Simple Implementation**: Minimal code changes, easy to audit
3. ✅ **Low Gas Cost**: No additional storage slots
4. ✅ **Clear Semantics**: Debt grows by unpaid amount (intuitive)
5. ✅ **Well-Tested Pattern**: Compound/Aave have used this for years

### Implementation Checklist

- [ ] Modify `_accrueInterest()` to capitalize unpaid interest
- [ ] Update `userBorrowIndex` after partial payment
- [ ] Add comprehensive tests for partial payment scenarios
- [ ] Add integration tests with multiple partial payments
- [ ] Update documentation explaining capitalization logic
- [ ] Add events for transparency: `InterestCapitalized(user, amount)`
- [ ] Audit by external security firm
- [ ] Deploy to testnet and stress test
- [ ] Gradual rollout with monitoring

---

## Additional Considerations

### Edge Cases to Test

1. **Multiple Partial Payments**: User makes 3-4 consecutive partial payments
2. **Dust Amounts**: Partial payment of 1 wei
3. **Full Balance Burn**: User burns exact amount to cover interest
4. **Alternating Solvency**: User goes insolvent → solvent → insolvent
5. **High Interest Rates**: Interest accrual > 100% (theoretical)
6. **Zero Principal**: User with no borrows receives interest payment request

### Monitoring & Alerts

After deployment, monitor for:
- Frequency of partial payments (should be rare in healthy market)
- Average partial payment amounts
- User recovery rates (do users deposit after partial payment?)
- Net impact on protocol reserves

### User Communication

Prepare user-facing documentation:
```markdown
## What happens if I can't pay full interest?

If your collateral balance is insufficient to cover interest owed:

1. **Your entire balance will be used** as partial payment
2. **Unpaid interest is added to your debt** (capitalized)
3. **Future interest compounds** from this higher debt amount
4. **You can deposit more** to pay the remaining debt
5. **No double-charging** occurs - all payments are credited

Example:
- You owe 15 tokens interest
- You only have 10 tokens balance
- We take your 10 tokens as payment
- Remaining 5 tokens is added to your debt principal
- You deposit 100 tokens later
- You'll only owe the 5 tokens plus any new interest
```

---

## Conclusion

The recommended mitigation (Strategy 1) is a battle-tested approach that:
- **Eliminates the double-charge vulnerability**
- **Maintains protocol invariants**
- **Minimizes implementation risk**
- **Provides clear user semantics**

This fix should be implemented immediately as a HIGH priority security patch.
