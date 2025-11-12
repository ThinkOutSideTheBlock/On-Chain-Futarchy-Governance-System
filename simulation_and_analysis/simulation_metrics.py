# simulation_metrics_FIXED.py
import json
import time
import random
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
from web3 import Web3
from typing import Dict, List, Tuple
from dataclasses import dataclass, asdict
from scipy import stats
from pathlib import Path

# ==================== CONFIGURATION ====================

ANVIL_URL = "http://localhost:8545"
FORGE_OUT_DIR = "out"
DEPLOYED_CONTRACTS_FILE = "deployed_contracts.json"

N_USERS = 20
N_MARKETS = 50
SIMULATION_SEED = 42

# ⚡ NEW: Block advancement config
BLOCKS_PER_MARKET = 5
SKIP_GENESIS_BLOCKS = 105  # Skip first 105 blocks to avoid genesis phase

# ==================== STANDARD ERC20 ABI ====================
ERC20_ABI = [
    {
        "constant": True,
        "inputs": [{"name": "_owner", "type": "address"}],
        "name": "balanceOf",
        "outputs": [{"name": "balance", "type": "uint256"}],
        "type": "function"
    },
    {
        "constant": False,
        "inputs": [
            {"name": "_to", "type": "address"},
            {"name": "_value", "type": "uint256"}
        ],
        "name": "transfer",
        "outputs": [{"name": "", "type": "bool"}],
        "type": "function"
    },
    {
        "constant": False,
        "inputs": [
            {"name": "_spender", "type": "address"},
            {"name": "_value", "type": "uint256"}
        ],
        "name": "approve",
        "outputs": [{"name": "", "type": "bool"}],
        "type": "function"
    }
]

# ==================== DATA CLASSES ====================


@dataclass
class MarketData:
    market_id: int
    creation_time: int
    creation_block: int  # ⚡ NEW
    close_time: int
    resolved_outcome: int
    total_staked: float
    total_fees: float
    total_payouts: float
    final_price: float
    b_parameter: float  # ⚡ NEW: LMSR liquidity parameter
    n_outcomes: int  # ⚡ NEW


@dataclass
class TradeData:
    market_id: int
    trader: str
    stake: float
    outcome: int
    price_before: float
    price_after: float
    execution_price: float
    slippage: float
    gas_used: int
    block_number: int
    timestamp: int
    tx_hash: str
    user_reputation: float  # ⚡ NEW


@dataclass
class UserData:
    address: str
    reputation: float
    accuracy: float
    total_stakes: float
    correct_predictions: int
    total_predictions: int

# ==================== HELPER FUNCTIONS ====================


def load_forge_artifact(contract_name: str) -> dict:
    """Load contract ABI from Forge build output"""
    artifact_path = Path(FORGE_OUT_DIR) / \
        f"{contract_name}.sol" / f"{contract_name}.json"

    if not artifact_path.exists():
        raise FileNotFoundError(
            f"Contract artifact not found: {artifact_path}\n"
            f"Run 'forge build' first to generate artifacts."
        )

    with open(artifact_path, 'r') as f:
        artifact = json.load(f)

    return artifact['abi']


def load_deployed_addresses() -> dict:
    """Load deployed contract addresses"""
    with open(DEPLOYED_CONTRACTS_FILE, 'r') as f:
        contracts = json.load(f)

    addresses = {}
    for name, data in contracts.items():
        addresses[name] = data['address'].strip()

    return addresses

# ==================== SIMULATION ENGINE ====================


class PredictionMarketSimulator:
    def __init__(self, anvil_url=ANVIL_URL):
        print("🔗 Connecting to Anvil...")
        self.w3 = Web3(Web3.HTTPProvider(anvil_url))

        if not self.w3.is_connected():
            raise ConnectionError(
                "Cannot connect to Anvil. Is it running on http://localhost:8545?"
            )

        print(f"✓ Connected to Anvil (chainId: {self.w3.eth.chain_id})")
        print(f"✓ Current block: {self.w3.eth.block_number}")

        self.load_contracts()
        self.users = []
        self.markets_data = []
        self.trades_data = []
        self.users_data = {}

        random.seed(SIMULATION_SEED)
        np.random.seed(SIMULATION_SEED)

    def load_contracts(self):
        """Load deployed contracts"""
        print("\n📦 Loading contract artifacts...")

        try:
            market_abi = load_forge_artifact('GovernancePredictionMarket')
            rep_abi = load_forge_artifact('ReputationToken')
            print("✓ Contract ABIs loaded")
        except FileNotFoundError as e:
            print(f"\n❌ Error: {e}")
            print("\nPlease run 'forge build' first.")
            exit(1)

        print("\n📍 Loading deployment addresses...")
        addresses = load_deployed_addresses()

        print(f"✓ Market: {addresses['GovernancePredictionMarket']}")
        print(f"✓ Reputation: {addresses['ReputationToken']}")
        print(f"✓ Staking Token: {addresses['DummyStakingToken']}")

        self.market = self.w3.eth.contract(
            address=Web3.to_checksum_address(
                addresses['GovernancePredictionMarket']),
            abi=market_abi
        )

        self.rep_token = self.w3.eth.contract(
            address=Web3.to_checksum_address(addresses['ReputationToken']),
            abi=rep_abi
        )

        self.staking_token = self.w3.eth.contract(
            address=Web3.to_checksum_address(addresses['DummyStakingToken']),
            abi=ERC20_ABI
        )

        self.admin = self.w3.eth.accounts[0]

        print("✓ All contracts loaded")

    def setup_users(self, n_users=N_USERS):
        """Setup test users with sufficient reputation"""
        print(f"\n👥 Setting up {n_users} users...")

        available_accounts = min(n_users, len(self.w3.eth.accounts) - 1)

        for i in range(1, available_accounts + 1):
            address = self.w3.eth.accounts[i]

            # Transfer staking tokens
            try:
                tx_hash = self.staking_token.functions.transfer(
                    address,
                    self.w3.to_wei(10000, 'ether')
                ).transact({'from': self.admin})
                self.w3.eth.wait_for_transaction_receipt(tx_hash)

                # Approve market
                tx_hash = self.staking_token.functions.approve(
                    self.market.address,
                    2**256 - 1
                ).transact({'from': address})
                self.w3.eth.wait_for_transaction_receipt(tx_hash)

            except Exception as e:
                print(
                    f"⚠️  Warning: Could not fund user {address}: {str(e)[:80]}")
                continue

            # Initialize user (grants 100 REP)
            try:
                tx_hash = self.market.functions.initializeUser(
                    address
                ).transact({'from': self.admin})
                self.w3.eth.wait_for_transaction_receipt(tx_hash)
            except Exception as e:
                print(f"⚠️  Warning: Could not initialize user: {str(e)[:80]}")

            # ⚡ NEW: Grant ADDITIONAL reputation to meet genesis requirements
            try:
                # Need 1000+ REP for genesis phase (user has 100, need 900 more)
                # But bonding curve reduces minting, so request 1500 to get ~900
                tx_hash = self.rep_token.functions.mintReputation(
                    address,
                    self.w3.to_wei(1500, 'ether'),  # Request 1500
                    7500  # 75% accuracy
                ).transact({'from': self.admin})
                self.w3.eth.wait_for_transaction_receipt(tx_hash)
            except Exception as e:
                print(
                    f"⚠️  Warning: Could not grant extra reputation: {str(e)[:80]}")

            # Get final reputation
            try:
                rep = self.rep_token.functions.balanceOf(address).call()
                rep_float = float(self.w3.from_wei(rep, 'ether'))
            except:
                rep_float = 0

            user = {
                'address': address,
                'skill': random.uniform(0.4, 0.9),
                'correct_predictions': 0,
                'total_predictions': 0,
                'total_stakes': 0
            }

            self.users.append(user)

            self.users_data[address] = UserData(
                address=address,
                reputation=rep_float,
                accuracy=0.5,
                total_stakes=0,
                correct_predictions=0,
                total_predictions=0
            )

            print(f"  ✓ User {i}: {rep_float:.0f} REP")

        print(f"✓ {len(self.users)} users initialized")

    def advance_blocks(self, n_blocks: int):
        """Advance Anvil blockchain by n blocks"""
        try:
            # Use Anvil's evm_mine RPC method
            for _ in range(n_blocks):
                self.w3.provider.make_request("evm_mine", [])
        except Exception as e:
            print(f"⚠️  Warning: Could not mine blocks: {e}")

    def create_market(self, market_id: int) -> Tuple[int, int]:
        """Create a prediction market"""
        try:
            current_block = self.w3.eth.block_number

            tx_hash = self.market.functions.createMarket(
                f"Will event {market_id} happen?",
                f"Description for market {market_id}",
                self.w3.keccak(text=f"market-{market_id}"),
                int(time.time()) + 7200,  # 2 hours trading
                ["YES", "NO"],
                0,  # Category
                self.w3.to_wei(100, 'ether')  # Min liquidity
            ).transact({
                'from': self.admin,
                'gas': 3000000
            })

            receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)

            if receipt['status'] == 1:
                return market_id, current_block
            else:
                print(f"❌ Market {market_id}: Transaction reverted")
                return None, None

        except Exception as e:
            print(f"❌ Market {market_id}: {str(e)[:100]}")
            return None, None

    def simulate_trading(self, market_id: int, n_trades: int = 10):
        """Simulate trading on market with proper block advancement"""
        trades = []

        for trade_num in range(n_trades):
            if not self.users:
                break

            user = random.choice(self.users)
            stake = random.uniform(1, 10)
            outcome = 0 if random.random() < user['skill'] else 1

            # ⚡ NEW: Advance 1 block per trade (prevents same-block issues)
            self.advance_blocks(1)

            trade = self._execute_trade(market_id, user, stake, outcome)
            if trade:
                trades.append(trade)
            else:
                print(f"  ⚠️  Trade {trade_num+1}/{n_trades} failed")

        return trades

    def _execute_trade(self, market_id: int, user: dict, stake: float, outcome: int) -> TradeData:
        """Execute single trade with PROPER error handling"""

        # ⚡ FIXED: Get price using correct function
        price_before = self._get_market_price(market_id, outcome)

        try:
            # Get user reputation BEFORE trade
            user_rep = self.rep_token.functions.balanceOf(
                user['address']).call()
            user_rep_float = float(self.w3.from_wei(user_rep, 'ether'))

            # Execute trade
            tx_hash = self.market.functions.takePosition(
                market_id,
                outcome,
                self.w3.to_wei(stake, 'ether'),
                1000  # 10% reputation stake
            ).transact({
                'from': user['address'],
                'gas': 500000
            })

            receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)

            # ⚡ NEW: Check if transaction actually succeeded
            if receipt['status'] != 1:
                print(
                    f"    ❌ Trade reverted: market={market_id}, user={user['address'][:8]}")
                return None

            # Get price after trade
            price_after = self._get_market_price(market_id, outcome)

            execution_price = (price_before + price_after) / 2
            slippage = abs(execution_price - price_before) / \
                max(price_before, 0.01)

            user['total_predictions'] += 1
            user['total_stakes'] += stake

            return TradeData(
                market_id=market_id,
                trader=user['address'],
                stake=stake,
                outcome=outcome,
                price_before=price_before,
                price_after=price_after,
                execution_price=execution_price,
                slippage=slippage,
                gas_used=receipt['gasUsed'],
                block_number=receipt['blockNumber'],
                timestamp=int(time.time()),
                tx_hash=tx_hash.hex(),
                user_reputation=user_rep_float  # ⚡ NEW
            )

        except Exception as e:
            # ⚡ NEW: Print actual error instead of silently failing
            print(f"    ❌ Trade exception: {str(e)[:100]}")
            return None

    def resolve_market(self, market_id: int) -> int:
        """Resolve market randomly"""
        outcome = random.choice([0, 1])

        # Update user stats
        for trade in self.trades_data:
            if trade.market_id == market_id:
                user_data = self.users_data.get(trade.trader)
                if user_data:
                    if trade.outcome == outcome:
                        user_data.correct_predictions += 1
                    user_data.total_predictions += 1
                    if user_data.total_predictions > 0:
                        user_data.accuracy = user_data.correct_predictions / user_data.total_predictions

        return outcome

    def _get_market_price(self, market_id: int, outcome: int = 0) -> float:
        """⚡ FIXED: Get market price using CORRECT function"""
        try:
            # ✅ Use the ACTUAL function that exists in your contract
            probabilities = self.market.functions.getOutcomeProbabilities(
                market_id).call()

            if len(probabilities) > outcome:
                # Probabilities are in basis points (10000 = 100%)
                return probabilities[outcome] / 10000
            else:
                return 0.5

        except Exception as e:
            # Fallback to 0.5 if error
            print(f"    ⚠️  Price query failed: {str(e)[:60]}")
            return 0.5

# ==================== METRICS CALCULATOR ====================


class MetricsCalculator:
    def __init__(self, markets: List[MarketData], trades: List[TradeData], users: Dict[str, UserData]):
        self.markets_df = pd.DataFrame(
            [asdict(m) for m in markets]) if markets else pd.DataFrame()
        self.trades_df = pd.DataFrame(
            [asdict(t) for t in trades]) if trades else pd.DataFrame()
        self.users_df = pd.DataFrame(
            [asdict(u) for u in users.values()]) if users else pd.DataFrame()

    def calculate_all_metrics(self) -> dict:
        """Calculate all metrics"""
        metrics = {}

        # A. Prediction Quality
        metrics['brier_score'] = self.calculate_brier_score()
        metrics['log_loss'] = self.calculate_log_loss()
        metrics['calibration'] = self.calculate_calibration()

        # B. Market Microstructure
        metrics['slippage'] = self.calculate_slippage_stats()
        metrics['market_depth'] = self.calculate_market_depth()
        metrics['lmsr_loss'] = self.calculate_lmsr_loss()

        # C. Reputation
        metrics['gini_coefficient'] = self.calculate_gini()
        metrics['rep_accuracy_corr'] = self.calculate_rep_accuracy_correlation()

        # D. Gas
        metrics['gas_stats'] = self.calculate_gas_stats()

        return metrics

    def calculate_brier_score(self) -> Tuple[float, Tuple[float, float]]:
        """Brier score with CI"""
        if len(self.markets_df) == 0:
            return 0.0, (0.0, 0.0)

        predictions = self.markets_df['final_price'].values
        outcomes = self.markets_df['resolved_outcome'].values

        brier = np.mean((predictions - outcomes) ** 2)
        ci_lower, ci_upper = self.bootstrap_ci((predictions - outcomes) ** 2)

        return brier, (ci_lower, ci_upper)

    def calculate_log_loss(self) -> float:
        """Log loss"""
        if len(self.markets_df) == 0:
            return 0.0

        predictions = self.markets_df['final_price'].values
        outcomes = self.markets_df['resolved_outcome'].values

        eps = 1e-12
        predictions = np.clip(predictions, eps, 1 - eps)

        return -np.mean(
            outcomes * np.log(predictions) +
            (1 - outcomes) * np.log(1 - predictions)
        )

    def calculate_calibration(self, n_bins=10) -> list:
        """Calibration curve"""
        if len(self.markets_df) == 0:
            return []

        predictions = self.markets_df['final_price'].values
        outcomes = self.markets_df['resolved_outcome'].values

        bin_edges = np.linspace(0, 1, n_bins + 1)
        bin_indices = np.digitize(predictions, bin_edges) - 1

        calibration_data = []
        for i in range(n_bins):
            mask = bin_indices == i
            if mask.sum() > 0:
                calibration_data.append({
                    'bin': i,
                    'avg_prediction': predictions[mask].mean(),
                    'observed_frequency': outcomes[mask].mean(),
                    'count': mask.sum()
                })

        return calibration_data

    def calculate_slippage_stats(self) -> pd.DataFrame:
        """Slippage statistics"""
        if len(self.trades_df) == 0:
            return pd.DataFrame()

        df = self.trades_df.copy()
        df['size_bucket'] = pd.cut(
            df['stake'],
            bins=[0, 1, 5, 10, float('inf')],
            labels=['<1', '1-5', '5-10', '>10']
        )

        return df.groupby('size_bucket')['slippage'].agg([
            'mean', 'median',
            ('p95', lambda x: np.percentile(x, 95) if len(x) > 0 else 0)
        ])

    def calculate_market_depth(self) -> float:
        """Market depth"""
        if len(self.trades_df) == 0:
            return 0.0
        return self.trades_df['stake'].mean()

    def calculate_lmsr_loss(self) -> float:
        """LMSR loss"""
        if len(self.markets_df) == 0:
            return 0.0
        return (self.markets_df['total_payouts'].sum() -
                self.markets_df['total_staked'].sum() +
                self.markets_df['total_fees'].sum())

    def calculate_gini(self) -> float:
        """Gini coefficient"""
        if len(self.users_df) == 0:
            return 0.0

        reputations = np.sort(self.users_df['reputation'].values)
        n = len(reputations)
        if n == 0 or reputations.sum() == 0:
            return 0.0
        index = np.arange(1, n + 1)
        return (2 * np.sum(index * reputations)) / (n * np.sum(reputations)) - (n + 1) / n

    def calculate_rep_accuracy_correlation(self) -> Tuple[float, float]:
        """Rep-accuracy correlation"""
        active = self.users_df[self.users_df['total_predictions'] >= 3]

        if len(active) < 2:
            return 0.0, 1.0

        return stats.spearmanr(active['reputation'], active['accuracy'])

    def calculate_gas_stats(self) -> pd.DataFrame:
        """Gas statistics"""
        if len(self.trades_df) == 0:
            return pd.DataFrame()

        return pd.DataFrame({
            'takePosition': {
                'median': self.trades_df['gas_used'].median(),
                'p95': self.trades_df['gas_used'].quantile(0.95),
                'mean': self.trades_df['gas_used'].mean()
            }
        }).T

    def bootstrap_ci(self, values, n_boot=1000, alpha=0.05):
        """Bootstrap CI"""
        n = len(values)
        boot_stats = []

        for _ in range(n_boot):
            sample = np.random.choice(values, size=n, replace=True)
            boot_stats.append(np.mean(sample))

        lower = np.percentile(boot_stats, 100 * alpha / 2)
        upper = np.percentile(boot_stats, 100 * (1 - alpha / 2))

        return lower, upper

# ==================== VISUALIZATION ====================


class ResultsVisualizer:
    def __init__(self, metrics: dict):
        self.metrics = metrics
        sns.set_style("whitegrid")
        Path("figures").mkdir(exist_ok=True)

    def create_all_figures(self):
        """Create all figures"""
        print("\n📊 Generating figures...")

        if len(self.metrics.get('calibration', [])) > 0:
            self.plot_calibration_curve()
            print("✓ Calibration curve saved")

        if not self.metrics.get('slippage', pd.DataFrame()).empty:
            self.plot_slippage_analysis()
            print("✓ Slippage analysis saved")

        self.plot_metrics_summary()
        print("✓ Metrics summary saved")

    def plot_calibration_curve(self):
        """Calibration curve"""
        fig, ax = plt.subplots(figsize=(8, 6))

        cal = pd.DataFrame(self.metrics['calibration'])

        ax.plot([0, 1], [0, 1], 'k--', alpha=0.5, label='Perfect calibration')
        ax.plot(cal['avg_prediction'], cal['observed_frequency'],
                'bo-', label='Observed', markersize=8)

        ax.set_xlabel('Mean Predicted Probability')
        ax.set_ylabel('Observed Frequency')
        ax.set_title('Calibration Curve')
        ax.legend()
        ax.grid(True, alpha=0.3)

        plt.tight_layout()
        plt.savefig('figures/calibration_curve.pdf',
                    dpi=300, bbox_inches='tight')
        plt.close()

    def plot_slippage_analysis(self):
        """Slippage plot"""
        fig, ax = plt.subplots(figsize=(8, 6))

        slippage = self.metrics['slippage']
        slippage['mean'].plot(kind='bar', ax=ax, alpha=0.7)

        ax.set_xlabel('Trade Size Bucket')
        ax.set_ylabel('Mean Slippage')
        ax.set_title('Price Impact by Trade Size')

        plt.tight_layout()
        plt.savefig('figures/slippage_analysis.pdf',
                    dpi=300, bbox_inches='tight')
        plt.close()

    def plot_metrics_summary(self):
        """Summary plot"""
        fig, ((ax1, ax2), (ax3, ax4)) = plt.subplots(2, 2, figsize=(12, 10))

        # Brier score
        brier, (ci_low, ci_high) = self.metrics['brier_score']
        ax1.bar(['Brier Score'], [brier], yerr=[
                [brier-ci_low], [ci_high-brier]])
        ax1.set_ylabel('Brier Score')
        ax1.set_title('Prediction Quality')

        # Gini
        ax2.bar(['Gini'], [self.metrics['gini_coefficient']])
        ax2.set_ylabel('Gini Coefficient')
        ax2.set_title('Reputation Inequality')
        ax2.set_ylim([0, 1])

        # Market depth
        ax3.bar(['Avg Depth'], [self.metrics['market_depth']])
        ax3.set_ylabel('Average Stake')
        ax3.set_title('Market Depth')

        # Correlation
        corr, p_val = self.metrics['rep_accuracy_corr']
        ax4.bar(['Correlation'], [corr])
        ax4.set_ylabel('Spearman ρ')
        ax4.set_title(f'Rep-Accuracy Correlation (p={p_val:.3f})')
        ax4.set_ylim([-1, 1])

        plt.tight_layout()
        plt.savefig('figures/metrics_summary.pdf',
                    dpi=300, bbox_inches='tight')
        plt.close()

# ==================== MAIN ====================


def main():
    print("=" * 60)
    print("PREDICTION MARKET SIMULATION & METRICS (FIXED)")
    print("=" * 60)

    # Initialize
    print("\n1. Initializing...")
    simulator = PredictionMarketSimulator()

    # ⚡ NEW: Skip genesis phase by advancing blocks
    print(f"\n⏭️  Skipping genesis phase ({SKIP_GENESIS_BLOCKS} blocks)...")
    simulator.advance_blocks(SKIP_GENESIS_BLOCKS)
    print(f"✓ Current block: {simulator.w3.eth.block_number}")

    # Setup users
    print("\n2. Setting up users...")
    simulator.setup_users(N_USERS)

    # Run simulation
    print(f"\n3. Running simulation ({N_MARKETS} markets)...")

    all_markets = []
    all_trades = []

    successful_markets = 0
    failed_markets = 0

    for i in range(N_MARKETS):
        if i % 10 == 0:
            print(
                f"\n   📊 Progress: {i}/{N_MARKETS} (Success: {successful_markets}, Failed: {failed_markets})")

        # Create market
        market_id, creation_block = simulator.create_market(i)
        if market_id is None:
            failed_markets += 1
            continue

        # ⚡ NEW: Advance a few blocks after market creation
        simulator.advance_blocks(BLOCKS_PER_MARKET)

        # Simulate trading
        print(f"   🔄 Trading on market {market_id}...")
        trades = simulator.simulate_trading(market_id, n_trades=10)
        valid_trades = [t for t in trades if t is not None]

        print(
            f"   ✓ Market {market_id}: {len(valid_trades)}/10 successful trades")

        if len(valid_trades) == 0:
            print(
                f"   ⚠️  Warning: No successful trades on market {market_id}")
            failed_markets += 1
            continue

        all_trades.extend(valid_trades)
        simulator.trades_data.extend(valid_trades)

        # Resolve market
        outcome = simulator.resolve_market(market_id)

        # Get final price
        try:
            final_price = simulator._get_market_price(market_id, 0)
        except:
            final_price = 0.5

        # Get LMSR b parameter from contract
        try:
            market_info = simulator.market.functions.markets(market_id).call()
            b_parameter = float(simulator.w3.from_wei(
                market_info[15], 'ether'))  # liquidityParameter
            n_outcomes = market_info[9]  # outcomeCount
        except:
            b_parameter = 100.0
            n_outcomes = 2

        market_data = MarketData(
            market_id=market_id,
            creation_time=int(time.time()),
            creation_block=creation_block if creation_block else 0,
            close_time=int(time.time()) + 7200,
            resolved_outcome=outcome,
            total_staked=sum(t.stake for t in valid_trades),
            total_fees=sum(t.stake * 0.02 for t in valid_trades),
            total_payouts=sum(
                t.stake * 2 for t in valid_trades if t.outcome == outcome),
            final_price=final_price,
            b_parameter=b_parameter,  # ⚡ NEW
            n_outcomes=n_outcomes  # ⚡ NEW
        )
        all_markets.append(market_data)
        successful_markets += 1

    print(f"\n✅ Simulation complete!")
    print(
        f"   Markets: {len(all_markets)} successful, {failed_markets} failed")
    print(f"   Trades: {len(all_trades)} total")
    print(f"   Trade success rate: {len(all_trades)/(N_MARKETS*10)*100:.1f}%")

    if len(all_markets) == 0:
        print("\n❌ ERROR: No successful markets! Check your deployment and setup.")
        return

    if len(all_trades) == 0:
        print("\n❌ ERROR: No successful trades! Check genesis phase and reputation.")
        return

    # Calculate metrics
    print("\n4. Calculating metrics...")
    calculator = MetricsCalculator(
        all_markets, all_trades, simulator.users_data)
    metrics = calculator.calculate_all_metrics()

    # Print results
    print("\n" + "=" * 60)
    print("RESULTS")
    print("=" * 60)

    brier, (ci_low, ci_high) = metrics['brier_score']
    print(f"\n📊 Prediction Quality:")
    print(
        f"   Brier Score: {brier:.4f} (95% CI: [{ci_low:.4f}, {ci_high:.4f}])")
    if brier > 0.24:
        print(
            f"   ⚠️  WARNING: Brier = {brier:.4f} suggests uninformative predictions")
        print(f"       (0.25 = random 50/50 guessing)")
    print(f"   Log Loss: {metrics['log_loss']:.4f}")

    print(f"\n💰 Market Microstructure:")
    print(f"   LMSR Loss: ${metrics['lmsr_loss']:,.2f}")
    if metrics['lmsr_loss'] > 0:
        print(f"   ⚠️  Positive loss = protocol paid more than collected")
    print(f"   Market Depth: ${metrics['market_depth']:,.2f}")

    print(f"\n👥 Reputation:")
    print(f"   Gini: {metrics['gini_coefficient']:.4f}")
    corr, p_val = metrics['rep_accuracy_corr']
    print(f"   Rep-Accuracy Correlation: {corr:.4f} (p={p_val:.4f})")
    if p_val < 0.05:
        print(f"   ✓ Significant correlation detected!")

    if not metrics['gas_stats'].empty:
        print(f"\n⛽ Gas:")
        print(metrics['gas_stats'].to_string())

    # ⚡ NEW: Price movement analysis
    print(f"\n📈 Price Movement:")
    price_changes = []
    for trade in all_trades:
        price_change = abs(trade.price_after - trade.price_before)
        price_changes.append(price_change)

    if price_changes:
        print(f"   Mean price change per trade: {np.mean(price_changes):.4f}")
        print(f"   Median price change: {np.median(price_changes):.4f}")
        print(f"   Max price change: {np.max(price_changes):.4f}")

        if np.mean(price_changes) < 0.001:
            print(
                f"   ⚠️  WARNING: Prices barely moving (mean Δ = {np.mean(price_changes):.6f})")
            print(
                f"       Check LMSR b parameter (current: {all_markets[0].b_parameter:.2f})")

    # Save
    print("\n5. Saving results...")
    Path("data").mkdir(exist_ok=True)

    results = {
        'config': {
            'n_users': N_USERS,
            'n_markets': N_MARKETS,
            'seed': SIMULATION_SEED,
            'skip_genesis_blocks': SKIP_GENESIS_BLOCKS,
            'blocks_per_market': BLOCKS_PER_MARKET
        },
        'markets': [asdict(m) for m in all_markets],
        'trades': [asdict(t) for t in all_trades],
        'users': [asdict(u) for u in simulator.users_data.values()],
        'metrics': {
            'brier_score': float(brier),
            'brier_ci': [float(ci_low), float(ci_high)],
            'log_loss': float(metrics['log_loss']),
            'gini': float(metrics['gini_coefficient']),
            'rep_corr': float(corr),
            'rep_corr_p': float(p_val),
            'price_movement': {
                'mean': float(np.mean(price_changes)) if price_changes else 0,
                'median': float(np.median(price_changes)) if price_changes else 0,
                'max': float(np.max(price_changes)) if price_changes else 0
            }
        }
    }

    with open('data/simulation_results.json', 'w') as f:
        json.dump(results, f, indent=2, default=str)
    print("✓ Saved to data/simulation_results.json")

    # Visualize
    print("\n6. Generating figures...")
    viz = ResultsVisualizer(metrics)
    viz.create_all_figures()

    print("\n" + "=" * 60)
    print("✅ COMPLETE!")
    print("=" * 60)
    print("\nOutputs:")
    print("  - data/simulation_results.json")
    print("  - figures/*.pdf")

    # ⚡ NEW: Diagnostic summary
    print("\n" + "=" * 60)
    print("DIAGNOSTIC SUMMARY")
    print("=" * 60)

    if brier > 0.24:
        print("\n⚠️  ISSUE: Uninformative predictions (Brier ≈ 0.25)")
        print("   Possible causes:")
        print("   1. LMSR b parameter too high (prices insensitive to trades)")
        print("   2. Trade sizes too small relative to liquidity")
        print("   3. Not enough trading activity per market")

    if len(price_changes) > 0 and np.mean(price_changes) < 0.001:
        print("\n⚠️  ISSUE: Prices not moving")
        print("   Solutions:")
        print("   1. Reduce MIN_LIQUIDITY (currently 100 ETH)")
        print("   2. Increase trade sizes (currently 1-10 ETH)")
        print("   3. More trades per market (currently 10)")

    if metrics['lmsr_loss'] > 0:
        print(
            f"\n⚠️  ISSUE: Protocol losing money (${metrics['lmsr_loss']:,.2f})")
        print("   Review reward calculation and fee structure")

    print("\n✅ If all looks good, simulation is working correctly!")


if __name__ == "__main__":
    main()
