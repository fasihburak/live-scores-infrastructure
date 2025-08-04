# This script pulls the deployment script from the repo and runs it.
# It needs to be run with 3 command line arguments; 
# GITHUB_USERNAME_AND_REPO e.g. USERNAME/REPO_NAME
# ECR_REPO_URI
# IMAGE_TAG

echo Starting run.sh

# Fail immediately
set -e

GITHUB_USERNAME_AND_REPO="$1"
ECR_REPO_URI="$2"
IMAGE_TAG="$3"

# Pull the script from the github repo
curl -O https://raw.githubusercontent.com/"$1"/main/docker.sh
chmod +x docker.sh
./docker.sh $ECR_REPO_URI $ECR_REPO_URI $IMAGE_TAG

echo Finished run.sh