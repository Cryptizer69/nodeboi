#!/bin/bash
# Script to push NODEBOI to GitHub
# 
# Before running this script:
# 1. Create a new repository on GitHub called "nodeboi"
# 2. Replace YOUR_USERNAME below with your actual GitHub username
# 3. Make sure you're logged into GitHub CLI or have SSH keys set up

set -e

GITHUB_USERNAME="YOUR_USERNAME"  # Replace with your GitHub username
REPO_URL="https://github.com/${GITHUB_USERNAME}/nodeboi.git"

echo "Pushing NODEBOI to GitHub..."

# Add the remote repository
git remote add origin "$REPO_URL" 2>/dev/null || git remote set-url origin "$REPO_URL"

# Create and push the main branch
git branch -M main
git push -u origin main

# Create and push the version tag
git tag -a v0.3.0 -m "NODEBOI v0.3.0: Major architectural improvements and monitoring integration

Features:
- Unified version management system
- Dynamic monitoring integration  
- Improved menu structure and UX
- Eliminated code duplication
- Enhanced monitoring display formatting"

git push origin v0.3.0

echo "✓ Successfully pushed to GitHub!"
echo "✓ Repository: $REPO_URL"
echo "✓ Tagged version: v0.3.0"
echo ""
echo "Next steps:"
echo "1. Go to $REPO_URL"
echo "2. Click 'Releases' → 'Create a new release'"
echo "3. Select tag 'v0.3.0' and publish the release"