// =============================================================================
// MongoDB Schema Validation — account_master
// Reference data for JOIN testing with account_transaction
// Run with: mongosh <connection-string> init-schema-accounts.js
// =============================================================================

db = db.getSiblingDB("odsperf");

// =============================================================================
// Drop + recreate collection with $jsonSchema validator
// =============================================================================
db.getCollection("account_master").drop();

db.createCollection("account_master", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      title: "account_master",
      description: "ODS Account Master — reference data for JOIN testing with account_transaction",

      required: ["iacct", "custid", "ctype", "dopen", "cstatus", "cbranch", "segment"],

      additionalProperties: false,

      properties: {
        _id: { bsonType: "objectId" },

        // -------------------------------------------------------------------
        // Primary key & required fields
        // -------------------------------------------------------------------
        iacct: {
          bsonType: "string",
          minLength: 11,
          maxLength: 11,
          description: "เลขที่บัญชี (Account Number) — 11 digits, shared pool with account_transaction"
        },
        custid: {
          bsonType: "string",
          minLength: 1,
          maxLength: 10,
          description: "รหัสลูกค้า (Customer ID)"
        },
        ctype: {
          bsonType: "string",
          enum: ["SAV", "CHK", "CUR", "FXD"],
          description: "ประเภทบัญชี: SAV=ออมทรัพย์, CHK=กระแสรายวัน, CUR=เงินตรา, FXD=ฝากประจำ"
        },
        dopen: {
          bsonType: "date",
          description: "วันที่เปิดบัญชี (Account Open Date)"
        },
        cstatus: {
          bsonType: "string",
          enum: ["ACTV", "INAC", "CLSD"],
          description: "สถานะบัญชี: ACTV=Active, INAC=Inactive, CLSD=Closed"
        },
        cbranch: {
          bsonType: "string",
          minLength: 1,
          maxLength: 4,
          description: "สาขาที่เปิดบัญชี (Branch Code) — matches cbr in account_transaction"
        },
        segment: {
          bsonType: "string",
          enum: ["RETAIL", "SME", "CORP", "PRIV"],
          description: "กลุ่มลูกค้า: RETAIL, SME, CORP, PRIV"
        },

        // -------------------------------------------------------------------
        // Nullable fields
        // -------------------------------------------------------------------
        dclose: {
          bsonType: ["date", "null"],
          description: "วันที่ปิดบัญชี (Account Close Date) — null = ยังเปิดอยู่"
        },
        credit_limit: {
          bsonType: ["decimal", "null"],
          description: "วงเงิน Decimal128 — null = ไม่มีวงเงิน"
        }
      }
    }
  },

  validationLevel:  "strict",
  validationAction: "error"
});

print("Collection 'account_master' created with schema validation ✓");

// =============================================================================
// Indexes — equivalent to PostgreSQL indexes
// =============================================================================

// Primary key equivalent: unique index on iacct
db.account_master.createIndex(
  { iacct: 1 },
  { unique: true, name: "idx_pk_account_master" }
);

// ค้นหาตาม customer ID
db.account_master.createIndex(
  { custid: 1 },
  { name: "idx_acctmaster_custid" }
);

// filter ตามประเภทบัญชี
db.account_master.createIndex(
  { ctype: 1 },
  { name: "idx_acctmaster_ctype" }
);

// filter ตามสาขา
db.account_master.createIndex(
  { cbranch: 1 },
  { name: "idx_acctmaster_cbranch" }
);

// filter ตาม segment
db.account_master.createIndex(
  { segment: 1 },
  { name: "idx_acctmaster_segment" }
);

print("Indexes created ✓");
print("");
print("Validation rules:");
print("  validationLevel  : strict  (reject invalid documents)");
print("  validationAction : error   (return error to client)");
print("");
print("Run 'db.getCollectionInfos({name: \"account_master\"})' to verify.");
