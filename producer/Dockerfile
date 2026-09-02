# =============================================================================
# The Binance producer image  (roadmap.md, Phase 5)
#
# Deliberately boring. This is the first container in the project, and Phase 12
# is where containerisation gets studied properly -- so this image does the
# minimum correctly rather than showing off.
#
# Build and push (the repository URL is a Terraform output):
#
#   REPO=$(terraform -chdir=terraform/envs/crypto output -raw producer_ecr_repository_url)
#   aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${REPO%%/*}"
#   docker build -t "$REPO:latest" -f producer/Dockerfile .
#   docker push "$REPO:latest"
#
# Note the build context is the REPO ROOT, not producer/. That is so
# config/tracked_assets.json can be copied in as a fallback for the subscription
# list; in production the list arrives as BINANCE_SYMBOLS from the task
# definition, which reads the same file.
# =============================================================================

FROM python:3.12-slim

# Match the Lambda runtime, and pin the platform: Fargate is configured X86_64
# in the task definition, and an image built on an ARM laptop that silently
# ships arm64 fails at task start with an exec format error that reads as a
# broken entrypoint.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY producer/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY producer/producer.py ./producer/producer.py
COPY config/tracked_assets.json ./config/tracked_assets.json

# Not root. Nothing here needs it, and a compromised producer holding a
# Kinesis-write task role should not also hold the container.
RUN useradd --create-home --uid 10001 producer
USER producer

CMD ["python", "-u", "producer/producer.py"]
