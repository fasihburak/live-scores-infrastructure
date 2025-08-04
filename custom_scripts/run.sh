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

echo "GITHUB_USERNAME_AND_REPO: $GITHUB_USERNAME_AND_REPO"
echo "ECR_REPO_URI: $ECR_REPO_URI"
echo "IMAGE_TAG: $IMAGE_TAG"

# Specify the download path
DOCKER_SCRIPT_PATH="/home/ec2-user/docker.sh"

# Pull the script from the github repo
curl -o "$SCRIPT_PATH" https://raw.githubusercontent.com/"$1"/main/docker.sh
chmod +x "$SCRIPT_PATH"
"$SCRIPT_PATH" "$ECR_REPO_URI" "$ECR_REPO_URI" "$IMAGE_TAG"

echo Finished run.sh