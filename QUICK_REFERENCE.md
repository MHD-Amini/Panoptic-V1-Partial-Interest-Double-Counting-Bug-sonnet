# Quick Reference: H-01 Double Interest Charge Bug

## 🎯 One-Minute Summary

**What**: Users who make partial interest payments get charged twice for the same interest  
**Where**: `CollateralTracker.sol::_accrueInterest()` lines 930-934  
**Why**: `userBorrowIndex` not updated after partial payment  
**Impact**: Users lose 50-100% of their partial payment amount  
**Fix**: Update index + capitalize unpaid interest (3 lines of code)

---

## 📊 Visual Flow Diagram

### Current Behavior (BUG)
```
Time T0: User borrows 100 tokens
├─ userBorrowIndex = 1.0
└─ netBorrows = 100

Time T1: Interest accrues
├─ currentBorrowIndex = 1.15
├─ Interest owed = 15 tokens
└─ User balance = 10 tokens ❌ INSOLVENT

Partial Payment:
├─ Burn 10 tokens ✅
├─ burntInterestValue = 10 ✅
└─ userBorrowIndex = 1.0 ❌ NOT UPDATED (BUG!)

Time T2: User deposits 100 tokens
└─ trigger _accrueInterest()

Interest Recalculated:
├─ currentBorrowIndex = 1.15
├─ userBorrowIndex = 1.0 (still old!)
├─ Interest = 100 * (1.15 - 1.0) / 1.0
└─ Interest = 15 tokens ❌ SAME AS BEFORE!

Result:
├─ First payment:  10 tokens
├─ Second payment: 15 tokens
├─ Total paid:     25 tokens
├─ Actual debt:    15 tokens
└─ LOSS:           10 tokens (66% overcharge)
```

### Expected Behavior (FIXED)
```
Time T0: User borrows 100 tokens
├─ userBorrowIndex = 1.0
└─ netBorrows = 100

Time T1: Interest accrues
├─ currentBorrowIndex = 1.15
├─ Interest owed = 15 tokens
└─ User balance = 10 tokens ❌ INSOLVENT

Partial Payment:
├─ Burn 10 tokens ✅
├─ burntInterestValue = 10 ✅
├─ Unpaid interest = 5 tokens
├─ Capitalize: netBorrows += 5 ✅
└─ userBorrowIndex = 1.15 ✅ UPDATED! (FIXED)

Time T2: User deposits 100 tokens
└─ trigger _accrueInterest()

Interest Recalculated:
├─ currentBorrowIndex = 1.15
├─ userBorrowIndex = 1.15 (updated!)
├─ Interest = 105 * (1.15 - 1.15) / 1.15
└─ Interest = 0 tokens ✅ (or minimal new interest)

Result:
├─ First payment:  10 tokens
├─ Second payment: 5 tokens (only remaining)
├─ Total paid:     15 tokens
├─ Actual debt:    15 tokens
└─ LOSS:           0 tokens ✅ CORRECT!
```

---

## 🔧 The Fix (Recommended)

### Before (Vulnerable Code)
```solidity
/// Insolvent case: Pay what you can
_burn(_owner, userBalance);

/// @dev DO NOT update index.
userBorrowIndex = userState.rightSlot(); // ❌ BUG
```

### After (Fixed Code)
```solidity
/// Insolvent case: Pay what you can
_burn(_owner, userBalance);

// Calculate unpaid interest
uint128 unpaidInterest = userInterestOwed - burntInterestValue;

// Capitalize unpaid interest into netBorrows
uint128 unpaidPrincipal = uint128(
    Math.mulDiv(unpaidInterest, uint128(userState.rightSlot()), currentBorrowIndex)
);
netBorrows += int128(unpaidPrincipal);

// Update index to prevent double counting
userBorrowIndex = int128(currentBorrowIndex); // ✅ FIXED
```

---

## 🧪 Testing Checklist

### Run PoC
```bash
# Clone repo
git clone https://github.com/code-423n4/2025-12-panoptic.git
cd 2025-12-panoptic

# Run PoC test
forge test --match-contract PoC_H01_DoubleInterestCharge -vvv
```

### Expected Results
- ✅ Test passes (confirms bug exists)
- ✅ Console shows: "LOSS TO USER: 10 shares"
- ✅ Console shows: "OVERCHARGE: 66%"
- ✅ Assertion: `totalPaid > actualDebt`

### After Applying Fix
- ❌ Original test should FAIL (bug is gone)
- ✅ `test_CorrectBehavior_IfBugFixed` should PASS

---

## 📈 Impact Scenarios

| Scenario | Partial Payment | Interest Owed | Overcharge | Loss % |
|----------|----------------|---------------|------------|--------|
| **Small** | 1 token | 15 tokens | 1 token | 6.7% |
| **Medium** | 10 tokens | 15 tokens | 10 tokens | 66% |
| **Large** | 50 tokens | 100 tokens | 50 tokens | 50% |
| **Massive** | 500 tokens | 1000 tokens | 500 tokens | 50% |

**Average Loss**: 50-66% of partial payment amount

---

## 🎓 How This Happens Naturally

### Scenario 1: Market Volatility
```
1. User has $1000 collateral, borrows $800
2. Market drops 20% → collateral now $800
3. Interest accrues: $50 owed
4. User can't pay full interest → partial payment
5. User later deposits more → DOUBLE CHARGED
```

### Scenario 2: High Utilization
```
1. Protocol utilization spikes to 95%
2. Interest rates jump from 5% to 50% APY
3. User's monthly interest: $10 → $100
4. User caught off guard → partial payment
5. User deposits to cover → DOUBLE CHARGED
```

### Scenario 3: Temporary Insolvency
```
1. User waiting for wire transfer
2. Interest deadline passes
3. Partial payment made with available balance
4. Wire arrives, user deposits → DOUBLE CHARGED
```

**Key Point**: This affects normal, honest users - not attackers!

---

## 🔍 Code Locations

### Main Bug
- **File**: `contracts/CollateralTracker.sol`
- **Function**: `_accrueInterest(address owner, bool isDeposit)`
- **Lines**: 930-934
- **Issue**: `userBorrowIndex = userState.rightSlot();`

### Related Functions
- `_getUserInterest()` - Line 1045 (calculates interest from index)
- `_calculateCurrentInterestState()` - Line 985 (updates global index)

### Storage Variables
- `s_interestState[owner]` - Stores (netBorrows, userBorrowIndex)
- `s_marketState` - Global (borrowIndex, epoch, rate, unrealizedInterest)

---

## 📚 Further Reading

1. **`BUG_ANALYSIS.md`** - Mathematical proof and technical deep-dive
2. **`MITIGATION_STRATEGIES.md`** - Three fix approaches with pros/cons
3. **`test/foundry/core/PoC_H01_DoubleInterestCharge.t.sol`** - Full PoC code
4. **`README.md`** - Complete audit report

---

## 🚨 Severity Justification

| Factor | Rating | Reason |
|--------|--------|--------|
| **Likelihood** | MEDIUM | Happens naturally, no exploit needed |
| **Impact** | HIGH | Direct fund loss, 50-100% overcharge |
| **Affected Users** | MEDIUM | Anyone with insolvency event |
| **Fix Complexity** | LOW | 10 lines of code |
| **Overall** | **HIGH** | Critical accounting bug |

---

## ✅ Action Items

### For Protocol Team
- [ ] Review this report
- [ ] Run PoC test to verify
- [ ] Check if any users affected
- [ ] Apply recommended fix
- [ ] Test thoroughly
- [ ] External audit
- [ ] Deploy to mainnet

### For Auditors
- [ ] Verify vulnerability exists
- [ ] Test mitigation strategies
- [ ] Check for similar bugs in codebase
- [ ] Review all interest accrual logic

### For Users
- [ ] Be aware of the issue
- [ ] Wait for fix before depositing after insolvency
- [ ] Report any suspicious interest charges

---

## 🏆 Credit

**Found by**: Security Researcher  
**Platform**: Code4rena  
**Date**: January 6, 2026  
**Severity**: HIGH  
**Status**: Reported ✅

---

**Last Updated**: 2026-01-06  
**Report Version**: 1.0
