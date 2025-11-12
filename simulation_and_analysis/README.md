# Simulation and Analysis Suite

This folder contains all the Python-based simulation and analysis scripts for the Governance Prediction Markets research project.

## Overview

These scripts enable comprehensive analysis of the prediction market system including:
- **Cartel Formation Analysis**: Simulates and analyzes cartel attack scenarios
- **Sybil Attack Simulation**: Evaluates system resilience against Sybil attacks
- **Prediction Accuracy Metrics**: Measures prediction accuracy and performance
- **Comparative Analysis**: Compares metrics across different scenarios
- **Gas Benchmarking**: Analyzes smart contract gas usage

## Files

### Core Analysis Scripts

#### 1. **cartel_analysis.py**
Analyzes cartel formation and coordination attacks on the prediction market.
- Simulates coordinated voting behavior
- Evaluates market manipulation resistance
- Generates cartel impact metrics
- Output: `cartel_simulation_results.csv`

```bash
python cartel_analysis.py
```

#### 2. **sybil_simulation.py**
Evaluates system resilience against Sybil attacks (fake identity attacks).
- Simulates multiple fake identities joining the market
- Analyzes reputation token accumulation
- Tests voting power distribution
- Output: `sybil_simulation_results.csv`

```bash
python sybil_simulation.py
```

#### 3. **prediction_accuracy.py**
Measures and tracks prediction accuracy across different scenarios.
- Calculates Brier score and other accuracy metrics
- Compares against baseline predictions
- Analyzes forecast calibration
- Output: `accuracy_comparison_results.csv`

```bash
python prediction_accuracy.py
```

#### 4. **simulation_metrics.py**
Comprehensive metrics calculator for simulation data.
- Aggregates results from all simulations
- Computes statistical measures (mean, median, std dev)
- Generates comparative statistics
- Supports detailed metric reporting

```bash
python simulation_metrics.py
```

#### 5. **comparative_metrics.py**
Comparative analysis across different market scenarios.
- Compares cartel vs. sybil attack results
- Analyzes relative system resilience
- Generates comparison reports
- Creates visualization data

```bash
python comparative_metrics.py
```

### Pipeline Scripts

#### 6. **run_paper_pipeline.sh**
Main pipeline for executing the complete research workflow.
- Runs all simulations in sequence
- Generates comprehensive result reports
- Creates analysis tables and figures
- Outputs results to `results/` directory

```bash
bash run_paper_pipeline.sh
```

#### 7. **run_all_analyses.sh**
Executes all individual analysis scripts in proper order.
- Runs cartel analysis
- Runs Sybil simulation
- Runs prediction accuracy analysis
- Runs comparative metrics
- Aggregates all results

```bash
bash run_all_analyses.sh
```

### Configuration

#### 8. **requirements.txt**
Python package dependencies for all analysis scripts.

Install dependencies:
```bash
pip install -r requirements.txt
```

**Required packages:**
- numpy: Numerical computations
- pandas: Data manipulation and analysis
- matplotlib: Data visualization
- scipy: Scientific computing
- web3: Blockchain interaction (if needed)
- pytest: Testing framework

## Usage Guide

### Quick Start

1. **Install dependencies:**
   ```bash
   pip install -r requirements.txt
   ```

2. **Run all analyses:**
   ```bash
   bash run_all_analyses.sh
   ```

3. **Run complete pipeline (recommended for publication):**
   ```bash
   bash run_paper_pipeline.sh
   ```

### Individual Analysis

Run specific analyses:

```bash
# Cartel analysis only
python cartel_analysis.py

# Sybil attack analysis only
python sybil_simulation.py

# Prediction accuracy only
python prediction_accuracy.py

# Comparative metrics
python comparative_metrics.py
```

## Output Files

After running analyses, the following files are generated:

### CSV Results
- `cartel_simulation_results.csv` - Cartel attack scenario results
- `sybil_simulation_results.csv` - Sybil attack scenario results
- `accuracy_comparison_results.csv` - Prediction accuracy metrics
- `simulation_data.csv` - Aggregated simulation data

### Reports & Tables
- `results/tables/paper_tables.tex` - LaTeX formatted tables for publication
- `results/gas_benchmarks/gas_report.txt` - Gas usage analysis

### Figures
- `results/figures/figure1_brier_comparison.png` - Prediction accuracy visualization
- `results/figures/figure2_whale_pressure.png` - Whale pressure analysis
- `results/figures/figure_cartel_analysis.png` - Cartel impact visualization

## Configuration Parameters

Most scripts support configuration parameters at the top of the file:

```python
# Example: Number of simulation iterations
NUM_SIMULATIONS = 1000

# Number of attackers in cartel
CARTEL_SIZE = 10

# Number of Sybil identities
SYBIL_IDENTITIES = 50

# Simulation duration (blocks)
SIMULATION_BLOCKS = 100000
```

## Dependencies on Smart Contracts

These scripts analyze the following smart contracts:
- `GovernancePredictionMarket.sol` - Main market contract
- `ReputationToken.sol` - Reputation token system
- `LegislatorElection.sol` - Election mechanism
- `MarketOracle.sol` - Price oracle

## Output Directory Structure

Results are organized as follows:
```
results/
├── accuracy_analysis/
│   ├── accuracy_comparison_results.csv
│   └── accuracy_output.txt
├── cartel_analysis/
│   ├── cartel_simulation_results.csv
│   └── cartel_output.txt
├── sybil_analysis/
│   ├── sybil_simulation_results.csv
│   └── sybil_output.txt
├── gas_benchmarks/
│   └── gas_report.txt
├── tables/
│   └── paper_tables.tex
└── figures/
    ├── figure1_brier_comparison.png
    ├── figure2_whale_pressure.png
    └── figure_cartel_analysis.png
```

## Research Paper Integration

These analyses were used to generate results for the research paper:
- Evaluates market efficiency and accuracy
- Demonstrates security against coordinated attacks
- Provides gas efficiency benchmarks
- Validates theoretical predictions with empirical data

## Notes

- All scripts use random seeds for reproducibility
- Results are deterministic given the same random seed
- Simulation duration affects computation time significantly
- Larger simulations produce more statistically robust results

## Support

For issues or questions about specific analysis scripts, refer to:
1. Script documentation at the top of each file
2. Inline comments within functions
3. Paper methods section for theoretical background
4. Generated output files for data interpretation

## License

These scripts are part of the Governance Prediction Markets research project.
