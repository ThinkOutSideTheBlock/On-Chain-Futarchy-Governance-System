# Governance Prediction Markets: Smart Contract Implementation and Analysis

## Overview

This repository contains a complete implementation of a **reputation-based governance prediction market system** with comprehensive smart contracts, test suite, and empirical validation through simulation and analysis.

The system enables decentralized prediction markets where participants earn reputation through accurate predictions, which directly influences their voting power in governance decisions. The implementation includes mechanisms to detect and resist common attacks including cartel formation and Sybil attacks.

## Quick Start

### Prerequisites

- **Foundry**: Smart contract development framework
  - Install: `curl -L https://foundry.paradigm.xyz | bash`
  - Verify: `forge --version`
- **Python 3.8+**: For simulation and analysis scripts
- **Solidity 0.8.27**: Compiler version specified in `foundry.toml`

### Installation

```bash
# Clone repository
git clone <https://github.com/ThinkOutSideTheBlock/On-Chain-Futarchy-Governance-System/>
cd governance-prediction-markets

# Install dependencies
forge install

# Install Python analysis dependencies
pip install -r simulation_and_analysis/requirements.txt
```

### Building

```bash
# Build smart contracts
forge build

# Build with optimization
forge build --optimize --optimizer-runs 1000
```

### Testing

```bash
# Run all tests
forge test

# Run with verbose output
forge test -vvv

# Run specific test file
forge test --match-path "test/unit/ReputationToken.t.sol"

# Run with gas snapshots
forge snapshot
```

### Running Analysis

```bash
# Install dependencies
pip install -r simulation_and_analysis/requirements.txt

# Run all analyses
cd simulation_and_analysis
bash run_all_analyses.sh

# Or run complete research pipeline
bash run_paper_pipeline.sh
```

## Architecture

### System Components

```
┌─────────────────────────────────────────────────┐
│      Governance Prediction Market System        │
├─────────────────────────────────────────────────┤
│                                                 │
│  ┌──────────────────────────────────────────┐  │
│  │  GovernancePredictionMarket (Core)      │  │
│  │  - Market creation & management         │  │
│  │  - Order book & settlement              │  │
│  │  - Outcome resolution                   │  │
│  └──────────────────────────────────────────┘  │
│         ↓              ↓              ↓         │
│  ┌──────────┐  ┌───────────┐  ┌──────────────┐ │
│  │Reputation│  │Legislator │  │   Treasury   │ │
│  │  Token   │  │ Election  │  │   Manager    │ │
│  └──────────┘  └───────────┘  └──────────────┘ │
│         ↓              ↓              ↓         │
│  ┌──────────────────────────────────────────┐  │
│  │       Governance & Reward System         │  │
│  │ - Proposal Manager                       │  │
│  │ - Reputation Lock Manager                │  │
│  │ - Reward Distributor                     │  │
│  └──────────────────────────────────────────┘  │
│         ↓                                       │
│  ┌──────────────────────────────────────────┐  │
│  │      Oracle & Price Feed Integration    │  │
│  │ - Market Oracle                          │  │
│  │ - Chainlink Price Oracle                 │  │
│  └──────────────────────────────────────────┘  │
│                                                 │
└─────────────────────────────────────────────────┘
```


### License
MIT License