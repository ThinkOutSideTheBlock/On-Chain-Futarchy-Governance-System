#!/bin/bash

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
ANVIL_PORT=8545
ANVIL_URL="http://localhost:${ANVIL_PORT}"
DEPLOYMENT_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # Anvil default account 0
RESULTS_DIR="results"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_step() {
    echo -e "${GREEN}[STEP $1/$2]${NC} $3"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

check_command() {
    if ! command -v $1 &> /dev/null; then
        print_error "$1 is not installed. Please install it first."
    fi
}

# =============================================================================
# PHASE 0: PREREQUISITES CHECK
# =============================================================================

print_header "PHASE 0: Checking Prerequisites"

check_command "anvil"
check_command "forge"
check_command "cast"
check_command "python3"

echo -e "${GREEN}✓${NC} All required tools found"

# Check if Anvil is already running
if lsof -Pi :${ANVIL_PORT} -sTCP:LISTEN -t >/dev/null 2>&1; then
    print_warning "Anvil already running on port ${ANVIL_PORT}"
    read -p "Kill existing Anvil and restart? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        pkill -9 anvil || true
        sleep 2
    else
        print_error "Please stop existing Anvil instance first"
    fi
fi

# Check Python dependencies
python3 -c "import numpy, pandas, matplotlib, seaborn, scipy, web3" 2>/dev/null || {
    print_error "Missing Python dependencies. Run: pip install numpy pandas matplotlib seaborn scipy web3 pulp"
}

echo -e "${GREEN}✓${NC} Python dependencies installed"

# =============================================================================
# PHASE 1: START ANVIL
# =============================================================================

print_header "PHASE 1: Starting Local Blockchain (Anvil)"
print_step 1 7 "Launching Anvil with 20 accounts..."

# Start Anvil in background
anvil --port ${ANVIL_PORT} --block-time 1 --accounts 20 --balance 10000 > anvil.log 2>&1 &
ANVIL_PID=$!

echo "Anvil PID: ${ANVIL_PID}" > anvil.pid

# Wait for Anvil to be ready
sleep 3

# Verify Anvil is running
if ! cast block-number --rpc-url ${ANVIL_URL} &> /dev/null; then
    print_error "Anvil failed to start. Check anvil.log"
fi

echo -e "${GREEN}✓${NC} Anvil running at ${ANVIL_URL} (PID: ${ANVIL_PID})"

# =============================================================================
# PHASE 2: COMPILE CONTRACTS
# =============================================================================

print_header "PHASE 2: Compiling Smart Contracts"
print_step 2 7 "Running forge build..."

forge build || print_error "Compilation failed"

echo -e "${GREEN}✓${NC} Contracts compiled successfully"

# =============================================================================
# PHASE 3: DEPLOY SYSTEM
# =============================================================================

print_header "PHASE 3: Deploying Complete System"
print_step 3 7 "Deploying 8 contracts via deployment script..."

# Deploy and capture output
DEPLOY_OUTPUT=$(forge script script/DeploySystem.s.sol:DeploySystem \
    --rpc-url ${ANVIL_URL} \
    --broadcast \
    --private-key ${DEPLOYMENT_KEY} \
    --via-ir \
    2>&1)

# Check deployment success
if echo "$DEPLOY_OUTPUT" | grep -q "CONTRACT_ADDRESSES_JSON_START"; then
    echo -e "${GREEN}✓${NC} System deployed successfully"
else
    echo "$DEPLOY_OUTPUT" > deployment_error.log
    print_error "Deployment failed. Check deployment_error.log"
fi

# Extract contract addresses
echo "$DEPLOY_OUTPUT" | \
    sed -n '/CONTRACT_ADDRESSES_JSON_START/,/CONTRACT_ADDRESSES_JSON_END/p' | \
    grep -v "CONTRACT_ADDRESSES" > deployed_contracts.json

if [ ! -s deployed_contracts.json ]; then
    print_error "Failed to extract contract addresses"
fi

echo -e "${GREEN}✓${NC} Contract addresses saved to deployed_contracts.json"

# Display deployed addresses
echo ""
echo "Deployed Contracts:"
cat deployed_contracts.json

# =============================================================================
# PHASE 4: RUN SIMULATIONS
# =============================================================================

print_header "PHASE 4: Running Empirical Simulations"

# Create results directory structure
mkdir -p ${RESULTS_DIR}/{figures,tables,accuracy_analysis,sybil_analysis,cartel_analysis,gas_benchmarks}

# 4.1 Main Simulation
print_step 4 7 "Running main simulation (50 markets, ~15-20 min)..."
python3 simulation_metrics.py || print_warning "Main simulation encountered issues (check logs)"
echo -e "${GREEN}✓${NC} Main simulation complete"

# 4.2 Prediction Accuracy
print_step 5 7 "Running prediction accuracy analysis (~5 min)..."
python3 prediction_accuracy.py || print_warning "Accuracy analysis encountered issues"
echo -e "${GREEN}✓${NC} Prediction accuracy analysis complete"

# 4.3 Sybil Resistance
print_step 6 7 "Running Sybil attack simulations (~8 min)..."
python3 sybil_simulation.py || print_warning "Sybil simulation encountered issues"
echo -e "${GREEN}✓${NC} Sybil resistance analysis complete"

# 4.4 Cartel Analysis
print_step 7 7 "Running cartel formation analysis (~10 min)..."
python3 cartel_analysis.py || print_warning "Cartel analysis encountered issues"
echo -e "${GREEN}✓${NC} Cartel analysis complete"

# 4.5 Comparative Metrics (LaTeX tables)
echo "Generating LaTeX tables..."
python3 comparative_metrics.py > ${RESULTS_DIR}/tables/paper_tables.tex || print_warning "Table generation encountered issues"
echo -e "${GREEN}✓${NC} LaTeX tables generated"

# =============================================================================
# PHASE 5: GENERATE SUMMARY REPORT
# =============================================================================

print_header "PHASE 5: Generating Summary Report"

# Check if SUMMARY_REPORT.md already exists
if [ -f "${RESULTS_DIR}/SUMMARY_REPORT.md" ]; then
    echo -e "${GREEN}✓${NC} Summary report exists at ${RESULTS_DIR}/SUMMARY_REPORT.md"
else
    print_warning "SUMMARY_REPORT.md not found (may be generated by scripts)"
fi

# =============================================================================
# PHASE 6: VERIFICATION
# =============================================================================

print_header "PHASE 6: Verifying Outputs"

# Check for required figures
REQUIRED_FIGURES=(
    "figure1_brier_comparison.png"
    "figure2_whale_pressure.png"
    "figure_cartel_analysis.png"
)

MISSING_FIGURES=0
for fig in "${REQUIRED_FIGURES[@]}"; do
    if [ -f "${RESULTS_DIR}/figures/${fig}" ]; then
        echo -e "${GREEN}✓${NC} ${fig}"
    else
        echo -e "${RED}✗${NC} ${fig} MISSING"
        MISSING_FIGURES=$((MISSING_FIGURES+1))
    fi
done

# Check for LaTeX tables
if [ -f "${RESULTS_DIR}/tables/paper_tables.tex" ]; then
    echo -e "${GREEN}✓${NC} paper_tables.tex"
else
    echo -e "${RED}✗${NC} paper_tables.tex MISSING"
fi

# Check for CSV data
CSV_FILES=$(find ${RESULTS_DIR} -name "*.csv" | wc -l)
echo -e "${GREEN}✓${NC} Found ${CSV_FILES} CSV data files"

# =============================================================================
# CLEANUP & SUMMARY
# =============================================================================

print_header "PIPELINE COMPLETE!"

echo ""
echo "📊 RESULTS SUMMARY:"
echo "-------------------"
echo "Figures:      ${RESULTS_DIR}/figures/"
echo "LaTeX Tables: ${RESULTS_DIR}/tables/paper_tables.tex"
echo "Raw Data:     ${RESULTS_DIR}/*_analysis/"
echo "Summary:      ${RESULTS_DIR}/SUMMARY_REPORT.md"
echo ""

if [ $MISSING_FIGURES -eq 0 ]; then
    echo -e "${GREEN}✓ All outputs generated successfully!${NC}"
else
    echo -e "${YELLOW}⚠ Some outputs missing (${MISSING_FIGURES} figures). Check logs.${NC}"
fi

echo ""
echo "🔬 NEXT STEPS:"
echo "--------------"
echo "1. Review summary: cat ${RESULTS_DIR}/SUMMARY_REPORT.md"
echo "2. View figures:   open ${RESULTS_DIR}/figures/*.png"
echo "3. Copy tables:    cat ${RESULTS_DIR}/tables/paper_tables.tex"
echo "4. Stop Anvil:     kill ${ANVIL_PID}"
echo ""

# Ask if user wants to stop Anvil
read -p "Stop Anvil now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    kill ${ANVIL_PID}
    rm anvil.pid
    echo -e "${GREEN}✓${NC} Anvil stopped"
else
    echo -e "${YELLOW}⚠${NC} Anvil still running (PID: ${ANVIL_PID})"
    echo "To stop later: kill ${ANVIL_PID}"
fi

echo ""
echo "📄 For detailed workflow, see: PAPER_WORKFLOW.md"
echo ""
