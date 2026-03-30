# DevOps-Node-API



<img width="668" height="481" alt="image" src="https://github.com/user-attachments/assets/a17b99d6-daae-4611-98f2-1dac2551482d" />





> **What we're building:** A production-grade CI/CD system. Terraform provisions the AWS infrastructure. Jenkins runs the full build-test-deploy pipeline. GitHub Actions handles code quality and Docker image publishing. All three tools talk to each other.

---

## The Big Picture

```
Developer pushes code to GitHub
        │
        ├─▶ GitHub Actions triggers (on every push/PR)
        │       ├─ Lint + unit test
        │       ├─ Build Docker image
        │       └─ Push image to GitHub Container Registry (GHCR)
        │
        └─▶ GitHub webhook triggers Jenkins (on push to main)
                ├─ Checkout code
                ├─ Run integration tests
                ├─ Pull Docker image from GHCR
                └─ SSH deploy to EC2 App server
                        └─ docker pull → docker run

Terraform (run once, or when infra changes):
        └─ Creates: VPC, subnets, SGs, EC2 (Jenkins), EC2 (App), S3 (state), DynamoDB (lock)
```

---

## What each tool owns in this project

- **Terraform** owns the infrastructure layer — VPC, security groups, EC2 instances, S3 state bucket. You run it once and when infra changes.
- **GitHub Actions** owns the CI layer — lint, test, build the Docker image, publish it to GHCR. Runs on every push and PR.
- **Jenkins** owns the CD layer — verify the image exists, integration test, SSH deploy to the app server, smoke test. Runs on pushes to main.


---

## Phase 0 — Prerequisites and Tools

### Create Your GitHub Repository

```bash
git clone https://github.com/YOUR_USERNAME/devops-node-api.git
cd devops-node-api
```

### Save GitHub credentials permanently

GitHub no longer accepts your account password for Git operations. You must use a **Personal Access Token (PAT)**.

```bash
git config --global credential.helper store
# On the next push, enter your username and PAT as the password
# Credentials will be saved permanently in ~/.git-credentials
```

**Create a PAT:** GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) Required scopes: `repo`, `write:packages`, `read:packages`, `admin:repo_hook`

### AWS IAM Setup (Security First)

```bash
aws iam create-user --user-name terraform-user

aws iam attach-user-policy --user-name terraform-user --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
aws iam attach-user-policy --user-name terraform-user --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam attach-user-policy --user-name terraform-user --policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess
aws iam attach-user-policy --user-name terraform-user --policy-arn arn:aws:iam::aws:policy/AmazonVPCFullAccess

aws iam create-access-key --user-name terraform-user
# Save the AccessKeyId and SecretAccessKey — you won't see them again

export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="us-east-1"
```

### ⚠️ Critical: .gitignore must exist BEFORE first commit

Make sure this `.gitignore` is in place before you ever run `git add .` — the `.terraform/` folder contains provider binaries up to 674MB and will be rejected by GitHub.

```
node_modules/
coverage/
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
.env
*.pem
*.key
```


---

## Phase 1 — The Application

### Project File Structure

```
devops-node-api/
├── app/
│   ├── src/
│   │   ├── index.js
│   │   └── routes/
│   │       └── health.js
│   ├── tests/
│   │   └── health.test.js
│   ├── package.json
│   ├── .eslintrc.json        ← required for GitHub Actions lint job
│   └── Dockerfile
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf
│   └── backend.tf
├── jenkins/
│   └── Jenkinsfile           ← must be lowercase 'j': jenkinsfile also works
├── .github/
│   └── workflows/
│       ├── ci.yml
│       └── release.yml
└── .gitignore
```

### Create the Application

`app/src/routes/health.js`:

```javascript
const express = require('express');
const router = express.Router();

router.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    version: process.env.APP_VERSION || '1.0.0',
    environment: process.env.NODE_ENV || 'development',
  });
});

router.get('/info', (req, res) => {
  res.json({
    name: 'devops-node-api',
    uptime: process.uptime(),
    memory: process.memoryUsage(),
  });
});

module.exports = router;
```

`app/src/index.js`:

```javascript
const express = require('express');
const healthRouter = require('./routes/health');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());
app.use('/api', healthRouter);

app.get('/', (req, res) => {
  res.json({ message: 'DevOps Node API is running' });
});

if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
  });
}

module.exports = app;
```

`app/tests/health.test.js`:

```javascript
const request = require('supertest');
const app = require('../src/index');

describe('Health Endpoints', () => {
  it('GET /api/health returns 200 with status ok', async () => {
    const res = await request(app).get('/api/health');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('ok');
    expect(res.body.timestamp).toBeDefined();
  });

  it('GET /api/info returns uptime info', async () => {
    const res = await request(app).get('/api/info');
    expect(res.statusCode).toBe(200);
    expect(res.body.uptime).toBeDefined();
  });

  it('GET / returns running message', async () => {
    const res = await request(app).get('/');
    expect(res.statusCode).toBe(200);
    expect(res.body.message).toContain('running');
  });
});
```

`app/package.json`:

```json
{
  "name": "devops-node-api",
  "version": "1.0.0",
  "description": "A Node.js API for DevOps practice",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js",
    "dev": "nodemon src/index.js",
    "test": "jest --coverage",
    "lint": "eslint src/ --ext .js"
  },
  "dependencies": {
    "express": "^4.18.2"
  },
  "devDependencies": {
    "eslint": "^8.50.0",
    "jest": "^29.7.0",
    "supertest": "^6.3.3"
  },
  "jest": {
    "testEnvironment": "node",
    "coverageDirectory": "coverage",
    "coverageThreshold": {
      "global": {
        "lines": 80
      }
    }
  }
}
```

`app/.eslintrc.json` — **required or the GitHub Actions lint job will fail:**

```json
{
  "env": {
    "node": true,
    "es2021": true
  },
  "extends": "eslint:recommended",
  "parserOptions": {
    "ecmaVersion": "latest"
  },
  "rules": {
    "no-unused-vars": "warn",
    "no-console": "off"
  }
}
```

`app/Dockerfile`:

```dockerfile
FROM node:18-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

FROM node:18-alpine AS runtime
RUN addgroup -g 1001 -S nodejs && adduser -S nodejs -u 1001
WORKDIR /app
COPY --from=builder --chown=nodejs:nodejs /app/node_modules ./node_modules
COPY --chown=nodejs:nodejs src/ ./src/
USER nodejs
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/api/health || exit 1
CMD ["node", "src/index.js"]
```

---

## Phase 2 — Terraform: Provision the Infrastructure

### Step 2.1 — Bootstrap State Storage (Run Once, Manually)

```bash
aws s3api create-bucket --bucket devops-node-api-terraform-state --region us-east-1

aws s3api put-bucket-versioning \
  --bucket devops-node-api-terraform-state \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket devops-node-api-terraform-state \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}}]
  }'

aws s3api put-public-access-block \
  --bucket devops-node-api-terraform-state \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### Step 2.2 — Create an SSH Key Pair

```bash
aws ec2 create-key-pair \
  --key-name devops-node-api-key \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/devops-node-api-key.pem

chmod 400 ~/.ssh/devops-node-api-key.pem
```

### Step 2.3 — Terraform Configuration Files

`terraform/providers.tf`:

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "devops-node-api"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
```

`terraform/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "devops-node-api-terraform-state"
    key            = "production/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}
```

`terraform/variables.tf`:

```hcl
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "production"
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "Must be staging or production."
  }
}

variable "jenkins_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "app_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "your_ip" {
  description = "Your local IP for SSH access (run: curl ifconfig.me)"
  type        = string
}
```

`terraform/terraform.tfvars`:

```hcl
aws_region            = "us-east-1"
environment           = "production"
jenkins_instance_type = "t3.micro"
app_instance_type     = "t3.micro"
your_ip               = "YOUR_IP_HERE/32"   # Replace with: curl ifconfig.me
```

### Step 2.4 — Run Terraform

```bash
cd terraform
terraform init
terraform validate
terraform fmt
terraform plan
terraform apply   # type 'yes' when prompted

# Save the IPs
JENKINS_IP=$(terraform output -raw jenkins_public_ip)
APP_IP=$(terraform output -raw app_public_ip)
APP_PRIVATE_IP=$(terraform output -raw app_private_ip)
```

---

## Phase 3 — Jenkins: Install and Configure

### Step 3.1 — Initial Setup

Open `http://YOUR_JENKINS_IP:8080` in your browser. Get the initial password:

```bash
ssh -i ~/.ssh/devops-node-api-key.pem ec2-user@$JENKINS_IP
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

- Click "Install suggested plugins"
- Create admin user
- Set Jenkins URL: `http://YOUR_JENKINS_IP:8080/`

### Step 3.2 — Install Required Plugins

Go to **Manage Jenkins → Plugins → Available plugins** and install:

- `Pipeline: Stage View`
- `GitHub Integration`
- `Docker Pipeline`
- `Credentials Binding`
- `Workspace Cleanup`
- `SSH Agent` 

Restart after installing: `http://YOUR_JENKINS_IP:8080/restart`

### Step 3.3 — Add Credentials to Jenkins

Go to **Manage Jenkins → Credentials → System → Global credentials → Add Credentials**

**Credential 1: GitHub token for pipeline use**

- Kind: **Secret text**
- Secret: your GitHub PAT
- ID: `github`
- Description: GitHub PAT for pipeline

**Credential 2: GitHub credentials for repo access (Multibranch Pipeline)**

- Kind: **Username with password** ← must be this type, not Secret text
- Username: `YOUR_GITHUB_USERNAME`
- Password: your GitHub PAT
- ID: `github-username-token`
- Description: GitHub Username and PAT

> Note: The Multibranch Pipeline branch source only shows **Username with password** credentials in its dropdown — Secret text credentials will not appear there.

**Credential 3: SSH key for App Server**

- Kind: **SSH Username with Private Key**
- Username: `ec2-user`
- Private Key: paste contents of `~/.ssh/devops-node-api-key.pem`
- ID: `app-server-ssh-key`

**Credential 4: App Server IP**

- Kind: **Secret text**
- Secret: your app server private IP (`terraform output -raw app_private_ip`)
- ID: `app-server-ip`

### Step 3.4 — Configure GitHub API Authentication

To prevent Jenkins from hitting GitHub's anonymous rate limit (60 req/hr → sleeps for minutes):

Go to **Manage Jenkins → Configure System → GitHub section → Add GitHub Server**:

- Name: `GitHub`
- API URL: `https://api.github.com`
- Credentials: select `github-username-token`
- Check **Manage hooks**
- Click **Test connection** — should show: `Credentials verified for user YOUR_USERNAME, rate limit: 4994`
- Save

### Step 3.5 — Configure the GitHub Webhook

Go to your GitHub repo → **Settings → Webhooks → Add webhook**:

- Payload URL: `http://YOUR_JENKINS_IP:8080/github-webhook/`
- Content type: `application/json`
- Events: Just the push event
- Click **Add webhook**

### Step 3.6 — Create the Multibranch Pipeline

1. Click **New Item** → name it `devops-node-api` → select **Multibranch Pipeline**
2. **Branch Sources** → Add source → GitHub
    - Credentials: `github-username-token`
    - Repository HTTPS URL: `https://github.com/YOUR_USERNAME/devops-node-api`
    - Click **Validate** — should say "Credentials ok"
3. **Build Configuration** → Script Path: `jenkins/Jenkinsfile`
4. **Scan Repository Triggers** → Periodically if not otherwise run → 1 minute
5. Save

---

## Phase 4 — GitHub Actions: CI and Image Publishing

`.github/workflows/ci.yml`:

```yaml
name: CI — Lint, Test, and Publish

on:
  push:
    branches: [main, develop, 'feature/**']
    paths:
      - 'app/**'
      - '.github/workflows/ci.yml'
  pull_request:
    branches: [main]
    paths:
      - 'app/**'

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}
  NODE_VERSION: '18'

permissions:
  contents: read
  packages: write
  pull-requests: write

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:

  lint:
    name: Lint
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ env.NODE_VERSION }}
          cache: 'npm'
          cache-dependency-path: app/package-lock.json
      - run: npm ci
        working-directory: app
      - run: npm run lint
        working-directory: app

  test:
    name: Test (Node ${{ matrix.node }})
    runs-on: ubuntu-latest
    timeout-minutes: 15
    strategy:
      fail-fast: false
      matrix:
        node: [16, 18, 20]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node }}
          cache: 'npm'
          cache-dependency-path: app/package-lock.json
      - run: npm ci
        working-directory: app
      - run: npm test -- --coverage --coverageReporters=text --coverageReporters=lcov
        working-directory: app
        env:
          NODE_ENV: test
          CI: true
      - uses: actions/upload-artifact@v4
        if: matrix.node == 18
        with:
          name: coverage-report
          path: app/coverage/
          retention-days: 7

  build-and-push:
    name: Build and Push Docker Image
    runs-on: ubuntu-latest
    timeout-minutes: 20
    needs: [lint, test]
    outputs:
      image-tag: ${{ steps.meta.outputs.version }}
      full-image: ${{ steps.meta.outputs.tags }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/metadata-action@v5
        id: meta
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=sha,prefix=sha-,format=short
            type=ref,event=branch
            type=ref,event=pr
            type=raw,value=latest,enable=${{ github.ref == 'refs/heads/main' }}
      - uses: docker/build-push-action@v5
        id: build
        with:
          context: ./app
          file: ./app/Dockerfile
          push: ${{ github.event_name != 'pull_request' }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

> **Note:** GitHub Actions only triggers when files in `app/**` or `.github/workflows/ci.yml` are changed. If you push changes only to `jenkins/Jenkinsfile` or `terraform/`, Actions won't run — this is by design.

---

## Phase 5 — Jenkins: The Full CD Pipeline

`jenkins/Jenkinsfile`:

```groovy
pipeline {

  agent any

  options {
    timeout(time: 30, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20'))
    disableConcurrentBuilds()
    timestamps()
  }

  environment {
    REGISTRY       = "ghcr.io"
    IMAGE_NAME     = "YOUR_GITHUB_USERNAME/devops-node-api"   // CHANGE THIS
    GITHUB_TOKEN   = credentials('github')                    // Secret text credential ID
    APP_SERVER_IP  = credentials('app-server-ip')
    SSH_KEY_ID     = 'app-server-ssh-key'
    APP_PORT       = '3000'
    CONTAINER_NAME = 'devops-node-api'
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.GIT_SHA_SHORT = sh(
            script: 'git rev-parse --short HEAD',
            returnStdout: true
          ).trim()
          env.IMAGE_TAG = "sha-${env.GIT_SHA_SHORT}"
          env.FULL_IMAGE = "${env.REGISTRY}/${env.IMAGE_NAME}:${env.IMAGE_TAG}"
          echo "Deploying image: ${env.FULL_IMAGE}"
          currentBuild.displayName = "#${env.BUILD_NUMBER} — ${env.IMAGE_TAG}"
        }
      }
    }

    // GitHub Actions builds and pushes the image first.
    // Jenkins waits up to 5 minutes for it to appear in GHCR.
    stage('Verify Image in GHCR') {
      steps {
        script {
          sh """
            echo "${GITHUB_TOKEN}" | docker login ${REGISTRY} \
              -u "YOUR_GITHUB_USERNAME" \
              --password-stdin
          """

          def pulled = false
          for (int i = 0; i < 5; i++) {
            def pullResult = sh(
              script: "docker pull ${env.FULL_IMAGE}",
              returnStatus: true
            )
            if (pullResult == 0) {
              pulled = true
              break
            }
            echo "Image not ready yet, waiting 30s... (attempt ${i + 1}/5)"
            sleep 30
          }

          if (!pulled) {
            error("Image ${env.FULL_IMAGE} not found in GHCR after 5 attempts. Did GitHub Actions finish successfully?")
          }

          echo "Image verified: ${env.FULL_IMAGE}"
        }
      }
    }

    stage('Integration Test') {
      steps {
        script {
          sh """
            docker run -d \
              --name ${env.CONTAINER_NAME}-test \
              --rm \
              -p 3001:3000 \
              -e NODE_ENV=test \
              ${env.FULL_IMAGE}
          """
          sh 'sleep 5'

          def healthCheck = sh(
            script: "curl -sf http://localhost:3001/api/health",
            returnStatus: true
          )

          sh "docker stop ${env.CONTAINER_NAME}-test || true"

          if (healthCheck != 0) {
            error('Integration test failed: health endpoint did not respond correctly')
          }

          echo 'Integration test passed!'
        }
      }
      post {
        always {
          sh "docker stop ${env.CONTAINER_NAME}-test || true"
          sh "docker rm ${env.CONTAINER_NAME}-test || true"
        }
      }
    }

    stage('Deploy to App Server') {
      steps {
        sshagent(credentials: [env.SSH_KEY_ID]) {
          script {
            def deployScript = """
              set -ex

              echo "${GITHUB_TOKEN}" | docker login ${REGISTRY} \\
                -u "YOUR_GITHUB_USERNAME" \\
                --password-stdin

              docker pull ${env.FULL_IMAGE}

              docker stop ${env.CONTAINER_NAME} || true
              docker rm   ${env.CONTAINER_NAME} || true

              docker run -d \\
                --name ${env.CONTAINER_NAME} \\
                --restart unless-stopped \\
                -p ${APP_PORT}:3000 \\
                -e NODE_ENV=production \\
                -e APP_VERSION=${env.IMAGE_TAG} \\
                ${env.FULL_IMAGE}

              sleep 5

              curl -sf http://localhost:${APP_PORT}/api/health || exit 1

              docker images ${REGISTRY}/${IMAGE_NAME} --format '{{.ID}}' | tail -n +4 | xargs -r docker rmi || true

              echo "Deploy successful!"
            """

            sh """
              ssh -o StrictHostKeyChecking=no ec2-user@${APP_SERVER_IP} '${deployScript}'
            """

            currentBuild.description = "Deployed ${env.IMAGE_TAG} to ${APP_SERVER_IP}"
          }
        }
      }
    }

    stage('Smoke Test') {
      steps {
        script {
          def smokeTest = sh(
            script: "curl -sf http://${APP_SERVER_IP}:${APP_PORT}/api/health",
            returnStatus: true
          )

          if (smokeTest != 0) {
            error('Smoke test failed: deployed app is not responding!')
          }

          def response = sh(
            script: "curl -s http://${APP_SERVER_IP}:${APP_PORT}/api/health",
            returnStdout: true
          ).trim()

          echo "Smoke test passed! App response: ${response}"
        }
      }
    }

  } // end stages

  post {
    success {
      echo "DEPLOYMENT SUCCESSFUL — ${env.FULL_IMAGE} deployed to ${env.APP_SERVER_IP}"
    }
    failure {
      echo "DEPLOYMENT FAILED — Check logs above for details"
    }
    always {
      node('built-in') {
        sh 'docker logout ghcr.io || true'
        cleanWs()
      }
    }
  }

}
```


---

## Phase 6 — Connect Everything: The Full Flow

```bash
# Make a change to trigger the full pipeline
cat >> app/src/routes/health.js << 'EOF'

router.get('/ready', (req, res) => {
  res.json({ ready: true, message: 'Application is ready to serve requests' });
});
EOF

git add app/src/routes/health.js
git commit -m "feat: add readiness endpoint"
git push origin main
```

Watch:

1. GitHub → Actions tab → CI workflow (lint → test → build → push to GHCR)
2. Jenkins → detects push via webhook → runs pipeline (checkout → verify → integration test → deploy → smoke test)
3. After both finish: `curl http://YOUR_APP_IP:3000/api/ready`

---




<img width="780" height="250" alt="image" src="https://github.com/user-attachments/assets/1e8a7f3a-47ee-4ee2-acfc-8a9ca411a1be" />

<img width="793" height="540" alt="image" src="https://github.com/user-attachments/assets/f58dc9f0-a152-4cd2-b0fb-a3b205581c38" />




## Phase 7 - Clean everything


**Step 1: Stop the running container on the app server**

bash

```bash
ssh -i ~/.ssh/devops-node-api-key.pem ec2-user@$APP_IP
docker stop devops-node-api
docker rm devops-node-api
exit
```

**Step 2: Destroy all AWS infrastructure with Terraform**

bash

```bash
cd terraform
terraform destroy
# type 'yes' when prompted
# Takes 3-5 minutes
```

**Step 3: Delete the S3 state bucket and DynamoDB table (created manually, must be deleted manually)**

bash

```bash
# Empty the bucket first (required before deletion)
aws s3 rm s3://devops-node-api-terraform-state --recursive

# Delete the bucket
aws s3api delete-bucket \
  --bucket devops-node-api-terraform-state \
  --region us-east-1

# Delete the DynamoDB lock table
aws dynamodb delete-table \
  --table-name terraform-state-lock \
  --region us-east-1
```

**Step 4: Delete the EC2 key pair**

bash

```bash
aws ec2 delete-key-pair --key-name devops-node-api-key
rm ~/.ssh/devops-node-api-key.pem
```

**Step 5: Delete the Docker images from GHCR**

Go to `https://github.com/YOUR_USERNAME?tab=packages` → click `devops-node-api` → Package settings → Delete this package.

**Step 6: Delete IAM user**

bash

```bash
# Detach policies first
aws iam detach-user-policy --user-name terraform-user --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
aws iam detach-user-policy --user-name terraform-user --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam detach-user-policy --user-name terraform-user --policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess
aws iam detach-user-policy --user-name terraform-user --policy-arn arn:aws:iam::aws:policy/AmazonVPCFullAccess

# Delete access keys (list them first)
aws iam list-access-keys --user-name terraform-user
aws iam delete-access-key --user-name terraform-user --access-key-id YOUR_KEY_ID

# Delete the user
aws iam delete-user --user-name terraform-user
```

**Step 7: Verify nothing is left running**

bash

```bash
# Should return empty
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=devops-node-api" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' \
  --output table
```
