terraform {
  # The actual backend settings live in backend.tfvars, which is gitignored.
  # Initialize with:
  #   tofu init -backend-config=backend.tfvars
  backend "s3" {}
}
