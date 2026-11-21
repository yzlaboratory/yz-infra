#!/usr/bin/env bash
set -euo pipefail

REGION=${2:-eu-central-1}

command -v aws >/dev/null 2>&1 || {
  echo "aws CLI is required" >&2
  exit 1
}

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET=${1:-yz-infra-tfstate-$ACCOUNT}

[[ $BUCKET =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || {
  echo "invalid bucket name: $BUCKET" >&2
  exit 1
}

echo "account: $ACCOUNT"
echo "bucket:  $BUCKET"
echo "region:  $REGION"

if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
  echo "bucket already exists; updating settings"
else
  echo "creating bucket"
  if [[ $REGION == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
fi

echo "enabling versioning"
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --versioning-configuration Status=Enabled

echo "blocking public access"
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "enabling default SSE-S3 encryption"
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo "configuring lifecycle for noncurrent versions and incomplete uploads"
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --lifecycle-configuration '{"Rules":[{"ID":"expire-noncurrent-state","Status":"Enabled","Filter":{"Prefix":""},"NoncurrentVersionExpiration":{"NoncurrentDays":90}},{"ID":"abort-incomplete-uploads","Status":"Enabled","Filter":{"Prefix":""},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}},{"ID":"remove-expired-delete-markers","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"ExpiredObjectDeleteMarker":true}}]}'

echo "denying insecure transport"
POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::$BUCKET",
        "arn:aws:s3:::$BUCKET/*"
      ],
      "Condition": {
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    }
  ]
}
EOF
)
aws s3api put-bucket-policy --bucket "$BUCKET" --region "$REGION" --policy "$POLICY"

echo
echo "state bucket ready"
echo "next:"
echo "  cp tofu/backend.tfvars.example tofu/backend.tfvars"
echo "  tofu -chdir=tofu init -backend-config=backend.tfvars"
