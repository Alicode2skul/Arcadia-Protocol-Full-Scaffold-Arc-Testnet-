# Arcadia Protocol — KMS + Audit + Localstack Integration (Dev & Codespaces)

This patch adds:
- KMSSigner for AWS KMS (production pluggable signer).
- /signer/info endpoint that publishes signer_id and public key for auditors.
- S3-backed audit logging with SSE and optional object lock retention.
- Audit viewer UI + backend endpoints to list/fetch audit entries.
- Localstack docker compose to run KMS + S3 locally in Codespaces.
- Integration tests (skip gracefully if no KMS configured).

Quick local dev (Codespaces) guide
1) Start localstack (in Codespaces or locally)
   docker-compose -f docker-compose.localstack.yml up -d
   # localstack exposes services on http://localhost:4566

2) Create a KMS key in localstack (example using AWS CLI pointed at localstack)
   export AWS_ACCESS_KEY_ID=test
   export AWS_SECRET_ACCESS_KEY=test
   export AWS_REGION=us-east-1
   export AWS_ENDPOINT_URL=http://localhost:4566

   # create a KMS key (localstack)
   aws --endpoint-url=$AWS_ENDPOINT_URL kms create-key --description "test key for arcadia" > key.json
   export KMS_KEY_ID=$(jq -r '.KeyMetadata.KeyId' key.json)

   # get public key for later manual checks
   aws --endpoint-url=$AWS_ENDPOINT_URL kms get-public-key --key-id $KMS_KEY_ID > pub.json

3) Create S3 bucket in localstack for audit:
   aws --endpoint-url=$AWS_ENDPOINT_URL s3api create-bucket --bucket arcadia-audit --region us-east-1

4) Start backend
   cd backend
   python -m venv venv
   source venv/bin/activate
   pip install -r requirements.txt
   # set env
   export AWS_ENDPOINT_URL=http://localhost:4566
   export AWS_REGION=us-east-1
   export KMS_KEY_ID=<KMS_KEY_ID from step 2>
   export SIGNER_TYPE=kms
   export ADMIN_API_KEY=devkey
   export AUDIT_S3_BUCKET=arcadia-audit
   export AUDIT_S3_PREFIX=timelock-audit/
   uvicorn app.main:app --reload --port 8001

5) Start frontend
   cd frontend
   npm install
   npm run dev
   Visit http://localhost:3000 and open Timelock Panel & Audit Viewer.

Running tests (KMS integration)
- If you have KMS_KEY_ID and AWS_ENDPOINT_URL set (localstack), the KMS integration test will run.
- Run:
  cd backend
  source venv/bin/activate
  pytest -q

CI
- There is a workflow snippet in .github/workflows/ci.yml to run backend tests and upload generated fixtures as artifacts.

Security notes
- Do NOT use ADMIN_PRIVATE_KEY env in production. Use SIGNER_TYPE=kms and a real cloud KMS backed by HSM.
- Configure IAM roles, KMS key policies, S3 bucket policies and Object Lock per regulatory needs.
```
