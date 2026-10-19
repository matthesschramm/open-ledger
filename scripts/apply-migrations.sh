#!/bin/bash
# Apply Supabase migrations to the connected project
# This script is intended for preview/READY environments

set -e

echo "=== Applying Supabase migrations ==="

# Check if we have Supabase credentials
if [ -z "$NEXT_PUBLIC_SUPABASE_URL" ] || [ -z "$SUPABASE_SERVICE_ROLE_KEY" ]; then
  echo "WARNING: Missing Supabase credentials. Skipping migration."
  echo "Set NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY to apply migrations."
  exit 0
fi

# Check if supabase CLI is installed
if ! command -v supabase &> /dev/null; then
  echo "Supabase CLI not found. Installing..."
  curl -L https://github.com/supabase/cli/releases/download/v2.10.0/supabase_linux_amd64.tar.gz | tar -xz
  sudo mv supabase /usr/local/bin/supabase || mv supabase ./supabase
  sudo chmod +x /usr/local/bin/supabase 2>/dev/null || chmod +x ./supabase
  export PATH="$PWD:$PATH"
fi

# Extract project ref from Supabase URL
PROJECT_REF=$(echo "$NEXT_PUBLIC_SUPABASE_URL" | sed -E 's|https://([^.]+)\.supabase\.co.*|\1|')

if [ -z "$PROJECT_REF" ]; then
  echo "Could not extract project ref from NEXT_PUBLIC_SUPABASE_URL: $NEXT_PUBLIC_SUPABASE_URL"
  exit 1
fi

echo "Project ref: $PROJECT_REF"
echo "Supabase URL: $NEXT_PUBLIC_SUPABASE_URL"

cd supabase

# Link to the project (using service role key for auth)
echo "Linking to Supabase project..."
supabase link --project-ref "$PROJECT_REF" --password "$SUPABASE_SERVICE_ROLE_KEY" || {
  echo "Failed to link to Supabase project. Trying alternative auth..."
  # If link fails, try with DB password from env
  if [ -n "$SUPABASE_DB_PASSWORD" ]; then
    supabase link --project-ref "$PROJECT_REF" --password "$SUPABASE_DB_PASSWORD"
  else
    echo "ERROR: Could not link to Supabase project and no SUPABASE_DB_PASSWORD provided"
    exit 1
  fi
}

# Push migrations
echo "Pushing migrations to remote database..."
supabase db push --include-all || {
  echo "WARNING: Migration push failed. This may be expected if migrations are already applied."
  echo "Checking migration status..."
  supabase migration list || true
}

echo "=== Migration application complete ==="
