// =============================================================================
// MongoDB Schema Validation — account_transaction
// Equivalent to PostgreSQL odsperf.account_transaction
// Run with: mongosh <connection-string> init-schema.js
// =============================================================================

db = db.getSiblingDB("odsperf");

// =============================================================================
// Drop + recreate collection with $jsonSchema validator
// =============================================================================
db.getCollection("account_transaction").drop();

db.createCollection("account_transaction", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      title: "account_transaction",
      description: "ODS Account Transaction — equivalent to DB2/PostgreSQL schema",

      // Columns ที่ NOT NULL (required)
      required: ["iacct", "drun", "cseq", "ddate"],

      additionalProperties: false,  // ไม่อนุญาต field นอก schema

      properties: {
        // MongoDB internal ID
        _id: { bsonType: "objectId" },

        // -------------------------------------------------------------------
        // Key fields (NOT NULL)
        // -------------------------------------------------------------------
        iacct: {
          bsonType: "string",
          minLength: 1,
          maxLength: 11,
          description: "เลขที่บัญชี (Account Number) — required, max 11 chars"
        },
        drun: {
          bsonType: "date",
          description: "วันที่ RUN ข้อมูล (Batch Run Date) — required"
        },
        cseq: {
          bsonType: "int",
          minimum: 0,
          description: "ลำดับรายการ (Sequence) — required, non-negative"
        },
        ddate: {
          bsonType: "date",
          description: "วันที่รายการนั้นมีผล (Value Date) — required"
        },

        // -------------------------------------------------------------------
        // Nullable fields
        // -------------------------------------------------------------------
        dtrans: {
          bsonType: ["date", "null"],
          description: "วันที่ทำรายการ (Transaction Date)"
        },
        ttime: {
          bsonType: ["string", "null"],
          maxLength: 5,
          description: "เวลาที่ทำรายการ HH:MM"
        },
        cmnemo: {
          bsonType: ["string", "null"],
          maxLength: 3,
          description: "รหัสการทำรายการ (Transaction Mnemonic)"
        },
        cchannel: {
          bsonType: ["string", "null"],
          maxLength: 4,
          description: "ช่องทางที่ทำรายการ (Channel)"
        },
        ctr: {
          bsonType: ["string", "null"],
          maxLength: 2,
          description: "เลขที่โอน (Transfer Ref)"
        },
        cbr: {
          bsonType: ["string", "null"],
          maxLength: 4,
          description: "สาขาที่ทำรายการ (Branch)"
        },
        cterm: {
          bsonType: ["string", "null"],
          maxLength: 5,
          description: "Terminal ID"
        },
        camt: {
          bsonType: ["string", "null"],
          enum: ["C", "D", null],
          description: "Credit/Debit flag — C=Credit, D=Debit"
        },
        aamount: {
          bsonType: ["decimal", "null"],
          description: "จำนวนเงินที่ทำรายการ — ใช้ Decimal128 เพื่อ precision เหมือน NUMERIC(13,2)"
        },
        abal: {
          bsonType: ["decimal", "null"],
          description: "ยอดเงินคงเหลือ — Decimal128"
        },
        description: {
          bsonType: ["string", "null"],
          maxLength: 20,
          description: "รายละเอียดของรายการ"
        },
        time_hms: {
          bsonType: ["string", "null"],
          maxLength: 8,
          description: "เวลา HH:MM:SS"
        }
      }
    }
  },

  // strict  = reject documents that fail validation (เหมือน PostgreSQL)
  // moderate = validate only on insert/update (ไม่ validate existing docs)
  validationLevel: "strict",

  // error = reject + return error (เหมาะกับ ODS/production)
  // warn  = allow but log warning (เหมาะกับ migration phase)
  validationAction: "error"
});

print("Collection 'account_transaction' created with schema validation ✓");

// =============================================================================
// Indexes — equivalent กับ PostgreSQL indexes
// =============================================================================

// Primary key equivalent: unique compound index on (iacct, drun, cseq)
db.account_transaction.createIndex(
  { iacct: 1, drun: 1, cseq: 1 },
  { unique: true, name: "idx_pk_account_transaction" }
);

// ค้นหาตาม account + transaction date (use case หลัก)
db.account_transaction.createIndex(
  { iacct: 1, dtrans: 1 },
  { name: "idx_acctxn_iacct_dtrans" }
);

// ค้นหาตาม batch run date
db.account_transaction.createIndex(
  { drun: 1 },
  { name: "idx_acctxn_drun" }
);

// filter Credit/Debit
db.account_transaction.createIndex(
  { camt: 1 },
  { name: "idx_acctxn_camt" }
);

print("Indexes created ✓");
print("");
print("Validation rules:");
print("  validationLevel  : strict  (reject invalid documents)");
print("  validationAction : error   (return error to client)");
print("");
print("Run 'db.getCollectionInfos({name: \"account_transaction\"})' to verify.");
