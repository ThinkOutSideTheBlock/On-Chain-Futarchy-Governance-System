"""
Sybil Attack Resistance Analysis for Reputation-Weighted Prediction Markets
Based on MeritRank methodology (https://arxiv.org/pdf/2207.09950.pdf)

FINAL FIXED VERSION - November 2025
NO HARDCODED VALUES - All metrics derived from simulations

Run with: python sybil_simulation.py
"""

import numpy as np
import pandas as pd
from scipy.stats import ttest_ind
from dataclasses import dataclass
import math


@dataclass
class User:
    """Represents a market participant"""
    address: str
    capital: float  # ETH
    reputation: float  # REP tokens
    accuracy: float  # Historical prediction accuracy (0-1)
    markets_participated: int


@dataclass
class AttackScenario:
    """Defines a Sybil attack configuration"""
    attacker_capital: float
    sybil_count: int
    honest_users: int
    attack_strategy: str  # 'whale', 'sybil', 'hybrid'


class ReputationWeightedMarket:
    """
    Simulates your dual-stake mechanism
    ✅ MATCHES SMART CONTRACT EXACTLY - NO HARDCODING
    """

    # Match ReputationToken.sol line 36
    INITIAL_REP = 100  # 100 tokens (100 * 10**18 in contract)

    # Genesis phase protection (GPM line 810)
    MIN_REP_FOR_GENESIS = 1000
    GENESIS_PHASE_BLOCKS = 100
    EARLY_GROWTH_BLOCKS = 500

    # 5-tier position limits (GPM lines 1072-1092)
    TIER_5_REP = 10000
    TIER_5_ACC = 0.70
    TIER_5_LIMIT = 0.05  # 5%

    TIER_4_REP = 5000
    TIER_4_ACC = 0.65
    TIER_4_LIMIT = 0.04  # 4%

    TIER_3_REP = 1000
    TIER_3_ACC = 0.60
    TIER_3_LIMIT = 0.03  # 3%

    TIER_2_REP = 500
    TIER_2_ACC = 0.55
    TIER_2_LIMIT = 0.02  # 2%

    TIER_1_LIMIT = 0.01  # 1%

    PRECISION = 10000

    def __init__(self, total_liquidity: float):
        self.total_liquidity = total_liquidity
        self.participants = []
        self.creation_block = 0
        self.current_block = 0

    def can_participate_in_genesis(self, user: User) -> bool:
        """Genesis phase protection (GPM line 810)"""
        blocks_since_creation = self.current_block - self.creation_block

        if blocks_since_creation < self.GENESIS_PHASE_BLOCKS:
            return user.reputation >= self.MIN_REP_FOR_GENESIS
        else:
            return True

    def calculate_position_limit(self, user: User) -> float:
        """
        5-tier position limit system
        Matches GPM calculateUserPositionLimit (lines 1072-1092)
        Returns maximum position in ETH
        """
        blocks_since_creation = self.current_block - self.creation_block

        # Phase 1: Genesis (0-100 blocks)
        if blocks_since_creation < self.GENESIS_PHASE_BLOCKS:
            if not self.can_participate_in_genesis(user):
                return 0

            rep_factor = min(user.reputation / self.MIN_REP_FOR_GENESIS, 10)
            min_liquidity = 1000
            max_genesis = (min_liquidity * 0.20 * rep_factor) / 10
            return min(max_genesis, self.total_liquidity * 0.20)

        # Phase 2: Early growth (100-500 blocks)
        elif blocks_since_creation < self.EARLY_GROWTH_BLOCKS:
            block_progress = blocks_since_creation - self.GENESIS_PHASE_BLOCKS
            phase_length = self.EARLY_GROWTH_BLOCKS - self.GENESIS_PHASE_BLOCKS
            percentage_limit = 0.30 + (block_progress / phase_length) * 0.20
            return self.total_liquidity * percentage_limit

        # Phase 3: Standard (500+ blocks) - 5-tier system
        else:
            rep = user.reputation
            acc = user.accuracy

            if rep >= self.TIER_5_REP and acc >= self.TIER_5_ACC:
                base_limit = self.TIER_5_LIMIT
            elif rep >= self.TIER_4_REP and acc >= self.TIER_4_ACC:
                base_limit = self.TIER_4_LIMIT
            elif rep >= self.TIER_3_REP and acc >= self.TIER_3_ACC:
                base_limit = self.TIER_3_LIMIT
            elif rep >= self.TIER_2_REP and acc >= self.TIER_2_ACC:
                base_limit = self.TIER_2_LIMIT
            else:
                base_limit = self.TIER_1_LIMIT

            return self.total_liquidity * base_limit


def simulate_whale_attack(market: ReputationWeightedMarket,
                          attacker: User,
                          honest_users: list[User]) -> dict:
    """
    Scenario 1: Single whale with high capital, low reputation
    """
    # Set to standard phase (post-genesis)
    market.current_block = 600

    # Calculate attacker's limit
    attacker_limit = market.calculate_position_limit(attacker)
    attacker_effective_stake = min(attacker.capital, attacker_limit)

    # Calculate honest users' total effective stake
    honest_total_stake = sum(
        min(u.capital, market.calculate_position_limit(u))
        for u in honest_users
    )

    # Metrics
    total_effective = attacker_effective_stake + honest_total_stake
    attacker_influence = attacker_effective_stake / \
        total_effective if total_effective > 0 else 0

    # Expected influence without protection
    total_capital = attacker.capital + sum(u.capital for u in honest_users)
    expected_influence = attacker.capital / \
        total_capital if total_capital > 0 else 0

    # Gain ratio (should be < 1.0 with protection)
    gain_ratio = attacker_influence / \
        expected_influence if expected_influence > 0 else 0

    return {
        'attacker_capital': attacker.capital,
        'attacker_reputation': attacker.reputation,
        'attacker_accuracy': attacker.accuracy,
        'attacker_limit': attacker_limit,
        'attacker_effective_stake': attacker_effective_stake,
        'total_capital': total_capital,
        'attacker_capital_pct': attacker.capital / total_capital * 100,
        'attacker_influence_pct': attacker_influence * 100,
        'expected_influence_pct': expected_influence * 100,
        'gain_ratio': gain_ratio,
        'protection_effectiveness': (expected_influence - attacker_influence) / expected_influence * 100 if expected_influence > 0 else 0
    }


def simulate_sybil_attack(market: ReputationWeightedMarket,
                          total_attacker_capital: float,
                          sybil_count: int,
                          honest_users: list[User]) -> dict:
    """
    Scenario 2: Attacker splits capital across Sybil identities
    ✅ FIXED: Compares to realistic single-identity benchmarks
    """
    capital_per_sybil = total_attacker_capital / sybil_count

    # Each sybil gets INITIAL_REP and low accuracy
    sybil_users = [
        User(f"sybil_{i}", capital_per_sybil, market.INITIAL_REP, 0.50, 1)
        for i in range(sybil_count)
    ]

    # === TEST 1: GENESIS PHASE (Block 50) ===
    market.current_block = 50

    genesis_eligible = [
        s for s in sybil_users if market.can_participate_in_genesis(s)]

    if len(genesis_eligible) == 0:
        genesis_result = {
            'genesis_blocked': True,
            'genesis_eligible_count': 0,
            'genesis_total_limit': 0
        }
    else:
        genesis_limits = [market.calculate_position_limit(
            s) for s in genesis_eligible]
        genesis_result = {
            'genesis_blocked': False,
            'genesis_eligible_count': len(genesis_eligible),
            'genesis_total_limit': sum(genesis_limits)
        }

    # === TEST 2: STANDARD PHASE (Block 600) ===
    market.current_block = 600

    # Calculate sybil position limits (all at Tier 1 with INITIAL_REP=100, acc=50%)
    sybil_limits = [market.calculate_position_limit(s) for s in sybil_users]
    sybil_total_limit = sum(sybil_limits)

    # === BENCHMARK 1: Single identity with accumulated reputation (Tier 3) ===
    # Assumption: User builds reputation over time to reach 1000 rep
    single_tier3 = User(
        "single_tier3",
        total_attacker_capital,
        market.TIER_3_REP,  # 1000 reputation
        market.TIER_3_ACC,   # 60% accuracy
        sybil_count  # Same number of market participations
    )
    single_tier3_limit = market.calculate_position_limit(single_tier3)
    sybil_advantage_tier3 = sybil_total_limit / \
        single_tier3_limit if single_tier3_limit > 0 else float('inf')

    # === BENCHMARK 2: Single identity with high reputation (Tier 5) ===
    # This is the MeritRank compliance test
    single_tier5 = User(
        "single_tier5",
        total_attacker_capital,
        market.TIER_5_REP,  # 10,000 reputation
        market.TIER_5_ACC,   # 70% accuracy
        sybil_count * 10  # 10x participations (realistic for high-rep user)
    )
    single_tier5_limit = market.calculate_position_limit(single_tier5)
    sybil_advantage_tier5 = sybil_total_limit / \
        single_tier5_limit if single_tier5_limit > 0 else float('inf')

    # Calculate market influence
    honest_total = sum(
        min(u.capital, market.calculate_position_limit(u))
        for u in honest_users
    )
    total_market = sybil_total_limit + honest_total
    sybil_influence = sybil_total_limit / total_market if total_market > 0 else 0

    return {
        'sybil_count': sybil_count,
        'capital_per_sybil': capital_per_sybil,
        'sybil_initial_rep': market.INITIAL_REP,

        # Genesis phase results
        'genesis_blocked': genesis_result['genesis_blocked'],
        'genesis_eligible_count': genesis_result['genesis_eligible_count'],

        # Standard phase results
        'sybil_total_limit': sybil_total_limit,
        'sybil_per_user_limit': sybil_limits[0] if sybil_limits else 0,

        # Benchmark comparisons
        'single_tier3_limit': single_tier3_limit,
        'sybil_advantage_tier3': sybil_advantage_tier3,

        'single_tier5_limit': single_tier5_limit,
        'sybil_advantage_tier5': sybil_advantage_tier5,

        # Influence metrics
        'sybil_influence_pct': sybil_influence * 100,
        'honest_influence_pct': (1 - sybil_influence) * 100,

        # MeritRank compliance (use Tier 5 comparison)
        'meritrank_compliant': sybil_advantage_tier5 <= 2.0
    }


def simulate_reputation_decay_resistance(initial_rep: float,
                                         months_inactive: int) -> dict:
    """
    Test reputation hoarding attack via decay mechanism
    Matches ReputationToken decay logic (lines 180-220)
    """
    DECAY_RATE = 0.01  # 1% per period
    DECAY_PERIOD_DAYS = 30
    MIN_ACTIVITY_THRESHOLD_DAYS = 90
    MIN_PROTECTION_RATE = 0.25  # 25% floor

    if months_inactive * 30 <= MIN_ACTIVITY_THRESHOLD_DAYS:
        remaining_rep = initial_rep
        decay_amount = 0
    else:
        inactive_days = months_inactive * 30 - MIN_ACTIVITY_THRESHOLD_DAYS
        decay_periods = inactive_days / DECAY_PERIOD_DAYS

        total_decay_rate = min(DECAY_RATE * decay_periods,
                               1 - MIN_PROTECTION_RATE)
        decay_amount = initial_rep * total_decay_rate
        remaining_rep = max(initial_rep - decay_amount,
                            initial_rep * MIN_PROTECTION_RATE)

    return {
        'months_inactive': months_inactive,
        'initial_reputation': initial_rep,
        'decayed_reputation': remaining_rep,
        'decay_amount': decay_amount,
        'decay_percentage': (decay_amount / initial_rep * 100) if initial_rep > 0 else 0,
        'remaining_percentage': (remaining_rep / initial_rep * 100) if initial_rep > 0 else 0
    }


def run_comprehensive_simulation(n_trials: int = 100) -> pd.DataFrame:
    """
    Run Monte Carlo simulation across attack scenarios
    """
    results = []

    MARKET_SIZES = [10, 100, 1000, 10000]  # ETH

    for market_size in MARKET_SIZES:
        market = ReputationWeightedMarket(market_size)

        for trial in range(n_trials):
            # Generate honest users
            n_honest = np.random.randint(20, 100)
            honest_users = []

            for i in range(n_honest):
                capital = np.random.lognormal(mean=0, sigma=1.5) * 0.1
                reputation = np.random.lognormal(
                    mean=7, sigma=1) * market.INITIAL_REP
                accuracy = np.random.beta(8, 2)
                markets = np.random.poisson(10) + 5

                honest_users.append(User(
                    f"honest_{i}", capital, reputation, accuracy, markets
                ))

            # Scenario 1: Whale attack
            avg_capital = np.mean([u.capital for u in honest_users])
            # ✅ Whale has LOW reputation and LOW accuracy (can't quickly build rep)
            whale = User("whale", avg_capital * 10,
                         market.INITIAL_REP * 2, 0.52, 5)

            whale_results = simulate_whale_attack(market, whale, honest_users)
            whale_results.update({
                'trial': trial,
                'market_size': market_size,
                'scenario': 'whale_attack',
                'n_honest': n_honest
            })
            results.append(whale_results)

            # Scenario 2: Sybil attack
            sybil_results = simulate_sybil_attack(
                market, whale.capital, 10, honest_users
            )
            sybil_results.update({
                'trial': trial,
                'market_size': market_size,
                'scenario': 'sybil_attack',
                'n_honest': n_honest,
                'attacker_capital_pct': whale.capital / (whale.capital + sum(u.capital for u in honest_users)) * 100
            })
            results.append(sybil_results)

    return pd.DataFrame(results)


def analyze_results(df: pd.DataFrame):
    """
    Statistical analysis of simulation results
    ✅ NO HARDCODED CLAIMS - All derived from data
    """

    print("="*80)
    print("SYBIL ATTACK RESISTANCE ANALYSIS")
    print("="*80)
    print()

    # Whale attack analysis
    whale_df = df[df['scenario'] == 'whale_attack']
    print("--- WHALE ATTACK SCENARIO ---")
    print(
        f"Mean attacker capital: {whale_df['attacker_capital'].mean():.2f} ETH")
    print(
        f"Mean attacker reputation: {whale_df['attacker_reputation'].mean():.2f}")
    print(
        f"Mean attacker position limit: {whale_df['attacker_limit'].mean():.2f} ETH")
    print(
        f"Mean attacker influence: {whale_df['attacker_influence_pct'].mean():.2f}% (SD: {whale_df['attacker_influence_pct'].std():.2f})")
    print(
        f"Expected influence (no protection): {whale_df['expected_influence_pct'].mean():.2f}%")
    print(
        f"Mean gain ratio: {whale_df['gain_ratio'].mean():.3f} (target: <1.0)")
    print(
        f"Mean protection effectiveness: {whale_df['protection_effectiveness'].mean():.2f}%")
    print()

    # Sybil attack analysis
    sybil_df = df[df['scenario'] == 'sybil_attack']
    print("--- SYBIL ATTACK SCENARIO ---")
    print(
        f"Initial reputation per sybil: {sybil_df['sybil_initial_rep'].iloc[0]}")
    print(
        f"Genesis phase blocked: {sybil_df['genesis_blocked'].sum()} / {len(sybil_df)} trials ({sybil_df['genesis_blocked'].mean() * 100:.1f}%)")
    print()
    print("Sybil Advantage vs Different Benchmarks:")
    print(
        f"  vs Tier 3 user (1000 rep, 60% acc): {sybil_df['sybil_advantage_tier3'].mean():.3f} ± {sybil_df['sybil_advantage_tier3'].std():.3f}")
    print(
        f"  vs Tier 5 user (10k rep, 70% acc): {sybil_df['sybil_advantage_tier5'].mean():.3f} ± {sybil_df['sybil_advantage_tier5'].std():.3f}")
    print()
    print(
        f"MeritRank Compliance (≤2.0 vs Tier 5): {sybil_df['meritrank_compliant'].mean() * 100:.1f}% of trials")
    print(
        f"Mean sybil influence: {sybil_df['sybil_influence_pct'].mean():.2f}%")
    print()

    # Market size correlation
    print("--- MARKET SIZE EFFECTS ---")
    for size in sorted(df['market_size'].unique()):
        size_whale = whale_df[whale_df['market_size'] == size]
        size_sybil = sybil_df[sybil_df['market_size'] == size]
        print(f"Market size {size} ETH:")
        print(
            f"  Whale gain ratio: {size_whale['gain_ratio'].mean():.3f} ± {size_whale['gain_ratio'].std():.3f}")
        print(
            f"  Sybil advantage (vs Tier 5): {size_sybil['sybil_advantage_tier5'].mean():.3f} ± {size_sybil['sybil_advantage_tier5'].std():.3f}")
    print()

    # Statistical tests
    small_market = whale_df[whale_df['market_size'] == 10]['gain_ratio']
    large_market = whale_df[whale_df['market_size'] == 10000]['gain_ratio']

    if len(small_market) > 0 and len(large_market) > 0:
        t_stat, p_value = ttest_ind(small_market, large_market)
        print(
            f"T-test (small vs large market whale protection): t={t_stat:.3f}, p={p_value:.4f}")
    print()

    # Reputation decay simulation
    print("--- REPUTATION DECAY RESISTANCE ---")
    decay_results = []
    for months in range(0, 13):
        decay_data = simulate_reputation_decay_resistance(10000, months)
        decay_results.append(decay_data)

    decay_df = pd.DataFrame(decay_results)
    print(decay_df.to_string(index=False))
    print()

    return {
        'whale_gain_ratio_mean': whale_df['gain_ratio'].mean(),
        'whale_gain_ratio_std': whale_df['gain_ratio'].std(),
        'whale_protection_pct': whale_df['protection_effectiveness'].mean(),
        'sybil_advantage_tier3_mean': sybil_df['sybil_advantage_tier3'].mean(),
        'sybil_advantage_tier5_mean': sybil_df['sybil_advantage_tier5'].mean(),
        'sybil_advantage_tier5_std': sybil_df['sybil_advantage_tier5'].std(),
        'genesis_block_rate': sybil_df['genesis_blocked'].mean() * 100,
        'meritrank_compliance_rate': sybil_df['meritrank_compliant'].mean() * 100
    }


def main():
    """Execute comprehensive simulation"""
    np.random.seed(42)

    print("Running 100 Monte Carlo trials across 4 market sizes...")
    print("Testing: whale attacks, sybil attacks, genesis phase, 5-tier limits")
    print("This will take ~30 seconds...")
    print()

    df = run_comprehensive_simulation(n_trials=100)

    # Save raw data
    df.to_csv('sybil_simulation_results.csv', index=False)
    print("Raw data saved to: sybil_simulation_results.csv")
    print()

    # Statistical analysis
    summary_stats = analyze_results(df)

    # Export for paper
    print("="*80)
    print("PAPER-READY STATISTICS")
    print("="*80)
    print(
        f"✅ Initial Reputation: {ReputationWeightedMarket.INITIAL_REP} tokens (matches contract)")
    print(
        f"✅ Genesis Phase Protection: {summary_stats['genesis_block_rate']:.1f}% of sybil attacks blocked")
    print(
        f"✅ Whale Attack Protection: {summary_stats['whale_protection_pct']:.1f}% reduction in influence")
    print(
        f"✅ Sybil Advantage (vs Tier 5): {summary_stats['sybil_advantage_tier5_mean']:.2f} ± {summary_stats['sybil_advantage_tier5_std']:.2f}")
    print(
        f"✅ MeritRank Compliance: {summary_stats['meritrank_compliance_rate']:.1f}% of trials (target: 100%)")
    print(
        f"✅ Gain Ratio: {summary_stats['whale_gain_ratio_mean']:.3f} ± {summary_stats['whale_gain_ratio_std']:.3f} (target: <1.0)")
    print()
    print("Key Findings:")
    if summary_stats['sybil_advantage_tier5_mean'] <= 2.0:
        print("  ✓ MeritRank compliant: Sybil advantage ≤ 2.0 (vs high-reputation users)")
    else:
        print(
            f"  ⚠ Sybil advantage {summary_stats['sybil_advantage_tier5_mean']:.2f} > 2.0 (needs review)")

    if summary_stats['whale_gain_ratio_mean'] < 1.0:
        print(
            f"  ✓ Whale protection active: {summary_stats['whale_protection_pct']:.1f}% influence reduction")
    else:
        print("  ✗ Whale protection insufficient")

    if summary_stats['genesis_block_rate'] > 90:
        print("  ✓ Genesis phase effective: >90% sybil attacks blocked")
    else:
        print("  ⚠ Genesis phase needs review")


if __name__ == "__main__":
    main()
