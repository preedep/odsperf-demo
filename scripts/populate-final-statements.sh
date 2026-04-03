#!/usr/bin/env bash
# =============================================================================
# populate-final-statements.sh
# Create final_statements collection from account_transaction data
# This merges account_master with embedded statements array for each account
# =============================================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Configuration ────────────────────────────────────────────────────────────
MONGODB_URI="${MONGODB_URI:-mongodb://odsuser:odspassword@localhost:27017/odsperf}"
MONGODB_DB="${MONGODB_DB:-odsperf}"

echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║  Populate final_statements Collection from Real Data        ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}📋 Configuration:${NC}"
echo -e "   MongoDB URI: ${MONGODB_URI}"
echo -e "   Database: ${MONGODB_DB}"
echo ""

# Check if mongosh is available
if ! command -v mongosh &> /dev/null; then
    echo -e "${RED}✘ mongosh not found${NC}"
    echo -e "  Install: brew install mongosh"
    exit 1
fi

echo -e "${CYAN}🔧 Step 1: Connecting to MongoDB...${NC}"
mongosh "${MONGODB_URI}" --quiet --eval "db.adminCommand('ping')" > /dev/null 2>&1 || {
    echo -e "${RED}✘ Failed to connect to MongoDB${NC}"
    exit 1
}
echo -e "${GREEN}✔ Connected${NC}"

echo ""
echo -e "${CYAN}🔧 Step 2: Dropping existing final_statements collection...${NC}"
mongosh "${MONGODB_URI}" --quiet --eval "use ${MONGODB_DB}; db.final_statements.drop();" > /dev/null 2>&1
echo -e "${GREEN}✔ Collection dropped${NC}"

echo ""
echo -e "${CYAN}🔧 Step 3: Creating final_statements from account_transaction...${NC}"
echo -e "${YELLOW}   This will:${NC}"
echo -e "   1. Group transactions by account (iacct)"
echo -e "   2. Get account master data from account_master collection"
echo -e "   3. Embed all statements into statements array"
echo -e "   4. Calculate max dtrans for each account"
echo ""

# Run aggregation pipeline
mongosh "${MONGODB_URI}" --quiet <<'EOF'
use odsperf;

// Step 1: Aggregate transactions by account
print("   → Aggregating transactions by account...");
const accountsWithStatements = db.account_transaction.aggregate([
  {
    $sort: { iacct: 1, dtrans: 1, cseq: 1 }
  },
  {
    $group: {
      _id: "$iacct",
      statements: {
        $push: {
          drun: "$drun",
          cseq: "$cseq",
          dtrans: "$dtrans",
          ddate: "$ddate",
          ttime: "$ttime",
          cmnemo: "$cmnemo",
          cchannel: "$cchannel",
          ctr: "$ctr",
          cbr: "$cbr",
          cterm: "$cterm",
          camt: "$camt",
          aamount: "$aamount",
          abal: "$abal",
          description: "$description",
          time_hms: "$time_hms"
        }
      },
      maxDtrans: { $max: "$dtrans" }
    }
  }
]).toArray();

print(`   → Found ${accountsWithStatements.length} accounts`);

// Step 2: Merge with account_master data
print("   → Merging with account_master data...");
let inserted = 0;
let errors = 0;

for (const acc of accountsWithStatements) {
  const accountMaster = db.account_master.findOne({ iacct: acc._id });
  
  if (!accountMaster) {
    print(`   ⚠ Warning: No account_master found for ${acc._id}, skipping...`);
    errors++;
    continue;
  }
  
  const finalDoc = {
    iacct: acc._id,
    custid: accountMaster.custid,
    ctype: accountMaster.ctype,
    dopen: accountMaster.dopen,
    dclose: accountMaster.dclose,
    cstatus: accountMaster.cstatus,
    cbranch: accountMaster.cbranch,
    segment: accountMaster.segment,
    credit_limit: accountMaster.credit_limit,
    dtrans: acc.maxDtrans,
    statements: acc.statements
  };
  
  db.final_statements.insertOne(finalDoc);
  inserted++;
  
  if (inserted % 1000 === 0) {
    print(`   → Inserted ${inserted} documents...`);
  }
}

print(`   → Total inserted: ${inserted} documents`);
if (errors > 0) {
  print(`   ⚠ Errors: ${errors} accounts skipped`);
}

// Step 3: Create index
print("   → Creating index on {iacct: 1, dtrans: 1}...");
db.final_statements.createIndex({ iacct: 1, dtrans: 1 });

// Step 4: Show stats
print("");
print("📊 Collection Statistics:");
const stats = db.final_statements.stats();
print(`   • Documents: ${stats.count}`);
print(`   • Avg document size: ${Math.round(stats.avgObjSize)} bytes`);
print(`   • Total size: ${Math.round(stats.size / 1024 / 1024 * 100) / 100} MB`);

// Step 5: Sample document
print("");
print("📄 Sample Document:");
const sample = db.final_statements.findOne();
if (sample) {
  print(`   • Account: ${sample.iacct}`);
  print(`   • Customer: ${sample.custid}`);
  print(`   • Type: ${sample.ctype}`);
  print(`   • Statements: ${sample.statements.length} transactions`);
  print(`   • Max dtrans: ${sample.dtrans}`);
}
EOF

echo ""
echo -e "${GREEN}${BOLD}✔ final_statements collection created successfully!${NC}"
echo ""
echo -e "${CYAN}💡 Next Steps:${NC}"
echo "  1. Test the new endpoint:"
echo "     ./scripts/test-api.sh --nojoin"
echo ""
echo "  2. Compare with JOIN query:"
echo "     ./scripts/test-api.sh --join"
echo ""
echo "  3. Query directly:"
echo "     mongosh \"${MONGODB_URI}\" --eval 'db.final_statements.findOne({iacct: \"10000007942\"})'"
echo ""
